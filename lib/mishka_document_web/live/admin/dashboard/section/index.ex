defmodule MishkaDocumentWeb.Live.Admin.Dashboard.Section.Index do
  use MishkaCmsCore.ExtensionLiveView

  alias MishkaCmsCore.Accounts.User
  alias MishkaCmsCore.Accounts.Checks.AccessPermissions
  alias MishkaCmsCore.Localized
  alias MishkaDocumentWeb.Templates.DocumentCard
  alias MishkaDocumentWeb.Templates.DocumentSection
  alias MishkaGervaz.Table.Web.UrlSync
  alias Phoenix.LiveView.AsyncResult
  require Ash.Query

  @activity_logs_limit 5
  @section_activity_logs_limit 3

  @doc """
  `/document/sections/workspace/:workspace_id` names a workspace, not a version, so it resolves the
  version to show and hands off to the route that shows it.

  The hand-off is `push_navigate/2`, not `redirect/2`: both ends are live routes in the same session,
  so this stays a client-side navigation. `redirect/2` would tear the page down and reload it — the
  caller followed a `<.link navigate>` precisely to avoid that. On a disconnected mount (someone typed
  the URL) it still degrades to an ordinary HTTP redirect.

  A workspace with no version sends a workspace admin to its versions page to add one, and anyone
  else to the documents Home, since the versions page is the workspace area's.
  """
  @impl true
  def mount(%{"workspace_id" => workspace_id}, _session, socket) do
    current_user = socket.assigns.current_user

    case find_default_version_id_for_workspace(current_user, workspace_id) do
      {:ok, version_id} ->
        {:ok, push_navigate(socket, to: "/admin/dashboard/document/sections/#{version_id}")}

      :error ->
        {:ok,
         socket
         |> put_flash(:error, gettext("No versions found for this workspace"))
         |> push_navigate(to: no_version_path(current_user, workspace_id))}
    end
  end

  def mount(%{"workspace_version_id" => workspace_version_id}, _session, socket) do
    current_user = socket.assigns.current_user
    master_user? = match?(%User{site_id: nil}, current_user)

    socket =
      socket
      |> assign(:page_title, gettext("Workspace Sections"))
      |> assign(:master_user?, master_user?)
      |> assign(:workspace_admin?, workspace_admin?(current_user))
      |> assign(:workspace_version_id, workspace_version_id)
      |> assign(:workspace, nil)
      |> assign(:workspace_id, nil)
      |> assign(:workspace_loading, AsyncResult.loading())
      |> assign(:version_ids, [])
      |> assign(:selected_version, nil)
      |> assign(:selected_version_id, workspace_version_id)
      |> assign(:front_page, nil)
      |> assign(:url_state, nil)
      |> assign(:show_note_form, false)
      |> assign(:editing_note_id, nil)
      |> assign(:note_section_id, nil)
      |> assign(:expanded_section_id, nil)
      |> assign(:expanded_section_notes, %{})
      |> assign(:section_notes_loading, %{})
      |> assign(:section_activity_logs, %{})
      |> assign(:section_activity_logs_loading, %{})
      |> assign(:activity_logs, [])
      |> assign(:activity_logs_loading, AsyncResult.loading())

    socket =
      if connected?(socket) do
        load_workspace_by_version_async(socket, workspace_version_id)
      else
        socket
      end

    {:ok, socket}
  end

  @impl true
  def handle_params(params, uri, socket) do
    url_state = UrlSync.decode(params, uri, MishkaDocument.Section)

    version_from_path =
      case url_state do
        %{path_params: %{workspace_version_id: id}} when is_binary(id) and id != "" -> id
        _ -> nil
      end

    socket =
      if version_from_path && version_from_path != socket.assigns.selected_version_id do
        versions =
          if socket.assigns.workspace,
            do: get_versions(socket.assigns.workspace, socket.assigns.master_user?),
            else: []

        selected_version = Enum.find(versions, &(&1.id == version_from_path))

        socket
        |> assign(:selected_version, selected_version)
        |> assign(:selected_version_id, version_from_path)
        |> assign(:workspace_version_id, version_from_path)
        |> load_front_page_async()
      else
        socket
      end

    {:noreply, assign(socket, :url_state, url_state)}
  end

  defp no_version_path(user, workspace_id) do
    if workspace_admin?(user),
      do: "/admin/dashboard/document/workspace-version/#{workspace_id}",
      else: "/admin/dashboard/document"
  end

  defp workspace_admin?(user),
    do: AccessPermissions.match?(user, %{}, permissions: ["admin:dashboard:document:workspace"])

  defp subscribe_to_pubsub(socket, %User{site_id: nil}, _workspace_id) do
    Phoenix.PubSub.subscribe(MishkaCmsCore.PubSub, "note:created")
    Phoenix.PubSub.subscribe(MishkaCmsCore.PubSub, "note:updated")
    Phoenix.PubSub.subscribe(MishkaCmsCore.PubSub, "note:destroyed")

    Phoenix.PubSub.subscribe(MishkaCmsCore.PubSub, "event_log:created")
    socket
  end

  defp subscribe_to_pubsub(socket, %User{site_id: site_id}, _workspace_id)
       when is_binary(site_id) do
    Phoenix.PubSub.subscribe(MishkaCmsCore.PubSub, "note:#{site_id}:created")
    Phoenix.PubSub.subscribe(MishkaCmsCore.PubSub, "note:#{site_id}:updated")
    Phoenix.PubSub.subscribe(MishkaCmsCore.PubSub, "note:#{site_id}:destroyed")

    Phoenix.PubSub.subscribe(MishkaCmsCore.PubSub, "event_log:created")
    socket
  end

  defp subscribe_to_pubsub(socket, _, _), do: socket

  @impl true
  def handle_event("new_note", %{"section-id" => section_id}, socket) do
    {:noreply,
     socket
     |> assign(:show_note_form, true)
     |> assign(:editing_note_id, nil)
     |> assign(:note_section_id, section_id)}
  end

  @impl true
  def handle_event("edit_note", %{"id" => id}, socket) do
    case get_note(socket.assigns.current_user, id) do
      {:ok, note} when not is_nil(note) ->
        {:noreply,
         socket
         |> assign(:show_note_form, true)
         |> assign(:editing_note_id, note.id)
         |> assign(:note_section_id, note.section_id)}

      _ ->
        {:noreply, put_flash(socket, :error, gettext("Note not found"))}
    end
  end

  @impl true
  def handle_event("cancel_note_form", _params, socket) do
    {:noreply,
     socket
     |> assign(:show_note_form, false)
     |> assign(:editing_note_id, nil)
     |> assign(:note_section_id, nil)}
  end

  @impl true
  def handle_event("change_version", %{"version_id" => version_id}, socket) do
    {:noreply, push_patch(socket, to: "/admin/dashboard/document/sections/#{version_id}")}
  end

  @impl true
  def handle_info({:form_saved, action, %MishkaDocument.Note{} = note}, socket)
      when action in [:create, :update] do
    section_id = note.section_id

    socket =
      socket
      |> put_flash(:info, note_saved_message(action))
      |> assign(:show_note_form, false)
      |> assign(:editing_note_id, nil)
      |> assign(:note_section_id, nil)
      |> close_form_modal("note-form-modal")

    socket =
      if socket.assigns.expanded_section_id == section_id && section_id do
        load_notes_for_section(socket, section_id)
      else
        socket
      end

    {:noreply, socket}
  end

  @impl true
  def handle_info({:form_saved, :create, _result}, socket) do
    {:noreply,
     socket
     |> close_form_modal("section-form-modal")
     |> put_flash(:info, gettext("Section created successfully"))}
  end

  @impl true
  def handle_info({:form_saved, :update, _result}, socket) do
    {:noreply,
     socket
     |> close_form_modal("section-form-modal")
     |> put_flash(:info, gettext("Section updated successfully"))}
  end

  @impl true
  def handle_info({:form_cancelled, MishkaDocument.Note}, socket) do
    {:noreply,
     socket
     |> assign(:show_note_form, false)
     |> assign(:editing_note_id, nil)
     |> assign(:note_section_id, nil)
     |> close_form_modal("note-form-modal")}
  end

  @impl true
  def handle_info({:form_cancelled, MishkaDocument.Section}, socket) do
    {:noreply, close_form_modal(socket, "section-form-modal")}
  end

  @impl true
  def handle_info({:row_action, "manage_notes", %{"id" => section_id}}, socket) do
    {:noreply,
     socket
     |> assign(:show_note_form, true)
     |> assign(:editing_note_id, nil)
     |> assign(:note_section_id, section_id)}
  end

  @impl true
  def handle_info({:expand_row, id}, socket) do
    socket =
      socket
      |> assign(:expanded_section_id, id)
      |> load_notes_for_section(id)
      |> load_section_activity_logs_async(id)

    {:noreply, socket}
  end

  @impl true
  def handle_info({:put_flash, kind, message}, socket) do
    {:noreply, put_flash(socket, kind, message)}
  end

  @impl true
  def handle_info(
        %Phoenix.Socket.Broadcast{
          topic: "note" <> _,
          payload: %Ash.Notifier.Notification{data: note, action: %{type: :create}}
        },
        socket
      ) do
    section_id = note.section_id
    expanded = socket.assigns.expanded_section_notes

    socket =
      if Map.has_key?(expanded, section_id) do
        socket
        |> add_note_to_expanded(section_id, note)
        |> maybe_resend_expanded_html(section_id)
      else
        socket
      end

    {:noreply, socket}
  end

  @impl true
  def handle_info(
        %Phoenix.Socket.Broadcast{
          topic: "note" <> _,
          payload: %Ash.Notifier.Notification{
            data: note,
            action: %{name: action_name}
          }
        },
        socket
      )
      when action_name in [:unarchive, :master_unarchive] do
    section_id = note.section_id
    expanded = socket.assigns.expanded_section_notes

    socket =
      if Map.has_key?(expanded, section_id) do
        socket
        |> add_note_to_expanded(section_id, note)
        |> maybe_resend_expanded_html(section_id)
      else
        socket
      end

    {:noreply, socket}
  end

  @impl true
  def handle_info(
        %Phoenix.Socket.Broadcast{
          topic: "note" <> _,
          payload: %Ash.Notifier.Notification{
            data: note,
            action: %{type: :update, name: action_name}
          }
        },
        socket
      )
      when action_name in [:update, :master_update] do
    section_id = note.section_id
    expanded = socket.assigns.expanded_section_notes

    socket =
      if Map.has_key?(expanded, section_id) && is_nil(note.archived_at) do
        socket
        |> update_note_in_expanded(section_id, note)
        |> maybe_resend_expanded_html(section_id)
      else
        socket
      end

    {:noreply, socket}
  end

  @impl true
  def handle_info(
        %Phoenix.Socket.Broadcast{
          topic: "note" <> _,
          payload: %Ash.Notifier.Notification{
            data: note,
            action: %{type: :destroy, name: action_name}
          }
        },
        socket
      )
      when action_name in [:destroy, :master_destroy] do
    section_id = note.section_id
    expanded = socket.assigns.expanded_section_notes

    socket =
      if Map.has_key?(expanded, section_id) do
        socket
        |> remove_note_from_expanded(section_id, note.id)
        |> maybe_resend_expanded_html(section_id)
      else
        socket
      end

    {:noreply, socket}
  end

  @impl true
  def handle_info(
        %Phoenix.Socket.Broadcast{
          topic: "note" <> _,
          payload: %Ash.Notifier.Notification{
            data: note,
            action: %{name: action_name}
          }
        },
        socket
      )
      when action_name in [:permanent_destroy, :master_permanent_destroy] do
    section_id = note.section_id

    socket =
      socket
      |> remove_note_from_expanded(section_id, note.id)
      |> maybe_resend_expanded_html(section_id)

    {:noreply, socket}
  end

  @impl true
  def handle_info(
        %Phoenix.Socket.Broadcast{
          topic: "event_log:created",
          payload: %Ash.Notifier.Notification{data: event}
        },
        socket
      ) do
    if event_belongs_to_workspace?(event, socket) do
      # Read the actor again as the viewer, with no site, or drop it: the broadcast's was read
      # without authorization, and under the event's site a master's account is not found.
      loaded_event =
        event
        |> Ash.Resource.put_metadata(:tenant, nil)
        |> Ash.load([:actor, :actor_master?], actor: socket.assigns.current_user)
        |> case do
          {:ok, e} -> e
          _ -> %{event | actor: nil}
        end

      updated_logs = with_event(socket.assigns.activity_logs, loaded_event, @activity_logs_limit)

      socket =
        socket
        |> assign(:activity_logs, updated_logs)
        |> maybe_update_section_activity_logs(loaded_event)

      {:noreply, socket}
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_info(
        %Phoenix.Socket.Broadcast{
          topic: "section" <> _,
          payload: %Ash.Notifier.Notification{} = notification
        },
        socket
      ) do
    send_update(MishkaGervaz.Table.Web.Live,
      id: "sections-table",
      pubsub_notification: notification
    )

    {:noreply, load_front_page_async(socket)}
  end

  @impl true
  def handle_info(_msg, socket), do: {:noreply, socket}

  defp note_saved_message(:create), do: gettext("Note created successfully")
  defp note_saved_message(:update), do: gettext("Note updated successfully")

  defp close_form_modal(socket, modal_id) do
    js = MishkaCmsCore.CoreComponents.hide_modal(modal_id)

    Phoenix.LiveView.push_event(socket, "gervaz:exec-js", %{
      target: modal_id,
      js: Jason.encode!(js.ops)
    })
  end

  @impl true
  def handle_async(:load_workspace, {:ok, {workspace, version}}, socket) do
    current_user = socket.assigns.current_user

    if is_nil(workspace) and !socket.assigns.master_user? do
      {:noreply,
       socket
       |> put_flash(:error, gettext("Workspace not found or not accessible"))
       |> push_navigate(to: "/admin/dashboard/document")}
    else
      {version_ids, selected_version} =
        if workspace do
          versions = get_versions(workspace, socket.assigns.master_user?)
          all_ids = Enum.map(versions, & &1.id)

          selected = version || find_default_version(versions)
          {all_ids, selected}
        else
          {[], nil}
        end

      workspace_id = if workspace, do: workspace.id, else: nil

      socket =
        socket
        |> assign(:workspace, workspace)
        |> assign(:workspace_id, workspace_id)
        |> assign(:version_ids, version_ids)
        |> assign(:selected_version, selected_version)
        |> assign(:selected_version_id, if(selected_version, do: selected_version.id, else: nil))
        |> assign(:workspace_loading, AsyncResult.ok(socket.assigns.workspace_loading, workspace))
        |> load_front_page_async()

      socket =
        if workspace_id do
          socket
          |> subscribe_to_pubsub(current_user, workspace_id)
          |> load_activity_logs_async(workspace_id, version_ids)
        else
          socket
        end

      {:noreply, socket}
    end
  end

  @impl true
  def handle_async(:load_workspace, {:exit, reason}, socket) do
    {:noreply,
     assign(
       socket,
       :workspace_loading,
       AsyncResult.failed(socket.assigns.workspace_loading, reason)
     )}
  end

  @impl true
  def handle_async(:load_front_page, {:ok, front_page}, socket),
    do: {:noreply, assign(socket, :front_page, front_page)}

  @impl true
  def handle_async(:load_front_page, {:exit, _reason}, socket),
    do: {:noreply, assign(socket, :front_page, nil)}

  @impl true
  def handle_async(:load_activity_logs, {:ok, logs}, socket) do
    {:noreply,
     socket
     |> assign(:activity_logs, logs)
     |> assign(:activity_logs_loading, AsyncResult.ok(socket.assigns.activity_logs_loading, logs))}
  end

  @impl true
  def handle_async(:load_activity_logs, {:exit, reason}, socket) do
    {:noreply,
     assign(
       socket,
       :activity_logs_loading,
       AsyncResult.failed(socket.assigns.activity_logs_loading, reason)
     )}
  end

  @impl true
  def handle_async({:load_notes, section_id}, {:ok, notes}, socket) do
    loading = Map.delete(socket.assigns.section_notes_loading, section_id)
    expanded = Map.put(socket.assigns.expanded_section_notes, section_id, notes)

    socket =
      socket
      |> assign(:section_notes_loading, loading)
      |> assign(:expanded_section_notes, expanded)
      |> maybe_resend_expanded_html(section_id)

    {:noreply, socket}
  end

  @impl true
  def handle_async({:load_notes, section_id}, {:exit, _reason}, socket) do
    loading = Map.delete(socket.assigns.section_notes_loading, section_id)
    expanded = Map.delete(socket.assigns.expanded_section_notes, section_id)

    {:noreply,
     socket
     |> assign(:section_notes_loading, loading)
     |> assign(:expanded_section_notes, expanded)
     |> put_flash(:error, gettext("Failed to load notes"))}
  end

  @impl true
  def handle_async({:load_section_activity_logs, section_id}, {:ok, logs}, socket) do
    loading = Map.delete(socket.assigns.section_activity_logs_loading, section_id)
    activity_logs = Map.put(socket.assigns.section_activity_logs, section_id, logs)

    socket =
      socket
      |> assign(:section_activity_logs_loading, loading)
      |> assign(:section_activity_logs, activity_logs)
      |> maybe_resend_expanded_html(section_id)

    {:noreply, socket}
  end

  @impl true
  def handle_async({:load_section_activity_logs, section_id}, {:exit, _reason}, socket) do
    loading = Map.delete(socket.assigns.section_activity_logs_loading, section_id)
    activity_logs = Map.delete(socket.assigns.section_activity_logs, section_id)

    {:noreply,
     socket
     |> assign(:section_activity_logs_loading, loading)
     |> assign(:section_activity_logs, activity_logs)}
  end

  defp maybe_resend_expanded_html(socket, section_id) do
    if socket.assigns.expanded_section_id == section_id do
      html = render_expanded_section(socket.assigns, section_id)

      send_update(MishkaGervaz.Table.Web.Live,
        id: "sections-table",
        expanded_html: html
      )
    end

    socket
  end

  defp render_expanded_section(assigns_map, section_id) do
    notes = Map.get(assigns_map.expanded_section_notes, section_id, [])
    notes_loading = Map.get(assigns_map.section_notes_loading, section_id, false)
    activity_logs = Map.get(assigns_map.section_activity_logs, section_id, [])
    activity_loading = Map.get(assigns_map.section_activity_logs_loading, section_id, false)

    workspace_version_id = assigns_map.workspace_version_id

    assigns =
      %{__changed__: %{}}
      |> Phoenix.Component.assign(:section_id, section_id)
      |> Phoenix.Component.assign(:workspace_version_id, workspace_version_id)
      |> Phoenix.Component.assign(:notes, notes)
      |> Phoenix.Component.assign(:notes_loading, notes_loading)
      |> Phoenix.Component.assign(:activity_logs, activity_logs)
      |> Phoenix.Component.assign(:activity_loading, activity_loading)

    ~H"""
    <div
      data-role="detailgrid"
      class="grid grid-cols-2 gap-5 max-[980px]:grid-cols-1! max-[980px]:gap-[22px]!"
    >
      <div>
        <div class="mb-3 flex items-center gap-2">
          <.icon name="hero-document-text" class="size-[15px] text-[#5b57d6]" />
          <span class="text-[12.5px] font-bold text-[#1b1a18]">
            {gettext("Notes (%{count})", count: length(@notes))}
          </span>
        </div>
        <%= if @notes_loading do %>
          <div class="flex items-center justify-center gap-2.5 py-6">
            <div class="size-4 animate-spin rounded-full border-2 border-[#e0ddd6] border-t-[#5b57d6]">
            </div>
            <span class="text-[12px] font-medium text-[#8a877f]">{gettext("Loading...")}</span>
          </div>
        <% else %>
          <%= if @notes == [] do %>
            <div class="flex flex-col items-center rounded-[10px] border border-dashed border-[#e6e4de] bg-white py-[26px] text-center">
              <span class="mb-[9px] grid size-9 place-items-center rounded-[10px] bg-[#f4f3ee] text-[#c3c0b8]">
                <.icon name="hero-document-text" class="size-[17px]" />
              </span>
              <span class="text-[12px] font-semibold text-[#a8a5a0]">{gettext("No notes yet")}</span>
              <span class="mt-[3px] text-[10.5px] font-medium text-[#c3c0b8]">
                {gettext("Notes added to this section will appear here.")}
              </span>
            </div>
          <% else %>
            <div class="flex max-h-[220px] flex-col gap-[7px] overflow-y-auto [scrollbar-width:none] [&::-webkit-scrollbar]:hidden">
              <%= for note <- @notes do %>
                <div class="flex items-center gap-2.5 rounded-[10px] border border-[#f0efea] bg-white px-[11px] py-[9px]">
                  <.icon name="hero-document-text" class="size-3.5 flex-none text-[#a8a5a0]" />
                  <span class="min-w-0 flex-1 truncate text-[12px] font-semibold text-[#3a382f]">
                    {note.title}
                  </span>
                  <span class={"rounded-[5px] px-[7px] py-0.5 text-[9.5px] font-bold uppercase tracking-[0.03em] #{review_status_color(note.content_review_status)}"}>
                    {DocumentSection.review_label(note.content_review_status)}
                  </span>
                  <button
                    phx-click="edit_note"
                    phx-value-id={note.id}
                    title={gettext("Edit note")}
                    class="grid size-[26px] flex-none place-items-center rounded-[7px] border border-[#e4e2f7] bg-[#f2f1fc] text-[#5b57d6] transition-colors hover:bg-[#e9e7fb]"
                  >
                    <.icon name="hero-pencil-square" class="size-3" />
                  </button>
                  <a
                    href={"/admin/dashboard/document/note-drafts?note_drafts_filter_source_note_id=#{note.id}&note_drafts_filter_section_id=#{@section_id}&return_to=#{@workspace_version_id}"}
                    title={gettext("View note drafts")}
                    class="grid size-[26px] flex-none place-items-center rounded-[7px] border border-[#f0e3c9] bg-[#fdf7ea] text-[#a5691a] transition-colors hover:bg-[#faf0d9]"
                  >
                    <.icon name="hero-document-text" class="size-3" />
                  </a>
                </div>
              <% end %>
            </div>
          <% end %>
        <% end %>
      </div>

      <div>
        <div class="mb-3 flex items-center gap-2">
          <.icon name="hero-clock" class="size-[15px] text-[#8a877f]" />
          <span class="text-[12.5px] font-bold text-[#1b1a18]">{gettext("Recent Activity")}</span>
        </div>
        <%= if @activity_loading do %>
          <div class="flex items-center justify-center gap-2.5 py-6">
            <div class="size-4 animate-spin rounded-full border-2 border-[#e0ddd6] border-t-[#5b57d6]">
            </div>
            <span class="text-[12px] font-medium text-[#8a877f]">{gettext("Loading...")}</span>
          </div>
        <% else %>
          <%= if @activity_logs == [] do %>
            <div class="flex flex-col items-center rounded-[10px] border border-dashed border-[#e6e4de] bg-white py-[26px] text-center">
              <span class="mb-[9px] grid size-9 place-items-center rounded-[10px] bg-[#f4f3ee] text-[#c3c0b8]">
                <.icon name="hero-clock" class="size-[17px]" />
              </span>
              <span class="text-[12px] font-semibold text-[#a8a5a0]">{gettext("No activity yet")}</span>
              <span class="mt-[3px] text-[10.5px] font-medium text-[#c3c0b8]">
                {gettext("Changes to this section will be logged here.")}
              </span>
            </div>
          <% else %>
            <div class="flex flex-col gap-2">
              <%= for event <- @activity_logs do %>
                <div class="flex items-center gap-[11px] rounded-[10px] border border-[#f0efea] bg-white px-3 py-2.5">
                  <span class={"flex-none rounded-[5px] px-2 py-[3px] text-[9.5px] font-bold uppercase tracking-[0.03em] #{action_type_color(event.action_type)}"}>
                    {action_type_label(event.action_type)}
                  </span>
                  <div class="min-w-0 flex-1">
                    <div class="flex min-w-0 items-center gap-1.5">
                      <span class="truncate text-[12px] font-bold text-[#1b1a18]">
                        {get_event_title(event)}
                      </span>
                      <span class="flex-none text-[10.5px] font-medium text-[#c3c0b8]">
                        {format_resource(event.resource)}
                      </span>
                    </div>
                    <div class="mt-0.5 text-[10.5px] font-medium text-[#a8a5a0]">
                      <span id={"section-activity-actor-#{event.id}"}>
                        {MishkaDocument.EventLog.actor_label(event)}
                      </span>
                      · {Localized.datetime(event.occurred_at, :MdHm)}
                    </div>
                  </div>
                </div>
              <% end %>
            </div>
          <% end %>
        <% end %>
      </div>
    </div>

    <div class="mt-4 flex flex-wrap gap-2.5">
      <.link
        navigate={"/admin/dashboard/document/section-drafts?section_drafts_filter_source_section_id=#{@section_id}&return_to=#{@workspace_version_id}"}
        class="inline-flex h-9 items-center gap-[7px] rounded-[10px] border border-[#dcdbf5] bg-[#f2f1fc] px-3.5 text-[12px] font-semibold text-[#4f4bcc] transition-colors hover:bg-[#e9e7fb]"
      >
        <.icon name="hero-document-duplicate" class="size-3.5" /> {gettext(
          "View Drafts for this Section"
        )}
      </.link>
      <.link
        navigate={"/admin/dashboard/document/note-drafts?note_drafts_filter_section_id=#{@section_id}&return_to=#{@workspace_version_id}"}
        class="inline-flex h-9 items-center gap-[7px] rounded-[10px] border border-[#f0e3c9] bg-[#fdf7ea] px-3.5 text-[12px] font-semibold text-[#a5691a] transition-colors hover:bg-[#faf0d9]"
      >
        <.icon name="hero-document-text" class="size-3.5" /> {gettext("View Note Drafts")}
      </.link>
    </div>
    """
  end

  defp load_workspace_by_version_async(socket, workspace_version_id) do
    current_user = socket.assigns.current_user

    MishkaGervaz.Messages.start_async(socket, :load_workspace, fn ->
      version = load_workspace_version(current_user, workspace_version_id)

      if version do
        workspace = load_workspace(current_user, version.workspace_id)

        if workspace do
          loads =
            case current_user do
              %User{site_id: nil} ->
                [
                  :site,
                  :health_metrics,
                  :maintainers_info,
                  master_versions:
                    Ash.Query.sort(MishkaDocument.WorkspaceVersion, inserted_at: :desc)
                ]

              _ ->
                [
                  :site,
                  :health_metrics,
                  :maintainers_info,
                  tenant_versions:
                    Ash.Query.sort(MishkaDocument.WorkspaceVersion, inserted_at: :desc)
                ]
            end

          loaded_workspace =
            Ash.load!(workspace, loads,
              actor: current_user,
              tenant: workspace.site_id
            )

          {loaded_workspace, version}
        else
          {nil, version}
        end
      else
        {nil, nil}
      end
    end)
  end

  # THE PAGE THE SELECTED VERSION DRAWS AT ITS DOCUMENT'S OWN ADDRESS, for the Site Information panel,
  # which a master alone is shown.
  defp load_front_page_async(%{assigns: %{master_user?: true, selected_version_id: id}} = socket)
       when is_binary(id) do
    current_user = socket.assigns.current_user

    MishkaGervaz.Messages.start_async(socket, :load_front_page, fn ->
      MishkaDocument.Section
      |> Ash.Query.for_read(:master_read, %{}, actor: current_user)
      |> Ash.Query.filter(workspace_version_id == ^id and front_page == true)
      |> Ash.Query.select([:id, :title, :slug])
      |> Ash.read(page: [limit: 1])
      |> case do
        {:ok, %{results: [front_page | _]}} -> front_page
        _none -> nil
      end
    end)
  end

  defp load_front_page_async(socket), do: socket

  defp load_workspace_version(%User{site_id: nil} = user, id) do
    case Ash.get(MishkaDocument.WorkspaceVersion, id, action: :master_get, actor: user) do
      {:ok, version} -> version
      _ -> nil
    end
  end

  defp load_workspace_version(%User{site_id: site_id} = user, id) when is_binary(site_id) do
    case Ash.get(MishkaDocument.WorkspaceVersion, id,
           action: :read,
           actor: user,
           tenant: site_id
         ) do
      {:ok, version} -> version
      _ -> nil
    end
  end

  defp load_workspace_version(_, _), do: nil

  defp find_default_version_id_for_workspace(current_user, workspace_id) do
    {action, opts} =
      case current_user do
        %User{site_id: nil} ->
          {:master_by_workspace, [actor: current_user]}

        %User{site_id: site_id} when is_binary(site_id) ->
          {:by_workspace, [actor: current_user, tenant: site_id]}
      end

    versions =
      MishkaDocument.WorkspaceVersion
      |> Ash.Query.for_read(action, %{workspace_id: workspace_id}, opts)
      |> Ash.Query.sort(inserted_at: :desc)
      |> Ash.read!(page: [limit: 100])
      |> Map.get(:results, [])

    case find_default_version(versions) do
      nil -> :error
      version -> {:ok, version.id}
    end
  end

  defp load_workspace(%User{site_id: nil} = user, workspace_id) do
    case Ash.get(MishkaDocument.Workspace, workspace_id, action: :master_get, actor: user) do
      {:ok, workspace} -> workspace
      _ -> nil
    end
  end

  defp load_workspace(%User{site_id: site_id} = user, workspace_id) when is_binary(site_id) do
    case Ash.get(MishkaDocument.Workspace, workspace_id,
           action: :read,
           actor: user,
           tenant: site_id
         ) do
      {:ok, workspace} -> workspace
      _ -> nil
    end
  end

  defp load_workspace(_, _), do: nil

  defp load_activity_logs_async(socket, workspace_id, version_ids) do
    current_user = socket.assigns.current_user

    MishkaGervaz.Messages.start_async(socket, :load_activity_logs, fn ->
      {action, action_args} =
        case current_user do
          %User{site_id: nil} -> {:master_read, %{}}
          %User{site_id: site_id} -> {:tenant_read, %{site_id: site_id}}
        end

      workspace_id_str = to_string(workspace_id)

      MishkaDocument.EventLog
      |> Ash.Query.for_read(action, action_args, actor: current_user)
      |> Ash.Query.filter(
        record_id == ^workspace_id or
          record_id in ^version_ids or
          fragment("metadata->>'workspace_id' = ?", ^workspace_id_str)
      )
      |> Ash.Query.load([:actor, :actor_master?])
      |> Ash.Query.sort(occurred_at: :desc)
      |> Ash.read!(page: [limit: @activity_logs_limit])
      |> Map.get(:results, [])
    end)
  end

  defp load_notes_for_section(socket, section_id) do
    current_user = socket.assigns.current_user

    socket =
      socket
      |> assign(
        :section_notes_loading,
        Map.put(socket.assigns.section_notes_loading, section_id, true)
      )
      |> assign(
        :expanded_section_notes,
        Map.put(socket.assigns.expanded_section_notes, section_id, [])
      )

    MishkaGervaz.Messages.start_async(socket, {:load_notes, section_id}, fn ->
      {action, query_opts} =
        case current_user do
          %User{site_id: nil} -> {:master_read, [actor: current_user]}
          %User{site_id: site_id} -> {:read, [actor: current_user, tenant: site_id]}
        end

      MishkaDocument.Note
      |> Ash.Query.for_read(action, %{}, query_opts)
      |> Ash.Query.filter(section_id == ^section_id)
      |> Ash.Query.sort(order_position: :asc, inserted_at: :desc)
      |> Ash.read!(page: [limit: 50])
      |> Map.get(:results, [])
    end)
  end

  defp load_section_activity_logs_async(socket, section_id) do
    current_user = socket.assigns.current_user

    socket =
      assign(
        socket,
        :section_activity_logs_loading,
        Map.put(socket.assigns.section_activity_logs_loading, section_id, true)
      )

    MishkaGervaz.Messages.start_async(socket, {:load_section_activity_logs, section_id}, fn ->
      section_id_str = to_string(section_id)

      {action, action_args} =
        case current_user do
          %User{site_id: nil} -> {:master_read, %{}}
          %User{site_id: site_id} -> {:tenant_read, %{site_id: site_id}}
        end

      MishkaDocument.EventLog
      |> Ash.Query.for_read(action, action_args, actor: current_user)
      |> Ash.Query.filter(
        (resource == "Elixir.MishkaDocument.Section" and
           fragment("?::text", record_id) == ^section_id_str) or
          fragment("metadata->>'section_id' = ?", ^section_id_str)
      )
      |> Ash.Query.load([:actor, :actor_master?])
      |> Ash.Query.sort(occurred_at: :desc)
      |> Ash.read!(page: [limit: @section_activity_logs_limit])
      |> Map.get(:results, [])
    end)
  end

  defp remove_note_from_expanded(socket, section_id, note_id) do
    expanded = socket.assigns.expanded_section_notes

    if Map.has_key?(expanded, section_id) do
      notes = Map.get(expanded, section_id, [])
      updated_notes = Enum.reject(notes, &(&1.id == note_id))
      assign(socket, :expanded_section_notes, Map.put(expanded, section_id, updated_notes))
    else
      socket
    end
  end

  defp add_note_to_expanded(socket, section_id, note) do
    expanded = socket.assigns.expanded_section_notes

    if Map.has_key?(expanded, section_id) do
      notes = Map.get(expanded, section_id, [])

      updated_notes =
        [note | notes]
        |> Enum.sort_by(&{&1.order_position || 0, &1.inserted_at}, :asc)

      assign(socket, :expanded_section_notes, Map.put(expanded, section_id, updated_notes))
    else
      socket
    end
  end

  defp update_note_in_expanded(socket, section_id, note) do
    expanded = socket.assigns.expanded_section_notes

    if Map.has_key?(expanded, section_id) do
      notes = Map.get(expanded, section_id, [])
      updated_notes = Enum.map(notes, fn n -> if n.id == note.id, do: note, else: n end)
      assign(socket, :expanded_section_notes, Map.put(expanded, section_id, updated_notes))
    else
      socket
    end
  end

  defp maybe_update_section_activity_logs(socket, event) do
    metadata = event.metadata || %{}
    section_activity_logs = socket.assigns.section_activity_logs
    expanded_section_id = socket.assigns.expanded_section_id

    section_id =
      cond do
        event.resource in ["Elixir.MishkaDocument.Section", MishkaDocument.Section] ->
          to_string(event.record_id)

        is_map(metadata) && (metadata["section_id"] || metadata[:section_id]) ->
          to_string(metadata["section_id"] || metadata[:section_id])

        true ->
          nil
      end

    if section_id && section_id == expanded_section_id do
      current_logs = Map.get(section_activity_logs, section_id, [])
      updated_logs = with_event(current_logs, event, @section_activity_logs_limit)

      socket
      |> assign(:section_activity_logs, Map.put(section_activity_logs, section_id, updated_logs))
      |> maybe_resend_expanded_html(section_id)
    else
      socket
    end
  end

  # The newest `limit` of `events` and `event`, each once. A broadcast can arrive twice, and after
  # newer events are already listed.
  defp with_event(events, event, limit) do
    [event | Enum.reject(events, &(&1.id == event.id))]
    |> Enum.sort_by(& &1.occurred_at, {:desc, DateTime})
    |> Enum.take(limit)
  end

  defp get_note(%User{site_id: nil} = user, id) do
    Ash.get(MishkaDocument.Note, id, action: :master_get, actor: user)
  end

  defp get_note(%User{site_id: site_id} = user, id) when is_binary(site_id) do
    MishkaDocument.Note
    |> Ash.Query.for_read(:read, %{}, tenant: site_id, actor: user)
    |> Ash.Query.filter(id: id)
    |> Ash.read_one(tenant: site_id, actor: user)
  end

  defp find_default_version([]), do: nil

  defp find_default_version(versions) do
    Enum.find(versions, &(&1.is_latest_for_version == true)) ||
      Enum.find(versions, &(&1.status == :stable)) ||
      List.first(versions)
  end

  defp event_belongs_to_workspace?(event, socket) do
    workspace_id = socket.assigns.workspace_id
    version_ids = socket.assigns.version_ids
    record_id = event.record_id
    metadata = event.metadata || %{}

    get_value = fn map, key ->
      Map.get(map, key) || Map.get(map, to_string(key))
    end

    cond do
      record_id == workspace_id -> true
      record_id in version_ids -> true
      get_value.(metadata, :workspace_id) == workspace_id -> true
      get_value.(metadata, :workspace_version_id) in version_ids -> true
      true -> false
    end
  end

  def get_versions(workspace, master_user?) do
    cond do
      master_user? && is_list(workspace.master_versions) ->
        workspace.master_versions

      !master_user? && is_list(workspace.tenant_versions) ->
        workspace.tenant_versions

      true ->
        []
    end
  end

  def get_maintainers(workspace) do
    case workspace.maintainers_info do
      %{"maintainers" => maintainers} when is_list(maintainers) -> maintainers
      %{maintainers: maintainers} when is_list(maintainers) -> maintainers
      _ -> []
    end
  end

  def review_status_color(:pending), do: "bg-yellow-100 text-yellow-800"
  def review_status_color(:approved), do: "bg-green-100 text-green-800"
  def review_status_color(:rejected), do: "bg-red-100 text-red-800"
  def review_status_color(:needs_revision), do: "bg-orange-100 text-orange-800"
  def review_status_color(:archived), do: "bg-gray-100 text-gray-800"
  def review_status_color(_), do: "bg-gray-100 text-gray-800"

  def status_color(:active), do: "bg-green-100 text-green-800"
  def status_color(:draft), do: "bg-yellow-100 text-yellow-800"
  def status_color(:archived), do: "bg-gray-100 text-gray-800"
  def status_color(_), do: "bg-gray-100 text-gray-800"

  def action_type_color(:create), do: "bg-green-100 text-green-800"
  def action_type_color(:update), do: "bg-blue-100 text-blue-800"
  def action_type_color(:destroy), do: "bg-red-100 text-red-800"
  def action_type_color(_), do: "bg-gray-100 text-gray-800"

  def format_resource(resource) when is_binary(resource) do
    resource
    |> String.split(".")
    |> List.last()
    |> resource_label()
  end

  def format_resource(resource) when is_atom(resource) do
    resource
    |> Atom.to_string()
    |> format_resource()
  end

  def format_resource(_), do: gettext("Unknown")

  defp resource_label("Workspace"), do: dgettext("mishka_gervaz", "Workspace")
  defp resource_label("WorkspaceVersion"), do: dgettext("mishka_gervaz", "Workspace Version")
  defp resource_label("Section"), do: dgettext("mishka_gervaz", "Section")
  defp resource_label("Note"), do: dgettext("mishka_gervaz", "Note")
  defp resource_label("SectionDraft"), do: dgettext("mishka_gervaz", "Section Draft")
  defp resource_label("NoteDraft"), do: dgettext("mishka_gervaz", "Note Draft")
  defp resource_label("Tag"), do: dgettext("mishka_gervaz", "Tag")
  defp resource_label("Issue"), do: dgettext("mishka_gervaz", "Issue")
  defp resource_label("IssueComment"), do: dgettext("mishka_gervaz", "Issue Comment")
  defp resource_label(name), do: Phoenix.Naming.humanize(name)

  @doc "The words an event's action badge reads, in the viewer's language."
  @spec action_type_label(atom() | String.t()) :: String.t()
  def action_type_label(type) when type in [:create, "create"],
    do: dgettext("mishka_gervaz", "Create")

  def action_type_label(type) when type in [:update, "update"],
    do: dgettext("mishka_gervaz", "Update")

  def action_type_label(type) when type in [:destroy, "destroy"],
    do: dgettext("mishka_gervaz", "Destroy")

  def action_type_label(type), do: to_string(type)

  @doc "The words a workspace version's status reads, in the viewer's language."
  @spec version_status_label(atom()) :: String.t()
  def version_status_label(:draft), do: dgettext("mishka_gervaz", "Draft")
  def version_status_label(:alpha), do: dgettext("mishka_gervaz", "Alpha")
  def version_status_label(:beta), do: dgettext("mishka_gervaz", "Beta")
  def version_status_label(:rc), do: dgettext("mishka_gervaz", "Rc")
  def version_status_label(:stable), do: dgettext("mishka_gervaz", "Stable")
  def version_status_label(:archived), do: dgettext("mishka_gervaz", "Archived")
  def version_status_label(status), do: to_string(status)

  @doc "The words a draft's version increment type reads, in the viewer's language."
  @spec increment_label(atom()) :: String.t()
  def increment_label(:major), do: gettext("major")
  def increment_label(:minor), do: gettext("minor")
  def increment_label(:patch), do: gettext("patch")
  def increment_label(:prerelease), do: gettext("prerelease")
  def increment_label(:none), do: gettext("none")
  def increment_label(type), do: to_string(type)

  def get_event_title(event) do
    cond do
      event.data && is_map(event.data) && event.data["title"] ->
        event.data["title"]

      event.data && is_map(event.data) && event.data["name"] ->
        event.data["name"]

      event.data && is_map(event.data) && event.data["version_number"] ->
        "v#{event.data["version_number"]}"

      event.metadata && is_map(event.metadata) && event.metadata["title"] ->
        event.metadata["title"]

      event.metadata && is_map(event.metadata) && event.metadata["name"] ->
        event.metadata["name"]

      true ->
        gettext("%{resource} Record", resource: format_resource(event.resource))
    end
  end
end
