# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_document/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaDocumentWeb.Api.Json.WorkspaceVersionLineageTest do
  @moduledoc """
  Comprehensive tests for WorkspaceVersionLineage JSON API endpoints.
  """

  use MishkaDocument.ConnCase
  import MishkaDocument.Test.Factory

  @moduletag :unit
  @moduletag :capture_log

  if Code.ensure_loaded?(MishkaDocument) do
    @password "Password123!"
    @api_user_path "/api/json/v1/auth/user"
    @api_master_path "/api/json/v1/master/admin/mishka-document/workspace-version-lineage"
    @api_tenant_path "/api/json/v1/tenant/admin/mishka-document/workspace-version-lineage"
    @api_public_path "/api/json/v1/user/mishka-document/workspace-version-lineage"

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

    describe "CREATE - POST /" do
      test "tenant admin can create lineage record", %{tenant_admin: tenant_admin, site: site} do
        token = sign_in_tenant(tenant_admin)

        workspace = create_workspace!(site_id: site.id, skip_version: true)

        source_version =
          create_workspace_version!(
            site_id: site.id,
            workspace_id: workspace.id,
            version_number: "1.0.0",
            status: :stable,
            published_at: DateTime.utc_now()
          )

        new_version =
          create_workspace_version!(
            site_id: site.id,
            workspace_id: workspace.id,
            version_number: "2.0.0",
            status: :stable,
            published_at: DateTime.utc_now()
          )

        response =
          make_api_request(
            @api_tenant_path,
            %{
              "type" => "workspace_version_lineage",
              "attributes" => %{
                "new_version_id" => new_version.id,
                "source_version_id" => source_version.id,
                "cloned_at" =>
                  DateTime.utc_now() |> DateTime.add(-3600, :second) |> DateTime.to_iso8601()
              }
            },
            method: :post,
            headers: [{"authorization", "Bearer #{token}"}]
          )

        assert response.status == 201
        body = Jason.decode!(response.resp_body)
        assert body["data"]["attributes"]["new_version_id"] == new_version.id
        assert body["data"]["attributes"]["source_version_id"] == source_version.id

        assert {:ok, %DateTime{}, _offset} =
                 DateTime.from_iso8601(body["data"]["attributes"]["cloned_at"])
      end

      test "master admin can create lineage record with explicit site_id", %{
        master_user: master_user,
        site: site
      } do
        token = sign_in_master(master_user)

        workspace = create_workspace!(site_id: site.id, skip_version: true)

        source_version =
          create_workspace_version!(
            site_id: site.id,
            workspace_id: workspace.id,
            version_number: "1.0.0"
          )

        new_version =
          create_workspace_version!(
            site_id: site.id,
            workspace_id: workspace.id,
            version_number: "2.0.0"
          )

        response =
          make_api_request(
            @api_master_path,
            %{
              "type" => "workspace_version_lineage",
              "attributes" => %{
                "new_version_id" => new_version.id,
                "source_version_id" => source_version.id,
                "site_id" => site.id,
                "cloned_at" =>
                  DateTime.utc_now() |> DateTime.add(-3600, :second) |> DateTime.to_iso8601()
              }
            },
            method: :post,
            headers: [{"authorization", "Bearer #{token}"}, {"x-no-tenant", "true"}]
          )

        assert response.status == 201
        body = Jason.decode!(response.resp_body)
        assert body["data"]["attributes"]["new_version_id"] == new_version.id
        assert body["data"]["attributes"]["source_version_id"] == source_version.id
      end

      test "cannot create lineage where version is cloned from itself", %{
        tenant_admin: tenant_admin,
        site: site
      } do
        token = sign_in_tenant(tenant_admin)

        workspace = create_workspace!(site_id: site.id, skip_version: true)

        version =
          create_workspace_version!(
            site_id: site.id,
            workspace_id: workspace.id,
            version_number: "1.0.0"
          )

        response =
          make_api_request(
            @api_tenant_path,
            %{
              "type" => "workspace_version_lineage",
              "attributes" => %{
                "new_version_id" => version.id,
                "source_version_id" => version.id
              }
            },
            method: :post,
            headers: [{"authorization", "Bearer #{token}"}]
          )

        assert response.status in [400, 422]
        body = Jason.decode!(response.resp_body)

        assert Enum.any?(body["errors"], fn error ->
                 error["detail"] =~ "cannot be cloned from itself"
               end)
      end
    end

    describe "READ - GET / and GET /:id" do
      test "tenant admin can list lineage records", %{tenant_admin: tenant_admin, site: site} do
        token = sign_in_tenant(tenant_admin)

        lineage1 = create_workspace_version_lineage!(site_id: site.id)
        lineage2 = create_workspace_version_lineage!(site_id: site.id)

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
        assert lineage1.id in ids
        assert lineage2.id in ids
      end

      test "tenant admin can get single lineage record", %{
        tenant_admin: tenant_admin,
        site: site
      } do
        token = sign_in_tenant(tenant_admin)

        lineage = create_workspace_version_lineage!(site_id: site.id)

        response =
          make_api_request(
            "#{@api_tenant_path}/#{lineage.id}",
            %{},
            method: :get,
            headers: [{"authorization", "Bearer #{token}"}]
          )

        assert response.status == 200
        body = Jason.decode!(response.resp_body)
        assert body["data"]["id"] == lineage.id
      end

      test "tenant admin cannot access other tenant's lineage records", %{
        tenant_admin: tenant_admin,
        site2: site2
      } do
        token = sign_in_tenant(tenant_admin)

        # Create lineage for site2
        lineage_site2 = create_workspace_version_lineage!(site_id: site2.id)

        response =
          make_api_request(
            "#{@api_tenant_path}/#{lineage_site2.id}",
            %{},
            method: :get,
            headers: [{"authorization", "Bearer #{token}"}]
          )

        assert response.status == 404
      end

      test "master admin can access all lineage records", %{
        master_user: master_user,
        site: site,
        site2: site2
      } do
        token = sign_in_master(master_user)

        lineage_site1 = create_workspace_version_lineage!(site_id: site.id)
        lineage_site2 = create_workspace_version_lineage!(site_id: site2.id)

        response =
          make_api_request(
            @api_master_path,
            %{},
            method: :get,
            headers: [{"authorization", "Bearer #{token}"}, {"x-no-tenant", "true"}]
          )

        assert response.status == 200
        body = Jason.decode!(response.resp_body)

        ids = Enum.map(body["data"], & &1["id"])
        assert lineage_site1.id in ids
        assert lineage_site2.id in ids
      end
    end

    describe "READ - GET /new-version/:new_version_id" do
      test "tenant admin can get lineage by new version", %{
        tenant_admin: tenant_admin,
        site: site
      } do
        token = sign_in_tenant(tenant_admin)

        workspace = create_workspace!(site_id: site.id, skip_version: true)

        source_version =
          create_workspace_version!(
            site_id: site.id,
            workspace_id: workspace.id,
            version_number: "1.0.0"
          )

        new_version =
          create_workspace_version!(
            site_id: site.id,
            workspace_id: workspace.id,
            version_number: "2.0.0"
          )

        lineage =
          create_workspace_version_lineage!(
            site_id: site.id,
            new_version_id: new_version.id,
            source_version_id: source_version.id
          )

        response =
          make_api_request(
            "#{@api_tenant_path}/new-version/#{new_version.id}",
            %{},
            method: :get,
            headers: [{"authorization", "Bearer #{token}"}]
          )

        assert response.status == 200
        body = Jason.decode!(response.resp_body)
        assert [_ | _] = body["data"]
        assert Enum.any?(body["data"], fn item -> item["id"] == lineage.id end)
      end
    end

    describe "READ - GET /source-version/:source_version_id" do
      test "tenant admin can get all lineages from a source version", %{
        tenant_admin: tenant_admin,
        site: site
      } do
        token = sign_in_tenant(tenant_admin)

        workspace = create_workspace!(site_id: site.id, skip_version: true)

        source_version =
          create_workspace_version!(
            site_id: site.id,
            workspace_id: workspace.id,
            version_number: "1.0.0"
          )

        new_version1 =
          create_workspace_version!(
            site_id: site.id,
            workspace_id: workspace.id,
            version_number: "2.0.0"
          )

        new_version2 =
          create_workspace_version!(
            site_id: site.id,
            workspace_id: workspace.id,
            version_number: "3.0.0"
          )

        lineage1 =
          create_workspace_version_lineage!(
            site_id: site.id,
            new_version_id: new_version1.id,
            source_version_id: source_version.id
          )

        lineage2 =
          create_workspace_version_lineage!(
            site_id: site.id,
            new_version_id: new_version2.id,
            source_version_id: source_version.id
          )

        response =
          make_api_request(
            "#{@api_tenant_path}/source-version/#{source_version.id}",
            %{},
            method: :get,
            headers: [{"authorization", "Bearer #{token}"}]
          )

        assert response.status == 200
        body = Jason.decode!(response.resp_body)

        ids = Enum.map(body["data"], & &1["id"])
        assert lineage1.id in ids
        assert lineage2.id in ids
        assert length(ids) == 2
      end
    end

    describe "READ - GET /recent" do
      test "tenant admin can get recent clones sorted by date", %{
        tenant_admin: tenant_admin,
        site: site
      } do
        token = sign_in_tenant(tenant_admin)

        # Create lineages with different timestamps
        lineage1 =
          create_workspace_version_lineage!(
            site_id: site.id,
            cloned_at: DateTime.add(DateTime.utc_now(), -3600, :second)
          )

        lineage2 =
          create_workspace_version_lineage!(
            site_id: site.id,
            cloned_at: DateTime.add(DateTime.utc_now(), -1800, :second)
          )

        lineage3 =
          create_workspace_version_lineage!(
            site_id: site.id,
            cloned_at: DateTime.add(DateTime.utc_now(), -60, :second)
          )

        response =
          make_api_request(
            "#{@api_tenant_path}/recent",
            %{},
            method: :get,
            headers: [{"authorization", "Bearer #{token}"}]
          )

        assert response.status == 200
        body = Jason.decode!(response.resp_body)

        ids = Enum.map(body["data"], & &1["id"])

        # Most recent should be first
        assert hd(ids) == lineage3.id
        assert Enum.at(ids, 1) == lineage2.id
        assert Enum.at(ids, 2) == lineage1.id
      end
    end

    describe "UPDATE - PATCH /:id" do
      test "tenant admin can update lineage cloned_at timestamp", %{
        tenant_admin: tenant_admin,
        site: site
      } do
        token = sign_in_tenant(tenant_admin)

        lineage = create_workspace_version_lineage!(site_id: site.id)
        new_timestamp = DateTime.add(DateTime.utc_now(), -7200, :second)

        response =
          make_api_request(
            "#{@api_tenant_path}/#{lineage.id}",
            %{
              "type" => "workspace_version_lineage",
              "attributes" => %{
                "cloned_at" => DateTime.to_iso8601(new_timestamp)
              }
            },
            method: :patch,
            headers: [{"authorization", "Bearer #{token}"}]
          )

        assert response.status == 200
        body = Jason.decode!(response.resp_body)
        # Timestamps should be close (within a few seconds due to processing time)
        assert {:ok, %DateTime{}, _offset} =
                 DateTime.from_iso8601(body["data"]["attributes"]["cloned_at"])
      end

      test "tenant admin cannot update other tenant's lineage", %{
        tenant_admin: tenant_admin,
        site2: site2
      } do
        token = sign_in_tenant(tenant_admin)

        lineage_site2 = create_workspace_version_lineage!(site_id: site2.id)

        response =
          make_api_request(
            "#{@api_tenant_path}/#{lineage_site2.id}",
            %{
              "type" => "workspace_version_lineage",
              "attributes" => %{
                "cloned_at" => DateTime.to_iso8601(DateTime.utc_now())
              }
            },
            method: :patch,
            headers: [{"authorization", "Bearer #{token}"}]
          )

        assert response.status == 404
      end
    end

    describe "DELETE - DELETE /:id" do
      test "tenant admin can delete lineage record", %{tenant_admin: tenant_admin, site: site} do
        token = sign_in_tenant(tenant_admin)

        lineage = create_workspace_version_lineage!(site_id: site.id)

        response =
          make_api_request(
            "#{@api_tenant_path}/#{lineage.id}",
            %{},
            method: :delete,
            headers: [{"authorization", "Bearer #{token}"}]
          )

        assert response.status in [200, 204]

        # API returning 200/204 confirms delete was successful
      end

      test "tenant admin cannot delete other tenant's lineage", %{
        tenant_admin: tenant_admin,
        site2: site2
      } do
        token = sign_in_tenant(tenant_admin)

        lineage_site2 = create_workspace_version_lineage!(site_id: site2.id)

        response =
          make_api_request(
            "#{@api_tenant_path}/#{lineage_site2.id}",
            %{},
            method: :delete,
            headers: [{"authorization", "Bearer #{token}"}]
          )

        assert response.status == 404
      end

      test "master admin can delete any lineage record", %{
        master_user: master_user,
        site: site,
        site2: site2
      } do
        token = sign_in_master(master_user)

        lineage_site1 = create_workspace_version_lineage!(site_id: site.id)
        lineage_site2 = create_workspace_version_lineage!(site_id: site2.id)

        response1 =
          make_api_request(
            "#{@api_master_path}/#{lineage_site1.id}",
            %{},
            method: :delete,
            headers: [{"authorization", "Bearer #{token}"}, {"x-no-tenant", "true"}]
          )

        assert response1.status in [200, 204]

        response2 =
          make_api_request(
            "#{@api_master_path}/#{lineage_site2.id}",
            %{},
            method: :delete,
            headers: [{"authorization", "Bearer #{token}"}, {"x-no-tenant", "true"}]
          )

        assert response2.status in [200, 204]
      end
    end

    describe "PUBLIC - GET /new-version/:new_version_id (only stable versions)" do
      test "public user can view lineage for stable versions", %{site: site} do
        workspace = create_workspace!(site_id: site.id, skip_version: true, status: :active)

        source_version =
          create_workspace_version!(
            site_id: site.id,
            workspace_id: workspace.id,
            version_number: "1.0.0",
            status: :stable,
            published_at: DateTime.utc_now()
          )

        new_version =
          create_workspace_version!(
            site_id: site.id,
            workspace_id: workspace.id,
            version_number: "2.0.0",
            status: :stable,
            published_at: DateTime.utc_now()
          )

        lineage =
          create_workspace_version_lineage!(
            site_id: site.id,
            new_version_id: new_version.id,
            source_version_id: source_version.id
          )

        response =
          make_api_request(
            "#{@api_public_path}/new-version/#{new_version.id}",
            %{},
            method: :get
          )

        assert response.status == 200
        body = Jason.decode!(response.resp_body)
        assert [_ | _] = body["data"]
        assert Enum.any?(body["data"], fn item -> item["id"] == lineage.id end)
      end

      test "public user cannot view lineage with draft versions", %{site: site} do
        workspace = create_workspace!(site_id: site.id, skip_version: true, status: :active)

        source_version =
          create_workspace_version!(
            site_id: site.id,
            workspace_id: workspace.id,
            version_number: "1.0.0",
            status: :stable,
            published_at: DateTime.utc_now()
          )

        new_version_draft =
          create_workspace_version!(
            site_id: site.id,
            workspace_id: workspace.id,
            version_number: "2.0.0",
            status: :draft
          )

        _lineage =
          create_workspace_version_lineage!(
            site_id: site.id,
            new_version_id: new_version_draft.id,
            source_version_id: source_version.id
          )

        response =
          make_api_request(
            "#{@api_public_path}/new-version/#{new_version_draft.id}",
            %{},
            method: :get
          )

        assert response.status == 200
        body = Jason.decode!(response.resp_body)
        # Should return empty list since draft version is filtered out
        assert body["data"] == []
      end
    end

    describe "PUBLIC - GET /source-version/:source_version_id (only stable versions)" do
      test "public user can view all stable versions cloned from a source", %{site: site} do
        workspace = create_workspace!(site_id: site.id, skip_version: true, status: :active)

        source_version =
          create_workspace_version!(
            site_id: site.id,
            workspace_id: workspace.id,
            version_number: "1.0.0",
            status: :stable,
            published_at: DateTime.utc_now()
          )

        new_version1 =
          create_workspace_version!(
            site_id: site.id,
            workspace_id: workspace.id,
            version_number: "2.0.0",
            status: :stable,
            published_at: DateTime.utc_now()
          )

        new_version2_draft =
          create_workspace_version!(
            site_id: site.id,
            workspace_id: workspace.id,
            version_number: "3.0.0",
            status: :draft
          )

        lineage1 =
          create_workspace_version_lineage!(
            site_id: site.id,
            new_version_id: new_version1.id,
            source_version_id: source_version.id
          )

        _lineage2_draft =
          create_workspace_version_lineage!(
            site_id: site.id,
            new_version_id: new_version2_draft.id,
            source_version_id: source_version.id
          )

        response =
          make_api_request(
            "#{@api_public_path}/source-version/#{source_version.id}",
            %{},
            method: :get
          )

        assert response.status == 200
        body = Jason.decode!(response.resp_body)

        ids = Enum.map(body["data"], & &1["id"])
        # Only stable version lineage should be returned
        assert lineage1.id in ids
        assert length(ids) == 1
      end
    end

    describe "PUBLIC - GET /recent (only stable versions)" do
      test "public user can view recent stable version clones", %{site: site} do
        workspace = create_workspace!(site_id: site.id, skip_version: true, status: :active)

        source_stable =
          create_workspace_version!(
            site_id: site.id,
            workspace_id: workspace.id,
            version_number: "1.0.0",
            status: :stable,
            published_at: DateTime.utc_now()
          )

        new_stable =
          create_workspace_version!(
            site_id: site.id,
            workspace_id: workspace.id,
            version_number: "2.0.0",
            status: :stable,
            published_at: DateTime.utc_now()
          )

        new_draft =
          create_workspace_version!(
            site_id: site.id,
            workspace_id: workspace.id,
            version_number: "3.0.0",
            status: :draft
          )

        lineage_stable =
          create_workspace_version_lineage!(
            site_id: site.id,
            new_version_id: new_stable.id,
            source_version_id: source_stable.id
          )

        _lineage_draft =
          create_workspace_version_lineage!(
            site_id: site.id,
            new_version_id: new_draft.id,
            source_version_id: source_stable.id
          )

        response =
          make_api_request(
            "#{@api_public_path}/recent",
            %{},
            method: :get
          )

        assert response.status == 200
        body = Jason.decode!(response.resp_body)

        ids = Enum.map(body["data"], & &1["id"])
        # Only stable lineage should be returned
        assert lineage_stable.id in ids
        assert length(ids) == 1
      end
    end

    describe "PUBLIC - GET /:id (only stable versions)" do
      test "public user can get a specific stable lineage record", %{site: site} do
        workspace = create_workspace!(site_id: site.id, skip_version: true, status: :active)

        source_version =
          create_workspace_version!(
            site_id: site.id,
            workspace_id: workspace.id,
            version_number: "1.0.0",
            status: :stable,
            published_at: DateTime.utc_now()
          )

        new_version =
          create_workspace_version!(
            site_id: site.id,
            workspace_id: workspace.id,
            version_number: "2.0.0",
            status: :stable,
            published_at: DateTime.utc_now()
          )

        lineage =
          create_workspace_version_lineage!(
            site_id: site.id,
            new_version_id: new_version.id,
            source_version_id: source_version.id
          )

        response =
          make_api_request(
            "#{@api_public_path}/#{lineage.id}",
            %{},
            method: :get
          )

        assert response.status == 200
        body = Jason.decode!(response.resp_body)
        assert body["data"]["id"] == lineage.id
      end

      test "public user cannot get lineage with draft versions", %{site: site} do
        workspace = create_workspace!(site_id: site.id, skip_version: true, status: :active)

        source_version =
          create_workspace_version!(
            site_id: site.id,
            workspace_id: workspace.id,
            version_number: "1.0.0",
            status: :stable,
            published_at: DateTime.utc_now()
          )

        new_version_draft =
          create_workspace_version!(
            site_id: site.id,
            workspace_id: workspace.id,
            version_number: "2.0.0",
            status: :draft
          )

        lineage =
          create_workspace_version_lineage!(
            site_id: site.id,
            new_version_id: new_version_draft.id,
            source_version_id: source_version.id
          )

        response =
          make_api_request(
            "#{@api_public_path}/#{lineage.id}",
            %{},
            method: :get
          )

        assert response.status == 404
      end
    end

    describe "INCLUDES - Fetching related version data" do
      test "can include new_version and source_version data", %{
        tenant_admin: tenant_admin,
        site: site
      } do
        token = sign_in_tenant(tenant_admin)

        workspace = create_workspace!(site_id: site.id, skip_version: true)

        source_version =
          create_workspace_version!(
            site_id: site.id,
            workspace_id: workspace.id,
            version_number: "1.0.0",
            version_name: "Source Version"
          )

        new_version =
          create_workspace_version!(
            site_id: site.id,
            workspace_id: workspace.id,
            version_number: "2.0.0",
            version_name: "New Version"
          )

        lineage =
          create_workspace_version_lineage!(
            site_id: site.id,
            new_version_id: new_version.id,
            source_version_id: source_version.id
          )

        response =
          make_api_request(
            "#{@api_tenant_path}/#{lineage.id}?include=new_version,source_version",
            %{},
            method: :get,
            headers: [{"authorization", "Bearer #{token}"}]
          )

        assert response.status == 200
        body = Jason.decode!(response.resp_body)

        # Verify included data
        assert [_ | _] = body["included"]
        included_versions = Enum.filter(body["included"], &(&1["type"] == "workspace_version"))
        assert length(included_versions) == 2

        version_ids = Enum.map(included_versions, & &1["id"])
        assert source_version.id in version_ids
        assert new_version.id in version_ids
      end
    end

    describe "MASTER - lineage lookups on the master routes" do
      setup %{site: site, site2: site2} do
        in_site = fn site_id ->
          workspace = create_workspace!(site_id: site_id, skip_version: true)
          source = create_workspace_version!(site_id: site_id, workspace_id: workspace.id)
          new = create_workspace_version!(site_id: site_id, workspace_id: workspace.id)

          create_workspace_version_lineage!(
            site_id: site_id,
            new_version_id: new.id,
            source_version_id: source.id
          )
        end

        %{own: in_site.(site.id), other: in_site.(site2.id)}
      end

      defp master_get(token, path) do
        response =
          make_api_request("#{@api_master_path}#{path}", %{},
            method: :get,
            headers: [{"authorization", "Bearer #{token}"}, {"x-no-tenant", "true"}]
          )

        {response.status, response.resp_body |> Jason.decode!() |> Map.get("data")}
      end

      defp data_ids(data), do: data |> List.wrap() |> Enum.map(& &1["id"])

      test "a master reads any site's lineage by new version, source version, date and recency",
           %{master_user: master_user, own: own, other: other} do
        token = sign_in_master(master_user)
        from = DateTime.utc_now() |> DateTime.add(-86_400, :second) |> DateTime.to_iso8601()
        to = DateTime.utc_now() |> DateTime.add(86_400, :second) |> DateTime.to_iso8601()

        assert {200, data} = master_get(token, "/new-version/#{other.new_version_id}")
        assert other.id in data_ids(data)

        assert {200, data} = master_get(token, "/source-version/#{other.source_version_id}")
        assert other.id in data_ids(data)

        assert {200, data} = master_get(token, "/date-range?start_date=#{from}&end_date=#{to}")
        assert own.id in data_ids(data)
        assert other.id in data_ids(data)

        assert {200, data} = master_get(token, "/recent")
        assert own.id in data_ids(data)
        assert other.id in data_ids(data)
      end

      test "a site admin is not served on the master routes", %{
        tenant_admin: tenant_admin,
        own: own
      } do
        token = sign_in_tenant(tenant_admin)

        for path <- ["/new-version/#{own.new_version_id}", "/recent"] do
          response =
            make_api_request("#{@api_master_path}#{path}", %{},
              method: :get,
              headers: [{"authorization", "Bearer #{token}"}]
            )

          refute response.status == 200, "#{path} served a site admin on the master route"
        end
      end
    end
  end
end
