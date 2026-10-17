# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_document/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaDocumentWeb.Live.Admin.Dashboard.Home.Index do
  use MishkaCmsCore.ExtensionLiveView

  alias MishkaCmsCore.Accounts.Checks.AccessPermissions
  alias MishkaCmsCore.Accounts.Helper
  alias MishkaCmsCore.Accounts.User
  alias MishkaCmsCore.Runtime.{ExtensionProvision, Site}
  alias MishkaCmsCoreWeb.Live.Admin.Components.ActivityFeed
  alias MishkaCmsCoreWeb.Live.Admin.Components.ExtensionInstallerPanel
  alias MishkaCmsCoreWeb.Live.Admin.Components.KitUpgradePanel
  alias MishkaDocument.Kit
  alias MishkaDocumentWeb.Live.Admin.Dashboard.Home.StatsLive
  alias MishkaGervaz.Table.Web.UrlSync
  alias Phoenix.LiveView.AsyncResult
  require Ash.Query

  @issues_per_page 10

  # Matched to the feed's own panel, so the two read as one control however they are opened.
  @panel_in {"transition-[opacity,transform] ease-out duration-200", "opacity-0 -translate-y-1",
             "opacity-100 translate-y-0"}
  @panel_out {"transition-[opacity,transform] ease-in duration-150", "opacity-100 translate-y-0",
              "opacity-0 -translate-y-1"}

  @issue_events [
    "toggle_issues",
    "toggle_issues_archive_filter",
    "unarchive_issue",
    "permanent_delete_issue"
  ]

  @impl true
  def mount(_params, session, socket) do
    # Loaded once here: the workspaces table asks about each row's actions, and the areas below.
    current_user = AccessPermissions.with_permissions(socket.assigns.current_user)
    master_user? = match?(%User{site_id: nil}, current_user)

    socket =
      socket
      |> assign(:current_user, current_user)
      |> assign(:page_title, gettext("Document Dashboard"))
      |> assign(:master_user?, master_user?)
      |> assign(:workspace_admin?, holds?(current_user, "admin:dashboard:document:workspace"))
      |> assign(:section_admin?, holds?(current_user, "admin:dashboard:document:section"))
      |> assign(:url_state, nil)
      |> assign(:show_issues, false)
      |> assign(:issues_loaded?, false)
      |> assign(:issues_page, 1)
      |> assign(:issues_count, 0)
      |> assign(:issues_loading, AsyncResult.ok(%AsyncResult{}, []))
      |> assign(:issues_archive_status, :active)
      |> stream(:issues, [])
      |> assign_provision(session)
      |> ExtensionInstallerPanel.setup(app: :mishka_document, noun: gettext("documentation"))
      |> then(&ExtensionInstallerPanel.start_on(&1, &1.assigns.provision_site_id))
      |> gate()
      |> KitUpgradePanel.setup(
        bundle: Kit.bundle_path(),
        noun: gettext("document components"),
        pages: &MishkaDocument.Provision.sample_pages/2,
        draft_label: gettext("Documentation sample page")
      )
      |> subscribe_to_pubsub(current_user)
      |> load_counts_async()
      |> then(
        &ActivityFeed.setup(&1, resources: feed_resources(&1), feed_id: "document-activity")
      )

    {:ok, socket}
  end

  @impl true
  def handle_params(params, uri, socket) do
    url_state = UrlSync.decode(params, uri, MishkaDocument.Workspace)
    {:noreply, assign(socket, :url_state, url_state)}
  end

  # `event_log:created` is left to `ActivityFeed.setup/2` — subscribing here too would
  # deliver every event twice.
  # THE GATE, ANSWERED ON EVERY RENDER rather than once at mount: an install, a skip or the badge all
  # change it, and each of them is an event. `MishkaCmsCoreWeb.Live.Admin.Components.ExtensionInstallerPanel`
  # pins the answer once an admin has said, so this follows what they said rather than re-deciding.
  defp gate(socket),
    do: assign(socket, :showing_installer?, ExtensionInstallerPanel.showing_installer?(socket))

  defp subscribe_to_pubsub(socket, %User{site_id: nil}) do
    Phoenix.PubSub.subscribe(MishkaCmsCore.PubSub, "workspace:created")
    Phoenix.PubSub.subscribe(MishkaCmsCore.PubSub, "workspace:updated")
    Phoenix.PubSub.subscribe(MishkaCmsCore.PubSub, "workspace:destroyed")
    Phoenix.PubSub.subscribe(MishkaCmsCore.PubSub, "issue:created")
    Phoenix.PubSub.subscribe(MishkaCmsCore.PubSub, "issue:updated")
    Phoenix.PubSub.subscribe(MishkaCmsCore.PubSub, "issue:destroyed")
    socket
  end

  defp subscribe_to_pubsub(socket, %User{site_id: site_id}) when is_binary(site_id) do
    Phoenix.PubSub.subscribe(MishkaCmsCore.PubSub, "workspace:#{site_id}:created")
    Phoenix.PubSub.subscribe(MishkaCmsCore.PubSub, "workspace:#{site_id}:updated")
    Phoenix.PubSub.subscribe(MishkaCmsCore.PubSub, "workspace:#{site_id}:destroyed")
    Phoenix.PubSub.subscribe(MishkaCmsCore.PubSub, "issue:#{site_id}:created")
    Phoenix.PubSub.subscribe(MishkaCmsCore.PubSub, "issue:#{site_id}:updated")
    Phoenix.PubSub.subscribe(MishkaCmsCore.PubSub, "issue:#{site_id}:destroyed")
    socket
  end

  defp subscribe_to_pubsub(socket, _), do: socket

  defp close_form_modal(socket) do
    js = MishkaCmsCore.CoreComponents.hide_modal("workspace-form-modal")

    push_event(socket, "gervaz:exec-js", %{
      target: "workspace-form-modal",
      js: Jason.encode!(js.ops)
    })
  end

  # The feed's panel and this one are one control: each toggle closes the other on its way in, so the
  # page never stacks two. Both are hidden client-side, a round trip ahead of the server hearing
  # about it, so neither waits on a render to slide away.
  defp toggle_issues(setup) do
    %JS{}
    |> ActivityFeed.close_panel(setup)
    |> JS.toggle(to: "#issues-panel", in: @panel_in, out: @panel_out, time: 200)
    |> JS.push("toggle_issues")
  end

  defp close_issues do
    %JS{}
    |> JS.hide(to: "#issues-panel", transition: @panel_out, time: 150)
    |> JS.push("close_issues")
  end

  @impl true
  def handle_event("toggle_issues", _params, %{assigns: %{show_issues: true}} = socket) do
    {:noreply, close_issues_panel(socket)}
  end

  # THE ISSUES ARE THE SECTION AREA'S, and so is everything this panel does with them: a workspace
  # admin is not shown the button, and a socket that sends its events anyway is told so.
  def handle_event(event, _params, %{assigns: %{section_admin?: false}} = socket)
      when event in @issue_events do
    {:noreply, put_flash(socket, :error, gettext("You are not allowed to manage issues."))}
  end

  def handle_event("toggle_issues", _params, socket) do
    {:noreply,
     socket
     |> assign(:show_issues, true)
     |> load_issues_async(page: 1, reset: true)}
  end

  # The feed's toggle fires this on every one of its opens, whether this panel was open or not, so it
  # closes rather than flips — see `ActivityFeed.close_panel/2` for the other half of the pairing.
  def handle_event("close_issues", _params, socket) do
    {:noreply, close_issues_panel(socket)}
  end

  def handle_event("toggle_issues_archive_filter", %{"status" => "active"}, socket),
    do: {:noreply, filter_issues(socket, :active)}

  def handle_event("toggle_issues_archive_filter", %{"status" => "archived"}, socket),
    do: {:noreply, filter_issues(socket, :archived)}

  def handle_event("toggle_issues_archive_filter", _params, socket), do: {:noreply, socket}

  def handle_event("unarchive_issue", %{"id" => id}, socket) do
    case unarchive_issue(socket.assigns.current_user, id) do
      {:ok, _issue} ->
        {:noreply,
         socket
         |> put_flash(:info, gettext("Issue restored successfully"))
         |> stream_delete(:issues, %{id: id})}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, gettext("Failed to restore issue"))}
    end
  end

  def handle_event("extension_install", params, socket) do
    allowed? = socket.assigns.may_provision?

    {:noreply,
     gate(ExtensionInstallerPanel.install(socket, chosen_site(socket, params), allowed?))}
  end

  def handle_event("extension_site", params, socket) do
    {:noreply, gate(ExtensionInstallerPanel.choose(socket, chosen_site(socket, params)))}
  end

  # THE ANSWER TO A CLASH, which is the same install with the addresses the admin chose — so a
  # second run writes what the first could not and leaves everything else exactly as it was.
  def handle_event("extension_retry", params, socket) do
    allowed? = socket.assigns.may_provision?
    answers = Map.take(params, ["paths", "prefix"])

    {:noreply,
     gate(ExtensionInstallerPanel.install(socket, chosen_site(socket, params), allowed?, answers))}
  end

  def handle_event("extension_open", _params, socket) do
    {:noreply, gate(ExtensionInstallerPanel.open(socket))}
  end

  def handle_event("extension_skip", _params, socket) do
    {:noreply, gate(ExtensionInstallerPanel.close(socket))}
  end

  # THE SAME TWO QUESTIONS REPAIR ASKS, and the same answers: which site, and may this
  # admin write its runtime. Everything after them — what is outdated, what carries an edit, what is
  # written — is `MishkaCmsCoreWeb.Live.Admin.Components.KitUpgradePanel`, so the blog dashboard says
  # all of it in the same words.
  # ONE PICKER FOR THE WHOLE MODAL, so the Repair button under the standings writes to the site
  # those standings are about. Both halves are told the same answer here rather than each keeping
  # its own, which is how a master could read one site and repair another.
  def handle_event("kit_check", params, socket) do
    site_id = chosen_site(socket, params)

    {:noreply,
     socket
     |> ExtensionInstallerPanel.choose(site_id)
     |> KitUpgradePanel.check(site_id, socket.assigns.may_provision?)}
  end

  def handle_event("kit_upgrade", %{"mode" => mode}, socket) do
    {:noreply, KitUpgradePanel.upgrade(socket, mode, socket.assigns.may_provision?)}
  end

  def handle_event("page_drafts", _params, socket) do
    {:noreply, KitUpgradePanel.offer(socket, socket.assigns.may_provision?)}
  end

  def handle_event("permanent_delete_issue", %{"id" => id}, socket) do
    case permanent_delete_issue(socket.assigns.current_user, id) do
      {:ok, _issue} ->
        {:noreply,
         socket
         |> put_flash(:info, gettext("Issue permanently deleted"))
         |> stream_delete(:issues, %{id: id})}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, gettext("Failed to permanently delete issue"))}
    end
  end

  # Flash messages from MishkaGervaz components
  @impl true
  def handle_info({:put_flash, kind, message}, socket) do
    {:noreply, put_flash(socket, kind, message)}
  end

  @impl true
  def handle_info({:form_saved, :create, _result}, socket) do
    {:noreply,
     socket
     |> close_form_modal()
     |> put_flash(:info, gettext("Workspace created successfully"))}
  end

  @impl true
  def handle_info({:form_saved, :update, _result}, socket) do
    {:noreply,
     socket
     |> close_form_modal()
     |> put_flash(:info, gettext("Workspace updated successfully"))}
  end

  @impl true
  def handle_info({:form_cancelled, _resource}, socket) do
    {:noreply, close_form_modal(socket)}
  end

  # PubSub: workspace changes
  @impl true
  def handle_info(
        %Phoenix.Socket.Broadcast{
          topic: "workspace" <> _,
          payload: %Ash.Notifier.Notification{} = notification
        },
        socket
      ) do
    send_update(MishkaGervaz.Table.Web.Live,
      id: "workspaces-table",
      pubsub_notification: notification
    )

    send_update(StatsLive, id: "document-stats", refresh: true)

    {:noreply, socket}
  end

  # PubSub: issue unarchive
  @impl true
  def handle_info(
        %Phoenix.Socket.Broadcast{
          topic: "issue" <> _,
          payload: %Ash.Notifier.Notification{
            data: issue,
            action: %{name: action_name}
          }
        },
        socket
      )
      when action_name in [:unarchive, :master_unarchive] do
    %{current_user: user, issues_archive_status: status} = socket.assigns

    socket =
      case {socket.assigns.show_issues, status, issue_visible_to_user?(issue, user)} do
        {false, _, _} ->
          socket

        {true, :archived, _} ->
          stream_delete(socket, :issues, issue)

        {true, :active, true} ->
          loaded = load_issue_relationships(issue, user)
          stream_insert(socket, :issues, loaded, at: 0)

        _ ->
          socket
      end

    {:noreply, load_counts_async(socket)}
  end

  # PubSub: issue permanent_destroy
  @impl true
  def handle_info(
        %Phoenix.Socket.Broadcast{
          topic: "issue" <> _,
          payload: %Ash.Notifier.Notification{
            data: issue,
            action: %{name: action_name}
          }
        },
        socket
      )
      when action_name in [:permanent_destroy, :master_permanent_destroy] do
    socket =
      if socket.assigns.show_issues, do: stream_delete(socket, :issues, issue), else: socket

    {:noreply, load_counts_async(socket)}
  end

  # PubSub: issue created
  @impl true
  def handle_info(
        %Phoenix.Socket.Broadcast{
          topic: "issue" <> _,
          payload: %Ash.Notifier.Notification{
            data: issue,
            action: %{type: :create}
          }
        },
        socket
      ) do
    user = socket.assigns.current_user
    archive_status = socket.assigns.issues_archive_status

    socket =
      if socket.assigns.show_issues && archive_status == :active &&
           issue_visible_to_user?(issue, user) do
        loaded = load_issue_relationships(issue, user)
        stream_insert(socket, :issues, loaded, at: 0)
      else
        socket
      end

    {:noreply,
     if(issue_visible_to_user?(issue, user), do: load_counts_async(socket), else: socket)}
  end

  # PubSub: issue updated
  @impl true
  def handle_info(
        %Phoenix.Socket.Broadcast{
          topic: "issue" <> _,
          payload: %Ash.Notifier.Notification{
            data: issue,
            action: %{type: :update}
          }
        },
        socket
      ) do
    user = socket.assigns.current_user
    archive_status = socket.assigns.issues_archive_status

    socket =
      if socket.assigns.show_issues && issue_visible_to_user?(issue, user) do
        is_archived = !is_nil(issue.archived_at)

        cond do
          is_archived && archive_status == :active ->
            stream_delete(socket, :issues, issue)

          !is_archived && archive_status == :archived ->
            stream_delete(socket, :issues, issue)

          true ->
            loaded = load_issue_relationships(issue, user)
            stream_insert(socket, :issues, loaded)
        end
      else
        socket
      end

    {:noreply,
     if(issue_visible_to_user?(issue, user), do: load_counts_async(socket), else: socket)}
  end

  # PubSub: issue destroyed (soft delete via AshArchival)
  @impl true
  def handle_info(
        %Phoenix.Socket.Broadcast{
          topic: "issue" <> _,
          payload: %Ash.Notifier.Notification{
            data: issue,
            action: %{type: :destroy, name: action_name}
          }
        },
        socket
      )
      when action_name not in [:permanent_destroy, :master_permanent_destroy] do
    user = socket.assigns.current_user
    archive_status = socket.assigns.issues_archive_status

    socket =
      if socket.assigns.show_issues do
        socket = stream_delete(socket, :issues, issue)

        if issue_visible_to_user?(issue, user) && archive_status == :archived do
          loaded = load_issue_relationships(issue, user)
          stream_insert(socket, :issues, loaded, at: 0)
        else
          socket
        end
      else
        socket
      end

    {:noreply,
     if(issue_visible_to_user?(issue, user), do: load_counts_async(socket), else: socket)}
  end

  # Any other broadcast this page subscribes to but does not draw.
  def handle_info(%Phoenix.Socket.Broadcast{}, socket), do: {:noreply, socket}

  @impl true
  def handle_async(:load_issues, {:ok, {page, results, _has_more, reset}}, socket) do
    socket =
      socket
      |> assign(:issues_page, page)
      |> assign(:issues_loaded?, true)
      |> assign(:issues_loading, AsyncResult.ok(socket.assigns.issues_loading, results))
      |> stream(:issues, results, reset: reset)

    {:noreply, socket}
  end

  @doc """
  A failed fetch still retires the skeleton.

  `issues_loaded?` says the panel has looked, not that it found anything — left false, the skeleton
  would pulse over a fetch that is never coming back.
  """
  def handle_async(:load_issues, {:exit, reason}, socket) do
    {:noreply,
     socket
     |> assign(:issues_loaded?, true)
     |> assign(:issues_loading, AsyncResult.failed(socket.assigns.issues_loading, reason))}
  end

  @impl true
  def handle_async(:load_counts, {:ok, issues_count}, socket) do
    {:noreply, assign(socket, :issues_count, issues_count)}
  end

  # A badge is decoration; if the count fails the panel still works, so it keeps its last figure.
  def handle_async(:load_counts, {:exit, _reason}, socket), do: {:noreply, socket}

  # A MASTER PICKS THE SITE; A TENANT ADMIN HAS ONE. The picker's options are the sites this
  # deployment has, and the one the admin is looking at — the host their request resolved to — is
  # preselected, because that is the site they mean. Read from the table rather than from
  # `SiteState`'s cache: a site created a moment ago has to be offerable at once, and the button
  # exists precisely for a site that has just appeared.
  defp assign_provision(socket, session) do
    user = socket.assigns[:current_user]
    allowed? = may_provision?(user)

    {sites, chosen} =
      cond do
        not allowed? -> {[], nil}
        is_binary(user.site_id) -> {[], user.site_id}
        Helper.master_user?(user) -> offered_sites(session)
        true -> {[], nil}
      end

    assign(socket,
      may_provision?: allowed?,
      provision_sites: sites,
      provision_site_id: chosen,
      provision_site_name: (sites == [] && site_name(chosen)) || nil
    )
  end

  # WHAT TO CALL THE SITE WHEN THERE IS NO PICKER. A tenant admin is offered no list — their site
  # is the only one this page will ever write to — so the modal says which site that is instead of
  # drawing a dropdown that cannot move.
  defp site_name(site_id) when is_binary(site_id) do
    Site
    |> Ash.Query.for_read(:read_any, %{}, authorize?: false)
    |> Ash.Query.filter(id == ^site_id)
    |> Ash.Query.select([:name])
    |> Ash.read_one(authorize?: false)
    |> case do
      {:ok, %{name: name}} -> name
      _no_such_site -> nil
    end
  end

  defp site_name(_no_site), do: nil

  defp offered_sites(session) do
    sites =
      Site
      |> Ash.Query.for_read(:read_any, %{}, authorize?: false)
      |> Ash.Query.filter(active == true)
      |> Ash.Query.sort(name: :asc)
      |> Ash.Query.select([:id, :name])
      |> Ash.read!(authorize?: false)
      |> Enum.map(&{&1.name, &1.id})

    ids = Enum.map(sites, &elem(&1, 1))

    current =
      case session do
        %{"current_site" => %{id: id}} -> id
        _no_site_in_session -> nil
      end

    {sites, (current in ids && current) || List.first(ids)}
  end

  # NEVER THE PARAMETER ON ITS OWN. A tenant admin provisions their own site whatever the form said,
  # and a master's choice has to be one this page offered — a `site_id` typed into a socket message
  # is not an authorization to write pages to that site.
  #
  # A SITE THAT WAS NOT OFFERED IS NOT A SITE NOBODY PICKED. They are two different answers and they
  # get two different ones back: a form that submitted nothing is a form to fill in, while a site id
  # this page never listed is a refusal, and telling somebody to choose a site when they did choose
  # one reads as a bug in the page rather than as the check it is.
  defp chosen_site(%{assigns: %{current_user: %{site_id: site_id}}}, _params)
       when is_binary(site_id),
       do: site_id

  defp chosen_site(%{assigns: %{provision_sites: sites}}, params) do
    case params["site_id"] do
      asked when is_binary(asked) and asked != "" ->
        Enum.find_value(sites, :refused, fn {_name, id} -> id == asked && id end)

      _nothing_chosen ->
        :none
    end
  end

  # EVERY AREA ASKED ON ITS OWN: holding all of them is what the button needs, and one list of names
  # is met by holding any.
  # WHAT THE BUTTON WRITES IS WHAT GATES IT, as the provision itself asks: setting a site up,
  # checking it and repairing it write the site's pages and components, save the snippet the page
  # builder offers, and read the site. The answer is kept on the socket and every handler reads it,
  # because hiding a button hides nothing from a socket.
  defp may_provision?(user),
    do: ExtensionProvision.allowed?(MishkaDocument.Provision.manifest(), user)

  defp holds?(user, permission),
    do: AccessPermissions.match?(user, %{}, permissions: [permission])

  # The feed follows the areas the admin holds, as the event log does: a workspace admin is not shown
  # who edited a section. The page itself needs one of the two, so the list is never empty — an
  # empty one is every resource.
  defp feed_resources(%{assigns: assigns}) do
    Enum.flat_map(
      [
        {assigns.workspace_admin?, :workspace},
        {assigns.section_admin?, :section}
      ],
      fn
        {true, area} -> MishkaDocument.EventLog.logged(area)
        {false, _area} -> []
      end
    )
  end

  # The badge on the toggle button, so a closed panel still says how much is behind it. A COUNT
  # over the same read the panel pages through, off the render path.
  defp load_counts_async(%{assigns: %{section_admin?: false}} = socket), do: socket

  defp load_counts_async(socket) do
    %{current_user: current_user, issues_archive_status: archive_status} = socket.assigns

    if connected?(socket) do
      MishkaGervaz.Messages.start_async(socket, :load_counts, fn ->
        count_issues(current_user, archive_status)
      end)
    else
      socket
    end
  end

  defp count_issues(current_user, archive_status) do
    {action, query_opts} =
      case {current_user, archive_status} do
        {%User{site_id: nil}, :archived} -> {:master_archived, [actor: current_user]}
        {%User{site_id: nil}, _} -> {:master_read, [actor: current_user]}
        {%User{site_id: id}, :archived} -> {:archived, [actor: current_user, tenant: id]}
        {%User{site_id: id}, _} -> {:read, [actor: current_user, tenant: id]}
      end

    MishkaDocument.Issue
    |> Ash.Query.for_read(action, %{}, query_opts)
    |> Ash.count!(query_opts)
  end

  # A closed panel stops taking live issue updates — every `issue:*` clause guards on `show_issues` —
  # so its rows are only good while it is open. Dropping them on close makes the next open refetch
  # instead of showing a list that quietly stopped tracking; `issues_loaded?` goes with them, so that
  # open gets its skeleton back.
  defp filter_issues(socket, status) do
    socket
    |> assign(:issues_archive_status, status)
    |> assign(:issues_page, 1)
    |> load_issues_async(page: 1, reset: true)
    |> load_counts_async()
  end

  defp close_issues_panel(%{assigns: %{show_issues: false}} = socket), do: socket

  defp close_issues_panel(socket) do
    socket
    |> assign(:show_issues, false)
    |> assign(:issues_loaded?, false)
    |> stream(:issues, [], reset: true)
  end

  defp load_issues_async(socket, opts) do
    %{
      current_user: current_user,
      issues_archive_status: archive_status
    } = socket.assigns

    page = Keyword.get(opts, :page, 1)
    reset = Keyword.get(opts, :reset, false)

    socket
    |> assign(:issues_loading, AsyncResult.loading())
    |> MishkaGervaz.Messages.start_async(:load_issues, fn ->
      {action, query_opts, loads} =
        case {current_user, archive_status} do
          {%User{site_id: nil}, :archived} ->
            {:master_archived, [actor: current_user],
             [:site, :reporter, :reporter_master?, :master_note, :master_section, :comments_count]}

          {%User{site_id: nil}, _} ->
            {:master_read, [actor: current_user],
             [:site, :reporter, :reporter_master?, :master_note, :master_section, :comments_count]}

          {%User{site_id: site_id}, :archived} ->
            {:archived, [actor: current_user, tenant: site_id],
             [:site, :reporter, :reporter_master?, :note, :section, :comments_count]}

          {%User{site_id: site_id}, _} ->
            {:read, [actor: current_user, tenant: site_id],
             [:site, :reporter, :reporter_master?, :note, :section, :comments_count]}
        end

      page_result =
        MishkaDocument.Issue
        |> Ash.Query.for_read(action, %{}, query_opts)
        |> Ash.Query.load(loads)
        |> Ash.Query.sort(inserted_at: :desc)
        |> Ash.read!(page: [offset: (page - 1) * @issues_per_page, limit: @issues_per_page])

      {page, page_result.results, page_result.more?, reset}
    end)
  end

  defp unarchive_issue(%User{site_id: nil} = user, id) do
    case Ash.get(MishkaDocument.Issue, id, action: :master_get_archived, actor: user) do
      {:ok, issue} when not is_nil(issue) ->
        issue
        |> Ash.Changeset.for_update(:master_unarchive, %{}, actor: user)
        |> Ash.update()

      _ ->
        {:error, :not_found}
    end
  end

  defp unarchive_issue(%User{site_id: site_id} = user, id) when is_binary(site_id) do
    case Ash.get(MishkaDocument.Issue, id,
           action: :get_archived,
           tenant: site_id,
           actor: user
         ) do
      {:ok, issue} when not is_nil(issue) ->
        issue
        |> Ash.Changeset.for_update(:unarchive, %{}, tenant: site_id, actor: user)
        |> Ash.update()

      _ ->
        {:error, :not_found}
    end
  end

  defp permanent_delete_issue(%User{site_id: nil} = user, id) do
    case Ash.get(MishkaDocument.Issue, id, action: :master_get_archived, actor: user) do
      {:ok, issue} when not is_nil(issue) ->
        Ash.destroy(issue,
          action: :master_permanent_destroy,
          actor: user,
          return_destroyed?: true
        )

      _ ->
        {:error, :not_found}
    end
  end

  defp permanent_delete_issue(%User{site_id: site_id} = user, id) when is_binary(site_id) do
    case Ash.get(MishkaDocument.Issue, id,
           action: :get_archived,
           tenant: site_id,
           actor: user
         ) do
      {:ok, issue} when not is_nil(issue) ->
        Ash.destroy(issue,
          action: :permanent_destroy,
          tenant: site_id,
          actor: user,
          return_destroyed?: true
        )

      _ ->
        {:error, :not_found}
    end
  end

  # A load under the issue's site finds no master's account, so a master reads the reporter on its
  # own, with no tenant.
  defp load_issue_relationships(issue, %User{site_id: nil} = user) do
    issue
    |> Ash.load!(
      [:site, :reporter_master?, :master_note, :master_section, :comments_count],
      actor: user,
      tenant: issue.site_id
    )
    |> Map.put(:reporter, reporter_for_master(issue.reporter_id, user))
  end

  defp load_issue_relationships(issue, %User{site_id: site_id} = user) when is_binary(site_id) do
    Ash.load!(
      issue,
      [:site, :reporter, :reporter_master?, :note, :section, :comments_count],
      actor: user,
      tenant: site_id
    )
  end

  defp reporter_for_master(nil, _user), do: nil

  defp reporter_for_master(reporter_id, user) do
    case Ash.get(User, reporter_id, action: :master_get, actor: user) do
      {:ok, reporter} -> reporter
      {:error, _reason} -> nil
    end
  end

  defp issue_visible_to_user?(_issue, %User{site_id: nil}), do: true
  defp issue_visible_to_user?(issue, %User{site_id: site_id}), do: issue.site_id == site_id

  @doc """
  How many issues the panel is actually showing — the page it has paged to, capped by how many exist.

  The badge reports what is under the button, not how many issues the site has: a button reading the
  full total promises a list it does not open.
  """
  def issues_shown(total, page), do: shown(total, page, @issues_per_page)

  defp shown(total, page, per_page) when is_integer(total) and is_integer(page),
    do: min(total, page * per_page)

  defp shown(_total, _page, per_page), do: per_page

  @doc "The pill an issue's status wears. Green resolved, amber open, grey closed."
  def issue_status_color(:open), do: "bg-[#fbf1df] text-[#a5691a]"
  def issue_status_color(:in_progress), do: "bg-[#eeedfb] text-[#4f4bcc]"
  def issue_status_color(:resolved), do: "bg-[#e6f6ee] text-[#177a53]"
  def issue_status_color(:closed), do: "bg-[#f2f1ec] text-[#6d6a63]"
  def issue_status_color(_), do: "bg-[#f2f1ec] text-[#6d6a63]"

  @doc "The pill an issue's type wears. The design names `broken_link` red; the rest follow its palette."
  def issue_type_color(:typo), do: "bg-[#eeedfb] text-[#4f4bcc]"
  def issue_type_color(:broken_link), do: "bg-[#fbe9e7] text-[#b3433a]"
  def issue_type_color(:incorrect_content), do: "bg-[#fbf1df] text-[#a5691a]"
  def issue_type_color(:suggestion), do: "bg-[#e6f1fa] text-[#276fa3]"
  def issue_type_color(:review_feedback), do: "bg-[#fbe8f0] text-[#a83f6d]"
  def issue_type_color(_), do: "bg-[#f2f1ec] text-[#6d6a63]"

  @doc """
  The icon tile an issue wears. Keyed off *severity* — how urgent the status is — not the type, so an
  open issue reads amber whatever kind it is.
  """
  def issue_severity_color(:open), do: "bg-[#fbf1df] text-[#cf8a24]"
  def issue_severity_color(:resolved), do: "bg-[#e6f6ee] text-[#1f9d6b]"
  def issue_severity_color(_), do: "bg-[#f2f1ec] text-[#8a877f]"
end
