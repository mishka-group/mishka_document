# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_document/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaDocumentWeb.Test.WhoLabelTest do
  @moduledoc """
  Who the document admin pages name: the actor on the event logs and in a workspace's Recent
  Activity, the maintainers, an issue's reporter and a draft's creator.

  A master reads every email. A site admin reads its own site's people by email and a master as
  "Master", and never the master's email or any part of it.
  """
  use MishkaDocument.ConnCase

  import Phoenix.LiveViewTest
  import MishkaDocument.Test.Factory

  alias MishkaCmsCore.Accounts.{Permission, User, UserPermission}
  alias MishkaCmsCore.Runtime.States.SiteState
  alias MishkaDocument.Dashboard.Widgets.RecentDocuments
  alias MishkaDocument.{EventLog, NoteDraft, SectionDraft}
  alias MishkaDocumentWeb.Templates.IssueCard

  require Ash.Query

  @password "Password123!"
  @await 5_000

  setup do
    SiteState.clear()
    :ok = Swoosh.TestAssertions.set_swoosh_global()

    site = create_site!(name: "localhost", host: "localhost", active: true, master: true)

    SiteState.save(%{
      id: site.id,
      name: site.name,
      host: site.host,
      priority: site.priority,
      active: site.active,
      master: site.master
    })

    :persistent_term.put(:mishka_installed, true)
    :ok = MishkaCmsCore.Install.Extensions.mark_installed!(site.id, :mishka_document, "test")

    on_exit(fn ->
      :persistent_term.erase(:mishka_installed)
      SiteState.clear()
    end)

    n = System.unique_integer([:positive])
    colleague = admin!("doc-colleague-#{n}@example.com", site.id)
    master = admin!("doc-master-#{n}@platform.test")
    section = create_section!(site_id: site.id)

    records = %{
      issue_by_colleague:
        create_issue!(site_id: site.id, reporter_id: colleague.id, section_id: section.id),
      issue_by_master:
        create_issue!(site_id: site.id, reporter_id: master.id, section_id: section.id),
      section_draft_by_colleague:
        create_section_draft!(site_id: site.id, created_by_user_id: colleague.id),
      section_draft_by_master:
        create_section_draft!(site_id: site.id, created_by_user_id: master.id),
      note_draft_by_colleague:
        create_note_draft!(site_id: site.id, created_by_user_id: colleague.id),
      note_draft_by_master: create_note_draft!(site_id: site.id, created_by_user_id: master.id)
    }

    {:ok,
     Map.merge(records, %{
       site: site,
       colleague: colleague,
       master: master,
       section: section,
       by_colleague: edit_section(section, site, colleague, "By the site"),
       by_master: edit_section(section, site, master, "By the master"),
       reader: admin!("doc-reader-#{n}@platform.test"),
       site_admin: admin!("doc-site-admin-#{n}@example.com", site.id)
     })}
  end

  describe "the word for someone a page shows no email for" do
    test "reads in the admin's language" do
      Gettext.put_locale(MishkaCmsCore.Gettext, "fa")
      id = Ash.UUID.generate()

      assert EventLog.actor_label(%{actor_id: nil}) == "[fa] System"
      assert EventLog.actor_label(%{actor_id: id}) == "[fa] Unknown"
      assert EventLog.actor_label(%{actor_id: id, actor_master?: true}) == "[fa] Master"
      assert IssueCard.reporter(%{}) == "[fa] Unknown"
      assert IssueCard.reporter(%{reporter_master?: true}) == "[fa] Master"
      assert NoteDraft.creator(%{}) == "[fa] Unknown"
      assert SectionDraft.creator(%{created_by_master?: true}) == "[fa] Master"
    end
  end

  describe "the event logs" do
    test "a master reads every actor's email", ctx do
      view = open(ctx.reader, "/admin/dashboard/document/event-logs")

      assert actor_cell(view, ctx.by_colleague) == ["D", email(ctx.colleague)]
      assert actor_cell(view, ctx.by_master) == ["D", email(ctx.master)]
    end

    test "a site admin reads its own people by email and is not shown a master's events", ctx do
      view = open(ctx.site_admin, "/admin/dashboard/document/event-logs")

      assert actor_cell(view, ctx.by_colleague) == ["D", email(ctx.colleague)]
      refute has_element?(view, "#event-actor-#{ctx.by_master.id}")
      refute_email(view, ctx.master)
    end
  end

  describe "a workspace's section page" do
    test "a master reads every actor and maintainer by email", ctx do
      view = open_section_page(ctx.reader, ctx.section)

      assert workspace_actor(view, ctx.by_colleague) == email(ctx.colleague)
      assert workspace_actor(view, ctx.by_master) == email(ctx.master)
      assert section_actor(view, ctx.by_master) == email(ctx.master)
      assert maintainer(view, ctx.colleague) == email(ctx.colleague)
      assert maintainer(view, ctx.master) == email(ctx.master)
    end

    test "a site admin reads its own people by email and a master as Master", ctx do
      view = open_section_page(ctx.site_admin, ctx.section)

      assert workspace_actor(view, ctx.by_colleague) == email(ctx.colleague)
      assert workspace_actor(view, ctx.by_master) == "Master"
      assert section_actor(view, ctx.by_colleague) == email(ctx.colleague)
      assert section_actor(view, ctx.by_master) == "Master"
      assert maintainer(view, ctx.colleague) == email(ctx.colleague)
      assert maintainer(view, ctx.master) == "Master"
      refute_email(view, ctx.master)
    end

    test "older events announced late do not push the newest out of Recent Activity", ctx do
      await_event_announcements()
      view = open_section_page(ctx.site_admin, ctx.section)

      newest = [ctx.by_colleague.id, ctx.by_master.id]

      older =
        MishkaDocument.EventLog
        |> Ash.Query.filter(id not in ^newest)
        |> Ash.read!(authorize?: false)

      assert length(older) >= 5

      for event <- older do
        send(view.pid, %Phoenix.Socket.Broadcast{
          topic: "event_log:created",
          event: "created",
          payload: %Ash.Notifier.Notification{
            resource: MishkaDocument.EventLog,
            data: event,
            action: %{name: :create, type: :create}
          }
        })
      end

      render(view)

      assert workspace_actor(view, ctx.by_colleague) == email(ctx.colleague)
      assert workspace_actor(view, ctx.by_master) == "Master"
    end

    test "a master's edit arriving live reads by email to a master", ctx do
      view = open_section_page(ctx.reader, ctx.section)
      newcomer = admin!("doc-live-master-#{System.unique_integer([:positive])}@platform.test")
      live_edit = edit_section(ctx.section, ctx.site, newcomer, "Live")

      render(view)

      assert workspace_actor(view, live_edit) == email(newcomer)
      assert section_actor(view, live_edit) == email(newcomer)
    end

    test "a master's edit arriving live reads Master to a site admin", ctx do
      view = open_section_page(ctx.site_admin, ctx.section)
      newcomer = admin!("doc-newcomer-#{System.unique_integer([:positive])}@platform.test")
      live_edit = edit_section(ctx.section, ctx.site, newcomer, "Live")

      render(view)

      assert workspace_actor(view, live_edit) == "Master"
      refute_email(view, newcomer)
    end
  end

  describe "the Recent documents widget" do
    test "names a master maintainer as Master to a site admin and by email to a master", ctx do
      section = create_section!(site_id: ctx.site.id)
      edit_section(section, ctx.site, ctx.master, "Only the master")

      site_admin = Ash.load!(ctx.site_admin, [:permissions], authorize?: false)
      reader = Ash.load!(ctx.reader, [:permissions], authorize?: false)

      assert widget_author(site_admin, section) == "Master"
      refute widget_html(site_admin) =~ email(ctx.master)
      refute widget_html(site_admin) =~ ctx.master |> email() |> String.split("@") |> hd()

      assert widget_author(reader, section) == email(ctx.master)
      assert widget_html(reader) =~ email(ctx.master)
    end
  end

  describe "a workspace's maintainers" do
    test "are listed by the name the reader sees, wherever a master's address would sort", ctx do
      n = System.unique_integer([:positive])
      section = create_section!(site_id: ctx.site.id)
      first_master = admin!("aaa-master-#{n}@platform.test")
      doc_ma = admin!("doc-ma-#{n}@example.com", ctx.site.id)
      doc_mz = admin!("doc-mz-#{n}@example.com", ctx.site.id)

      [ctx.colleague, doc_ma, doc_mz, ctx.master, first_master]
      |> Enum.with_index(1)
      |> Enum.each(fn {user, i} -> edit_section(section, ctx.site, user, "Edit #{i}") end)

      view = open_section_page(ctx.site_admin, section)

      assert maintainer_names(view) == [
               email(ctx.colleague),
               email(doc_ma),
               email(doc_mz),
               "Master",
               "Master"
             ]

      refute_email(view, first_master)
      site_admin = Ash.load!(ctx.site_admin, [:permissions], authorize?: false)
      assert widget_author(site_admin, section) == email(ctx.colleague)
    end

    test "a master who wrote last is listed among more people than the list holds", ctx do
      n = System.unique_integer([:positive])
      section = create_section!(site_id: ctx.site.id)

      for i <- 1..100 do
        writer = create_user!(email: "doc-many-#{n}-#{i}@example.com", site_id: ctx.site.id)
        edit_section(section, ctx.site, writer, "By writer #{i}")
      end

      edit_section(section, ctx.site, admin!("zzz-master-#{n}@platform.test"), "By the master")

      assert %{"count" => 100, "maintainers" => maintainers} =
               maintainers_info(section, ctx.site_admin)

      assert Enum.count(maintainers, &(&1["name"] == "Master")) == 1
    end
  end

  describe "an issue's reporter" do
    test "a master reads every reporter's email, on the Issues page and the Documents home",
         ctx do
      view = open(ctx.reader, "/admin/dashboard/document/issues")

      assert text(view, "#issue-reporter-#{ctx.issue_by_colleague.id}") == email(ctx.colleague)
      assert text(view, "#issue-reporter-#{ctx.issue_by_master.id}") == email(ctx.master)

      home = open_issues_panel(ctx.reader)

      assert text(home, "#home-issue-reporter-#{ctx.issue_by_colleague.id}") ==
               email(ctx.colleague)

      assert text(home, "#home-issue-reporter-#{ctx.issue_by_master.id}") == email(ctx.master)
    end

    test "a master reads a master reporter's email after a live update", ctx do
      home = open_issues_panel(ctx.reader)

      ctx.issue_by_master
      |> Ash.Changeset.for_update(:update, %{title: "Updated live"},
        tenant: ctx.site.id,
        actor: ctx.master,
        authorize?: false
      )
      |> Ash.update!()

      render(home)

      assert text(home, "#home-issue-reporter-#{ctx.issue_by_master.id}") == email(ctx.master)
    end

    test "a site admin reads a master reporter as Master after a live update", ctx do
      home = open_issues_panel(ctx.site_admin)

      ctx.issue_by_master
      |> Ash.Changeset.for_update(:update, %{title: "Updated live"},
        tenant: ctx.site.id,
        actor: ctx.master,
        authorize?: false
      )
      |> Ash.update!()

      render(home)

      assert text(home, "#issues-#{ctx.issue_by_master.id}") =~ "Updated live"
      assert text(home, "#home-issue-reporter-#{ctx.issue_by_master.id}") == "Master"
      refute_email(home, ctx.master)
    end

    test "a site admin reads its own people by email and a master as Master", ctx do
      view = open(ctx.site_admin, "/admin/dashboard/document/issues")

      assert text(view, "#issue-reporter-#{ctx.issue_by_colleague.id}") == email(ctx.colleague)
      assert text(view, "#issue-reporter-#{ctx.issue_by_master.id}") == "Master"
      refute_email(view, ctx.master)

      home = open_issues_panel(ctx.site_admin)

      assert text(home, "#home-issue-reporter-#{ctx.issue_by_colleague.id}") ==
               email(ctx.colleague)

      assert text(home, "#home-issue-reporter-#{ctx.issue_by_master.id}") == "Master"
      refute_email(home, ctx.master)
    end
  end

  describe "a draft's creator" do
    for {page, kind, prefix} <- [
          {"section-drafts", :section_draft, "section-draft"},
          {"note-drafts", :note_draft, "note-draft"}
        ] do
      test "a master reads every #{kind} creator's email", ctx do
        view = open(ctx.reader, "/admin/dashboard/document/#{unquote(page)}")

        for {draft, user} <- drafts(ctx, unquote(kind)) do
          assert creator_cell(view, unquote(prefix), draft) == email(user)
        end
      end

      test "a site admin reads its own #{kind} creators by email and a master as Master", ctx do
        view = open(ctx.site_admin, "/admin/dashboard/document/#{unquote(page)}")
        [{by_colleague, colleague}, {by_master, _master}] = drafts(ctx, unquote(kind))

        assert creator_cell(view, unquote(prefix), by_colleague) == email(colleague)
        assert creator_cell(view, unquote(prefix), by_master) == "Master"
        refute_email(view, ctx.master)
      end
    end
  end

  defp drafts(ctx, :section_draft),
    do: [
      {ctx.section_draft_by_colleague, ctx.colleague},
      {ctx.section_draft_by_master, ctx.master}
    ]

  defp drafts(ctx, :note_draft),
    do: [{ctx.note_draft_by_colleague, ctx.colleague}, {ctx.note_draft_by_master, ctx.master}]

  # The event `actor`'s edit of `section` wrote.
  defp edit_section(section, site, actor, title) do
    section
    |> Ash.Changeset.for_update(:update, %{title: title},
      tenant: site.id,
      actor: actor,
      authorize?: false
    )
    |> Ash.update!()

    MishkaDocument.EventLog
    |> Ash.Query.filter(record_id == ^section.id and actor_id == ^actor.id)
    |> Ash.Query.limit(1)
    |> Ash.read_one!(authorize?: false)
  end

  # Waits until the event log has announced every event this test wrote. It announces each one from
  # a task of its own a moment after the write, so a page opened sooner hears them after it loads.
  defp await_event_announcements do
    Process.list()
    |> Enum.filter(&announcing_for_this_test?/1)
    |> Enum.map(&Process.monitor/1)
    |> Enum.each(fn ref -> assert_receive {:DOWN, ^ref, :process, _pid, _reason}, @await end)
  end

  defp announcing_for_this_test?(pid) do
    case Process.info(pid, :dictionary) do
      {:dictionary, dictionary} ->
        match?({MishkaDocument.EventLog, _fun, 0}, dictionary[:"$initial_call"]) and
          self() in List.wrap(dictionary[:"$callers"])

      nil ->
        false
    end
  end

  defp open(user, path) do
    {:ok, view, _html} = live(conn_for(user), path)
    render_async(view, @await)
    view
  end

  defp open_section_page(user, section) do
    view = open(user, "/admin/dashboard/document/sections/#{section.workspace_version_id}")
    render_async(view, @await)
    expand(view, section)
    view
  end

  defp open_issues_panel(user) do
    view = open(user, "/admin/dashboard/document")
    render_click(view, "toggle_issues", %{})
    render_async(view, @await)
    view
  end

  # The author line the widget draws for `section`'s workspace.
  defp widget_author(user, section) do
    version =
      MishkaDocument.WorkspaceVersion
      |> Ash.Query.for_read(:read_any, %{}, authorize?: false)
      |> Ash.Query.filter(id == ^section.workspace_version_id)
      |> Ash.read_one!(authorize?: false)

    %{workspaces: workspaces} = data = RecentDocuments.load(user)
    assert Enum.any?(workspaces, &(&1.id == version.workspace_id))

    widget_html(user, data)
    |> LazyHTML.from_fragment()
    |> LazyHTML.query("#recent-document-author-#{version.workspace_id}")
    |> LazyHTML.text()
    |> String.trim()
  end

  defp widget_html(user, data \\ nil) do
    render_component(&RecentDocuments.render/1,
      data: data || RecentDocuments.load(user),
      widget: RecentDocuments.widget()
    )
  end

  defp actor_cell(view, event),
    do: view |> text("#event-actor-#{event.id}") |> String.split()

  defp workspace_actor(view, event), do: text(view, "#workspace-activity-actor-#{event.id}")
  defp section_actor(view, event), do: text(view, "#section-activity-actor-#{event.id}")
  defp maintainer(view, user), do: text(view, "#maintainer-#{user.id}")

  # The Maintainers panel's names, top to bottom.
  defp maintainer_names(view) do
    view
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.query("[id^='maintainer-']")
    |> Enum.map(&(&1 |> LazyHTML.text() |> String.trim()))
  end

  # `section`'s workspace's maintainers, as `user` loads them.
  defp maintainers_info(section, user) do
    version =
      MishkaDocument.WorkspaceVersion
      |> Ash.Query.for_read(:read_any, %{}, authorize?: false)
      |> Ash.Query.filter(id == ^section.workspace_version_id)
      |> Ash.read_one!(authorize?: false)

    MishkaDocument.Workspace
    |> Ash.get!(version.workspace_id, action: :master_get, authorize?: false)
    |> Ash.load!(:maintainers_info,
      actor: Ash.load!(user, [:permissions], authorize?: false),
      tenant: section.site_id
    )
    |> Map.fetch!(:maintainers_info)
  end

  defp creator_cell(view, prefix, draft) do
    view
    |> element("##{prefix}-creator-#{draft.id}")
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.query("span[title]")
    |> LazyHTML.text()
    |> String.trim()
  end

  defp expand(view, record) do
    view
    |> element(~s(button[phx-click="expand_row"][phx-value-id="#{record.id}"]))
    |> render_click()

    render_async(view, @await)
  end

  defp text(view, selector) do
    view
    |> element(selector)
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.text()
    |> String.trim()
  end

  defp email(user), do: to_string(user.email)

  defp refute_email(view, user) do
    html = render(view)

    refute html =~ email(user)
    refute html =~ user |> email() |> String.split("@") |> hd()
  end

  defp conn_for(user) do
    Phoenix.ConnTest.build_conn()
    |> Map.put(:host, "localhost")
    |> Map.update!(:req_headers, &[{"host", "localhost"} | List.keydelete(&1, "host", 0)])
    |> Plug.Test.init_test_session(%{})
    |> Plug.Conn.put_session(:master_mode, true)
    |> AshAuthentication.Plug.Helpers.store_in_session(user)
  end

  defp star_permission do
    case Permission |> Ash.Query.filter(name == "*") |> Ash.read_one(authorize?: false) do
      {:ok, nil} ->
        Permission
        |> Ash.Changeset.for_create(:create, %{name: "*"}, authorize?: false)
        |> Ash.create!()

      {:ok, permission} ->
        permission
    end
  end

  defp admin!(email, site_id \\ nil) do
    {:ok, user} =
      User
      |> Ash.Changeset.for_create(
        :register_with_password,
        %{email: email, password: @password, password_confirmation: @password},
        authorize?: false
      )
      |> then(&if(site_id, do: Ash.Changeset.set_tenant(&1, site_id), else: &1))
      |> Ash.create()

    UserPermission
    |> Ash.Changeset.for_create(:assign, %{}, authorize?: false)
    |> Ash.Changeset.force_change_attribute(:user_id, user.id)
    |> Ash.Changeset.force_change_attribute(:permission_id, star_permission().id)
    |> Ash.create!(authorize?: false)

    user
  end
end
