defmodule MishkaDocumentWeb.Test.AdminActionsTest do
  @moduledoc """
  The buttons plugins add to a document's Sections screen on `document:workspace:admin_actions`
  (`MishkaDocumentWeb.AdminActions`): a reader who may manage the workspace is shown each action a
  plugin adds, and its button opens the plugin's LiveComponent in the screen's modal with the
  document it is about; a reader who may not is shown none and no plugin is asked; an event that
  cannot run leaves the screen as it is without them.

  `async: false` — the event's compiled module and the plugin registry are the node's.
  """
  use MishkaDocument.ConnCase, async: false

  @moduletag :capture_log

  import Phoenix.LiveViewTest
  import MishkaDocument.Test.Factory

  alias MishkaCmsCore.Runtime.States.SiteState
  alias MishkaDocument.Test.Plugins.WorkspaceAdminAction
  alias MishkaDocumentWeb.AdminActions
  alias MishkaInstaller.Event.{Event, EventHandler, ModuleStateCompiler}

  require Ash.Query

  @event "document:workspace:admin_actions"
  @workspace "admin:dashboard:document:workspace"
  @section "admin:dashboard:document:section"
  # Drawing the sections table loads each row's site, which the core opens to a full admin.
  @site_loads "admin:api:*"

  @actions "#document-admin-actions"
  @open "#document-admin-action-probe-open"
  @modal "#document-admin-action-modal"

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

    workspace =
      create_workspace!(site_id: site.id, name: "Probe Handbook", slug: "probe", status: :active)

    version =
      MishkaDocument.WorkspaceVersion
      |> Ash.Query.filter(workspace_id == ^workspace.id)
      |> Ash.read_one!(tenant: site.id, authorize?: false)

    Process.register(self(), :__admin_actions_probe__)
    register_plugin!(WorkspaceAdminAction)

    {:ok, conn: conn, site: site, workspace: workspace, version: version}
  end

  defp register_plugin!(module) do
    {:ok, _} =
      Event.write(%{
        name: module,
        event: @event,
        extension: :mishka_installer,
        status: :started
      })

    on_exit(fn -> Event.unregister(:name, module, false) end)
    :ok = EventHandler.do_compile(@event, :start, false)
  end

  # The event answers as one whose plugins are not all loaded, until the test exits.
  defp cannot_run! do
    :ok = ModuleStateCompiler.purge_create([], @event, [__MODULE__.NotLoadedPlugin])
    on_exit(fn -> EventHandler.do_compile(@event, :start, false) end)
  end

  defp tenant(names, site), do: create_user_with_permissions!(names, site_id: site.id)

  defp log_in(conn, user) do
    conn
    |> Plug.Test.init_test_session(%{})
    |> Plug.Conn.put_session(:master_mode, false)
    |> AshAuthentication.Plug.Helpers.store_in_session(user)
  end

  # The workspace loads in `start_async/3`, and its handler starts the activity load; a view stopped
  # while one is in flight raises on the way down once the test's sandbox owner is gone.
  defp open(conn, user, version) do
    {:ok, view, _html} =
      live(log_in(conn, user), "/admin/dashboard/document/sections/#{version.id}")

    render_async(view, 5_000)
    render_async(view, 5_000)
    view
  end

  # Sends the screen `message`. The screen hands it to the open modal's component with a message to
  # itself, so once the screen has taken it, the next render follows that update.
  defp heard(view, message) do
    send(view.pid, message)
    :sys.get_state(view.pid)
  end

  defp close(view) do
    render_async(view, 5_000)
    ref = Process.monitor(view.pid)
    GenServer.stop(view.pid, :normal)
    assert_receive {:DOWN, ^ref, :process, _pid, _reason}
  end

  describe "a reader who may manage the workspace" do
    setup %{site: site} do
      %{user: tenant([@site_loads, @workspace, @section], site)}
    end

    test "is shown the plugin's action, and the plugin is told the document", %{
      conn: conn,
      site: site,
      workspace: workspace,
      version: version,
      user: user
    } do
      view = open(conn, user, version)

      assert has_element?(view, @open, "Probe action")
      assert has_element?(view, "#{@open} .hero-bolt")

      buttons = view |> element(@actions) |> render() |> LazyHTML.from_fragment()
      assert buttons |> LazyHTML.query("button") |> Enum.count() == 1

      refute has_element?(view, @modal)

      workspace_id = workspace.id
      version_id = version.id
      user_id = user.id
      site_id = site.id

      assert_receive {:admin_actions_asked,
                      %{
                        site_id: ^site_id,
                        workspace: %{id: ^workspace_id, slug: "probe", name: "Probe Handbook"},
                        version: %{id: ^version_id, version_number: _number},
                        actor: %{id: ^user_id}
                      }}

      close(view)
    end

    test "opens the plugin's component in the modal, with the document it is about", %{
      conn: conn,
      site: site,
      version: version,
      user: user
    } do
      view = open(conn, user, version)

      view |> element(@open) |> render_click()

      assert has_element?(view, "#{@modal} #probe-panel")
      assert has_element?(view, "#probe-panel-site", site.id)
      assert has_element?(view, "#probe-panel-workspace", "probe")
      assert has_element?(view, "#probe-panel-version", version.version_number)
      assert has_element?(view, "#probe-panel-greeting", "hello")
      assert has_element?(view, "#probe-panel-user", user.id)

      heard(view, {:probe_heard, 1})
      assert has_element?(view, "#probe-panel-heard-0", "{:probe_heard, 1}")

      render_click(view, "close_admin_action", %{})
      refute has_element?(view, @modal)

      heard(view, {:probe_heard, 2})
      refute has_element?(view, @modal)

      close(view)
    end

    test "opens nothing for an action no plugin added", %{
      conn: conn,
      version: version,
      user: user
    } do
      view = open(conn, user, version)

      render_click(view, "open_admin_action", %{"id" => "no-component"})
      refute has_element?(view, @modal)

      close(view)
    end

    test "is shown no action when the event cannot run, and the screen still works", %{
      conn: conn,
      version: version,
      user: user
    } do
      cannot_run!()

      view = open(conn, user, version)

      assert has_element?(view, "h1", "Probe Handbook")
      refute has_element?(view, @actions)
      refute_received {:admin_actions_asked, _state}

      render_click(view, "open_admin_action", %{"id" => "probe"})
      refute has_element?(view, @modal)

      close(view)
    end
  end

  describe "a reader who may not manage the workspace" do
    test "is shown no action, and no plugin is asked", %{conn: conn, site: site, version: version} do
      view = open(conn, tenant([@site_loads, @section], site), version)

      assert has_element?(view, "h1", "Probe Handbook")
      refute has_element?(view, @actions)
      refute_received {:admin_actions_asked, _state}

      render_click(view, "open_admin_action", %{"id" => "probe"})
      refute has_element?(view, @modal)

      close(view)
    end
  end

  describe "AdminActions.actions/2" do
    test "keeps the first well-formed action of each id", %{
      workspace: workspace,
      version: version
    } do
      context = AdminActions.context(workspace, version)

      assert [%{id: "probe", label: "Probe action", icon: "hero-bolt", assigns: assigns}] =
               AdminActions.actions(context, nil)

      assert %{greeting: "hello", workspace: %{slug: "probe"}, current_user: :me} =
               AdminActions.assigns(%{assigns: assigns}, context, :me)
    end

    test "is empty when the event cannot run", %{workspace: workspace, version: version} do
      cannot_run!()
      assert AdminActions.actions(AdminActions.context(workspace, version), nil) == []
    end
  end
end
