# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_document/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaDocumentWeb.Test.AreaScreensTest do
  @moduledoc """
  The document screens as an admin holding ONE document area sees them.

    * Home is open to either area. The workspace form and the workspace writes in its table are the
      workspace area's; the issues panel, and restoring or deleting an issue from it, the section
      area's. The table itself is drawn for both, since it is how a section admin reaches the
      sections, and its links lead only to the pages the viewer may open.
    * A link from one area's page to the other's, and the Sections page's hand-off when a workspace
      has no version, lead only to a page the viewer may open.
    * Every other page is one area's, except the event log, which is either's and shows each area
      the events of its own records.
    * An admin of any other area is not let in at all.
    * Setting the documentation up asks for every area it writes: pages (the page builder's snippet
      included), components and the site.

  The workspaces table's actions are asked of the table's own declaration: drawing its rows loads
  each row's site, which is the core's to open to an admin of one document area.
  """
  use MishkaDocument.ConnCase

  @moduletag :capture_log

  import Phoenix.LiveViewTest
  import MishkaDocument.Test.Factory

  alias MishkaCmsCore.Runtime.States.SiteState
  alias MishkaDocument.Issue

  require Ash.Query

  @workspace "admin:dashboard:document:workspace"
  @section "admin:dashboard:document:section"
  # What setting the documentation up writes: its pages, its components, the stylesheet its code
  # blocks are coloured by, the hook their copy buttons are answered by, and the site's settings.
  @provision [
    "admin:dashboard:runtime:page",
    "admin:dashboard:runtime:component",
    "admin:dashboard:runtime:stylesheet",
    "admin:dashboard:runtime:js_hook",
    "admin:dashboard:runtime:site"
  ]

  setup %{conn: conn} do
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

    on_exit(fn ->
      :persistent_term.erase(:mishka_installed)
      SiteState.clear()
    end)

    :ok = MishkaCmsCore.Install.Extensions.mark_installed!(site.id, :mishka_document, "test")

    conn =
      conn
      |> Map.put(:host, "localhost")
      |> Map.update!(:req_headers, &[{"host", "localhost"} | List.keydelete(&1, "host", 0)])

    workspace = create_workspace!(site_id: site.id, name: "Area Handbook", status: :active)

    version =
      MishkaDocument.WorkspaceVersion
      |> Ash.Query.filter(workspace_id == ^workspace.id)
      |> Ash.read_one!(tenant: site.id, authorize?: false)

    {:ok, conn: conn, site: site, workspace: workspace, version: version}
  end

  defp tenant(names, site), do: create_user_with_permissions!(names, site_id: site.id)

  defp log_in(conn, user) do
    conn
    |> Plug.Test.init_test_session(%{})
    |> Plug.Conn.put_session(:master_mode, false)
    |> AshAuthentication.Plug.Helpers.store_in_session(user)
  end

  # A page refused by the dashboard's gate or by PageGuard: a plain redirect carrying the refusal.
  # A page that lets the admin in and then sends it on to another page is not refused.
  defp refused?(conn, path) do
    match?(
      {:error,
       {:redirect, %{flash: %{"error" => "You don't have permission to access this page"}}}},
      live(conn, path)
    )
  end

  defp archived_issue!(site) do
    issue = create_issue!(site_id: site.id)
    Ash.destroy!(issue, action: :master_destroy, authorize?: false)
    issue
  end

  defp archived?(issue) do
    case Ash.get(Issue, issue.id, action: :master_get_archived, authorize?: false) do
      {:ok, %{archived_at: %DateTime{}}} -> true
      _gone_or_restored -> false
    end
  end

  # The dashboard's figures and its workspaces table load in `start_async/3`; a view stopped while
  # one is in flight raises on the way down once the test's sandbox owner is gone.
  defp close(view) do
    render_async(view, 5_000)
    ref = Process.monitor(view.pid)
    GenServer.stop(view.pid, :normal)
    assert_receive {:DOWN, ^ref, :process, _pid, _reason}
  end

  describe "Home, as a workspace admin" do
    setup %{conn: conn, site: site} do
      {:ok, conn: log_in(conn, tenant([@workspace], site))}
    end

    test "is given the workspace form and not the issues", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/admin/dashboard/document")

      assert has_element?(view, "#add-workspace-btn")
      assert has_element?(view, "#workspace-form-modal")
      refute has_element?(view, "#toggle-issues-btn")
      refute has_element?(view, "#issues-panel")

      close(view)
    end

    test "is refused every issue event a socket sends anyway", %{conn: conn, site: site} do
      restored = archived_issue!(site)
      deleted = archived_issue!(site)

      {:ok, view, _html} = live(conn, "/admin/dashboard/document")

      assert render_click(view, "toggle_issues", %{}) =~ "not allowed to manage issues"
      assert render_click(view, "unarchive_issue", %{"id" => restored.id}) =~ "not allowed"
      assert render_click(view, "permanent_delete_issue", %{"id" => deleted.id}) =~ "not allowed"

      assert archived?(restored)
      assert archived?(deleted)

      close(view)
    end

    test "opens the workspace versions, and not the section pages", %{
      conn: conn,
      workspace: workspace,
      version: version
    } do
      assert {:ok, view, _html} =
               live(conn, "/admin/dashboard/document/workspace-version/#{workspace.id}")

      close(view)

      for path <- [
            "/admin/dashboard/document/issues",
            "/admin/dashboard/document/tags",
            "/admin/dashboard/document/section-drafts",
            "/admin/dashboard/document/note-drafts",
            "/admin/dashboard/document/sections/#{version.id}",
            "/admin/dashboard/document/sections/workspace/#{workspace.id}"
          ] do
        assert refused?(conn, path), "#{path} let a workspace admin in"
      end
    end
  end

  describe "Home, as a section admin" do
    setup %{conn: conn, site: site} do
      {:ok, conn: log_in(conn, tenant([@section], site))}
    end

    test "is given the issues and not the workspace form", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/admin/dashboard/document")

      assert has_element?(view, "#toggle-issues-btn")
      assert has_element?(view, "#issues-panel")
      refute has_element?(view, "#add-workspace-btn")
      refute has_element?(view, "#workspace-form-modal")

      close(view)
    end

    test "restores one archived issue and deletes another", %{conn: conn, site: site} do
      restored = archived_issue!(site)
      deleted = archived_issue!(site)

      {:ok, view, _html} = live(conn, "/admin/dashboard/document")

      assert render_click(view, "unarchive_issue", %{"id" => restored.id}) =~
               "Issue restored successfully"

      assert render_click(view, "permanent_delete_issue", %{"id" => deleted.id}) =~
               "Issue permanently deleted"

      refute archived?(restored)
      assert {:error, _gone} = Ash.get(Issue, deleted.id, action: :master_get, authorize?: false)

      close(view)
    end

    test "opens the section pages, and not the workspace versions", %{
      conn: conn,
      workspace: workspace
    } do
      for path <- [
            "/admin/dashboard/document/issues",
            "/admin/dashboard/document/tags",
            "/admin/dashboard/document/section-drafts",
            "/admin/dashboard/document/note-drafts"
          ] do
        assert {:ok, view, _html} = live(conn, path), "#{path} refused a section admin"
        close(view)
      end

      assert refused?(conn, "/admin/dashboard/document/workspace-version/#{workspace.id}")
    end
  end

  describe "links between the two areas' pages" do
    # Drawing a table row loads the row's site. The core's Site policy on this branch answers it
    # only to a full admin, so `admin:api:*` lets it load here; it holds no name of the document
    # dashboard, which is all these tests ask about.
    @site_loads "admin:api:*"
    @versions_link ~s(a[href*="/admin/dashboard/document/workspace-version/"])

    test "Home's language edition chips lead each admin to a page it may open", %{
      conn: conn,
      site: site,
      workspace: workspace
    } do
      edition =
        create_workspace!(
          site_id: site.id,
          name: "Area Handbook fa",
          language: "fa",
          language_group_id: workspace.id,
          status: :active
        )

      card = ~s([data-role^="wscard"][id$="#{workspace.id}"])

      to_sections =
        ~s(#{card} a[href="/admin/dashboard/document/sections/workspace/#{edition.id}"])

      to_versions =
        ~s(#{card} a[href="/admin/dashboard/document/workspace-version/#{edition.id}"])

      for {names, shown, hidden} <- [
            {[@section], to_sections, to_versions},
            {[@workspace], to_versions, to_sections},
            {[@workspace, @section], to_sections, to_versions}
          ] do
        {:ok, view, _html} =
          live(log_in(conn, tenant([@site_loads | names], site)), "/admin/dashboard/document")

        render_async(view, 5_000)

        assert has_element?(view, shown),
               "#{inspect(names)} was given no edition chip it may follow"

        refute has_element?(view, hidden), "#{inspect(names)} was given a chip to a refused page"

        close(view)
      end
    end

    test "the Sections page links the versions page only for a workspace admin", %{
      conn: conn,
      site: site,
      version: version
    } do
      path = "/admin/dashboard/document/sections/#{version.id}"

      {:ok, view, _html} = live(log_in(conn, tenant([@site_loads, @section], site)), path)
      render_async(view, 5_000)
      refute has_element?(view, @versions_link), "a section admin was linked to the versions page"
      close(view)

      {:ok, view, _html} =
        live(log_in(conn, tenant([@site_loads, @workspace, @section], site)), path)

      render_async(view, 5_000)
      assert has_element?(view, @versions_link), "an admin of both lost the versions link"
      close(view)
    end

    test "a workspace with no version sends each admin to a page it may open", %{
      conn: conn,
      site: site
    } do
      empty = create_workspace!(site_id: site.id, skip_version: true, status: :active)
      path = "/admin/dashboard/document/sections/workspace/#{empty.id}"

      assert {:error, {:live_redirect, %{to: "/admin/dashboard/document"}}} =
               live(log_in(conn, tenant([@section], site)), path)

      versions = "/admin/dashboard/document/workspace-version/#{empty.id}"

      assert {:error, {:live_redirect, %{to: ^versions}}} =
               live(log_in(conn, tenant([@workspace, @section], site)), path)
    end
  end

  describe "Home's activity feed" do
    # The feed follows the areas the admin holds: what happened to a workspace is the workspace
    # area's, what happened to an issue the section area's.
    setup %{site: site} do
      create_issue!(site_id: site.id, title: "Feed Issue")
      create_workspace!(site_id: site.id, name: "Feed Workspace", skip_version: true)
      :ok
    end

    defp feed(conn, names, site) do
      {:ok, view, _html} = live(log_in(conn, tenant(names, site)), "/admin/dashboard/document")
      view |> element("#document-activity-toggle") |> render_click()

      panel =
        view
        |> render_async(5_000)
        |> LazyHTML.from_fragment()
        |> LazyHTML.query("#document-activity-panel")
        |> LazyHTML.text()

      close(view)
      panel
    end

    test "shows a workspace admin what happened to workspaces, and none of the issues", %{
      conn: conn,
      site: site
    } do
      html = feed(conn, [@workspace], site)

      assert html =~ "Feed Workspace"
      refute html =~ "Feed Issue"
    end

    test "shows a section admin what happened to issues, and none of the workspaces", %{
      conn: conn,
      site: site
    } do
      html = feed(conn, [@section], site)

      assert html =~ "Feed Issue"
      refute html =~ "Feed Workspace"
    end

    test "shows an admin of both areas both", %{conn: conn, site: site} do
      html = feed(conn, [@workspace, @section], site)

      assert html =~ "Feed Workspace"
      assert html =~ "Feed Issue"
    end
  end

  describe "the workspaces table on Home" do
    # Each row action as the table asks it: the record, and the table's state.
    defp drawn(action, status, names, site) do
      state = %{archive_status: status, current_user: tenant(names, site), master_user?: false}

      MishkaDocument.Workspace
      |> MishkaGervaz.ResourceInfo.table_row_action(action)
      |> MishkaGervaz.Table.Templates.Shared.action_visible?(%{}, state)
    end

    defp bulk_drawn(action, status, names, site) do
      state = %{archive_status: status, current_user: tenant(names, site), master_user?: false}

      MishkaDocument.Workspace
      |> MishkaGervaz.ResourceInfo.table_bulk_actions()
      |> Enum.find(&(&1.name == action))
      |> Map.fetch!(:visible)
      |> then(& &1.(state))
    end

    test "leads a section admin to the sections, and a workspace admin to the versions", %{
      site: site
    } do
      for action <- [:open, :sections] do
        assert drawn(action, :active, [@section], site)
        refute drawn(action, :active, [@workspace], site)
      end

      assert drawn(:versions, :active, [@workspace], site)
      refute drawn(:versions, :active, [@section], site)
    end

    test "offers the workspace writes to the workspace area alone", %{site: site} do
      for {action, status} <- [
            edit: :active,
            delete: :active,
            unarchive: :archived,
            permanent_destroy: :archived
          ] do
        assert drawn(action, status, [@workspace], site), "#{action} hidden from its own area"
        refute drawn(action, status, [@section], site), "#{action} shown to a section admin"
      end

      for {action, status} <- [
            archive: :active,
            unarchive: :archived,
            permanent_destroy: :archived
          ] do
        assert bulk_drawn(action, status, [@workspace], site), "bulk #{action} hidden"
        refute bulk_drawn(action, status, [@section], site), "bulk #{action} shown to sections"
      end
    end

    test "keeps each action to the records it was for", %{site: site} do
      refute drawn(:edit, :archived, [@workspace], site)
      refute drawn(:permanent_destroy, :active, [@workspace], site)
    end
  end

  describe "the event log page" do
    defp event_about!(record_id) do
      MishkaDocument.EventLog
      |> Ash.Query.filter(record_id == ^record_id and action_type == :create)
      |> Ash.read_one!(authorize?: false)
    end

    test "opens for either area and shows each the events of its own records", %{
      conn: conn,
      site: site,
      workspace: workspace,
      version: version
    } do
      section = create_section!(site_id: site.id, workspace_version_id: version.id)
      workspace_event = event_about!(workspace.id)
      section_event = event_about!(section.id)

      for {names, shown, hidden} <- [
            {[@workspace], workspace_event, section_event},
            {[@section], section_event, workspace_event}
          ] do
        assert {:ok, view, _html} =
                 live(log_in(conn, tenant(names, site)), "/admin/dashboard/document/event-logs")

        render_async(view, 5_000)

        assert has_element?(view, "[id$='#{shown.id}']"),
               "#{inspect(names)} was not shown its own area's event"

        refute has_element?(view, "[id$='#{hidden.id}']"),
               "#{inspect(names)} was shown the other area's event"

        close(view)
      end
    end
  end

  describe "dates and times" do
    test "read as the reader's language writes them, on the Sections and event log pages", %{
      conn: conn,
      site: site,
      workspace: workspace,
      version: version
    } do
      section = create_section!(site_id: site.id, workspace_version_id: version.id)
      Ash.Seed.update!(section, %{inserted_at: ~U[2024-03-09 10:00:00.000000Z]})
      Ash.Seed.update!(workspace, %{updated_at: ~U[2025-07-03 08:04:00.000000Z]})

      # An event of the workspace's own, written at the moment asserted on. Its creation event is not
      # rewritten to it: `MishkaDocument.EventLog` broadcasts every row a second time a moment after
      # writing it, as written, and the Sections page takes that copy over the row it read.
      event =
        workspace.id
        |> event_about!()
        |> Map.take([:record_id, :resource, :action, :action_type, :metadata, :data, :actor_id])
        |> Map.put(:occurred_at, ~U[2099-07-03 08:04:00.000000Z])
        |> then(&Ash.create!(MishkaDocument.EventLog, &1, action: :create, authorize?: false))

      {:ok, view, _html} =
        live(
          log_in(conn, tenant([@site_loads, @workspace, @section], site)),
          "/admin/dashboard/document/sections/#{version.id}"
        )

      # The activity feed is read by a task the loaded workspace starts, so it is awaited in a second
      # pass, once the first has drawn the workspace.
      render_async(view, 5_000)
      render_async(view, 5_000)
      assert has_element?(view, "span", "Updated Jul 3, 2025")
      assert has_element?(view, "[data-role=seccard][id$='#{section.id}']", "Mar 9, 2024")

      assert has_element?(
               view,
               "div:has(> #workspace-activity-actor-#{event.id})",
               "· 7/3, 08:04"
             )

      close(view)

      {:ok, view, _html} =
        live(log_in(conn, tenant([@workspace], site)), "/admin/dashboard/document/event-logs")

      render_async(view, 5_000)
      assert has_element?(view, "[id$='#{event.id}']", ~r/08:04\s+Jul 3\b/)
      close(view)
    end
  end

  test "the document API's names open no document page", %{conn: conn, site: site} do
    conn = log_in(conn, tenant(["admin:dashboard:runtime:page", "admin:api:document:*"], site))

    for path <- ["/admin/dashboard/document", "/admin/dashboard/document/issues"] do
      assert refused?(conn, path), "#{path} let an API admin in"
    end
  end

  test "an admin of another area is not let into any document page", %{
    conn: conn,
    site: site,
    workspace: workspace
  } do
    conn = log_in(conn, tenant(["admin:dashboard:runtime:page"], site))

    for path <- [
          "/admin/dashboard/document",
          "/admin/dashboard/document/event-logs",
          "/admin/dashboard/document/workspace-version/#{workspace.id}",
          "/admin/dashboard/document/issues"
        ] do
      assert refused?(conn, path), "#{path} let a page admin in"
    end
  end

  describe "setting the documentation up" do
    test "is offered to an admin holding every area it writes", %{conn: conn, site: site} do
      conn = log_in(conn, tenant([@workspace | @provision], site))
      {:ok, view, _html} = live(conn, "/admin/dashboard/document")

      assert has_element?(view, "#document-kit-upgrade-open")
      refute render_submit(view, "kit_check", %{"site_id" => site.id}) =~ "not allowed"

      close(view)
    end

    test "is refused to an admin missing any one of them", %{conn: conn, site: site} do
      for missing <- @provision do
        user = tenant([@workspace | @provision -- [missing]], site)
        {:ok, view, _html} = live(log_in(conn, user), "/admin/dashboard/document")

        refute has_element?(view, "#document-kit-upgrade-open"), "offered without #{missing}"

        assert render_submit(view, "kit_check", %{"site_id" => site.id}) =~ "not allowed",
               "checked without #{missing}"

        assert render_click(view, "extension_install", %{"site_id" => site.id}) =~ "not allowed",
               "set up without #{missing}"

        close(view)
      end
    end
  end
end
