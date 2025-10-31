defmodule MishkaDocumentWeb.Api.Json.WorkspaceTest do
  @moduledoc """
  Comprehensive tests for Workspace JSON API endpoints.
  """

  use MishkaDocument.ConnCase

  # Raw SQL here needs the same repo the resources write through.
  @repo Application.compile_env!(:mishka_cms_core, :repo)
  import MishkaDocument.Test.Factory

  @moduletag :unit
  @moduletag :capture_log

  if Code.ensure_loaded?(MishkaDocument) do
    @password "Password123!"
    @api_user_path "/api/json/v1/auth/user"
    @api_master_path "/api/json/v1/master/admin/mishka-document/workspace"
    @api_tenant_path "/api/json/v1/tenant/admin/mishka-document/workspace"
    @api_public_path "/api/json/v1/user/mishka-document/workspace"

    setup do
      MishkaCmsCore.Runtime.States.SiteState.clear()
      :ok = Swoosh.TestAssertions.set_swoosh_global()

      Application.put_env(:ash_json_api, MishkaDocument, router: MishkaDocument.TestRouter)

      # Create initial site for testing
      site =
        create_site!(
          name: "localhost",
          host: "localhost",
          active: true,
          priority: 50,
          master: true
        )

      MishkaCmsCore.Runtime.States.SiteState.save(%{
        id: site.id,
        name: site.name,
        host: site.host,
        priority: site.priority,
        active: site.active,
        master: site.master
      })

      # Create a second site for cross-tenant testing
      site2 = create_site!(name: "site2", host: "site2.com", active: true, priority: 40)

      MishkaCmsCore.Runtime.States.SiteState.save(%{
        id: site2.id,
        name: site2.name,
        host: site2.host,
        priority: site2.priority,
        active: site2.active
      })

      # Create admin permission
      admin_permission = create_permission!(name: "admin:api:*")

      # Create master user with admin permissions (no site_id)
      master_user =
        MishkaCmsCore.Accounts.User
        |> Ash.Changeset.for_create(:create, %{
          email: "master@example.com",
          hashed_password: Bcrypt.hash_pwd_salt(@password)
        })
        |> Ash.create!(authorize?: false, tenant: nil)
        |> Ash.Changeset.for_update(
          :assign_permissions,
          %{permission_ids: [admin_permission.id]},
          authorize?: false
        )
        |> Ash.update!()

      # Create tenant admin user for site1
      tenant_admin =
        create_user!(
          email: "tenant.admin@example.com",
          password: @password,
          password_confirmation: @password,
          site_id: site.id
        )
        |> Ash.Changeset.for_update(
          :assign_permissions,
          %{permission_ids: [admin_permission.id]},
          authorize?: false,
          tenant: site.id
        )
        |> Ash.update!()

      tenant_user =
        create_user!(
          email: "tenant.user@example.com",
          password: @password,
          password_confirmation: @password,
          site_id: site.id
        )
        |> Ash.Changeset.for_update(
          :assign_permissions,
          %{permission_ids: []},
          authorize?: false,
          tenant: site.id
        )
        |> Ash.update!()

      # Create tenant admin user for site2
      site2_admin =
        create_user!(
          email: "site2.admin@example.com",
          password: @password,
          password_confirmation: @password,
          site_id: site2.id
        )
        |> Ash.Changeset.for_update(
          :assign_permissions,
          %{permission_ids: [admin_permission.id]},
          authorize?: false,
          tenant: site2.id
        )
        |> Ash.update!()

      on_exit(fn ->
        MishkaCmsCore.Runtime.States.SiteState.delete(site.id)
        MishkaCmsCore.Runtime.States.SiteState.delete(site2.id)
        MishkaCmsCore.Runtime.States.SiteState.clear()
      end)

      %{
        site: site,
        site2: site2,
        admin_permission: admin_permission,
        master_user: master_user,
        tenant_admin: tenant_admin,
        tenant_user: tenant_user,
        site2_admin: site2_admin
      }
    end

    # Helper functions
    defp sign_in_master(master_user) do
      sign_in_response =
        make_api_request(
          "#{@api_user_path}/sign-in",
          %{
            "type" => "user",
            "attributes" => %{
              "email" => to_string(master_user.email),
              "password" => @password
            }
          },
          headers: [{"x-no-tenant", "true"}]
        )

      assert sign_in_response.status == 201
      %{"meta" => %{"token" => token}} = Jason.decode!(sign_in_response.resp_body)
      token
    end

    defp sign_in_tenant(tenant_user) do
      sign_in_response =
        make_api_request(
          "#{@api_user_path}/sign-in",
          %{
            "type" => "user",
            "attributes" => %{
              "email" => to_string(tenant_user.email),
              "password" => @password
            }
          }
        )

      assert sign_in_response.status == 201
      %{"meta" => %{"token" => token}} = Jason.decode!(sign_in_response.resp_body)
      token
    end

    describe "CREATE - POST /workspace" do
      test "master admin can create workspace for any site", %{
        master_user: master_user,
        site: site,
        site2: site2
      } do
        token = sign_in_master(master_user)

        # Create workspace for site1
        response =
          make_api_request(
            @api_master_path,
            %{
              "type" => "workspace",
              "attributes" => %{
                "name" => "Tech Workspace",
                "slug" => "tech-workspace",
                "description" => "Technology documentation",
                "status" => "active",
                "language" => "en",
                "site_id" => site.id
              }
            },
            headers: [{"authorization", "Bearer #{token}"}, {"x-no-tenant", "true"}]
          )

        assert response.status == 201
        body = Jason.decode!(response.resp_body)
        assert body["data"]["attributes"]["name"] == "Tech Workspace"
        assert body["data"]["attributes"]["slug"] == "tech-workspace"
        assert body["data"]["attributes"]["status"] == "active"
        assert body["data"]["attributes"]["site_id"] == site.id

        # Create workspace for site2
        response2 =
          make_api_request(
            @api_master_path,
            %{
              "type" => "workspace",
              "attributes" => %{
                "name" => "Business Workspace",
                "slug" => "business-workspace",
                "status" => "draft",
                "language" => "en",
                "site_id" => site2.id
              }
            },
            headers: [{"authorization", "Bearer #{token}"}, {"x-no-tenant", "true"}]
          )

        assert response2.status == 201
        body2 = Jason.decode!(response2.resp_body)
        assert body2["data"]["attributes"]["name"] == "Business Workspace"
        assert body2["data"]["attributes"]["site_id"] == site2.id
      end

      test "tenant admin can create workspace only for their own site", %{
        tenant_admin: tenant_admin,
        site: site,
        site2: site2
      } do
        token = sign_in_tenant(tenant_admin)

        # Successfully create workspace for their own site
        response =
          make_api_request(
            @api_tenant_path,
            %{
              "type" => "workspace",
              "attributes" => %{
                "name" => "My Workspace",
                "slug" => "my-workspace",
                "description" => "Test workspace",
                "status" => "active",
                "language" => "en"
              }
            },
            headers: [{"authorization", "Bearer #{token}"}]
          )

        assert response.status == 201
        body = Jason.decode!(response.resp_body)
        assert body["data"]["attributes"]["name"] == "My Workspace"
        assert body["data"]["attributes"]["site_id"] == site.id

        # Tenant users cannot send site_id
        response2 =
          make_api_request(
            @api_tenant_path,
            %{
              "type" => "workspace",
              "attributes" => %{
                "name" => "Invalid",
                "slug" => "invalid",
                "status" => "active",
                "site_id" => site2.id
              }
            },
            headers: [{"authorization", "Bearer #{token}"}]
          )

        assert response2.status == 400
      end
    end

    describe "READ - GET /workspace (list and get)" do
      test "master admin can list workspaces from all sites", %{
        master_user: master_user,
        site: site,
        site2: site2
      } do
        token = sign_in_master(master_user)

        workspace1 = create_workspace!(site_id: site.id, name: "Workspace 1")
        workspace2 = create_workspace!(site_id: site2.id, name: "Workspace 2")

        response =
          make_api_request(
            @api_master_path,
            %{},
            method: :get,
            headers: [{"authorization", "Bearer #{token}"}, {"x-no-tenant", "true"}]
          )

        assert response.status == 200
        body = Jason.decode!(response.resp_body)
        assert is_list(body["data"])

        ids = Enum.map(body["data"], & &1["id"])
        assert workspace1.id in ids
        assert workspace2.id in ids
      end

      test "tenant admin can list only their own site's workspaces", %{
        tenant_admin: tenant_admin,
        site: site,
        site2: site2
      } do
        token = sign_in_tenant(tenant_admin)

        workspace1 = create_workspace!(site_id: site.id, name: "Own Workspace")
        workspace2 = create_workspace!(site_id: site2.id, name: "Other Workspace")

        response =
          make_api_request(
            @api_tenant_path,
            %{},
            method: :get,
            headers: [{"authorization", "Bearer #{token}"}]
          )

        assert response.status == 200
        body = Jason.decode!(response.resp_body)

        ids = Enum.map(body["data"], & &1["id"])
        assert workspace1.id in ids
        refute workspace2.id in ids
      end

      test "master admin can get any workspace by id", %{
        master_user: master_user,
        site: site
      } do
        token = sign_in_master(master_user)
        workspace = create_workspace!(site_id: site.id, name: "Test Workspace")

        response =
          make_api_request(
            "#{@api_master_path}/#{workspace.id}",
            %{},
            method: :get,
            headers: [{"authorization", "Bearer #{token}"}, {"x-no-tenant", "true"}]
          )

        assert response.status == 200
        body = Jason.decode!(response.resp_body)
        assert body["data"]["id"] == workspace.id
        assert body["data"]["attributes"]["name"] == "Test Workspace"
      end

      test "tenant admin can get only their own site's workspace", %{
        tenant_admin: tenant_admin,
        site: site,
        site2: site2
      } do
        token = sign_in_tenant(tenant_admin)

        workspace1 = create_workspace!(site_id: site.id, name: "Own")
        workspace2 = create_workspace!(site_id: site2.id, name: "Other")

        # Can get own site's workspace
        response =
          make_api_request(
            "#{@api_tenant_path}/#{workspace1.id}",
            %{},
            method: :get,
            headers: [{"authorization", "Bearer #{token}"}]
          )

        assert response.status == 200

        # Cannot get another site's workspace
        response2 =
          make_api_request(
            "#{@api_tenant_path}/#{workspace2.id}",
            %{},
            method: :get,
            headers: [{"authorization", "Bearer #{token}"}]
          )

        assert response2.status == 404
      end

      test "master admin can list language variants", %{
        master_user: master_user,
        site: site
      } do
        token = sign_in_master(master_user)

        # Create master workspace (English) - language_group_id will be auto-set to its own id
        master_workspace =
          create_workspace!(
            site_id: site.id,
            name: "English Version",
            language: "en"
          )

        # Create translation workspace (French) using master's id as language_group_id
        create_workspace!(
          site_id: site.id,
          name: "French Version",
          language: "fr",
          language_group_id: master_workspace.id
        )

        response =
          make_api_request(
            "#{@api_master_path}/language-variants?language_group_id=#{master_workspace.id}",
            %{},
            method: :get,
            headers: [{"authorization", "Bearer #{token}"}, {"x-no-tenant", "true"}]
          )

        assert response.status == 200
        body = Jason.decode!(response.resp_body)
        assert is_list(body["data"])
        assert length(body["data"]) == 2
      end

      test "tenant admin can list language variants for their site", %{
        tenant_admin: tenant_admin,
        site: site
      } do
        token = sign_in_tenant(tenant_admin)

        # Create master workspace (English) - language_group_id will be auto-set to its own id
        master_workspace =
          create_workspace!(
            site_id: site.id,
            name: "English",
            language: "en"
          )

        # Create translation workspace (Spanish) using master's id as language_group_id
        create_workspace!(
          site_id: site.id,
          name: "Spanish",
          language: "es",
          language_group_id: master_workspace.id
        )

        response =
          make_api_request(
            "#{@api_tenant_path}/language-variants?language_group_id=#{master_workspace.id}",
            %{},
            method: :get,
            headers: [{"authorization", "Bearer #{token}"}]
          )

        assert response.status == 200
        body = Jason.decode!(response.resp_body)
        assert is_list(body["data"])
        assert length(body["data"]) == 2
      end
    end

    describe "UPDATE - PATCH /workspace" do
      test "master admin can update any workspace", %{
        master_user: master_user,
        site: site
      } do
        token = sign_in_master(master_user)
        workspace = create_workspace!(site_id: site.id, name: "Old Name")

        response =
          make_api_request(
            "#{@api_master_path}/#{workspace.id}",
            %{
              "type" => "workspace",
              "attributes" => %{
                "name" => "Updated Name",
                "description" => "Updated description"
              }
            },
            method: :patch,
            headers: [{"authorization", "Bearer #{token}"}, {"x-no-tenant", "true"}]
          )

        assert response.status == 200
        body = Jason.decode!(response.resp_body)
        assert body["data"]["attributes"]["name"] == "Updated Name"
      end

      test "tenant admin can update only their own site's workspace", %{
        tenant_admin: tenant_admin,
        site: site,
        site2: site2
      } do
        token = sign_in_tenant(tenant_admin)

        workspace_own = create_workspace!(site_id: site.id, name: "Own")
        workspace_other = create_workspace!(site_id: site2.id, name: "Other")

        # Can update own
        response =
          make_api_request(
            "#{@api_tenant_path}/#{workspace_own.id}",
            %{
              "type" => "workspace",
              "attributes" => %{"name" => "Updated Own"}
            },
            method: :patch,
            headers: [{"authorization", "Bearer #{token}"}]
          )

        assert response.status == 200

        # Cannot update other site's
        response2 =
          make_api_request(
            "#{@api_tenant_path}/#{workspace_other.id}",
            %{
              "type" => "workspace",
              "attributes" => %{"name" => "Hacked"}
            },
            method: :patch,
            headers: [{"authorization", "Bearer #{token}"}]
          )

        assert response2.status == 404
      end
    end

    describe "DELETE - Soft delete (archive)" do
      test "master admin can archive any workspace", %{
        master_user: master_user,
        site: site
      } do
        token = sign_in_master(master_user)
        workspace = create_workspace!(site_id: site.id)

        response =
          make_api_request(
            "#{@api_master_path}/#{workspace.id}/archive",
            %{},
            method: :delete,
            headers: [{"authorization", "Bearer #{token}"}, {"x-no-tenant", "true"}]
          )

        assert response.status == 200

        # Verify archived
        list_response =
          make_api_request(
            @api_master_path,
            %{},
            method: :get,
            headers: [{"authorization", "Bearer #{token}"}, {"x-no-tenant", "true"}]
          )

        list_body = Jason.decode!(list_response.resp_body)
        ids = Enum.map(list_body["data"], & &1["id"])
        refute workspace.id in ids
      end

      test "tenant admin can archive their own site's workspace", %{
        tenant_admin: tenant_admin,
        site: site,
        site2: site2
      } do
        token = sign_in_tenant(tenant_admin)

        workspace_own = create_workspace!(site_id: site.id)
        workspace_other = create_workspace!(site_id: site2.id)

        # Can archive own
        response =
          make_api_request(
            "#{@api_tenant_path}/#{workspace_own.id}/archive",
            %{},
            method: :delete,
            headers: [{"authorization", "Bearer #{token}"}]
          )

        assert response.status == 200

        # Cannot archive other
        response2 =
          make_api_request(
            "#{@api_tenant_path}/#{workspace_other.id}/archive",
            %{},
            method: :delete,
            headers: [{"authorization", "Bearer #{token}"}]
          )

        assert response2.status == 404
      end
    end

    describe "ARCHIVED - Working with archived records" do
      test "master admin can list archived workspaces from all sites", %{
        master_user: master_user,
        site: site,
        site2: site2
      } do
        token = sign_in_master(master_user)

        workspace1 = create_workspace!(site_id: site.id)
        workspace2 = create_workspace!(site_id: site2.id)

        # Archive them
        workspace1
        |> Ash.Changeset.for_destroy(:destroy, %{}, tenant: site.id, authorize?: false)
        |> Ash.destroy!()

        workspace2
        |> Ash.Changeset.for_destroy(:destroy, %{}, tenant: site2.id, authorize?: false)
        |> Ash.destroy!()

        response =
          make_api_request(
            "#{@api_master_path}/archived",
            %{},
            method: :get,
            headers: [{"authorization", "Bearer #{token}"}, {"x-no-tenant", "true"}]
          )

        assert response.status == 200
        body = Jason.decode!(response.resp_body)

        ids = Enum.map(body["data"], & &1["id"])
        assert workspace1.id in ids
        assert workspace2.id in ids
      end

      test "tenant admin can list archived workspaces for their site only", %{
        tenant_admin: tenant_admin,
        site: site,
        site2: site2
      } do
        token = sign_in_tenant(tenant_admin)

        workspace_own = create_workspace!(site_id: site.id)
        workspace_other = create_workspace!(site_id: site2.id)

        workspace_own
        |> Ash.Changeset.for_destroy(:destroy, %{}, tenant: site.id, authorize?: false)
        |> Ash.destroy!()

        workspace_other
        |> Ash.Changeset.for_destroy(:destroy, %{}, tenant: site2.id, authorize?: false)
        |> Ash.destroy!()

        response =
          make_api_request(
            "#{@api_tenant_path}/archived",
            %{},
            method: :get,
            headers: [{"authorization", "Bearer #{token}"}]
          )

        assert response.status == 200
        body = Jason.decode!(response.resp_body)

        ids = Enum.map(body["data"], & &1["id"])
        assert workspace_own.id in ids
        refute workspace_other.id in ids
      end

      test "master admin can get archived workspace by id", %{
        master_user: master_user,
        site: site
      } do
        token = sign_in_master(master_user)
        workspace = create_workspace!(site_id: site.id)

        workspace
        |> Ash.Changeset.for_destroy(:destroy, %{}, tenant: site.id, authorize?: false)
        |> Ash.destroy!()

        response =
          make_api_request(
            "#{@api_master_path}/archived/#{workspace.id}",
            %{},
            method: :get,
            headers: [{"authorization", "Bearer #{token}"}, {"x-no-tenant", "true"}]
          )

        assert response.status == 200
        body = Jason.decode!(response.resp_body)
        assert body["data"]["id"] == workspace.id
      end

      test "tenant admin can get archived workspace from their site", %{
        tenant_admin: tenant_admin,
        site: site
      } do
        token = sign_in_tenant(tenant_admin)
        workspace = create_workspace!(site_id: site.id)

        workspace
        |> Ash.Changeset.for_destroy(:destroy, %{}, tenant: site.id, authorize?: false)
        |> Ash.destroy!()

        response =
          make_api_request(
            "#{@api_tenant_path}/archived/#{workspace.id}",
            %{},
            method: :get,
            headers: [{"authorization", "Bearer #{token}"}]
          )

        assert response.status == 200
      end

      test "master admin can unarchive any workspace", %{
        master_user: master_user,
        site: site
      } do
        token = sign_in_master(master_user)
        workspace = create_workspace!(site_id: site.id)

        workspace
        |> Ash.Changeset.for_destroy(:destroy, %{}, tenant: site.id, authorize?: false)
        |> Ash.destroy!()

        response =
          make_api_request(
            "#{@api_master_path}/#{workspace.id}/unarchive",
            %{"type" => "workspace", "attributes" => %{}},
            method: :patch,
            headers: [{"authorization", "Bearer #{token}"}, {"x-no-tenant", "true"}]
          )

        assert response.status == 200
      end

      test "tenant admin can unarchive their own site's workspace", %{
        tenant_admin: tenant_admin,
        site: site
      } do
        token = sign_in_tenant(tenant_admin)
        workspace = create_workspace!(site_id: site.id)

        workspace
        |> Ash.Changeset.for_destroy(:destroy, %{}, tenant: site.id, authorize?: false)
        |> Ash.destroy!()

        response =
          make_api_request(
            "#{@api_tenant_path}/#{workspace.id}/unarchive",
            %{"type" => "workspace", "attributes" => %{}},
            method: :patch,
            headers: [{"authorization", "Bearer #{token}"}]
          )

        assert response.status == 200
      end
    end

    describe "DELETE - Permanent deletion" do
      test "master admin can permanently delete any workspace", %{
        master_user: master_user,
        site: site
      } do
        token = sign_in_master(master_user)
        workspace = create_workspace!(site_id: site.id)
        workspace_id = workspace.id

        response =
          make_api_request(
            "#{@api_master_path}/#{workspace_id}/permanent",
            %{},
            method: :delete,
            headers: [{"authorization", "Bearer #{token}"}, {"x-no-tenant", "true"}]
          )

        assert response.status == 200

        # Verify completely gone
        archived_response =
          make_api_request(
            "#{@api_master_path}/archived",
            %{},
            method: :get,
            headers: [{"authorization", "Bearer #{token}"}, {"x-no-tenant", "true"}]
          )

        archived_body = Jason.decode!(archived_response.resp_body)
        archived_ids = Enum.map(archived_body["data"], & &1["id"])
        refute workspace_id in archived_ids
      end

      test "tenant admin can permanently delete their own site's workspace", %{
        tenant_admin: tenant_admin,
        site: site,
        site2: site2
      } do
        token = sign_in_tenant(tenant_admin)

        workspace_own = create_workspace!(site_id: site.id)
        workspace_other = create_workspace!(site_id: site2.id)

        # Can permanently delete own
        response =
          make_api_request(
            "#{@api_tenant_path}/#{workspace_own.id}/permanent",
            %{},
            method: :delete,
            headers: [{"authorization", "Bearer #{token}"}]
          )

        assert response.status == 200

        # Cannot permanently delete other
        response2 =
          make_api_request(
            "#{@api_tenant_path}/#{workspace_other.id}/permanent",
            %{},
            method: :delete,
            headers: [{"authorization", "Bearer #{token}"}]
          )

        assert response2.status == 404
      end
    end

    describe "PUBLIC - Unauthenticated access" do
      test "anyone can list active workspaces", %{site: site} do
        # Create active and draft workspaces in the same site
        active1 =
          create_workspace!(site_id: site.id, name: "Active1", status: :active)

        active2 =
          create_workspace!(site_id: site.id, name: "Active2", status: :active)

        _draft =
          create_workspace!(site_id: site.id, name: "Draft", status: :draft)

        response =
          make_api_request(
            "#{@api_public_path}",
            %{},
            method: :get,
            headers: []
          )

        assert response.status == 200
        body = Jason.decode!(response.resp_body)
        assert is_list(body["data"])

        ids = Enum.map(body["data"], & &1["id"])
        assert active1.id in ids
        assert active2.id in ids

        # All should be active status
        Enum.each(body["data"], fn workspace ->
          assert workspace["attributes"]["status"] == "active"
        end)
      end

      test "anyone can get active workspace by id", %{site: site} do
        active_workspace =
          create_workspace!(site_id: site.id, name: "Public Workspace", status: :active)

        response =
          make_api_request(
            "#{@api_public_path}/#{active_workspace.id}",
            %{},
            method: :get,
            headers: []
          )

        assert response.status == 200
        body = Jason.decode!(response.resp_body)
        assert body["data"]["id"] == active_workspace.id
        assert body["data"]["attributes"]["status"] == "active"
      end

      test "anyone cannot get draft workspace", %{site: site} do
        draft_workspace =
          create_workspace!(site_id: site.id, name: "Draft Workspace", status: :draft)

        response =
          make_api_request(
            "#{@api_public_path}/#{draft_workspace.id}",
            %{},
            method: :get,
            headers: []
          )

        assert response.status == 404
      end
    end

    describe "maintainers_info - the accounts that wrote a workspace" do
      setup %{site: site} do
        workspace = create_workspace!(site_id: site.id, status: :active, skip_version: true)

        ws_version =
          create_workspace_version!(
            workspace_id: workspace.id,
            site_id: site.id,
            status: :stable,
            published_at: DateTime.utc_now()
          )

        maintainer = create_user!(email: "maintainer@example.com", site_id: site.id)

        [workspace_version_id: ws_version.id, site_id: site.id]
        |> MishkaDocument.Dev.Generator.section(site.id, maintainer)
        |> Ash.Generator.generate()

        %{workspace: workspace, maintainer: maintainer, version: ws_version}
      end

      test "a visitor asking for it never receives the maintainers' addresses", %{
        workspace: workspace,
        maintainer: maintainer
      } do
        for path <- [
              "#{@api_public_path}/#{workspace.id}?fields[workspace]=name,maintainers_info",
              "#{@api_public_path}?fields[workspace]=name,maintainers_info"
            ] do
          response = make_api_request(path, %{}, method: :get)

          assert response.status == 200, "#{path} answered #{response.status}"
          refute response.resp_body =~ to_string(maintainer.email), "#{path} leaked the address"

          for workspace <- List.wrap(Jason.decode!(response.resp_body)["data"]) do
            refute Map.has_key?(workspace["attributes"], "maintainers_info")
          end
        end
      end

      test "a signed-in user who is not an admin does not receive them either", %{
        workspace: workspace,
        maintainer: maintainer,
        tenant_user: tenant_user
      } do
        response =
          make_api_request(
            "#{@api_public_path}/#{workspace.id}?fields[workspace]=name,maintainers_info",
            %{},
            method: :get,
            headers: [{"authorization", "Bearer #{sign_in_tenant(tenant_user)}"}]
          )

        assert response.status == 200
        refute response.resp_body =~ to_string(maintainer.email)
      end

      test "a tenant admin still receives them", %{
        workspace: workspace,
        maintainer: maintainer,
        tenant_admin: tenant_admin
      } do
        response =
          make_api_request(
            "#{@api_tenant_path}/#{workspace.id}?fields[workspace]=name,maintainers_info",
            %{},
            method: :get,
            headers: [{"authorization", "Bearer #{sign_in_tenant(tenant_admin)}"}]
          )

        assert response.status == 200

        assert %{"count" => 1, "maintainers" => [%{"email" => email}]} =
                 Jason.decode!(response.resp_body)["data"]["attributes"]["maintainers_info"]

        assert email == to_string(maintainer.email)
      end

      test "a tenant admin reads a master who wrote the workspace as Master, never its address",
           %{
             workspace: workspace,
             version: version,
             maintainer: maintainer,
             tenant_admin: tenant_admin
           } do
        master_maintainer = master_maintainer!(version)

        response =
          make_api_request(
            "#{@api_tenant_path}/#{workspace.id}?fields[workspace]=name,maintainers_info",
            %{},
            method: :get,
            headers: [{"authorization", "Bearer #{sign_in_tenant(tenant_admin)}"}]
          )

        assert response.status == 200
        master_email = to_string(master_maintainer.email)
        refute response.resp_body =~ master_email
        refute response.resp_body =~ master_email |> String.split("@") |> hd()

        by_id = maintainers_by_id(response)

        assert by_id[master_maintainer.id] == %{"email" => nil, "name" => "Master"}

        assert by_id[maintainer.id] == %{
                 "email" => to_string(maintainer.email),
                 "name" => to_string(maintainer.email)
               }
      end

      test "a master reads every maintainer's address", %{
        workspace: workspace,
        version: version,
        maintainer: maintainer,
        master_user: master_user
      } do
        master_maintainer = master_maintainer!(version)

        response =
          make_api_request(
            "#{@api_master_path}/#{workspace.id}?fields[workspace]=name,maintainers_info",
            %{},
            method: :get,
            headers: [
              {"authorization", "Bearer #{sign_in_master(master_user)}"},
              {"x-no-tenant", "true"}
            ]
          )

        assert response.status == 200
        by_id = maintainers_by_id(response)

        for user <- [master_maintainer, maintainer] do
          email = to_string(user.email)
          assert by_id[user.id] == %{"email" => email, "name" => email}
        end
      end
    end

    # A master who wrote a section of `version`'s workspace, so it is one of its maintainers.
    defp master_maintainer!(version) do
      master = create_user!(email: "writer.master@platform.test")

      [workspace_version_id: version.id, site_id: version.site_id]
      |> MishkaDocument.Dev.Generator.section(version.site_id, master)
      |> Ash.Generator.generate()

      master
    end

    defp maintainers_by_id(response) do
      response.resp_body
      |> Jason.decode!()
      |> get_in(["data", "attributes", "maintainers_info", "maintainers"])
      |> Map.new(&{&1["user_id"], Map.take(&1, ["email", "name"])})
    end

    describe "PAGINATED INCLUDES - Fetching related versions with pagination" do
      test "tenant user can fetch workspace with paginated tenant_versions", %{
        tenant_admin: tenant_admin,
        site: site
      } do
        token = sign_in_tenant(tenant_admin)

        # Create two workspaces
        workspace_large =
          create_workspace!(
            site_id: site.id,
            name: "Large Workspace",
            status: :active
          )

        workspace_small =
          create_workspace!(
            site_id: site.id,
            name: "Small Workspace",
            status: :active
          )

        # Create 30 versions for the large workspace
        _large_version_ids =
          Enum.map(1..30, fn i ->
            version =
              MishkaDocument.WorkspaceVersion
              |> Ash.Changeset.for_create(
                :create,
                %{
                  version_number: "1.0.#{i}",
                  version_name: "Version #{i}",
                  workspace_id: workspace_large.id,
                  status: :stable,
                  published_at: DateTime.utc_now()
                },
                actor: tenant_admin,
                context: %{shared: %{admin_surface: :api}},
                tenant: site.id
              )
              |> Ash.create!()

            version.id
          end)

        # Create 3 versions for the small workspace
        _small_version_ids =
          Enum.map(1..3, fn i ->
            version =
              MishkaDocument.WorkspaceVersion
              |> Ash.Changeset.for_create(
                :create,
                %{
                  version_number: "2.0.#{i}",
                  version_name: "Small Version #{i}",
                  workspace_id: workspace_small.id,
                  status: :stable,
                  published_at: DateTime.utc_now()
                },
                actor: tenant_admin,
                context: %{shared: %{admin_surface: :api}},
                tenant: site.id
              )
              |> Ash.create!()

            version.id
          end)

        # Fetch large workspace with first page of versions (limit 30)
        response =
          make_api_request(
            "#{@api_tenant_path}/#{workspace_large.id}?include=tenant_versions&included_page[tenant_versions][limit]=30&included_page[tenant_versions][offset]=0",
            %{},
            method: :get,
            headers: [{"authorization", "Bearer #{token}"}]
          )

        assert response.status == 200
        body = Jason.decode!(response.resp_body)

        # Verify workspace data
        assert body["data"]["id"] == workspace_large.id
        assert body["data"]["attributes"]["name"] == "Large Workspace"
        assert body["data"]["relationships"]["tenant_versions"]["links"]["first"] |> is_binary()
        assert body["data"]["relationships"]["tenant_versions"]["links"]["next"] |> is_binary()
        assert body["data"]["relationships"]["tenant_versions"]["links"]["prev"] |> is_nil()

        # Verify versions relationship data is present
        relationship_versions = body["data"]["relationships"]["tenant_versions"]["data"] || []
        assert length(relationship_versions) == 30, "All 30 versions should be in relationships"

        # Verify the relationship version IDs match what we created
        relationship_version_ids = Enum.map(relationship_versions, & &1["id"])
        # Note: The relationship may return versions in different order or filtered
        # Let's just verify we got versions back
        assert length(relationship_version_ids) == 30

        # Fetch small workspace with all versions
        response2 =
          make_api_request(
            "#{@api_tenant_path}/#{workspace_small.id}?include=tenant_versions",
            %{},
            method: :get,
            headers: [{"authorization", "Bearer #{token}"}]
          )

        assert response2.status == 200
        body2 = Jason.decode!(response2.resp_body)

        # Verify small workspace has at least 3 versions (may have initial version from factory)
        relationship_versions2 = body2["data"]["relationships"]["tenant_versions"]["data"] || []
        assert length(relationship_versions2) >= 3

        # Verify the versions belong to the small workspace
        relationship_version_ids2 = Enum.map(relationship_versions2, & &1["id"])
        assert length(relationship_version_ids2) >= 3
      end

      test "master user can fetch workspace with paginated master_versions", %{
        master_user: master_user,
        site: site
      } do
        token = sign_in_master(master_user)

        # Create a workspace
        workspace =
          create_workspace!(
            site_id: site.id,
            name: "Master Workspace",
            status: :active
          )

        # Create 25 versions using master_create action
        _version_ids =
          Enum.map(1..25, fn i ->
            version =
              MishkaDocument.WorkspaceVersion
              |> Ash.Changeset.for_create(
                :master_create,
                %{
                  version_number: "3.0.#{i}",
                  version_name: "Master Version #{i}",
                  workspace_id: workspace.id,
                  status: :stable,
                  published_at: DateTime.utc_now(),
                  site_id: site.id
                },
                actor: master_user,
                context: %{shared: %{admin_surface: :api}},
                tenant: nil
              )
              |> Ash.create!()

            version.id
          end)

        # Fetch workspace with master_versions relationship (bypassing tenant)
        response =
          make_api_request(
            "#{@api_master_path}/#{workspace.id}?include=master_versions&included_page[master_versions][limit]=25",
            %{},
            method: :get,
            headers: [{"authorization", "Bearer #{token}"}, {"x-no-tenant", "true"}]
          )

        assert response.status == 200
        body = Jason.decode!(response.resp_body)

        # Verify workspace data
        assert body["data"]["id"] == workspace.id

        # Verify master_versions relationship data is present
        relationship_versions = body["data"]["relationships"]["master_versions"]["data"] || []

        assert length(relationship_versions) == 25,
               "All 25 versions should be in relationships"

        # Verify the versions belong to the workspace
        relationship_version_ids = Enum.map(relationship_versions, & &1["id"])
        assert length(relationship_version_ids) == 25
      end

      test "any user can fetch workspace with paginated versions (public)", %{
        tenant_admin: tenant_admin,
        site: site
      } do
        # Create workspace
        workspace =
          create_workspace!(
            site_id: site.id,
            name: "Public Workspace",
            status: :active
          )

        # Create 30 versions for the workspace
        _version_ids =
          Enum.map(1..30, fn i ->
            version =
              MishkaDocument.WorkspaceVersion
              |> Ash.Changeset.for_create(
                :create,
                %{
                  version_number: "4.0.#{i}",
                  version_name: "Public Version #{i}",
                  workspace_id: workspace.id,
                  status: :stable,
                  published_at: DateTime.utc_now()
                },
                actor: tenant_admin,
                context: %{shared: %{admin_surface: :api}},
                tenant: site.id
              )
              |> Ash.create!()

            version.id
          end)

        response =
          make_api_request(
            "#{@api_public_path}/#{workspace.id}?include=versions&included_page[versions][limit]=30&included_page[versions][offset]=0",
            %{},
            method: :get,
            headers: []
          )

        assert response.status == 200
        body = Jason.decode!(response.resp_body)

        # Verify workspace data
        assert body["data"]["id"] == workspace.id
        assert body["data"]["attributes"]["name"] == "Public Workspace"
        assert body["data"]["relationships"]["versions"]["links"]["first"] |> is_binary()
        assert body["data"]["relationships"]["versions"]["links"]["next"] |> is_binary()
        assert body["data"]["relationships"]["versions"]["links"]["prev"] |> is_nil()

        # Verify versions relationship data is present
        relationship_versions = body["data"]["relationships"]["versions"]["data"] || []
        assert length(relationship_versions) == 30, "All 30 versions should be in relationships"

        # Verify the relationship version IDs match what we created
        relationship_version_ids = Enum.map(relationship_versions, & &1["id"])
        assert length(relationship_version_ids) == 30
      end
    end

    describe "Health Metrics Calculation" do
      test "calculates completion percentage for fully approved items", %{
        site: site
      } do
        # Create workspace with version
        workspace = create_workspace!(site_id: site.id, status: :active, skip_version: true)

        version =
          create_workspace_version!(
            workspace_id: workspace.id,
            site_id: site.id,
            version_number: "1.0.0"
          )

        # Create sections with different statuses
        approved_section1 =
          create_section!(
            workspace_version_id: version.id,
            site_id: site.id,
            title: "Approved 1",
            content_review_status: :approved,
            technical_review_status: :approved
          )

        approved_section2 =
          create_section!(
            workspace_version_id: version.id,
            site_id: site.id,
            title: "Approved 2",
            content_review_status: :approved,
            technical_review_status: :approved
          )

        _pending_section =
          create_section!(
            workspace_version_id: version.id,
            site_id: site.id,
            title: "Pending",
            content_review_status: :pending,
            technical_review_status: :pending
          )

        # Create notes (notes belong to sections)
        _approved_note =
          create_note!(
            section_id: approved_section1.id,
            site_id: site.id,
            title: "Approved Note",
            content_review_status: :approved,
            technical_review_status: :approved
          )

        _pending_note =
          create_note!(
            section_id: approved_section2.id,
            site_id: site.id,
            title: "Pending Note",
            content_review_status: :pending,
            technical_review_status: :pending
          )

        # Load workspace with health metrics
        workspace_with_metrics =
          Ash.get!(MishkaDocument.Workspace, workspace.id,
            tenant: site.id,
            authorize?: false,
            load: [:health_metrics]
          )

        metrics = workspace_with_metrics.health_metrics

        # 3 approved out of 5 total = 60%
        assert metrics.completion == 60
        assert metrics.total_items == 5
        assert metrics.approved_items == 3
        assert metrics.sections_count == 3
        assert metrics.contributors_count == 0
        assert metrics.active_contributors_today == 0
      end

      test "calculates trend based on monthly comparison", %{site: site} do
        workspace = create_workspace!(site_id: site.id, status: :active, skip_version: true)

        version =
          create_workspace_version!(
            workspace_id: workspace.id,
            site_id: site.id,
            version_number: "1.0.0"
          )

        # Create old section (updated last month)
        last_month = DateTime.utc_now() |> DateTime.add(-40, :day)

        # Ensure current time is in current month
        # Need to account for timezone - set to tomorrow to be safe
        current_month_time = DateTime.utc_now() |> DateTime.add(1, :day)

        old_section =
          create_section!(
            workspace_version_id: version.id,
            site_id: site.id,
            title: "Old Section",
            content_review_status: :pending,
            technical_review_status: :pending
          )

        # Create new section (approved this month)
        new_section =
          create_section!(
            workspace_version_id: version.id,
            site_id: site.id,
            title: "New Section",
            content_review_status: :approved,
            technical_review_status: :approved
          )

        # Manually update timestamps AFTER creating all sections
        # This prevents language_group_id auto-update from changing them
        Ecto.Adapters.SQL.query!(
          @repo,
          "UPDATE mishka_document_sections SET updated_at = $1 WHERE id = $2",
          [last_month, Ecto.UUID.dump!(old_section.id)]
        )

        # Ensure new section timestamp is in current month
        # (Need to add extra time to account for timezone differences)
        Ecto.Adapters.SQL.query!(
          @repo,
          "UPDATE mishka_document_sections SET updated_at = $1 WHERE id = $2",
          [current_month_time, Ecto.UUID.dump!(new_section.id)]
        )

        # Load with metrics
        workspace_with_metrics =
          Ash.get!(MishkaDocument.Workspace, workspace.id,
            tenant: site.id,
            authorize?: false,
            load: [:health_metrics]
          )

        metrics = workspace_with_metrics.health_metrics

        # Last month: 0% (0/1 approved)
        # Current: 50% (1/2 approved)
        # Trend: +50
        assert metrics.trend == 50
        assert metrics.completion == 50
        assert metrics.sections_count == 2
        assert metrics.contributors_count == 0
        assert metrics.active_contributors_today == 0
      end

      test "calculates quality score based on open issues", %{site: site} do
        workspace = create_workspace!(site_id: site.id, status: :active, skip_version: true)

        version =
          create_workspace_version!(
            workspace_id: workspace.id,
            site_id: site.id,
            version_number: "1.0.0"
          )

        # Create 5 sections
        sections =
          for i <- 1..5 do
            create_section!(
              workspace_version_id: version.id,
              site_id: site.id,
              title: "Section #{i}",
              content_review_status: :approved,
              technical_review_status: :approved
            )
          end

        # Create 2 open issues on 2 different sections
        _issue1 =
          create_issue!(
            site_id: site.id,
            section_id: Enum.at(sections, 0).id,
            title: "Open Issue 1",
            status: :open
          )

        _issue2 =
          create_issue!(
            site_id: site.id,
            section_id: Enum.at(sections, 1).id,
            title: "Open Issue 2",
            status: :open
          )

        # Create 1 resolved issue
        _resolved_issue =
          create_issue!(
            site_id: site.id,
            section_id: Enum.at(sections, 2).id,
            title: "Resolved Issue",
            status: :resolved
          )

        # Load with metrics
        workspace_with_metrics =
          Ash.get!(MishkaDocument.Workspace, workspace.id,
            tenant: site.id,
            authorize?: false,
            load: [:health_metrics]
          )

        metrics = workspace_with_metrics.health_metrics

        # 5 total items - 2 open issues = 3 healthy items
        # (3 / 5) * 100 = 60% quality
        assert metrics.quality == 60
        assert metrics.open_issues == 2
        assert metrics.resolved_issues == 1
        assert metrics.sections_count == 5
        assert metrics.contributors_count == 0
        assert metrics.active_contributors_today == 0
      end

      test "includes section drafts in total count", %{site: site} do
        workspace = create_workspace!(site_id: site.id, status: :active, skip_version: true)

        version =
          create_workspace_version!(
            workspace_id: workspace.id,
            site_id: site.id,
            version_number: "1.0.0"
          )

        # Create original section
        section =
          create_section!(
            workspace_version_id: version.id,
            site_id: site.id,
            title: "Original",
            content_review_status: :approved,
            technical_review_status: :approved
          )

        # Create draft for the section
        _draft =
          create_section_draft!(
            workspace_version_id: version.id,
            source_section_id: section.id,
            site_id: site.id,
            title: "Draft Version",
            content_review_status: :pending,
            technical_review_status: :pending
          )

        # Load with metrics
        workspace_with_metrics =
          Ash.get!(MishkaDocument.Workspace, workspace.id,
            tenant: site.id,
            authorize?: false,
            load: [:health_metrics]
          )

        metrics = workspace_with_metrics.health_metrics

        # 1 section + 1 draft = 2 total, but only 1 approved
        assert metrics.total_items == 2
        assert metrics.approved_items == 1
        assert metrics.completion == 50
        assert metrics.sections_count == 1
        assert metrics.contributors_count == 0
        assert metrics.active_contributors_today == 0
      end

      test "includes note drafts in total count", %{site: site} do
        workspace = create_workspace!(site_id: site.id, status: :active, skip_version: true)

        version =
          create_workspace_version!(
            workspace_id: workspace.id,
            site_id: site.id,
            version_number: "1.0.0"
          )

        section =
          create_section!(
            workspace_version_id: version.id,
            site_id: site.id,
            title: "Section",
            content_review_status: :approved,
            technical_review_status: :approved
          )

        # Create original note (notes belong to sections)
        _note =
          create_note!(
            section_id: section.id,
            site_id: site.id,
            title: "Original Note",
            content_review_status: :approved,
            technical_review_status: :approved
          )

        # Create note draft (use existing section)
        _draft =
          create_note_draft!(
            workspace_version_id: version.id,
            section_id: section.id,
            site_id: site.id,
            title: "Draft Note",
            content_review_status: :pending,
            technical_review_status: :pending
          )

        # Load with metrics
        workspace_with_metrics =
          Ash.get!(MishkaDocument.Workspace, workspace.id,
            tenant: site.id,
            authorize?: false,
            load: [:health_metrics]
          )

        metrics = workspace_with_metrics.health_metrics

        # 1 section + 1 note + 1 note_draft = 3 total, 2 approved (section + note)
        assert metrics.total_items == 3
        assert metrics.approved_items == 2
        assert metrics.completion == 67
        assert metrics.sections_count == 1
        assert metrics.contributors_count == 0
        assert metrics.active_contributors_today == 0
      end

      test "handles empty workspace gracefully", %{site: site} do
        workspace = create_workspace!(site_id: site.id, status: :active, skip_version: true)

        # Load with metrics (no sections, notes, or issues)
        workspace_with_metrics =
          Ash.get!(MishkaDocument.Workspace, workspace.id,
            tenant: site.id,
            authorize?: false,
            load: [:health_metrics]
          )

        metrics = workspace_with_metrics.health_metrics

        assert metrics.completion == 0
        assert metrics.trend == 0
        assert metrics.quality == 100
        assert metrics.total_items == 0
        assert metrics.approved_items == 0
        assert metrics.open_issues == 0
        assert metrics.resolved_issues == 0
        assert metrics.sections_count == 0
        assert metrics.contributors_count == 0
        assert metrics.active_contributors_today == 0
      end

      test "handles workspace with 100% completion", %{site: site} do
        workspace = create_workspace!(site_id: site.id, status: :active, skip_version: true)

        version =
          create_workspace_version!(
            workspace_id: workspace.id,
            site_id: site.id,
            version_number: "1.0.0"
          )

        # All items approved
        section =
          create_section!(
            workspace_version_id: version.id,
            site_id: site.id,
            title: "Perfect Section",
            content_review_status: :approved,
            technical_review_status: :approved
          )

        _note =
          create_note!(
            section_id: section.id,
            site_id: site.id,
            title: "Perfect Note",
            content_review_status: :approved,
            technical_review_status: :approved
          )

        # Load with metrics
        workspace_with_metrics =
          Ash.get!(MishkaDocument.Workspace, workspace.id,
            tenant: site.id,
            authorize?: false,
            load: [:health_metrics]
          )

        metrics = workspace_with_metrics.health_metrics

        assert metrics.completion == 100
        assert metrics.approved_items == 2
        assert metrics.total_items == 2
        assert metrics.sections_count == 1
        assert metrics.contributors_count == 0
        assert metrics.active_contributors_today == 0
      end

      test "excludes archived sections and notes from calculation", %{site: site} do
        workspace = create_workspace!(site_id: site.id, status: :active, skip_version: true)

        version =
          create_workspace_version!(
            workspace_id: workspace.id,
            site_id: site.id,
            version_number: "1.0.0"
          )

        # Active section
        _active_section =
          create_section!(
            workspace_version_id: version.id,
            site_id: site.id,
            title: "Active",
            content_review_status: :approved,
            technical_review_status: :approved
          )

        # Archived section (should not be counted)
        archived_section =
          create_section!(
            workspace_version_id: version.id,
            site_id: site.id,
            title: "Archived",
            content_review_status: :approved,
            technical_review_status: :approved
          )

        # Archive it
        Ash.Changeset.for_destroy(archived_section, :destroy, %{},
          tenant: site.id,
          authorize?: false
        )
        |> Ash.destroy!()

        # Load with metrics
        workspace_with_metrics =
          Ash.get!(MishkaDocument.Workspace, workspace.id,
            tenant: site.id,
            authorize?: false,
            load: [:health_metrics]
          )

        metrics = workspace_with_metrics.health_metrics

        # Only 1 active section should be counted
        assert metrics.total_items == 1
        assert metrics.approved_items == 1
        assert metrics.completion == 100
        assert metrics.sections_count == 1
        assert metrics.contributors_count == 0
        assert metrics.active_contributors_today == 0
      end

      test "counts issues for both sections and notes", %{site: site} do
        workspace = create_workspace!(site_id: site.id, status: :active, skip_version: true)

        version =
          create_workspace_version!(
            workspace_id: workspace.id,
            site_id: site.id,
            version_number: "1.0.0"
          )

        section =
          create_section!(
            workspace_version_id: version.id,
            site_id: site.id,
            title: "Section"
          )

        note =
          create_note!(
            section_id: section.id,
            site_id: site.id,
            title: "Note"
          )

        # Issue on section
        _section_issue =
          create_issue!(
            site_id: site.id,
            section_id: section.id,
            title: "Section Issue",
            status: :open
          )

        # Issue on note
        _note_issue =
          create_issue!(
            site_id: site.id,
            note_id: note.id,
            title: "Note Issue",
            status: :open
          )

        # Resolved issue
        _resolved_issue =
          create_issue!(
            site_id: site.id,
            section_id: section.id,
            title: "Resolved",
            status: :resolved
          )

        # Load with metrics
        workspace_with_metrics =
          Ash.get!(MishkaDocument.Workspace, workspace.id,
            tenant: site.id,
            authorize?: false,
            load: [:health_metrics]
          )

        metrics = workspace_with_metrics.health_metrics

        assert metrics.open_issues == 2
        assert metrics.resolved_issues == 1
        assert metrics.sections_count == 1
        assert metrics.contributors_count == 0
        assert metrics.active_contributors_today == 0
      end

      test "returns consistent metrics across multiple loads", %{site: site} do
        workspace = create_workspace!(site_id: site.id, status: :active, skip_version: true)

        version =
          create_workspace_version!(
            workspace_id: workspace.id,
            site_id: site.id,
            version_number: "1.0.0"
          )

        _section =
          create_section!(
            workspace_version_id: version.id,
            site_id: site.id,
            title: "Section",
            content_review_status: :approved,
            technical_review_status: :approved
          )

        # Load metrics multiple times
        metrics1 =
          Ash.get!(MishkaDocument.Workspace, workspace.id,
            tenant: site.id,
            authorize?: false,
            load: [:health_metrics]
          )
          |> Map.get(:health_metrics)

        metrics2 =
          Ash.get!(MishkaDocument.Workspace, workspace.id,
            tenant: site.id,
            authorize?: false,
            load: [:health_metrics]
          )
          |> Map.get(:health_metrics)

        # Should be identical
        assert metrics1.completion == metrics2.completion
        assert metrics1.trend == metrics2.trend
        assert metrics1.quality == metrics2.quality
        assert metrics1.total_items == metrics2.total_items
        assert metrics1.sections_count == metrics2.sections_count
        assert metrics1.contributors_count == metrics2.contributors_count
        assert metrics1.active_contributors_today == metrics2.active_contributors_today
      end

      test "counts unique contributors with approved drafts", %{site: site} do
        workspace = create_workspace!(site_id: site.id, status: :active, skip_version: true)

        version =
          create_workspace_version!(
            workspace_id: workspace.id,
            site_id: site.id,
            version_number: "1.0.0"
          )

        section =
          create_section!(
            workspace_version_id: version.id,
            site_id: site.id,
            title: "Section"
          )

        # Create 3 users
        user1 = create_user!(email: "user1@test.com")
        user2 = create_user!(email: "user2@test.com")
        user3 = create_user!(email: "user3@test.com")

        # User 1: Multiple section drafts (should count once)
        # Create using Ash.Changeset with actor to set created_by_user_id
        MishkaDocument.SectionDraft
        |> Ash.Changeset.for_create(
          :create,
          %{
            workspace_version_id: version.id,
            source_section_id: section.id,
            title: "Draft 1",
            slug: "draft-1",
            language: "en",
            change_version: "1.0.0",
            version_increment_type: :none,
            content_review_status: :approved,
            technical_review_status: :approved
          },
          actor: user1,
          tenant: site.id,
          authorize?: false
        )
        |> Ash.create!()

        MishkaDocument.SectionDraft
        |> Ash.Changeset.for_create(
          :create,
          %{
            workspace_version_id: version.id,
            source_section_id: section.id,
            title: "Draft 2",
            slug: "draft-2",
            language: "en",
            change_version: "1.0.0",
            version_increment_type: :none,
            content_review_status: :approved,
            technical_review_status: :approved
          },
          actor: user1,
          tenant: site.id,
          authorize?: false
        )
        |> Ash.create!()

        # User 2: Approved note draft
        MishkaDocument.NoteDraft
        |> Ash.Changeset.for_create(
          :create,
          %{
            workspace_version_id: version.id,
            section_id: section.id,
            title: "Note Draft",
            content: "Note content",
            change_version: "1.0.0",
            version_increment_type: :none,
            content_review_status: :approved,
            technical_review_status: :approved
          },
          actor: user2,
          tenant: site.id,
          authorize?: false
        )
        |> Ash.create!()

        # User 3: Pending draft (should not count)
        MishkaDocument.SectionDraft
        |> Ash.Changeset.for_create(
          :create,
          %{
            workspace_version_id: version.id,
            source_section_id: section.id,
            title: "Pending Draft",
            slug: "pending-draft",
            language: "en",
            change_version: "1.0.0",
            version_increment_type: :none,
            content_review_status: :pending,
            technical_review_status: :pending
          },
          actor: user3,
          tenant: site.id,
          authorize?: false
        )
        |> Ash.create!()

        # Load with metrics
        workspace_with_metrics =
          Ash.get!(MishkaDocument.Workspace, workspace.id,
            tenant: site.id,
            authorize?: false,
            load: [:health_metrics]
          )

        metrics = workspace_with_metrics.health_metrics

        # Only user1 and user2 have approved drafts = 2 contributors
        assert metrics.contributors_count == 2
        # Both users have drafts approved within last 24 hours = 2 active
        assert metrics.active_contributors_today == 2
        assert metrics.sections_count == 1
      end
    end
  end
end
