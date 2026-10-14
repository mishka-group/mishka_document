defmodule MishkaDocumentWeb.Test.WorkspaceVersionCloneTest do
  @moduledoc """
  The versions screen's Clone row action, as an admin uses it: the button on each row for an admin
  who may write versions and pages, the modal it opens, the copy it runs and what the screen shows
  after it.
  """
  use MishkaDocument.ConnCase

  @moduletag :capture_log

  import Phoenix.LiveViewTest
  import MishkaDocument.Test.Factory

  alias MishkaCmsCore.Runtime.States.SiteState
  alias MishkaDocument.{Section, WorkspaceVersion}

  require Ash.Query

  @workspace "admin:dashboard:document:workspace"
  @section "admin:dashboard:document:section"

  @clone_button ~s(button[phx-value-event="clone"])
  @modal "#workspace-version-clone-modal"
  @form "#clone-version-form"

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
      create_workspace!(
        site_id: site.id,
        name: "Clone Handbook",
        status: :active,
        skip_version: true
      )

    source =
      create_workspace_version!(
        workspace_id: workspace.id,
        site_id: site.id,
        version_number: "0.0.9",
        status: :draft
      )

    page = create_section!(site_id: site.id, workspace_version_id: source.id, slug: "intro")
    create_section!(site_id: site.id, workspace_version_id: source.id, slug: "usage")
    create_note!(site_id: site.id, section_id: page.id)

    {:ok, conn: conn, site: site, workspace: workspace, source: source}
  end

  defp log_in(conn, names, site) do
    user = create_user_with_permissions!(names, site_id: site.id)

    conn
    |> Plug.Test.init_test_session(%{})
    |> Plug.Conn.put_session(:master_mode, false)
    |> AshAuthentication.Plug.Helpers.store_in_session(user)
  end

  defp open_versions(conn, workspace) do
    {:ok, view, _html} = live(conn, "/admin/dashboard/document/workspace-version/#{workspace.id}")
    render_async(view, 5_000)
    view
  end

  defp open_clone(view, source) do
    view
    |> element(~s(#{@clone_button}[phx-value-values*="#{source.id}"]))
    |> render_click()

    view
  end

  defp versions(workspace, site) do
    WorkspaceVersion
    |> Ash.Query.filter(workspace_id == ^workspace.id)
    |> Ash.read!(tenant: site.id, authorize?: false)
  end

  test "an admin of versions and pages is given Clone on each row", %{
    conn: conn,
    site: site,
    workspace: workspace,
    source: source
  } do
    view = conn |> log_in([@workspace, @section], site) |> open_versions(workspace)

    assert has_element?(view, ~s(#{@clone_button}[phx-value-values*="#{source.id}"]))
    refute has_element?(view, @modal)
  end

  test "an admin of versions alone is not given Clone", %{
    conn: conn,
    site: site,
    workspace: workspace
  } do
    view = conn |> log_in([@workspace], site) |> open_versions(workspace)

    assert has_element?(view, "#workspace-versions-table")
    refute has_element?(view, @clone_button)
  end

  test "Clone opens a form naming the version it copies", %{
    conn: conn,
    site: site,
    workspace: workspace,
    source: source
  } do
    view = conn |> log_in([@workspace, @section], site) |> open_versions(workspace)
    open_clone(view, source)

    assert has_element?(view, @modal)
    assert has_element?(view, "#{@modal}-description", "0.0.9")
    assert has_element?(view, ~s(#{@form} input[name="clone[version_number]"][dir="ltr"]))
    assert has_element?(view, ~s(#{@form} input[name="clone[version_name]"]))
    assert has_element?(view, ~s(#{@form} textarea[name="clone[description]"]))
    assert has_element?(view, "#clone-version-submit")
  end

  test "submitting copies the version, closes the form and says what was copied", %{
    conn: conn,
    site: site,
    workspace: workspace,
    source: source
  } do
    view = conn |> log_in([@workspace, @section], site) |> open_versions(workspace)
    open_clone(view, source)

    running =
      view
      |> form(@form,
        clone: %{version_number: "0.0.10", version_name: "Next", description: "Copied"}
      )
      |> render_submit()

    running_button =
      running |> LazyHTML.from_fragment() |> LazyHTML.query("#clone-version-submit")

    assert LazyHTML.attribute(running_button, "disabled") == [""]
    assert LazyHTML.text(running_button) =~ "Copying pages and notes"

    html = render_async(view, 10_000)

    assert html =~ "Version 0.0.10 created from 0.0.9"
    assert html =~ "2 pages, 1 note copied"
    refute has_element?(view, @modal)

    assert %WorkspaceVersion{} =
             copy = Enum.find(versions(workspace, site), &(&1.version_number == "0.0.10"))

    assert copy.source_version_id == source.id
    assert copy.version_name == "Next"

    assert Section
           |> Ash.Query.filter(workspace_version_id == ^copy.id)
           |> Ash.count!(tenant: site.id, authorize?: false) == 2

    render_async(view, 5_000)
    assert has_element?(view, ~s(#{@clone_button}[phx-value-values*="#{copy.id}"]))
  end

  test "a version number the document has is shown on the form, and nothing is copied", %{
    conn: conn,
    site: site,
    workspace: workspace,
    source: source
  } do
    view = conn |> log_in([@workspace, @section], site) |> open_versions(workspace)
    open_clone(view, source)

    view
    |> form(@form, clone: %{version_number: "0.0.9"})
    |> render_submit()

    html = render_async(view, 10_000)

    assert has_element?(view, @modal)
    assert html =~ "Version number must be unique within a workspace."
    refute has_element?(view, "#clone-version-submit[disabled]")
    assert length(versions(workspace, site)) == 1
  end
end
