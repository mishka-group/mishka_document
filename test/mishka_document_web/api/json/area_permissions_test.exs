defmodule MishkaDocumentWeb.Api.Json.AreaPermissionsTest do
  @moduledoc """
  The admin JSON:API answers the `admin:api:` document areas, and only them.

  A bearer holding `admin:api:document:workspace` reads and writes workspaces, their versions and
  version lineage; one holding `admin:api:document:section` reads and writes sections and issues,
  and none of the workspace side. The dashboard's names for the same areas open nothing here, and
  neither does an API admin of another area.
  """
  use MishkaDocument.ConnCase

  import MishkaDocument.Test.Factory

  alias MishkaCmsCore.Runtime.States.SiteState

  @moduletag :capture_log

  @password "Password123!"
  @sign_in "/api/json/v1/auth/user/sign-in"
  @workspaces "/api/json/v1/tenant/admin/mishka-document/workspace"
  @sections "/api/json/v1/tenant/admin/mishka-document/section"
  @issues "/api/json/v1/tenant/admin/mishka-document/issue"
  @versions "/api/json/v1/tenant/admin/mishka-document/workspace-version"
  @lineage "/api/json/v1/tenant/admin/mishka-document/workspace-version-lineage"

  setup do
    SiteState.clear()
    :ok = Swoosh.TestAssertions.set_swoosh_global()
    Application.put_env(:ash_json_api, MishkaDocument, router: MishkaDocument.TestRouter)

    site = create_site!(name: "localhost", host: "localhost", active: true, priority: 50)

    SiteState.save(%{
      id: site.id,
      name: site.name,
      host: site.host,
      priority: site.priority,
      active: site.active,
      master: site.master
    })

    on_exit(fn -> SiteState.clear() end)

    workspace = create_workspace!(site_id: site.id, name: "API Handbook", status: :active)
    section = create_section!(site_id: site.id)
    issue = create_issue!(site_id: site.id, section_id: section.id)

    {:ok, site: site, workspace: workspace, section: section, issue: issue}
  end

  defp bearer(names, site) do
    email = "api-#{System.unique_integer([:positive])}@example.com"

    create_user_with_permissions!(names,
      email: email,
      password: @password,
      password_confirmation: @password,
      site_id: site.id
    )

    response =
      make_api_request(@sign_in, %{
        "type" => "user",
        "attributes" => %{"email" => email, "password" => @password}
      })

    assert response.status == 201
    %{"meta" => %{"token" => token}} = Jason.decode!(response.resp_body)
    [{"authorization", "Bearer #{token}"}]
  end

  defp status_of(path, headers),
    do: make_api_request(path, %{}, method: :get, headers: headers).status

  defp rename(path, type, attributes, headers) do
    make_api_request(path, %{"type" => type, "attributes" => attributes},
      method: :patch,
      headers: headers
    ).status
  end

  defp create(path, type, attributes, headers) do
    response =
      make_api_request(path, %{"type" => type, "attributes" => attributes},
        method: :post,
        headers: headers
      )

    {response.status, response.resp_body}
  end

  defp remove(path, headers),
    do: make_api_request(path, %{}, method: :delete, headers: headers).status

  # Each workspace-side route as `{create path, type, attributes, removal path}`, with fresh records
  # so every bearer asked starts from the same state.
  defp workspace_side_routes(site) do
    n = System.unique_integer([:positive])
    workspace = create_workspace!(site_id: site.id, skip_version: true, status: :active)
    archivable = create_workspace!(site_id: site.id, skip_version: true, status: :active)
    source = create_workspace_version!(workspace_id: workspace.id, site_id: site.id)
    cloned = create_workspace_version!(workspace_id: workspace.id, site_id: site.id)
    removable = create_workspace_version!(workspace_id: workspace.id, site_id: site.id)

    lineage =
      create_workspace_version_lineage!(source_version_id: source.id, site_id: site.id)

    [
      {@workspaces, "workspace",
       %{"name" => "New #{n}", "slug" => "new-#{n}", "status" => "active", "language" => "en"},
       "#{@workspaces}/#{archivable.id}/archive"},
      {@versions, "workspace_version",
       %{"workspace_id" => workspace.id, "version_number" => "9.#{n}.0", "status" => "draft"},
       "#{@versions}/#{removable.id}"},
      {@lineage, "workspace_version_lineage",
       %{"source_version_id" => source.id, "new_version_id" => cloned.id},
       "#{@lineage}/#{lineage.id}"}
    ]
  end

  describe "the workspace area" do
    test "an API bearer of it reads and writes workspaces, and reads no issue", %{
      site: site,
      workspace: workspace,
      issue: issue
    } do
      headers = bearer(["admin:api:document:workspace"], site)

      assert status_of(@workspaces, headers) == 200
      assert status_of(@versions, headers) == 200
      assert status_of(@lineage, headers) == 200

      assert rename(
               "#{@workspaces}/#{workspace.id}",
               "workspace",
               %{"name" => "Renamed"},
               headers
             ) ==
               200

      assert status_of(@issues, headers) == 403
      assert status_of("#{@issues}/#{issue.id}", headers) in [403, 404]
    end

    test "an API bearer of it creates and removes workspaces, versions and lineage", %{
      site: site
    } do
      headers = bearer(["admin:api:document:workspace"], site)

      for {path, type, attributes, removal} <- workspace_side_routes(site) do
        assert {201, _body} = create(path, type, attributes, headers), "#{path} refused a create"
        assert remove(removal, headers) in [200, 204], "#{removal} refused a removal"
      end
    end

    test "an API bearer of the section area, or its dashboard name, creates and removes none", %{
      site: site
    } do
      for names <- [["admin:api:document:section"], ["admin:dashboard:document:workspace"]] do
        headers = bearer(names, site)

        for {path, type, attributes, removal} <- workspace_side_routes(site) do
          assert {403, _body} = create(path, type, attributes, headers),
                 "#{path} let #{inspect(names)} create"

          assert remove(removal, headers) in [403, 404],
                 "#{removal} let #{inspect(names)} remove"
        end
      end
    end

    test "its dashboard name opens none of it here", %{site: site, workspace: workspace} do
      headers = bearer(["admin:dashboard:document:workspace"], site)

      assert status_of(@workspaces, headers) == 403

      assert rename(
               "#{@workspaces}/#{workspace.id}",
               "workspace",
               %{"name" => "Renamed"},
               headers
             ) in [
               403,
               404
             ]
    end
  end

  describe "the section area" do
    test "an API bearer of it writes sections, and reads and writes nothing of the workspace side",
         %{site: site, workspace: workspace, section: section} do
      headers = bearer(["admin:api:document:section"], site)
      version = create_workspace_version!(workspace_id: workspace.id, site_id: site.id)

      lineage =
        create_workspace_version_lineage!(source_version_id: version.id, site_id: site.id)

      assert status_of(@sections, headers) == 200
      assert status_of(@issues, headers) == 200

      assert rename("#{@sections}/#{section.id}", "section", %{"title" => "Retitled"}, headers) ==
               200

      for path <- [
            @workspaces,
            "#{@workspaces}/#{workspace.id}",
            @versions,
            "#{@versions}/#{version.id}",
            @lineage,
            "#{@lineage}/#{lineage.id}"
          ] do
        assert status_of(path, headers) == 403, "#{path} answered a section bearer"
      end

      assert rename(
               "#{@workspaces}/#{workspace.id}",
               "workspace",
               %{"name" => "Renamed"},
               headers
             ) ==
               403
    end

    test "a section's workspace version is included for a bearer holding the workspace area too",
         %{site: site, section: section} do
      included = "#{@sections}/#{section.id}?include=workspace_version"

      assert status_of("#{@sections}/#{section.id}", bearer(["admin:api:document:section"], site)) ==
               200

      assert status_of(included, bearer(["admin:api:document:section"], site)) == 403

      assert status_of(
               included,
               bearer(["admin:api:document:section", "admin:api:document:workspace"], site)
             ) == 200
    end

    test "its dashboard name opens none of it here", %{site: site, section: section} do
      headers = bearer(["admin:dashboard:document:section"], site)

      assert status_of(@sections, headers) == 403
      assert status_of(@issues, headers) == 403

      assert rename("#{@sections}/#{section.id}", "section", %{"title" => "Retitled"}, headers) in [
               403,
               404
             ]
    end
  end

  test "an API admin of another area is refused both", %{site: site} do
    headers = bearer(["admin:api:runtime:page"], site)

    assert status_of(@workspaces, headers) == 403
    assert status_of(@sections, headers) == 403
  end

  test "the whole document API holds both areas", %{site: site, workspace: workspace} do
    headers = bearer(["admin:api:document:*"], site)

    assert status_of(@sections, headers) == 200

    assert rename("#{@workspaces}/#{workspace.id}", "workspace", %{"name" => "Renamed"}, headers) ==
             200
  end
end
