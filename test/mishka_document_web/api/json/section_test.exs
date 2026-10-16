# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_document/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaDocumentWeb.Api.Json.SectionTest do
  @moduledoc """
  Comprehensive tests for Section JSON API endpoints.

  Tests all public, tenant admin, and master admin section endpoints.
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
    @public_path "/api/json/v1/user/mishka-document/section"
    @tenant_path "/api/json/v1/tenant/admin/mishka-document/section"
    @master_path "/api/json/v1/master/admin/mishka-document/section"

    setup do
      MishkaCmsCore.Runtime.States.SiteState.clear()
      :ok = Swoosh.TestAssertions.set_swoosh_global()

      Application.put_env(:ash_json_api, MishkaDocument, router: MishkaDocument.TestRouter)

      # Create site
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

      # Create tenant admin user
      tenant_admin =
        create_user!(
          email: "admin@example.com",
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

      on_exit(fn ->
        MishkaCmsCore.Runtime.States.SiteState.delete(site.id)
        MishkaCmsCore.Runtime.States.SiteState.clear()
      end)

      %{
        site: site,
        master_user: master_user,
        tenant_admin: tenant_admin
      }
    end

    # Helper functions for sign-in
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

    describe "PUBLIC - GET /v1/user/mishka-document/section (index :public_list)" do
      test "returns only approved sections", %{site: site} do
        workspace = create_workspace!(site_id: site.id, skip_version: true, status: :active)

        ws_version =
          create_workspace_version!(
            workspace_id: workspace.id,
            site_id: site.id,
            version_number: "1.0.0",
            status: :stable,
            published_at: DateTime.utc_now()
          )

        # Create approved section
        approved =
          create_section!(
            workspace_version_id: ws_version.id,
            site_id: site.id,
            title: "Approved Section",
            slug: "approved",
            content_review_status: :approved,
            technical_review_status: :approved
          )

        # Create pending section
        _pending =
          create_section!(
            workspace_version_id: ws_version.id,
            site_id: site.id,
            title: "Pending Section",
            slug: "pending",
            content_review_status: :pending,
            technical_review_status: :approved
          )

        response =
          make_api_request(
            @public_path,
            %{},
            method: :get,
            headers: []
          )

        assert response.status == 200
        body = Jason.decode!(response.resp_body)

        # Should only return approved section
        assert length(body["data"]) == 1
        assert hd(body["data"])["id"] == approved.id
      end

      test "supports pagination", %{site: site} do
        workspace = create_workspace!(site_id: site.id, skip_version: true, status: :active)

        ws_version =
          create_workspace_version!(
            workspace_id: workspace.id,
            site_id: site.id,
            version_number: "1.0.0",
            status: :stable,
            published_at: DateTime.utc_now()
          )

        # Create 5 approved sections
        _sections =
          1..5
          |> Enum.map(fn i ->
            create_section!(
              workspace_version_id: ws_version.id,
              site_id: site.id,
              title: "Section #{i}",
              slug: "section-#{i}",
              content_review_status: :approved,
              technical_review_status: :approved
            )
          end)

        response =
          make_api_request(
            "#{@public_path}?page[limit]=2",
            %{},
            method: :get,
            headers: []
          )

        assert response.status == 200
        body = Jason.decode!(response.resp_body)
        assert length(body["data"]) == 2
      end
    end

    describe "PUBLIC - GET /v1/user/mishka-document/section/:id (get :public_get)" do
      test "returns approved section by id", %{site: site} do
        workspace = create_workspace!(site_id: site.id, skip_version: true, status: :active)

        ws_version =
          create_workspace_version!(
            workspace_id: workspace.id,
            site_id: site.id,
            version_number: "1.0.0",
            status: :stable,
            published_at: DateTime.utc_now()
          )

        section =
          create_section!(
            workspace_version_id: ws_version.id,
            site_id: site.id,
            title: "Installation Guide",
            slug: "installation",
            content: "How to install",
            content_review_status: :approved,
            technical_review_status: :approved
          )

        response =
          make_api_request(
            "#{@public_path}/#{section.id}",
            %{},
            method: :get,
            headers: []
          )

        assert response.status == 200
        body = Jason.decode!(response.resp_body)
        assert body["data"]["id"] == section.id
        assert body["data"]["attributes"]["title"] == "Installation Guide"
      end

      test "returns 404 for pending section", %{site: site} do
        workspace = create_workspace!(site_id: site.id, skip_version: true, status: :active)

        ws_version =
          create_workspace_version!(
            workspace_id: workspace.id,
            site_id: site.id,
            version_number: "1.0.0",
            status: :stable,
            published_at: DateTime.utc_now()
          )

        pending =
          create_section!(
            workspace_version_id: ws_version.id,
            site_id: site.id,
            title: "Pending Section",
            slug: "pending",
            content_review_status: :pending,
            technical_review_status: :approved
          )

        response =
          make_api_request(
            "#{@public_path}/#{pending.id}",
            %{},
            method: :get,
            headers: []
          )

        assert response.status == 404
      end
    end

    describe "PUBLIC - GET /workspace/:workspace_version_id/version/:version_number" do
      test "returns approved sections for specific workspace version", %{site: site} do
        workspace = create_workspace!(site_id: site.id, skip_version: true, status: :active)

        v1 =
          create_workspace_version!(
            workspace_id: workspace.id,
            site_id: site.id,
            version_number: "1.0.0",
            status: :stable,
            published_at: DateTime.utc_now()
          )

        v2 =
          create_workspace_version!(
            workspace_id: workspace.id,
            site_id: site.id,
            version_number: "2.0.0",
            status: :stable,
            published_at: DateTime.utc_now()
          )

        # Create section for v1
        v1_section =
          create_section!(
            workspace_version_id: v1.id,
            site_id: site.id,
            title: "V1 Section",
            slug: "v1-section",
            content_review_status: :approved,
            technical_review_status: :approved
          )

        # Create section for v2
        _v2_section =
          create_section!(
            workspace_version_id: v2.id,
            site_id: site.id,
            title: "V2 Section",
            slug: "v2-section",
            content_review_status: :approved,
            technical_review_status: :approved
          )

        response =
          make_api_request(
            "#{@public_path}/workspace/#{v1.id}/version/#{v1.version_number}",
            %{},
            method: :get,
            headers: []
          )

        assert response.status == 200
        body = Jason.decode!(response.resp_body)

        # Should only return v1 section
        assert length(body["data"]) == 1
        assert hd(body["data"])["id"] == v1_section.id
      end

      test "only returns sections with both approvals", %{site: site} do
        workspace = create_workspace!(site_id: site.id, skip_version: true, status: :active)

        ws_version =
          create_workspace_version!(
            workspace_id: workspace.id,
            site_id: site.id,
            version_number: "1.0.0",
            status: :stable,
            published_at: DateTime.utc_now()
          )

        # Fully approved
        approved =
          create_section!(
            workspace_version_id: ws_version.id,
            site_id: site.id,
            title: "Approved",
            slug: "approved",
            content_review_status: :approved,
            technical_review_status: :approved
          )

        # Only content approved
        _content_only =
          create_section!(
            workspace_version_id: ws_version.id,
            site_id: site.id,
            title: "Content Only",
            slug: "content-only",
            content_review_status: :approved,
            technical_review_status: :pending
          )

        # Only technical approved
        _technical_only =
          create_section!(
            workspace_version_id: ws_version.id,
            site_id: site.id,
            title: "Technical Only",
            slug: "technical-only",
            content_review_status: :pending,
            technical_review_status: :approved
          )

        response =
          make_api_request(
            "#{@public_path}/workspace/#{ws_version.id}/version/#{ws_version.version_number}",
            %{},
            method: :get,
            headers: []
          )

        assert response.status == 200
        body = Jason.decode!(response.resp_body)
        assert length(body["data"]) == 1
        assert hd(body["data"])["id"] == approved.id
      end

      test "returns sections with pagination", %{site: site} do
        workspace = create_workspace!(site_id: site.id, skip_version: true, status: :active)

        ws_version =
          create_workspace_version!(
            workspace_id: workspace.id,
            site_id: site.id,
            version_number: "1.0.0",
            status: :stable,
            published_at: DateTime.utc_now()
          )

        # Create 5 sections
        _sections =
          1..5
          |> Enum.map(fn i ->
            create_section!(
              workspace_version_id: ws_version.id,
              site_id: site.id,
              title: "Section #{i}",
              slug: "section-#{i}",
              content_review_status: :approved,
              technical_review_status: :approved
            )
          end)

        response =
          make_api_request(
            "#{@public_path}/workspace/#{ws_version.id}/version/#{ws_version.version_number}?page[limit]=2",
            %{},
            method: :get,
            headers: []
          )

        assert response.status == 200
        body = Jason.decode!(response.resp_body)
        assert length(body["data"]) == 2
      end
    end

    describe "TENANT ADMIN - GET /v1/tenant/admin/mishka-document/section (index :read)" do
      test "returns all sections including non-approved", %{
        site: site,
        tenant_admin: tenant_admin
      } do
        token = sign_in_tenant(tenant_admin)

        workspace = create_workspace!(site_id: site.id, skip_version: true, status: :active)

        ws_version =
          create_workspace_version!(
            workspace_id: workspace.id,
            site_id: site.id,
            version_number: "1.0.0",
            status: :stable,
            published_at: DateTime.utc_now()
          )

        _approved =
          create_section!(
            workspace_version_id: ws_version.id,
            site_id: site.id,
            title: "Approved",
            slug: "approved",
            content_review_status: :approved,
            technical_review_status: :approved
          )

        _pending =
          create_section!(
            workspace_version_id: ws_version.id,
            site_id: site.id,
            title: "Pending",
            slug: "pending",
            content_review_status: :pending,
            technical_review_status: :pending
          )

        response =
          make_api_request(
            @tenant_path,
            %{},
            method: :get,
            headers: [
              {"authorization", "Bearer #{token}"}
            ]
          )

        assert response.status == 200
        body = Jason.decode!(response.resp_body)
        assert length(body["data"]) == 2
      end
    end

    describe "TENANT ADMIN - GET /v1/tenant/admin/mishka-document/section/:id (get :read)" do
      test "returns section by id", %{site: site, tenant_admin: tenant_admin} do
        token = sign_in_tenant(tenant_admin)

        workspace = create_workspace!(site_id: site.id, skip_version: true, status: :active)

        ws_version =
          create_workspace_version!(
            workspace_id: workspace.id,
            site_id: site.id,
            version_number: "1.0.0",
            status: :stable,
            published_at: DateTime.utc_now()
          )

        section =
          create_section!(
            workspace_version_id: ws_version.id,
            site_id: site.id,
            title: "Test Section",
            slug: "test",
            content_review_status: :pending,
            technical_review_status: :pending
          )

        response =
          make_api_request(
            "#{@tenant_path}/#{section.id}",
            %{},
            method: :get,
            headers: [
              {"authorization", "Bearer #{token}"}
            ]
          )

        assert response.status == 200
        body = Jason.decode!(response.resp_body)
        assert body["data"]["id"] == section.id
        assert body["data"]["attributes"]["title"] == "Test Section"
      end
    end

    describe "TENANT ADMIN - POST /v1/tenant/admin/mishka-document/section (create)" do
      test "creates new section", %{site: site, tenant_admin: tenant_admin} do
        token = sign_in_tenant(tenant_admin)

        workspace = create_workspace!(site_id: site.id, skip_version: true, status: :active)

        ws_version =
          create_workspace_version!(
            workspace_id: workspace.id,
            site_id: site.id,
            version_number: "1.0.0",
            status: :stable,
            published_at: DateTime.utc_now()
          )

        params = %{
          "type" => "section",
          "attributes" => %{
            "workspace_version_id" => ws_version.id,
            "title" => "New Section",
            "slug" => "new-section",
            "content" => "New content",
            "language" => "en"
          }
        }

        response =
          make_api_request(
            @tenant_path,
            params,
            method: :post,
            headers: [
              {"authorization", "Bearer #{token}"},
              {"content-type", "application/vnd.api+json"}
            ]
          )

        assert response.status == 201
        body = Jason.decode!(response.resp_body)
        assert body["data"]["attributes"]["title"] == "New Section"
      end
    end

    describe "TENANT ADMIN - PATCH /v1/tenant/admin/mishka-document/section/:id (update)" do
      test "updates section", %{site: site, tenant_admin: tenant_admin} do
        token = sign_in_tenant(tenant_admin)

        workspace = create_workspace!(site_id: site.id, skip_version: true, status: :active)

        ws_version =
          create_workspace_version!(
            workspace_id: workspace.id,
            site_id: site.id,
            version_number: "1.0.0",
            status: :stable,
            published_at: DateTime.utc_now()
          )

        section =
          create_section!(
            workspace_version_id: ws_version.id,
            site_id: site.id,
            title: "Original Title",
            slug: "original",
            content_review_status: :pending,
            technical_review_status: :pending
          )

        params = %{
          "type" => "section",
          "attributes" => %{
            "title" => "Updated Title"
          }
        }

        response =
          make_api_request(
            "#{@tenant_path}/#{section.id}",
            params,
            method: :patch,
            headers: [
              {"authorization", "Bearer #{token}"},
              {"content-type", "application/vnd.api+json"}
            ]
          )

        assert response.status == 200
        body = Jason.decode!(response.resp_body)
        assert body["data"]["attributes"]["title"] == "Updated Title"
      end
    end

    describe "TENANT ADMIN - DELETE /v1/tenant/admin/mishka-document/section/:id/archive (destroy)" do
      test "archives section (soft delete)", %{site: site, tenant_admin: tenant_admin} do
        token = sign_in_tenant(tenant_admin)

        workspace = create_workspace!(site_id: site.id, skip_version: true, status: :active)

        ws_version =
          create_workspace_version!(
            workspace_id: workspace.id,
            site_id: site.id,
            version_number: "1.0.0",
            status: :stable,
            published_at: DateTime.utc_now()
          )

        section =
          create_section!(
            workspace_version_id: ws_version.id,
            site_id: site.id,
            title: "To Archive",
            slug: "to-archive",
            content_review_status: :pending,
            technical_review_status: :pending
          )

        response =
          make_api_request(
            "#{@tenant_path}/#{section.id}/archive",
            %{},
            method: :delete,
            headers: [
              {"authorization", "Bearer #{token}"}
            ]
          )

        assert response.status == 200
      end
    end

    describe "TENANT ADMIN - GET /v1/tenant/admin/mishka-document/section/archived (index :archived)" do
      test "lists archived sections", %{site: site, tenant_admin: tenant_admin} do
        token = sign_in_tenant(tenant_admin)

        workspace = create_workspace!(site_id: site.id, skip_version: true, status: :active)

        ws_version =
          create_workspace_version!(
            workspace_id: workspace.id,
            site_id: site.id,
            version_number: "1.0.0",
            status: :stable,
            published_at: DateTime.utc_now()
          )

        # Create and archive a section
        section =
          create_section!(
            workspace_version_id: ws_version.id,
            site_id: site.id,
            title: "Archived Section",
            slug: "archived",
            content_review_status: :pending,
            technical_review_status: :pending
          )

        section
        |> Ash.Changeset.for_destroy(:destroy, %{}, tenant: site.id, authorize?: false)
        |> Ash.destroy!()

        response =
          make_api_request(
            "#{@tenant_path}/archived",
            %{},
            method: :get,
            headers: [
              {"authorization", "Bearer #{token}"}
            ]
          )

        assert response.status == 200
        body = Jason.decode!(response.resp_body)
        assert length(body["data"]) == 1
        assert hd(body["data"])["id"] == section.id
      end
    end

    describe "TENANT ADMIN - GET /v1/tenant/admin/mishka-document/section/archived/:id (get :get_archived)" do
      test "gets archived section by id", %{site: site, tenant_admin: tenant_admin} do
        token = sign_in_tenant(tenant_admin)

        workspace = create_workspace!(site_id: site.id, skip_version: true, status: :active)

        ws_version =
          create_workspace_version!(
            workspace_id: workspace.id,
            site_id: site.id,
            version_number: "1.0.0",
            status: :stable,
            published_at: DateTime.utc_now()
          )

        # Create and archive a section
        section =
          create_section!(
            workspace_version_id: ws_version.id,
            site_id: site.id,
            title: "Archived Section",
            slug: "archived",
            content_review_status: :approved,
            technical_review_status: :approved
          )

        section
        |> Ash.Changeset.for_destroy(:destroy, %{}, tenant: site.id, authorize?: false)
        |> Ash.destroy!()

        response =
          make_api_request(
            "#{@tenant_path}/archived/#{section.id}",
            %{},
            method: :get,
            headers: [
              {"authorization", "Bearer #{token}"}
            ]
          )

        assert response.status == 200
        body = Jason.decode!(response.resp_body)
        assert body["data"]["id"] == section.id
        assert body["data"]["attributes"]["title"] == "Archived Section"
      end
    end

    describe "TENANT ADMIN - PATCH /v1/tenant/admin/mishka-document/section/:id/unarchive (unarchive)" do
      test "unarchives section", %{site: site, tenant_admin: tenant_admin} do
        token = sign_in_tenant(tenant_admin)

        workspace = create_workspace!(site_id: site.id, skip_version: true, status: :active)

        ws_version =
          create_workspace_version!(
            workspace_id: workspace.id,
            site_id: site.id,
            version_number: "1.0.0",
            status: :stable,
            published_at: DateTime.utc_now()
          )

        # Create and archive a section
        section =
          create_section!(
            workspace_version_id: ws_version.id,
            site_id: site.id,
            title: "To Unarchive",
            slug: "to-unarchive",
            content_review_status: :approved,
            technical_review_status: :approved
          )

        section
        |> Ash.Changeset.for_destroy(:destroy, %{}, tenant: site.id, authorize?: false)
        |> Ash.destroy!()

        response =
          make_api_request(
            "#{@tenant_path}/#{section.id}/unarchive",
            %{},
            method: :patch,
            headers: [
              {"authorization", "Bearer #{token}"}
            ]
          )

        assert response.status == 200
        body = Jason.decode!(response.resp_body)
        assert body["data"]["attributes"]["archived_at"] == nil
        # Should be reset to pending after unarchive
        assert body["data"]["attributes"]["content_review_status"] == "pending"
        assert body["data"]["attributes"]["technical_review_status"] == "pending"
      end
    end

    describe "TENANT ADMIN - DELETE /v1/tenant/admin/mishka-document/section/:id/permanent (permanent_destroy)" do
      test "permanently deletes section from database", %{site: site, tenant_admin: tenant_admin} do
        token = sign_in_tenant(tenant_admin)

        workspace = create_workspace!(site_id: site.id, skip_version: true, status: :active)

        ws_version =
          create_workspace_version!(
            workspace_id: workspace.id,
            site_id: site.id,
            version_number: "1.0.0",
            status: :stable,
            published_at: DateTime.utc_now()
          )

        section =
          create_section!(
            workspace_version_id: ws_version.id,
            site_id: site.id,
            title: "To Delete Permanently",
            slug: "to-delete",
            content_review_status: :pending,
            technical_review_status: :pending
          )

        response =
          make_api_request(
            "#{@tenant_path}/#{section.id}/permanent",
            %{},
            method: :delete,
            headers: [
              {"authorization", "Bearer #{token}"}
            ]
          )

        assert response.status == 200
      end
    end

    describe "MASTER ADMIN - GET /v1/master/admin/mishka-document/section (index :master_read)" do
      test "returns sections from all sites", %{site: site, master_user: master_user} do
        token = sign_in_master(master_user)

        # Create second site
        site2 = create_site!(name: "site2", host: "site2.com", active: true, priority: 50)

        MishkaCmsCore.Runtime.States.SiteState.save(%{
          id: site2.id,
          name: site2.name,
          host: site2.host,
          priority: site2.priority,
          active: site2.active
        })

        # Create workspace and section for site 1
        ws1 = create_workspace!(site_id: site.id, skip_version: true, status: :active)

        ws_v1 =
          create_workspace_version!(
            workspace_id: ws1.id,
            site_id: site.id,
            version_number: "1.0.0",
            status: :stable,
            published_at: DateTime.utc_now()
          )

        _section1 =
          create_section!(
            workspace_version_id: ws_v1.id,
            site_id: site.id,
            title: "Site 1 Section",
            slug: "site1-section",
            content_review_status: :approved,
            technical_review_status: :approved
          )

        # Create workspace and section for site 2
        ws2 = create_workspace!(site_id: site2.id, skip_version: true, status: :active)

        ws_v2 =
          create_workspace_version!(
            workspace_id: ws2.id,
            site_id: site2.id,
            version_number: "1.0.0",
            status: :stable,
            published_at: DateTime.utc_now()
          )

        _section2 =
          create_section!(
            workspace_version_id: ws_v2.id,
            site_id: site2.id,
            title: "Site 2 Section",
            slug: "site2-section",
            content_review_status: :approved,
            technical_review_status: :approved
          )

        response =
          make_api_request(
            @master_path,
            %{},
            method: :get,
            headers: [
              {"authorization", "Bearer #{token}"},
              {"x-no-tenant", "true"}
            ]
          )

        assert response.status == 200
        body = Jason.decode!(response.resp_body)
        # Should see sections from both sites
        assert length(body["data"]) == 2
      end
    end

    describe "MASTER ADMIN - GET /v1/master/admin/mishka-document/section/:id (get :master_get)" do
      test "gets section by id from any site", %{site: site, master_user: master_user} do
        token = sign_in_master(master_user)

        workspace = create_workspace!(site_id: site.id, skip_version: true, status: :active)

        ws_version =
          create_workspace_version!(
            workspace_id: workspace.id,
            site_id: site.id,
            version_number: "1.0.0",
            status: :stable,
            published_at: DateTime.utc_now()
          )

        section =
          create_section!(
            workspace_version_id: ws_version.id,
            site_id: site.id,
            title: "Test Section",
            slug: "test",
            content_review_status: :pending,
            technical_review_status: :pending
          )

        response =
          make_api_request(
            "#{@master_path}/#{section.id}",
            %{},
            method: :get,
            headers: [
              {"authorization", "Bearer #{token}"},
              {"x-no-tenant", "true"}
            ]
          )

        assert response.status == 200
        body = Jason.decode!(response.resp_body)
        assert body["data"]["id"] == section.id
        assert body["data"]["attributes"]["title"] == "Test Section"
      end
    end

    describe "MASTER ADMIN - POST /v1/master/admin/mishka-document/section (master_create)" do
      test "creates section for specified site", %{site: site, master_user: master_user} do
        token = sign_in_master(master_user)

        workspace = create_workspace!(site_id: site.id, skip_version: true, status: :active)

        ws_version =
          create_workspace_version!(
            workspace_id: workspace.id,
            site_id: site.id,
            version_number: "1.0.0",
            status: :stable,
            published_at: DateTime.utc_now()
          )

        params = %{
          "type" => "section",
          "attributes" => %{
            "workspace_version_id" => ws_version.id,
            "site_id" => site.id,
            "title" => "Master Created Section",
            "slug" => "master-section",
            "content" => "Content",
            "language" => "en"
          }
        }

        response =
          make_api_request(
            @master_path,
            params,
            method: :post,
            headers: [
              {"authorization", "Bearer #{token}"},
              {"x-no-tenant", "true"},
              {"content-type", "application/vnd.api+json"}
            ]
          )

        assert response.status == 201
        body = Jason.decode!(response.resp_body)
        assert body["data"]["attributes"]["title"] == "Master Created Section"
      end
    end

    describe "MASTER ADMIN - PATCH /v1/master/admin/mishka-document/section/:id (master_update)" do
      test "updates section on any site", %{site: site, master_user: master_user} do
        token = sign_in_master(master_user)

        workspace = create_workspace!(site_id: site.id, skip_version: true, status: :active)

        ws_version =
          create_workspace_version!(
            workspace_id: workspace.id,
            site_id: site.id,
            version_number: "1.0.0",
            status: :stable,
            published_at: DateTime.utc_now()
          )

        section =
          create_section!(
            workspace_version_id: ws_version.id,
            site_id: site.id,
            title: "Original Title",
            slug: "original",
            content_review_status: :pending,
            technical_review_status: :pending
          )

        params = %{
          "type" => "section",
          "attributes" => %{
            "title" => "Master Updated Title"
          }
        }

        response =
          make_api_request(
            "#{@master_path}/#{section.id}",
            params,
            method: :patch,
            headers: [
              {"authorization", "Bearer #{token}"},
              {"x-no-tenant", "true"},
              {"content-type", "application/vnd.api+json"}
            ]
          )

        assert response.status == 200
        body = Jason.decode!(response.resp_body)
        assert body["data"]["attributes"]["title"] == "Master Updated Title"
      end
    end

    describe "MASTER ADMIN - DELETE /v1/master/admin/mishka-document/section/:id/archive (master_destroy)" do
      test "archives section from any site", %{site: site, master_user: master_user} do
        token = sign_in_master(master_user)

        workspace = create_workspace!(site_id: site.id, skip_version: true, status: :active)

        ws_version =
          create_workspace_version!(
            workspace_id: workspace.id,
            site_id: site.id,
            version_number: "1.0.0",
            status: :stable,
            published_at: DateTime.utc_now()
          )

        section =
          create_section!(
            workspace_version_id: ws_version.id,
            site_id: site.id,
            title: "To Archive",
            slug: "to-archive",
            content_review_status: :pending,
            technical_review_status: :pending
          )

        response =
          make_api_request(
            "#{@master_path}/#{section.id}/archive",
            %{},
            method: :delete,
            headers: [
              {"authorization", "Bearer #{token}"},
              {"x-no-tenant", "true"}
            ]
          )

        assert response.status == 200
      end
    end

    describe "MASTER ADMIN - GET /v1/master/admin/mishka-document/section/archived (index :master_archived)" do
      test "lists archived sections from all sites", %{site: site, master_user: master_user} do
        token = sign_in_master(master_user)

        workspace = create_workspace!(site_id: site.id, skip_version: true, status: :active)

        ws_version =
          create_workspace_version!(
            workspace_id: workspace.id,
            site_id: site.id,
            version_number: "1.0.0",
            status: :stable,
            published_at: DateTime.utc_now()
          )

        # Create and archive a section
        section =
          create_section!(
            workspace_version_id: ws_version.id,
            site_id: site.id,
            title: "Archived Section",
            slug: "archived",
            content_review_status: :pending,
            technical_review_status: :pending
          )

        section
        |> Ash.Changeset.for_destroy(:destroy, %{}, tenant: site.id, authorize?: false)
        |> Ash.destroy!()

        response =
          make_api_request(
            "#{@master_path}/archived",
            %{},
            method: :get,
            headers: [
              {"authorization", "Bearer #{token}"},
              {"x-no-tenant", "true"}
            ]
          )

        assert response.status == 200
        body = Jason.decode!(response.resp_body)
        assert length(body["data"]) == 1
        assert hd(body["data"])["id"] == section.id
      end
    end

    describe "MASTER ADMIN - GET /v1/master/admin/mishka-document/section/archived/:id (get :master_get_archived)" do
      test "gets archived section by id from any site", %{site: site, master_user: master_user} do
        token = sign_in_master(master_user)

        workspace = create_workspace!(site_id: site.id, skip_version: true, status: :active)

        ws_version =
          create_workspace_version!(
            workspace_id: workspace.id,
            site_id: site.id,
            version_number: "1.0.0",
            status: :stable,
            published_at: DateTime.utc_now()
          )

        # Create and archive a section
        section =
          create_section!(
            workspace_version_id: ws_version.id,
            site_id: site.id,
            title: "Archived Section",
            slug: "archived",
            content_review_status: :approved,
            technical_review_status: :approved
          )

        section
        |> Ash.Changeset.for_destroy(:destroy, %{}, tenant: site.id, authorize?: false)
        |> Ash.destroy!()

        response =
          make_api_request(
            "#{@master_path}/archived/#{section.id}",
            %{},
            method: :get,
            headers: [
              {"authorization", "Bearer #{token}"},
              {"x-no-tenant", "true"}
            ]
          )

        assert response.status == 200
        body = Jason.decode!(response.resp_body)
        assert body["data"]["id"] == section.id
        assert body["data"]["attributes"]["title"] == "Archived Section"
      end
    end

    describe "MASTER ADMIN - PATCH /v1/master/admin/mishka-document/section/:id/unarchive (master_unarchive)" do
      test "unarchives section from any site", %{site: site, master_user: master_user} do
        token = sign_in_master(master_user)

        workspace = create_workspace!(site_id: site.id, skip_version: true, status: :active)

        ws_version =
          create_workspace_version!(
            workspace_id: workspace.id,
            site_id: site.id,
            version_number: "1.0.0",
            status: :stable,
            published_at: DateTime.utc_now()
          )

        # Create and archive a section
        section =
          create_section!(
            workspace_version_id: ws_version.id,
            site_id: site.id,
            title: "To Unarchive",
            slug: "to-unarchive",
            content_review_status: :approved,
            technical_review_status: :approved
          )

        section
        |> Ash.Changeset.for_destroy(:destroy, %{}, tenant: site.id, authorize?: false)
        |> Ash.destroy!()

        response =
          make_api_request(
            "#{@master_path}/#{section.id}/unarchive",
            %{},
            method: :patch,
            headers: [
              {"authorization", "Bearer #{token}"},
              {"x-no-tenant", "true"}
            ]
          )

        assert response.status == 200
        body = Jason.decode!(response.resp_body)
        assert body["data"]["attributes"]["archived_at"] == nil
        # Should be reset to pending after unarchive
        assert body["data"]["attributes"]["content_review_status"] == "pending"
        assert body["data"]["attributes"]["technical_review_status"] == "pending"
      end
    end

    describe "MASTER ADMIN - DELETE /v1/master/admin/mishka-document/section/:id/permanent (master_permanent_destroy)" do
      test "permanently deletes section from database", %{site: site, master_user: master_user} do
        token = sign_in_master(master_user)

        workspace = create_workspace!(site_id: site.id, skip_version: true, status: :active)

        ws_version =
          create_workspace_version!(
            workspace_id: workspace.id,
            site_id: site.id,
            version_number: "1.0.0",
            status: :stable,
            published_at: DateTime.utc_now()
          )

        section =
          create_section!(
            workspace_version_id: ws_version.id,
            site_id: site.id,
            title: "To Delete Permanently",
            slug: "to-delete",
            content_review_status: :pending,
            technical_review_status: :pending
          )

        response =
          make_api_request(
            "#{@master_path}/#{section.id}/permanent",
            %{},
            method: :delete,
            headers: [
              {"authorization", "Bearer #{token}"},
              {"x-no-tenant", "true"}
            ]
          )

        assert response.status == 200
      end
    end

    # Testing that pending_content_review_count and pending_technical_review_count
    # are only accessible to admin users

    describe "FIELD ACCESS - pending review counts" do
      setup %{site: site} do
        workspace = create_workspace!(site_id: site.id, skip_version: true, status: :active)

        ws_version =
          create_workspace_version!(
            workspace_id: workspace.id,
            site_id: site.id,
            version_number: "1.0.0",
            status: :stable,
            published_at: DateTime.utc_now()
          )

        # Create section with pending drafts to ensure count > 0
        section =
          create_section!(
            workspace_version_id: ws_version.id,
            site_id: site.id,
            title: "Section with Drafts",
            slug: "section-drafts",
            content_review_status: :approved,
            technical_review_status: :approved
          )

        # Create pending content review draft
        MishkaDocument.SectionDraft
        |> Ash.Changeset.for_create(
          :master_create,
          %{
            workspace_version_id: ws_version.id,
            source_section_id: section.id,
            title: "Draft 1",
            slug: "draft-1",
            change_version: "1.0.1",
            version_increment_type: :minor,
            content_review_status: :pending,
            technical_review_status: :approved,
            site_id: site.id
          },
          authorize?: false
        )
        |> Ash.create!(authorize?: false)

        # Create pending technical review draft
        MishkaDocument.SectionDraft
        |> Ash.Changeset.for_create(
          :master_create,
          %{
            workspace_version_id: ws_version.id,
            source_section_id: section.id,
            title: "Draft 2",
            slug: "draft-2",
            change_version: "1.0.2",
            version_increment_type: :minor,
            content_review_status: :approved,
            technical_review_status: :pending,
            site_id: site.id
          },
          authorize?: false
        )
        |> Ash.create!(authorize?: false)

        # Create pending content review note draft
        MishkaDocument.NoteDraft
        |> Ash.Changeset.for_create(
          :master_create,
          %{
            workspace_version_id: ws_version.id,
            section_id: section.id,
            title: "Note Draft 1",
            content: "Note draft content 1",
            change_version: "1.0.1",
            version_increment_type: :minor,
            content_review_status: :pending,
            technical_review_status: :approved,
            site_id: site.id
          },
          authorize?: false
        )
        |> Ash.create!(authorize?: false)

        # Create pending technical review note draft
        MishkaDocument.NoteDraft
        |> Ash.Changeset.for_create(
          :master_create,
          %{
            workspace_version_id: ws_version.id,
            section_id: section.id,
            title: "Note Draft 2",
            content: "Note draft content 2",
            change_version: "1.0.2",
            version_increment_type: :minor,
            content_review_status: :approved,
            technical_review_status: :pending,
            site_id: site.id
          },
          authorize?: false
        )
        |> Ash.create!(authorize?: false)

        # Create approved section draft (both reviews approved)
        # Use direct Ecto insert to bypass any Ash actions/hooks that might trigger auto-apply
        # Multitenancy uses :attribute strategy (site_id column), not schemas
        @repo.insert!(%MishkaDocument.SectionDraft{
          id: Ash.UUID.generate(),
          workspace_version_id: ws_version.id,
          source_section_id: section.id,
          title: "Approved Draft",
          slug: "approved-draft",
          content: "Approved draft content",
          order_position: 0,
          change_version: "1.0.3",
          version_increment_type: :minor,
          content_review_status: :approved,
          technical_review_status: :approved,
          site_id: site.id,
          language: "en",
          schema: [],
          seo_tags: [],
          inserted_at: DateTime.utc_now(),
          updated_at: DateTime.utc_now()
        })

        %{section: section}
      end

      test "tenant admin CAN access pending review count fields", %{
        site: site,
        tenant_admin: tenant_admin,
        section: section
      } do
        token = sign_in_tenant(tenant_admin)

        response =
          make_api_request(
            "#{@tenant_path}/#{section.id}?fields[section]=pending_section_draft_content_review_count,pending_section_draft_technical_review_count,approved_section_draft_count,pending_note_draft_content_review_count,pending_note_draft_technical_review_count,title,slug",
            %{},
            method: :get,
            headers: [
              {"authorization", "Bearer #{token}"},
              {"x-site-id", site.id}
            ]
          )

        assert response.status == 200
        body = Jason.decode!(response.resp_body)

        # Admin should see these fields
        assert Map.has_key?(
                 body["data"]["attributes"],
                 "pending_section_draft_content_review_count"
               )

        assert Map.has_key?(
                 body["data"]["attributes"],
                 "pending_section_draft_technical_review_count"
               )

        assert Map.has_key?(body["data"]["attributes"], "approved_section_draft_count")
        assert Map.has_key?(body["data"]["attributes"], "pending_note_draft_content_review_count")

        assert Map.has_key?(
                 body["data"]["attributes"],
                 "pending_note_draft_technical_review_count"
               )

        # Verify counts are correct (1 each for section drafts and note drafts)
        assert body["data"]["attributes"]["pending_section_draft_content_review_count"] == 1
        assert body["data"]["attributes"]["pending_section_draft_technical_review_count"] == 1
        assert body["data"]["attributes"]["approved_section_draft_count"] == 1
        assert body["data"]["attributes"]["pending_note_draft_content_review_count"] == 1
        assert body["data"]["attributes"]["pending_note_draft_technical_review_count"] == 1
      end

      test "master admin CAN access pending review count fields", %{
        master_user: master_user,
        section: section
      } do
        token = sign_in_master(master_user)

        response =
          make_api_request(
            "#{@master_path}/#{section.id}?fields[section]=pending_section_draft_content_review_count,pending_section_draft_technical_review_count,approved_section_draft_count,pending_note_draft_content_review_count,pending_note_draft_technical_review_count,title,slug",
            %{},
            method: :get,
            headers: [
              {"authorization", "Bearer #{token}"},
              {"x-no-tenant", "true"}
            ]
          )

        assert response.status == 200
        body = Jason.decode!(response.resp_body)

        # Admin should see these fields
        assert Map.has_key?(
                 body["data"]["attributes"],
                 "pending_section_draft_content_review_count"
               )

        assert Map.has_key?(
                 body["data"]["attributes"],
                 "pending_section_draft_technical_review_count"
               )

        assert Map.has_key?(body["data"]["attributes"], "approved_section_draft_count")
        assert Map.has_key?(body["data"]["attributes"], "pending_note_draft_content_review_count")

        assert Map.has_key?(
                 body["data"]["attributes"],
                 "pending_note_draft_technical_review_count"
               )

        # Verify counts are correct (1 each for section drafts and note drafts)
        assert body["data"]["attributes"]["pending_section_draft_content_review_count"] == 1
        assert body["data"]["attributes"]["pending_section_draft_technical_review_count"] == 1
        assert body["data"]["attributes"]["approved_section_draft_count"] == 1
        assert body["data"]["attributes"]["pending_note_draft_content_review_count"] == 1
        assert body["data"]["attributes"]["pending_note_draft_technical_review_count"] == 1
      end

      test "public/guest users CANNOT access pending review count fields", %{section: section} do
        # Explicitly request the forbidden calculation fields
        response =
          make_api_request(
            "#{@public_path}/#{section.id}?fields[section]=pending_section_draft_content_review_count,pending_section_draft_technical_review_count,approved_section_draft_count,pending_note_draft_content_review_count,pending_note_draft_technical_review_count,title,slug",
            %{},
            method: :get
          )

        assert response.status == 200
        body = Jason.decode!(response.resp_body)

        # Public users get null values for forbidden calculation fields when explicitly requested
        assert body["data"]["attributes"]["pending_section_draft_content_review_count"] == nil
        assert body["data"]["attributes"]["pending_section_draft_technical_review_count"] == nil
        assert body["data"]["attributes"]["approved_section_draft_count"] == nil
        assert body["data"]["attributes"]["pending_note_draft_content_review_count"] == nil
        assert body["data"]["attributes"]["pending_note_draft_technical_review_count"] == nil

        # But should see the other fields with actual values
        assert body["data"]["attributes"]["title"] == "Section with Drafts"
        assert body["data"]["attributes"]["slug"] == "section-drafts"
      end

      test "normal authenticated user (non-admin) CANNOT access pending review count fields", %{
        site: site,
        section: section
      } do
        # Create normal user without admin permissions
        normal_user =
          create_user!(
            email: "normal@example.com",
            password: @password,
            password_confirmation: @password,
            site_id: site.id
          )

        # Sign in as normal user
        sign_in_response =
          make_api_request(
            "#{@api_user_path}/sign-in",
            %{
              "type" => "user",
              "attributes" => %{
                "email" => to_string(normal_user.email),
                "password" => @password
              }
            }
          )

        assert sign_in_response.status == 201
        %{"meta" => %{"token" => token}} = Jason.decode!(sign_in_response.resp_body)

        # Explicitly request forbidden calculation fields
        response =
          make_api_request(
            "#{@public_path}/#{section.id}?fields[section]=pending_section_draft_content_review_count,pending_section_draft_technical_review_count,approved_section_draft_count,pending_note_draft_content_review_count,pending_note_draft_technical_review_count,title,slug",
            %{},
            method: :get,
            headers: [{"authorization", "Bearer #{token}"}]
          )

        assert response.status == 200
        body = Jason.decode!(response.resp_body)

        # Normal authenticated user (non-admin) gets null values for forbidden calculation fields
        assert body["data"]["attributes"]["pending_section_draft_content_review_count"] == nil
        assert body["data"]["attributes"]["pending_section_draft_technical_review_count"] == nil
        assert body["data"]["attributes"]["approved_section_draft_count"] == nil
        assert body["data"]["attributes"]["pending_note_draft_content_review_count"] == nil
        assert body["data"]["attributes"]["pending_note_draft_technical_review_count"] == nil

        # But should see other fields with actual values
        assert body["data"]["attributes"]["title"] == "Section with Drafts"
        assert body["data"]["attributes"]["slug"] == "section-drafts"
      end
    end

    describe "FIELD ACCESS - contributors_count" do
      setup %{site: site} do
        workspace = create_workspace!(site_id: site.id, skip_version: true, status: :active)

        ws_version =
          create_workspace_version!(
            workspace_id: workspace.id,
            site_id: site.id,
            version_number: "1.0.0",
            status: :stable,
            published_at: DateTime.utc_now()
          )

        # Create 2 contributor users
        user1 = create_user!(email: "contributor1@test.com")
        user2 = create_user!(email: "contributor2@test.com")

        # User 1: Creates the section (generates EventLog with actor)
        section =
          MishkaDocument.Section
          |> Ash.Changeset.for_create(
            :create,
            %{
              workspace_version_id: ws_version.id,
              title: "Section with Contributors",
              slug: "section-contributors",
              content_review_status: :approved,
              technical_review_status: :approved
            },
            actor: user1,
            tenant: site.id,
            authorize?: false
          )
          |> Ash.create!()

        # User 2: Creates a note for this section (generates EventLog with section_id in metadata)
        MishkaDocument.Note
        |> Ash.Changeset.for_create(
          :create,
          %{
            section_id: section.id,
            title: "Contributor Note",
            content: "Note by contributor 2",
            content_review_status: :approved,
            technical_review_status: :approved
          },
          actor: user2,
          tenant: site.id,
          authorize?: false
        )
        |> Ash.create!()

        %{section: section}
      end

      test "tenant admin CAN access contributors_count field", %{
        site: site,
        tenant_admin: tenant_admin,
        section: section
      } do
        token = sign_in_tenant(tenant_admin)

        response =
          make_api_request(
            "#{@tenant_path}/#{section.id}?fields[section]=contributors_count,title,slug",
            %{},
            method: :get,
            headers: [
              {"authorization", "Bearer #{token}"},
              {"x-site-id", site.id}
            ]
          )

        assert response.status == 200
        body = Jason.decode!(response.resp_body)

        # Admin should see the contributors_count field
        assert Map.has_key?(body["data"]["attributes"], "contributors_count")
        # Should count 2 unique contributors
        assert body["data"]["attributes"]["contributors_count"] == 2
      end

      test "master admin CAN access contributors_count field", %{
        master_user: master_user,
        section: section
      } do
        token = sign_in_master(master_user)

        response =
          make_api_request(
            "#{@master_path}/#{section.id}?fields[section]=contributors_count,title,slug",
            %{},
            method: :get,
            headers: [
              {"authorization", "Bearer #{token}"},
              {"x-no-tenant", "true"}
            ]
          )

        assert response.status == 200
        body = Jason.decode!(response.resp_body)

        # Admin should see the contributors_count field
        assert Map.has_key?(body["data"]["attributes"], "contributors_count")
        # Should count 2 unique contributors
        assert body["data"]["attributes"]["contributors_count"] == 2
      end

      test "public/guest users CANNOT access contributors_count field", %{section: section} do
        # Explicitly request the forbidden contributors_count field
        response =
          make_api_request(
            "#{@public_path}/#{section.id}?fields[section]=contributors_count,title,slug",
            %{},
            method: :get
          )

        assert response.status == 200
        body = Jason.decode!(response.resp_body)

        # Public users get null value for forbidden field when explicitly requested
        assert body["data"]["attributes"]["contributors_count"] == nil

        # But should see other fields with actual values
        assert body["data"]["attributes"]["title"] == "Section with Contributors"
        assert body["data"]["attributes"]["slug"] == "section-contributors"
      end

      test "normal authenticated user (non-admin) CANNOT access contributors_count field", %{
        site: site,
        section: section
      } do
        # Create normal user without admin permissions
        normal_user =
          create_user!(
            email: "normaluser@example.com",
            password: @password,
            password_confirmation: @password,
            site_id: site.id
          )

        # Sign in as normal user
        sign_in_response =
          make_api_request(
            "#{@api_user_path}/sign-in",
            %{
              "type" => "user",
              "attributes" => %{
                "email" => to_string(normal_user.email),
                "password" => @password
              }
            }
          )

        assert sign_in_response.status == 201
        %{"meta" => %{"token" => token}} = Jason.decode!(sign_in_response.resp_body)

        # Explicitly request forbidden contributors_count field
        response =
          make_api_request(
            "#{@public_path}/#{section.id}?fields[section]=contributors_count,title,slug",
            %{},
            method: :get,
            headers: [{"authorization", "Bearer #{token}"}]
          )

        assert response.status == 200
        body = Jason.decode!(response.resp_body)

        # Normal authenticated user (non-admin) gets null value for forbidden field
        assert body["data"]["attributes"]["contributors_count"] == nil

        # But should see other fields with actual values
        assert body["data"]["attributes"]["title"] == "Section with Contributors"
        assert body["data"]["attributes"]["slug"] == "section-contributors"
      end
    end

    describe "TAG MANAGEMENT - tenant admin create and update sections with tags" do
      test "tenant admin can create section with tags", %{
        site: site,
        tenant_admin: tenant_admin
      } do
        token = sign_in_tenant(tenant_admin)

        # Create workspace and version
        workspace =
          create_workspace!(
            site_id: site.id,
            title: "Test Workspace",
            slug: "test-workspace",
            skip_version: true
          )

        ws_version =
          create_workspace_version!(
            workspace_id: workspace.id,
            site_id: site.id,
            version_number: "1.0.0",
            status: :draft
          )

        # Create tags
        tag1 =
          create_document_tag!(
            site_id: site.id,
            name: "Tag 1",
            slug: "tag-1",
            language: "en"
          )

        tag2 =
          create_document_tag!(
            site_id: site.id,
            name: "Tag 2",
            slug: "tag-2",
            language: "en"
          )

        params = %{
          "type" => "section",
          "attributes" => %{
            "workspace_version_id" => ws_version.id,
            "title" => "Section with Tags",
            "slug" => "section-with-tags",
            "content" => "Content",
            "language" => "en",
            "tag_ids" => [tag1.id, tag2.id]
          }
        }

        response =
          make_api_request(
            @tenant_path,
            params,
            headers: [
              {"authorization", "Bearer #{token}"},
              {"x-site-id", site.id}
            ]
          )

        assert response.status == 201
        body = Jason.decode!(response.resp_body)
        section_id = body["data"]["id"]

        # Verify tags were assigned
        section =
          MishkaDocument.Section
          |> Ash.get!(section_id, tenant: site.id, authorize?: false)
          |> Ash.load!(:tags, tenant: site.id, authorize?: false)

        tag_ids = Enum.map(section.tags, & &1.id) |> Enum.sort()
        assert tag_ids == Enum.sort([tag1.id, tag2.id])
      end

      test "tenant admin can update section tags", %{
        site: site,
        tenant_admin: tenant_admin
      } do
        token = sign_in_tenant(tenant_admin)

        # Create workspace and version
        workspace =
          create_workspace!(
            site_id: site.id,
            title: "Test Workspace",
            slug: "test-workspace",
            skip_version: true
          )

        ws_version =
          create_workspace_version!(
            workspace_id: workspace.id,
            site_id: site.id,
            version_number: "1.0.0",
            status: :draft
          )

        # Create tags
        tag1 =
          create_document_tag!(
            site_id: site.id,
            name: "Tag 1",
            slug: "tag-1",
            language: "en"
          )

        tag2 =
          create_document_tag!(
            site_id: site.id,
            name: "Tag 2",
            slug: "tag-2",
            language: "en"
          )

        tag3 =
          create_document_tag!(
            site_id: site.id,
            name: "Tag 3",
            slug: "tag-3",
            language: "en"
          )

        # Create section via API
        create_params = %{
          "type" => "section",
          "attributes" => %{
            "workspace_version_id" => ws_version.id,
            "title" => "Test Section",
            "slug" => "test-section",
            "content" => "Content",
            "language" => "en"
          }
        }

        create_response =
          make_api_request(
            @tenant_path,
            create_params,
            headers: [
              {"authorization", "Bearer #{token}"},
              {"x-site-id", site.id}
            ]
          )

        assert create_response.status == 201
        create_body = Jason.decode!(create_response.resp_body)
        section_id = create_body["data"]["id"]

        # Update section with tags
        params = %{
          "type" => "section",
          "attributes" => %{
            "tag_ids" => [tag1.id, tag2.id]
          }
        }

        response =
          make_api_request(
            "#{@tenant_path}/#{section_id}",
            params,
            method: :patch,
            headers: [
              {"authorization", "Bearer #{token}"},
              {"x-site-id", site.id}
            ]
          )

        assert response.status == 200

        # Verify tags were assigned
        updated_section =
          MishkaDocument.Section
          |> Ash.get!(section_id, tenant: site.id, authorize?: false)
          |> Ash.load!(:tags, tenant: site.id, authorize?: false)

        tag_ids = Enum.map(updated_section.tags, & &1.id) |> Enum.sort()
        assert tag_ids == Enum.sort([tag1.id, tag2.id])

        # Update again to replace tags
        params2 = %{
          "type" => "section",
          "attributes" => %{
            "tag_ids" => [tag2.id, tag3.id]
          }
        }

        response2 =
          make_api_request(
            "#{@tenant_path}/#{section_id}",
            params2,
            method: :patch,
            headers: [
              {"authorization", "Bearer #{token}"},
              {"x-site-id", site.id}
            ]
          )

        assert response2.status == 200

        # Verify tags were replaced
        final_section =
          MishkaDocument.Section
          |> Ash.get!(section_id, tenant: site.id, authorize?: false)
          |> Ash.load!(:tags, tenant: site.id, authorize?: false)

        final_tag_ids = Enum.map(final_section.tags, & &1.id) |> Enum.sort()
        assert final_tag_ids == Enum.sort([tag2.id, tag3.id])
      end

      test "tenant admin cannot assign non-existent tag", %{
        site: site,
        tenant_admin: tenant_admin
      } do
        token = sign_in_tenant(tenant_admin)

        # Create workspace and version
        workspace =
          create_workspace!(
            site_id: site.id,
            title: "Test Workspace",
            slug: "test-workspace",
            skip_version: true
          )

        ws_version =
          create_workspace_version!(
            workspace_id: workspace.id,
            site_id: site.id,
            version_number: "1.0.0",
            status: :draft
          )

        fake_tag_id = Ash.UUID.generate()

        params = %{
          "type" => "section",
          "attributes" => %{
            "workspace_version_id" => ws_version.id,
            "title" => "Section with Invalid Tag",
            "slug" => "section-invalid-tag",
            "content" => "Content",
            "language" => "en",
            "tag_ids" => [fake_tag_id]
          }
        }

        response =
          make_api_request(
            @tenant_path,
            params,
            headers: [
              {"authorization", "Bearer #{token}"},
              {"x-site-id", site.id}
            ]
          )

        # Should get an error (404 when tag not found)
        assert response.status in [400, 404, 422]
      end
    end

    describe "TAG MANAGEMENT - master admin create and update sections with tags" do
      test "master admin can create section with tags", %{
        site: site,
        master_user: master_user
      } do
        token = sign_in_master(master_user)

        # Create workspace and version
        workspace =
          create_workspace!(
            site_id: site.id,
            title: "Test Workspace",
            slug: "test-workspace",
            skip_version: true
          )

        ws_version =
          create_workspace_version!(
            workspace_id: workspace.id,
            site_id: site.id,
            version_number: "1.0.0",
            status: :draft
          )

        # Create tags
        tag1 =
          create_document_tag!(
            site_id: site.id,
            name: "Tag 1",
            slug: "tag-1",
            language: "en"
          )

        tag2 =
          create_document_tag!(
            site_id: site.id,
            name: "Tag 2",
            slug: "tag-2",
            language: "en"
          )

        params = %{
          "type" => "section",
          "attributes" => %{
            "workspace_version_id" => ws_version.id,
            "title" => "Master Section with Tags",
            "slug" => "master-section-tags",
            "content" => "Content",
            "language" => "en",
            "site_id" => site.id,
            "tag_ids" => [tag1.id, tag2.id]
          }
        }

        response =
          make_api_request(
            @master_path,
            params,
            headers: [
              {"authorization", "Bearer #{token}"},
              {"x-no-tenant", "true"}
            ]
          )

        assert response.status == 201
        body = Jason.decode!(response.resp_body)
        section_id = body["data"]["id"]

        # Verify tags were assigned
        section =
          MishkaDocument.Section
          |> Ash.get!(section_id, tenant: site.id, authorize?: false)
          |> Ash.load!(:tags, tenant: site.id, authorize?: false)

        tag_ids = Enum.map(section.tags, & &1.id) |> Enum.sort()
        assert tag_ids == Enum.sort([tag1.id, tag2.id])
      end

      test "master admin can update section tags via master_update", %{
        site: site,
        master_user: master_user
      } do
        token = sign_in_master(master_user)

        # Create workspace and version
        workspace =
          create_workspace!(
            site_id: site.id,
            title: "Test Workspace",
            slug: "test-workspace",
            skip_version: true
          )

        ws_version =
          create_workspace_version!(
            workspace_id: workspace.id,
            site_id: site.id,
            version_number: "1.0.0",
            status: :draft
          )

        # Create tags
        tag1 =
          create_document_tag!(
            site_id: site.id,
            name: "Tag 1",
            slug: "tag-1",
            language: "en"
          )

        tag2 =
          create_document_tag!(
            site_id: site.id,
            name: "Tag 2",
            slug: "tag-2",
            language: "en"
          )

        # Create section via API
        create_params = %{
          "type" => "section",
          "attributes" => %{
            "workspace_version_id" => ws_version.id,
            "site_id" => site.id,
            "title" => "Test Section",
            "slug" => "test-section",
            "content" => "Content",
            "language" => "en"
          }
        }

        create_response =
          make_api_request(
            @master_path,
            create_params,
            headers: [
              {"authorization", "Bearer #{token}"},
              {"x-no-tenant", "true"}
            ]
          )

        assert create_response.status == 201
        create_body = Jason.decode!(create_response.resp_body)
        section_id = create_body["data"]["id"]

        # Update section with tags via master_update
        params = %{
          "type" => "section",
          "attributes" => %{
            "tag_ids" => [tag1.id, tag2.id]
          }
        }

        response =
          make_api_request(
            "#{@master_path}/#{section_id}",
            params,
            method: :patch,
            headers: [
              {"authorization", "Bearer #{token}"},
              {"x-no-tenant", "true"}
            ]
          )

        assert response.status == 200

        # Verify tags were assigned
        updated_section =
          MishkaDocument.Section
          |> Ash.get!(section_id, tenant: site.id, authorize?: false)
          |> Ash.load!(:tags, tenant: site.id, authorize?: false)

        tag_ids = Enum.map(updated_section.tags, & &1.id) |> Enum.sort()
        assert tag_ids == Enum.sort([tag1.id, tag2.id])
      end
    end
  end
end
