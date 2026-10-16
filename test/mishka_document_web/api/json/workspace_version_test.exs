# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_document/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaDocumentWeb.Api.Json.WorkspaceVersionTest do
  @moduledoc """
  Comprehensive tests for WorkspaceVersion JSON API endpoints.
  """

  use MishkaDocument.ConnCase
  import MishkaDocument.Test.Factory

  @moduletag :unit
  @moduletag :capture_log

  if Code.ensure_loaded?(MishkaDocument) do
    @password "Password123!"
    @api_user_path "/api/json/v1/auth/user"
    @api_master_path "/api/json/v1/master/admin/mishka-document/workspace-version"
    @api_tenant_path "/api/json/v1/tenant/admin/mishka-document/workspace-version"
    @api_public_path "/api/json/v1/user/mishka-document/workspace-version"

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

    describe "CREATE - POST /workspace-version" do
      test "master admin can create version for any site", %{
        master_user: master_user,
        site: site
      } do
        token = sign_in_master(master_user)
        workspace = create_workspace!(site_id: site.id)

        response =
          make_api_request(
            @api_master_path,
            %{
              "type" => "workspace_version",
              "attributes" => %{
                "workspace_id" => workspace.id,
                "version_number" => "1.0.0",
                "version_name" => "Initial Release",
                "description" => "First stable version",
                "status" => "stable",
                "published_at" => DateTime.utc_now() |> DateTime.to_iso8601(),
                "site_id" => site.id
              }
            },
            headers: [{"authorization", "Bearer #{token}"}, {"x-no-tenant", "true"}]
          )

        assert response.status == 201
        body = Jason.decode!(response.resp_body)
        assert body["data"]["attributes"]["version_number"] == "1.0.0"
        assert body["data"]["attributes"]["status"] == "stable"
      end

      test "tenant admin can create version for their own site", %{
        tenant_admin: tenant_admin,
        site: site
      } do
        token = sign_in_tenant(tenant_admin)
        workspace = create_workspace!(site_id: site.id)

        response =
          make_api_request(
            @api_tenant_path,
            %{
              "type" => "workspace_version",
              "attributes" => %{
                "workspace_id" => workspace.id,
                "version_number" => "0.1.0",
                "status" => "draft"
              }
            },
            headers: [{"authorization", "Bearer #{token}"}]
          )

        assert response.status == 201
        body = Jason.decode!(response.resp_body)
        assert body["data"]["attributes"]["version_number"] == "0.1.0"
        assert body["data"]["attributes"]["status"] == "draft"
      end

      test "stable version requires published_at timestamp", %{
        tenant_admin: tenant_admin,
        site: site
      } do
        token = sign_in_tenant(tenant_admin)
        workspace = create_workspace!(site_id: site.id)

        response =
          make_api_request(
            @api_tenant_path,
            %{
              "type" => "workspace_version",
              "attributes" => %{
                "workspace_id" => workspace.id,
                "version_number" => "1.0.0",
                "status" => "stable"
              }
            },
            headers: [{"authorization", "Bearer #{token}"}]
          )

        assert response.status == 400
      end
    end

    describe "READ - GET /workspace-version (list and get)" do
      test "master admin can list versions from all sites", %{
        master_user: master_user,
        site: site,
        site2: site2
      } do
        token = sign_in_master(master_user)

        version1 = create_workspace_version!(site_id: site.id, version_number: "1.0.0")
        version2 = create_workspace_version!(site_id: site2.id, version_number: "2.0.0")

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
        assert version1.id in ids
        assert version2.id in ids
      end

      test "tenant admin can list only their own site's versions", %{
        tenant_admin: tenant_admin,
        site: site,
        site2: site2
      } do
        token = sign_in_tenant(tenant_admin)

        version1 = create_workspace_version!(site_id: site.id, version_number: "1.0.0")
        version2 = create_workspace_version!(site_id: site2.id, version_number: "2.0.0")

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
        assert version1.id in ids
        refute version2.id in ids
      end

      test "master admin can get any version by id", %{
        master_user: master_user,
        site: site
      } do
        token = sign_in_master(master_user)
        version = create_workspace_version!(site_id: site.id, version_number: "1.5.0")

        response =
          make_api_request(
            "#{@api_master_path}/#{version.id}",
            %{},
            method: :get,
            headers: [{"authorization", "Bearer #{token}"}, {"x-no-tenant", "true"}]
          )

        assert response.status == 200
        body = Jason.decode!(response.resp_body)
        assert body["data"]["id"] == version.id
        assert body["data"]["attributes"]["version_number"] == "1.5.0"
      end

      test "tenant admin can get only their own site's version", %{
        tenant_admin: tenant_admin,
        site: site,
        site2: site2
      } do
        token = sign_in_tenant(tenant_admin)

        version1 = create_workspace_version!(site_id: site.id, version_number: "1.0.0")
        version2 = create_workspace_version!(site_id: site2.id, version_number: "2.0.0")

        # Can get own site's version
        response =
          make_api_request(
            "#{@api_tenant_path}/#{version1.id}",
            %{},
            method: :get,
            headers: [{"authorization", "Bearer #{token}"}]
          )

        assert response.status == 200

        # Cannot get another site's version
        response2 =
          make_api_request(
            "#{@api_tenant_path}/#{version2.id}",
            %{},
            method: :get,
            headers: [{"authorization", "Bearer #{token}"}]
          )

        assert response2.status == 404
      end
    end

    describe "READ - GET /workspace/:workspace_id - Versions by workspace" do
      test "tenant admin can list versions for a specific workspace", %{
        tenant_admin: tenant_admin,
        site: site
      } do
        token = sign_in_tenant(tenant_admin)
        workspace = create_workspace!(site_id: site.id, skip_version: true)

        version1 =
          create_workspace_version!(
            site_id: site.id,
            workspace_id: workspace.id,
            version_number: "1.0.0"
          )

        version2 =
          create_workspace_version!(
            site_id: site.id,
            workspace_id: workspace.id,
            version_number: "2.0.0"
          )

        # Create version for different workspace (should not appear)
        other_workspace = create_workspace!(site_id: site.id, skip_version: true)

        _version3 =
          create_workspace_version!(
            site_id: site.id,
            workspace_id: other_workspace.id,
            version_number: "3.0.0"
          )

        response =
          make_api_request(
            "#{@api_tenant_path}/workspace/#{workspace.id}",
            %{},
            method: :get,
            headers: [{"authorization", "Bearer #{token}"}]
          )

        assert response.status == 200
        body = Jason.decode!(response.resp_body)

        ids = Enum.map(body["data"], & &1["id"])
        assert version1.id in ids
        assert version2.id in ids
        assert length(ids) == 2
      end
    end

    describe "READ - GET /latest - Latest versions only" do
      test "tenant admin can list only latest versions", %{
        tenant_admin: tenant_admin,
        site: site
      } do
        token = sign_in_tenant(tenant_admin)
        workspace = create_workspace!(site_id: site.id)

        version1 =
          create_workspace_version!(
            site_id: site.id,
            workspace_id: workspace.id,
            version_number: "1.0.0",
            is_latest_for_version: false
          )

        version2 =
          create_workspace_version!(
            site_id: site.id,
            workspace_id: workspace.id,
            version_number: "2.0.0",
            is_latest_for_version: true
          )

        response =
          make_api_request(
            "#{@api_tenant_path}/latest",
            %{},
            method: :get,
            headers: [{"authorization", "Bearer #{token}"}]
          )

        assert response.status == 200
        body = Jason.decode!(response.resp_body)

        ids = Enum.map(body["data"], & &1["id"])
        refute version1.id in ids
        assert version2.id in ids
      end
    end

    describe "READ - GET /status/:status - Filter by status" do
      test "tenant admin can filter versions by status", %{
        tenant_admin: tenant_admin,
        site: site
      } do
        token = sign_in_tenant(tenant_admin)

        draft_version =
          create_workspace_version!(site_id: site.id, version_number: "0.1.0", status: :draft)

        _stable_version =
          create_workspace_version!(
            site_id: site.id,
            version_number: "1.0.0",
            status: :stable,
            published_at: DateTime.utc_now()
          )

        response =
          make_api_request(
            "#{@api_tenant_path}/status/draft",
            %{},
            method: :get,
            headers: [{"authorization", "Bearer #{token}"}]
          )

        assert response.status == 200
        body = Jason.decode!(response.resp_body)

        ids = Enum.map(body["data"], & &1["id"])
        assert draft_version.id in ids

        # Verify all returned versions have draft status
        Enum.each(body["data"], fn version ->
          assert version["attributes"]["status"] == "draft"
        end)
      end
    end

    describe "UPDATE - PATCH /workspace-version" do
      test "master admin can update any version", %{
        master_user: master_user,
        site: site
      } do
        token = sign_in_master(master_user)
        version = create_workspace_version!(site_id: site.id, version_number: "1.0.0")

        response =
          make_api_request(
            "#{@api_master_path}/#{version.id}",
            %{
              "type" => "workspace_version",
              "attributes" => %{
                "version_name" => "Updated Name",
                "description" => "Updated description"
              }
            },
            method: :patch,
            headers: [{"authorization", "Bearer #{token}"}, {"x-no-tenant", "true"}]
          )

        assert response.status == 200
        body = Jason.decode!(response.resp_body)
        assert body["data"]["attributes"]["version_name"] == "Updated Name"
      end

      test "tenant admin can update only their own site's version", %{
        tenant_admin: tenant_admin,
        site: site,
        site2: site2
      } do
        token = sign_in_tenant(tenant_admin)

        version_own = create_workspace_version!(site_id: site.id, version_number: "1.0.0")
        version_other = create_workspace_version!(site_id: site2.id, version_number: "2.0.0")

        # Can update own
        response =
          make_api_request(
            "#{@api_tenant_path}/#{version_own.id}",
            %{
              "type" => "workspace_version",
              "attributes" => %{"description" => "Updated"}
            },
            method: :patch,
            headers: [{"authorization", "Bearer #{token}"}]
          )

        assert response.status == 200

        # Cannot update other site's
        response2 =
          make_api_request(
            "#{@api_tenant_path}/#{version_other.id}",
            %{
              "type" => "workspace_version",
              "attributes" => %{"description" => "Hacked"}
            },
            method: :patch,
            headers: [{"authorization", "Bearer #{token}"}]
          )

        assert response2.status == 404
      end
    end

    describe "PATCH /:id/publish - Publish version" do
      test "tenant admin can publish a draft version", %{
        tenant_admin: tenant_admin,
        site: site
      } do
        token = sign_in_tenant(tenant_admin)

        version =
          create_workspace_version!(
            site_id: site.id,
            version_number: "1.0.0",
            status: :draft
          )

        response =
          make_api_request(
            "#{@api_tenant_path}/#{version.id}/publish",
            %{"type" => "workspace_version", "attributes" => %{}},
            method: :patch,
            headers: [{"authorization", "Bearer #{token}"}]
          )

        assert response.status == 200
        body = Jason.decode!(response.resp_body)
        assert body["data"]["attributes"]["status"] == "stable"
        assert body["data"]["attributes"]["published_at"] != nil
      end

      test "cannot publish already published version", %{
        tenant_admin: tenant_admin,
        site: site
      } do
        token = sign_in_tenant(tenant_admin)

        version =
          create_workspace_version!(
            site_id: site.id,
            version_number: "1.0.0",
            status: :stable,
            published_at: DateTime.utc_now()
          )

        response =
          make_api_request(
            "#{@api_tenant_path}/#{version.id}/publish",
            %{"type" => "workspace_version", "attributes" => %{}},
            method: :patch,
            headers: [{"authorization", "Bearer #{token}"}]
          )

        assert response.status == 400
      end
    end

    describe "PATCH /:id/mark-latest - Mark as latest version" do
      test "tenant admin can mark version as latest", %{
        tenant_admin: tenant_admin,
        site: site
      } do
        token = sign_in_tenant(tenant_admin)
        workspace = create_workspace!(site_id: site.id)

        version1 =
          create_workspace_version!(
            site_id: site.id,
            workspace_id: workspace.id,
            version_number: "1.0.0",
            is_latest_for_version: true
          )

        version2 =
          create_workspace_version!(
            site_id: site.id,
            workspace_id: workspace.id,
            version_number: "2.0.0",
            is_latest_for_version: false
          )

        response =
          make_api_request(
            "#{@api_tenant_path}/#{version2.id}/mark-latest",
            %{"type" => "workspace_version", "attributes" => %{}},
            method: :patch,
            headers: [{"authorization", "Bearer #{token}"}]
          )

        assert response.status == 200
        body = Jason.decode!(response.resp_body)
        assert body["data"]["attributes"]["is_latest_for_version"] == true

        # Verify version1 is no longer latest
        version1_updated =
          Ash.get!(MishkaDocument.WorkspaceVersion, version1.id,
            action: :master_get,
            authorize?: false
          )

        assert version1_updated.is_latest_for_version == false
      end
    end

    describe "DELETE - Permanent deletion" do
      test "master admin can permanently delete any version", %{
        master_user: master_user,
        site: site
      } do
        token = sign_in_master(master_user)

        version =
          create_workspace_version!(
            site_id: site.id,
            version_number: "1.0.0",
            is_latest_for_version: false
          )

        version_id = version.id

        response =
          make_api_request(
            "#{@api_master_path}/#{version_id}",
            %{},
            method: :delete,
            headers: [{"authorization", "Bearer #{token}"}, {"x-no-tenant", "true"}]
          )

        assert response.status == 200

        # Verify completely gone
        result = Ash.get(MishkaDocument.WorkspaceVersion, version_id, action: :master_get)
        assert match?({:error, _}, result)
      end

      test "tenant admin can permanently delete their own site's version", %{
        tenant_admin: tenant_admin,
        site: site,
        site2: site2
      } do
        token = sign_in_tenant(tenant_admin)

        version_own =
          create_workspace_version!(
            site_id: site.id,
            version_number: "1.0.0",
            is_latest_for_version: false
          )

        version_other = create_workspace_version!(site_id: site2.id, version_number: "2.0.0")

        # Can delete own
        response =
          make_api_request(
            "#{@api_tenant_path}/#{version_own.id}",
            %{},
            method: :delete,
            headers: [{"authorization", "Bearer #{token}"}]
          )

        assert response.status == 200

        # Cannot delete other
        response2 =
          make_api_request(
            "#{@api_tenant_path}/#{version_other.id}",
            %{},
            method: :delete,
            headers: [{"authorization", "Bearer #{token}"}]
          )

        assert response2.status == 404
      end

      test "cannot delete latest version", %{
        tenant_admin: tenant_admin,
        site: site
      } do
        token = sign_in_tenant(tenant_admin)

        version =
          create_workspace_version!(
            site_id: site.id,
            version_number: "1.0.0",
            is_latest_for_version: true
          )

        response =
          make_api_request(
            "#{@api_tenant_path}/#{version.id}",
            %{},
            method: :delete,
            headers: [{"authorization", "Bearer #{token}"}]
          )

        assert response.status == 400
      end
    end

    describe "PUBLIC - Unauthenticated access" do
      test "anyone can list published versions (alpha, beta, stable)", %{site: site} do
        # Create published versions (alpha, beta, stable) and draft versions
        alpha =
          create_workspace_version!(
            site_id: site.id,
            version_number: "1.0.0",
            status: :alpha,
            published_at: DateTime.utc_now()
          )

        beta =
          create_workspace_version!(
            site_id: site.id,
            version_number: "2.0.0",
            status: :beta,
            published_at: DateTime.utc_now()
          )

        stable =
          create_workspace_version!(
            site_id: site.id,
            version_number: "3.0.0",
            status: :stable,
            published_at: DateTime.utc_now()
          )

        draft =
          create_workspace_version!(site_id: site.id, version_number: "4.0.0", status: :draft)

        response =
          make_api_request(
            @api_public_path,
            %{},
            method: :get,
            headers: []
          )

        assert response.status == 200
        body = Jason.decode!(response.resp_body)
        assert is_list(body["data"])

        ids = Enum.map(body["data"], & &1["id"])
        assert alpha.id in ids
        assert beta.id in ids
        assert stable.id in ids
        refute draft.id in ids

        # All should be published status (alpha, beta, or stable)
        Enum.each(body["data"], fn version ->
          assert version["attributes"]["status"] in ["alpha", "beta", "stable"]
        end)
      end

      test "anyone can get published version by id (alpha, beta, or stable)", %{site: site} do
        alpha_version =
          create_workspace_version!(
            site_id: site.id,
            version_number: "1.0.0",
            status: :alpha,
            published_at: DateTime.utc_now()
          )

        beta_version =
          create_workspace_version!(
            site_id: site.id,
            version_number: "2.0.0",
            status: :beta,
            published_at: DateTime.utc_now()
          )

        stable_version =
          create_workspace_version!(
            site_id: site.id,
            version_number: "3.0.0",
            status: :stable,
            published_at: DateTime.utc_now()
          )

        # Test alpha
        response_alpha =
          make_api_request(
            "#{@api_public_path}/#{alpha_version.id}",
            %{},
            method: :get,
            headers: []
          )

        assert response_alpha.status == 200
        body_alpha = Jason.decode!(response_alpha.resp_body)
        assert body_alpha["data"]["id"] == alpha_version.id
        assert body_alpha["data"]["attributes"]["status"] == "alpha"

        # Test beta
        response_beta =
          make_api_request(
            "#{@api_public_path}/#{beta_version.id}",
            %{},
            method: :get,
            headers: []
          )

        assert response_beta.status == 200
        body_beta = Jason.decode!(response_beta.resp_body)
        assert body_beta["data"]["id"] == beta_version.id
        assert body_beta["data"]["attributes"]["status"] == "beta"

        # Test stable
        response_stable =
          make_api_request(
            "#{@api_public_path}/#{stable_version.id}",
            %{},
            method: :get,
            headers: []
          )

        assert response_stable.status == 200
        body_stable = Jason.decode!(response_stable.resp_body)
        assert body_stable["data"]["id"] == stable_version.id
        assert body_stable["data"]["attributes"]["status"] == "stable"
      end

      test "anyone cannot get draft version", %{site: site} do
        draft_version =
          create_workspace_version!(
            site_id: site.id,
            version_number: "0.1.0",
            status: :draft
          )

        response =
          make_api_request(
            "#{@api_public_path}/#{draft_version.id}",
            %{},
            method: :get,
            headers: []
          )

        assert response.status == 404
      end

      test "anyone cannot get archived version", %{site: site} do
        archived_version =
          create_workspace_version!(
            site_id: site.id,
            version_number: "0.1.0",
            status: :archived
          )

        response =
          make_api_request(
            "#{@api_public_path}/#{archived_version.id}",
            %{},
            method: :get,
            headers: []
          )

        assert response.status == 404
      end
    end

    describe "BUSINESS LOGIC - Ensure single latest version per workspace" do
      test "creating version with is_latest_for_version=true unmarks other latest versions", %{
        tenant_admin: tenant_admin,
        site: site
      } do
        token = sign_in_tenant(tenant_admin)
        workspace = create_workspace!(site_id: site.id, skip_version: true)

        # Create first version marked as latest
        version1 =
          create_workspace_version!(
            site_id: site.id,
            workspace_id: workspace.id,
            version_number: "1.0.0",
            is_latest_for_version: true
          )

        # Verify version1 is marked as latest
        assert version1.is_latest_for_version == true

        # Create second version also marked as latest via API
        response =
          make_api_request(
            @api_tenant_path,
            %{
              "type" => "workspace_version",
              "attributes" => %{
                "workspace_id" => workspace.id,
                "version_number" => "2.0.0",
                "version_name" => "Version 2",
                "status" => "draft",
                "is_latest_for_version" => true
              }
            },
            method: :post,
            headers: [{"authorization", "Bearer #{token}"}]
          )

        assert response.status == 201
        body = Jason.decode!(response.resp_body)

        # Verify version2 is marked as latest
        assert body["data"]["attributes"]["is_latest_for_version"] == true

        # Reload version1 and verify it's no longer marked as latest
        reloaded_version1 =
          Ash.get!(MishkaDocument.WorkspaceVersion, version1.id,
            action: :read,
            tenant: site.id,
            authorize?: false
          )

        assert reloaded_version1.is_latest_for_version == false
      end

      test "updating version to is_latest_for_version=true unmarks other latest versions", %{
        tenant_admin: tenant_admin,
        site: site
      } do
        token = sign_in_tenant(tenant_admin)
        workspace = create_workspace!(site_id: site.id, skip_version: true)

        # Create two versions, first one marked as latest
        version1 =
          create_workspace_version!(
            site_id: site.id,
            workspace_id: workspace.id,
            version_number: "1.0.0",
            is_latest_for_version: true
          )

        version2 =
          create_workspace_version!(
            site_id: site.id,
            workspace_id: workspace.id,
            version_number: "2.0.0",
            is_latest_for_version: false
          )

        # Verify initial state
        assert version1.is_latest_for_version == true
        assert version2.is_latest_for_version == false

        # Update version2 to be latest via API
        response =
          make_api_request(
            "#{@api_tenant_path}/#{version2.id}",
            %{
              "type" => "workspace_version",
              "attributes" => %{
                "is_latest_for_version" => true
              }
            },
            method: :patch,
            headers: [{"authorization", "Bearer #{token}"}]
          )

        assert response.status == 200
        body = Jason.decode!(response.resp_body)
        assert body["data"]["attributes"]["is_latest_for_version"] == true

        # Reload version1 and verify it's no longer marked as latest
        reloaded_version1 =
          Ash.get!(MishkaDocument.WorkspaceVersion, version1.id,
            action: :read,
            tenant: site.id,
            authorize?: false
          )

        assert reloaded_version1.is_latest_for_version == false
      end

      test "mark_as_latest endpoint correctly unmarks other versions", %{
        tenant_admin: tenant_admin,
        site: site
      } do
        token = sign_in_tenant(tenant_admin)
        workspace = create_workspace!(site_id: site.id, skip_version: true)

        # Create three versions, first one marked as latest
        version1 =
          create_workspace_version!(
            site_id: site.id,
            workspace_id: workspace.id,
            version_number: "1.0.0",
            is_latest_for_version: true
          )

        version2 =
          create_workspace_version!(
            site_id: site.id,
            workspace_id: workspace.id,
            version_number: "2.0.0",
            is_latest_for_version: false
          )

        version3 =
          create_workspace_version!(
            site_id: site.id,
            workspace_id: workspace.id,
            version_number: "3.0.0",
            is_latest_for_version: false
          )

        # Mark version3 as latest using the dedicated endpoint
        response =
          make_api_request(
            "#{@api_tenant_path}/#{version3.id}/mark-latest",
            %{"type" => "workspace_version", "attributes" => %{}},
            method: :patch,
            headers: [{"authorization", "Bearer #{token}"}]
          )

        assert response.status == 200
        body = Jason.decode!(response.resp_body)
        assert body["data"]["attributes"]["is_latest_for_version"] == true

        # Reload all versions and verify only version3 is latest
        reloaded_version1 =
          Ash.get!(MishkaDocument.WorkspaceVersion, version1.id,
            action: :read,
            tenant: site.id,
            authorize?: false
          )

        reloaded_version2 =
          Ash.get!(MishkaDocument.WorkspaceVersion, version2.id,
            action: :read,
            tenant: site.id,
            authorize?: false
          )

        reloaded_version3 =
          Ash.get!(MishkaDocument.WorkspaceVersion, version3.id,
            action: :read,
            tenant: site.id,
            authorize?: false
          )

        assert reloaded_version1.is_latest_for_version == false
        assert reloaded_version2.is_latest_for_version == false
        assert reloaded_version3.is_latest_for_version == true
      end

      test "transaction rollback: failed create doesn't leave workspace without latest version",
           %{
             tenant_admin: tenant_admin,
             site: site
           } do
        token = sign_in_tenant(tenant_admin)
        workspace = create_workspace!(site_id: site.id, skip_version: true)

        # Create first version marked as latest
        version1 =
          create_workspace_version!(
            site_id: site.id,
            workspace_id: workspace.id,
            version_number: "1.0.0",
            is_latest_for_version: true
          )

        # Verify version1 is marked as latest
        assert version1.is_latest_for_version == true

        # Try to create duplicate version (same version_number) with is_latest=true
        # This should FAIL due to unique constraint, and version1 should REMAIN latest
        response =
          make_api_request(
            @api_tenant_path,
            %{
              "type" => "workspace_version",
              "attributes" => %{
                "workspace_id" => workspace.id,
                "version_number" => "1.0.0",
                "version_name" => "Duplicate Version",
                "status" => "draft",
                "is_latest_for_version" => true
              }
            },
            method: :post,
            headers: [{"authorization", "Bearer #{token}"}]
          )

        # Verify create failed due to duplicate version_number
        assert response.status in [400, 422, 409]

        # CRITICAL: Reload version1 and verify it's STILL marked as latest
        # Without transaction, it would have been unmarked and we'd have NO latest version
        reloaded_version1 =
          Ash.get!(MishkaDocument.WorkspaceVersion, version1.id,
            action: :read,
            tenant: site.id,
            authorize?: false
          )

        assert reloaded_version1.is_latest_for_version == true,
               "Transaction rollback failed! version1 should still be marked as latest after failed create"
      end

      test "single latest version works across different workspaces", %{
        site: site
      } do
        workspace1 = create_workspace!(site_id: site.id, skip_version: true)
        workspace2 = create_workspace!(site_id: site.id, skip_version: true)

        # Create versions for workspace1, both marked as latest
        version1_ws1 =
          create_workspace_version!(
            site_id: site.id,
            workspace_id: workspace1.id,
            version_number: "1.0.0",
            is_latest_for_version: true
          )

        version2_ws1 =
          create_workspace_version!(
            site_id: site.id,
            workspace_id: workspace1.id,
            version_number: "2.0.0",
            is_latest_for_version: true
          )

        # Create version for workspace2, marked as latest
        version1_ws2 =
          create_workspace_version!(
            site_id: site.id,
            workspace_id: workspace2.id,
            version_number: "1.0.0",
            is_latest_for_version: true
          )

        # Reload all versions
        reloaded_v1_ws1 =
          Ash.get!(MishkaDocument.WorkspaceVersion, version1_ws1.id,
            action: :read,
            tenant: site.id,
            authorize?: false
          )

        reloaded_v2_ws1 =
          Ash.get!(MishkaDocument.WorkspaceVersion, version2_ws1.id,
            action: :read,
            tenant: site.id,
            authorize?: false
          )

        reloaded_v1_ws2 =
          Ash.get!(MishkaDocument.WorkspaceVersion, version1_ws2.id,
            action: :read,
            tenant: site.id,
            authorize?: false
          )

        # Verify: workspace1 only has version2 as latest, workspace2 still has version1 as latest
        assert reloaded_v1_ws1.is_latest_for_version == false
        assert reloaded_v2_ws1.is_latest_for_version == true
        assert reloaded_v1_ws2.is_latest_for_version == true
      end
    end

    describe "INCLUDES - Fetching related workspace data" do
      test "can include workspace data when listing versions", %{
        tenant_admin: tenant_admin,
        site: site
      } do
        token = sign_in_tenant(tenant_admin)

        workspace =
          create_workspace!(
            site_id: site.id,
            name: "API Documentation",
            status: :active
          )

        version =
          create_workspace_version!(
            site_id: site.id,
            workspace_id: workspace.id,
            version_number: "1.0.0"
          )

        response =
          make_api_request(
            "#{@api_tenant_path}?include=workspace",
            %{},
            method: :get,
            headers: [{"authorization", "Bearer #{token}"}]
          )

        assert response.status == 200
        body = Jason.decode!(response.resp_body)

        # Find our version in the results
        version_data = Enum.find(body["data"], &(&1["id"] == version.id))
        assert version_data != nil

        # Verify workspace relationship is present
        assert version_data["relationships"]["workspace"]["data"]["id"] == workspace.id

        # Verify included workspace data
        assert body["included"] != nil
        included_workspaces = Enum.filter(body["included"], &(&1["type"] == "workspace"))
        assert length(included_workspaces) >= 1

        workspace_included = Enum.find(included_workspaces, &(&1["id"] == workspace.id))
        assert workspace_included != nil
        assert workspace_included["attributes"]["name"] == "API Documentation"
      end
    end
  end
end
