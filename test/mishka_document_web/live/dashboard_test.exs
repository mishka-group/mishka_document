defmodule MishkaDocumentWeb.Test.DashboardTest do
  @moduledoc """
  Mounts this extension's admin dashboard as a logged-in master admin — the page-level guard a
  compile cannot give: it renders the real LiveView (dead + connected), so a broken assign in the
  ported React layout surfaces here, and the preserved panels (event logs / issues toggles) are
  asserted still wired.

  The workspaces table and the activity feed both load asynchronously, so those assertions run
  against `render_async/1`.
  """
  use MishkaDocument.ConnCase

  import Phoenix.LiveViewTest
  import MishkaDocument.Test.Factory

  alias MishkaCmsCore.Accounts.{Permission, User, UserPermission}
  alias MishkaCmsCore.Runtime.States.SiteState
  alias MishkaDocument.Issue

  require Ash.Query

  @password "Password123!"

  setup %{conn: conn} do
    SiteState.clear()
    :ok = Swoosh.TestAssertions.set_swoosh_global()

    site = master_site()

    SiteState.save(%{
      id: site.id,
      name: site.name,
      host: site.host,
      priority: site.priority,
      active: site.active,
      master: site.master
    })

    :persistent_term.put(:mishka_installed, true)
    on_exit(fn -> :persistent_term.erase(:mishka_installed) end)

    # THIS SITE HAS THE DOCUMENTATION. Everything below is about the dashboard, and a site that has
    # never been set up opens on the installer instead — which is the right answer there and the
    # wrong fixture here. `MishkaDocument.ProvisionTest` is where the installer screen is driven.
    :ok = MishkaCmsCore.Install.Extensions.mark_installed!(site.id, :mishka_document, "test")

    conn =
      conn
      |> Map.put(:host, "localhost")
      |> Map.update!(:req_headers, &[{"host", "localhost"} | List.keydelete(&1, "host", 0)])

    {:ok, conn: conn}
  end

  test "every documentation page says it is powered by Mishka Document, linking to its own page",
       %{
         conn: conn
       } do
    conn = log_in(conn, create_admin("doccredit@example.com"))

    {:ok, view, _html} = live(conn, "/admin/dashboard/document")

    assert has_element?(
             view,
             "#admin-footer a[href='https://mishka.tools/cms/extensions/documentation']",
             "Mishka Document"
           )

    footer = render(element(view, "#admin-footer"))
    assert footer =~ "© #{MishkaCmsCore.Layouts.copyright_years()}"
    assert footer =~ "Powered by"
  end

  test "document dashboard renders the React overview with its real panels still wired", %{
    conn: conn
  } do
    conn = log_in(conn, create_admin("docboss@example.com"))

    {:ok, view, html} = live(conn, "/admin/dashboard/document")

    assert html =~ "Documentation Management"
    # Preserved real functionality: the issues panel is still wired.
    assert has_element?(view, "#toggle-issues-btn")

    # The workspaces table loads asynchronously, so it is only there after the async render.
    assert render_async(view, 5_000) =~ "Workspaces"
    assert has_element?(view, "#workspaces-table_workspaces")

    # Logs are the shared ActivityFeed (same component as the blog / runtime pages), fetched only
    # once the panel is opened. Its skeleton is rendered up front on purpose — the panel opens
    # client-side a round trip before the fetch is asked for — and is replaced by the first result.
    assert has_element?(view, "#document-activity-toggle")
    assert has_element?(view, "#document-activity-skeleton")

    view |> element("#document-activity-toggle") |> render_click()

    assert render_async(view, 5_000) =~ "System Logs"
    refute has_element?(view, "#document-activity-skeleton")
  end

  # Restore and Permanent Delete run `:master_unarchive` and `:master_permanent_destroy`, an update
  # and a destroy, on the issue they read first — neither is a generic action to run as one.
  test "a master restores one archived issue and permanently deletes another from the issues panel",
       %{conn: conn} do
    [restored, deleted] = for _ <- 1..2, do: archived_issue!(master_site())

    conn = log_in(conn, create_admin("docboss@example.com"))
    {:ok, view, _html} = live(conn, "/admin/dashboard/document")

    view |> element("#toggle-issues-btn") |> render_click()
    view |> element(~s(#issues-panel button[phx-value-status="archived"])) |> render_click()
    render_async(view, 5_000)

    view
    |> element(~s(#issues-#{restored.id} button[phx-click="unarchive_issue"]))
    |> render_click()

    refute has_element?(view, "#issues-#{restored.id}")

    assert %{archived_at: nil} =
             Ash.get!(Issue, restored.id, action: :master_get, authorize?: false)

    view
    |> element(~s(#issues-#{deleted.id} button[phx-click="permanent_delete_issue"]))
    |> render_click()

    refute has_element?(view, "#issues-#{deleted.id}")
    assert {:error, _gone} = Ash.get(Issue, deleted.id, action: :master_get, authorize?: false)
  end

  # A workspace's activity names who did each thing by their account's address. The page is an admin
  # page and loads that account as the admin looking at it, so the address is there to show — and the
  # event a later edit broadcasts is loaded the same way when the page prepends it.
  test "a master opens a workspace's sections page and its activity names the account that acted",
       %{conn: conn} do
    site = master_site()
    writer = create_user!(site_id: site.id, email: "writer@example.com")

    workspace =
      MishkaDocument.Workspace
      |> Ash.Changeset.for_create(
        :create,
        %{name: "Activity Workspace", slug: "activity-ws", status: :active, language: "en"},
        tenant: site.id,
        actor: writer,
        authorize?: false
      )
      |> Ash.create!()

    version = create_workspace_version!(workspace_id: workspace.id, site_id: site.id)

    conn = log_in(conn, create_admin("docboss@example.com"))
    {:ok, view, _html} = live(conn, "/admin/dashboard/document/sections/#{version.id}")

    # The workspace loads first, and its handler is what starts the activity load: two awaits.
    render_async(view, 5_000)
    assert render_async(view, 5_000) =~ "writer@example.com"

    editor = create_user!(site_id: site.id, email: "editor@example.com")

    workspace
    |> Ash.Changeset.for_update(:update, %{name: "Activity Workspace, renamed"},
      tenant: site.id,
      actor: editor,
      authorize?: false
    )
    |> Ash.update!()

    assert render(view) =~ "editor@example.com"
  end

  test "an expanded section's activity names the account that acted on it", %{conn: conn} do
    site = master_site()
    workspace = create_workspace!(site_id: site.id)
    version = create_workspace_version!(workspace_id: workspace.id, site_id: site.id)
    section = create_section!(site_id: site.id, workspace_version_id: version.id)
    sectioner = create_user!(site_id: site.id, email: "sectioner@example.com")

    section
    |> Ash.Changeset.for_update(:update, %{title: "Retitled section"},
      tenant: site.id,
      actor: sectioner,
      authorize?: false
    )
    |> Ash.update!()

    conn = log_in(conn, create_admin("docboss@example.com"))
    {:ok, view, _html} = live(conn, "/admin/dashboard/document/sections/#{version.id}")
    render_async(view, 5_000)
    render_async(view, 5_000)

    view
    |> element(~s([phx-click="expand_row"][phx-value-id="#{section.id}"]))
    |> render_click()

    assert render_async(view, 5_000) =~ "sectioner@example.com"
  end

  # THE ADDRESS A DOCUMENT IS READ AT DRAWS ITS VERSION'S FRONT PAGE, so the Sections screen names
  # the one the version being looked at draws there, beside the address.
  test "the Sections screen names the page its version draws at the document's address", %{
    conn: conn
  } do
    site = master_site()
    workspace = create_workspace!(site_id: site.id)
    version = create_workspace_version!(workspace_id: workspace.id, site_id: site.id)
    bare = create_workspace_version!(workspace_id: workspace.id, site_id: site.id)

    create_section!(
      site_id: site.id,
      workspace_version_id: version.id,
      title: "Get started",
      front_page: true
    )

    conn = log_in(conn, create_admin("docfront@example.com"))

    {:ok, view, _html} = live(conn, "/admin/dashboard/document/sections/#{version.id}")
    render_async(view, 5_000)
    render_async(view, 5_000)
    assert has_element?(view, "#section-front-page", "Get started")

    {:ok, view, _html} = live(conn, "/admin/dashboard/document/sections/#{bare.id}")
    render_async(view, 5_000)
    render_async(view, 5_000)
    refute has_element?(view, "#section-front-page")
  end

  defp archived_issue!(site) do
    issue = create_issue!(site_id: site.id)
    Ash.destroy!(issue, action: :master_destroy, authorize?: false)
    issue
  end

  defp master_site do
    MishkaCmsCore.Runtime.Site
    |> Ash.Query.filter(master == true)
    |> Ash.Query.limit(1)
    |> Ash.read_one!(authorize?: false)
    |> case do
      nil -> create_site!(name: "localhost", host: "localhost", active: true, master: true)
      site -> site
    end
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

  defp create_admin(email) do
    {:ok, user} =
      User
      |> Ash.Changeset.for_create(
        :register_with_password,
        %{email: email, password: @password, password_confirmation: @password},
        authorize?: false
      )
      |> Ash.create()

    UserPermission
    |> Ash.Changeset.for_create(:assign, %{}, authorize?: false)
    |> Ash.Changeset.force_change_attribute(:user_id, user.id)
    |> Ash.Changeset.force_change_attribute(:permission_id, star_permission().id)
    |> Ash.create!(authorize?: false)

    user
  end

  defp log_in(conn, user) do
    conn
    |> Plug.Test.init_test_session(%{})
    |> Plug.Conn.put_session(:master_mode, true)
    |> AshAuthentication.Plug.Helpers.store_in_session(user)
  end
end
