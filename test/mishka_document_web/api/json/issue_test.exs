defmodule MishkaDocumentWeb.Api.Json.IssueTest do
  @moduledoc """
  Comprehensive tests for Issue JSON API endpoints.

  Tests all tenant admin and master admin issue endpoints including
  CRUD operations, status transitions, archive/unarchive, and
  relationship loading with pagination.
  """

  use MishkaDocument.ConnCase
  import MishkaDocument.Test.Factory

  @moduletag :unit
  @moduletag :capture_log

  if Code.ensure_loaded?(MishkaDocument) do
    @password "Password123!"
    @api_user_path "/api/json/v1/auth/user"
    @tenant_path "/api/json/v1/tenant/admin/mishka-document/issue"
    @master_path "/api/json/v1/master/admin/mishka-document/issue"

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

    describe "TENANT ADMIN - GET /v1/tenant/admin/mishka-document/issue (index :read)" do
      test "returns all issues for tenant", %{site: site, tenant_admin: tenant_admin} do
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
            slug: "test-section"
          )

        _issue1 =
          create_issue!(
            site_id: site.id,
            section_id: section.id,
            reporter_id: tenant_admin.id,
            title: "Issue 1",
            description: "First issue",
            issue_type: :typo
          )

        _issue2 =
          create_issue!(
            site_id: site.id,
            section_id: section.id,
            reporter_id: tenant_admin.id,
            title: "Issue 2",
            description: "Second issue",
            issue_type: :broken_link
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

      test "supports pagination", %{site: site, tenant_admin: tenant_admin} do
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
            slug: "test-section"
          )

        # Create 5 issues
        1..5
        |> Enum.each(fn i ->
          create_issue!(
            site_id: site.id,
            section_id: section.id,
            reporter_id: tenant_admin.id,
            title: "Issue #{i}",
            description: "Issue description #{i}",
            issue_type: :typo
          )
        end)

        response =
          make_api_request(
            "#{@tenant_path}?page[limit]=2",
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

    describe "TENANT ADMIN - GET /v1/tenant/admin/mishka-document/issue/:id (get :read)" do
      test "returns issue by id", %{site: site, tenant_admin: tenant_admin} do
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
            slug: "test-section"
          )

        issue =
          create_issue!(
            site_id: site.id,
            section_id: section.id,
            reporter_id: tenant_admin.id,
            title: "Test Issue",
            description: "This is a test issue",
            issue_type: :typo
          )

        response =
          make_api_request(
            "#{@tenant_path}/#{issue.id}",
            %{},
            method: :get,
            headers: [
              {"authorization", "Bearer #{token}"}
            ]
          )

        assert response.status == 200
        body = Jason.decode!(response.resp_body)
        assert body["data"]["id"] == issue.id
        assert body["data"]["attributes"]["title"] == "Test Issue"
        assert body["data"]["attributes"]["status"] == "open"
      end

      test "loads comments relationship with pagination", %{
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

        section =
          create_section!(
            workspace_version_id: ws_version.id,
            site_id: site.id,
            title: "Test Section",
            slug: "test-section"
          )

        issue =
          create_issue!(
            site_id: site.id,
            section_id: section.id,
            reporter_id: tenant_admin.id,
            title: "Test Issue",
            description: "Issue with comments",
            issue_type: :typo
          )

        # Create 10 comments
        1..10
        |> Enum.each(fn i ->
          create_issue_comment!(
            issue_id: issue.id,
            contributor_id: tenant_admin.id,
            site_id: site.id,
            content: "Comment #{i}"
          )
        end)

        response =
          make_api_request(
            "#{@tenant_path}/#{issue.id}?include=comments&included_page[comments][limit]=5",
            %{},
            method: :get,
            headers: [
              {"authorization", "Bearer #{token}"}
            ]
          )

        assert response.status == 200
        body = Jason.decode!(response.resp_body)
        assert body["data"]["id"] == issue.id

        # Verify paginated comments are included
        assert is_list(body["included"])
        comments = Enum.filter(body["included"], &(&1["type"] == "issue_comment"))
        assert length(comments) == 5
      end
    end

    describe "TENANT ADMIN - POST /v1/tenant/admin/mishka-document/issue (create)" do
      test "creates new issue for section", %{site: site, tenant_admin: tenant_admin} do
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
            slug: "test-section"
          )

        params = %{
          "type" => "issue",
          "attributes" => %{
            "section_id" => section.id,
            "title" => "New Issue",
            "description" => "This is a new issue",
            "issue_type" => "typo"
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
        assert body["data"]["attributes"]["title"] == "New Issue"
        assert body["data"]["attributes"]["status"] == "open"
      end

      test "creates new issue for note", %{site: site, tenant_admin: tenant_admin} do
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
            slug: "test-section"
          )

        note =
          create_note!(
            workspace_version_id: ws_version.id,
            section_id: section.id,
            site_id: site.id,
            title: "Test Note",
            content: "Note content"
          )

        params = %{
          "type" => "issue",
          "attributes" => %{
            "note_id" => note.id,
            "title" => "Issue on Note",
            "description" => "This is an issue on a note",
            "issue_type" => "suggestion"
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
        assert body["data"]["attributes"]["title"] == "Issue on Note"
      end

      test "fails when neither section_id nor note_id is provided", %{
        tenant_admin: tenant_admin
      } do
        token = sign_in_tenant(tenant_admin)

        params = %{
          "type" => "issue",
          "attributes" => %{
            "title" => "Invalid Issue",
            "description" => "This issue has no reference",
            "issue_type" => "other"
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

        assert response.status in [400, 422]
      end

      test "tenant CANNOT create issue for section from different site (tenant isolation)", %{
        tenant_admin: tenant_admin
      } do
        token = sign_in_tenant(tenant_admin)

        # Create a second site
        site2 = create_site!(name: "site2", host: "site2.com", active: true, priority: 50)

        MishkaCmsCore.Runtime.States.SiteState.save(%{
          id: site2.id,
          name: site2.name,
          host: site2.host,
          priority: site2.priority,
          active: site2.active
        })

        # Create workspace and section for site2 (different tenant)
        workspace2 = create_workspace!(site_id: site2.id, skip_version: true, status: :active)

        ws_version2 =
          create_workspace_version!(
            workspace_id: workspace2.id,
            site_id: site2.id,
            version_number: "1.0.0",
            status: :stable,
            published_at: DateTime.utc_now()
          )

        section2 =
          create_section!(
            workspace_version_id: ws_version2.id,
            site_id: site2.id,
            title: "Site2 Section",
            slug: "site2-section"
          )

        # Tenant admin from site1 tries to create issue for site2's section
        params = %{
          "type" => "issue",
          "attributes" => %{
            "section_id" => section2.id,
            "title" => "Cross-site Issue",
            "description" => "Trying to create issue for different site",
            "issue_type" => "typo"
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

        # Should fail - tenant cannot create issues for other sites' content
        assert response.status in [400, 403, 404, 422]
      end

      test "tenant CANNOT create issue for note from different site (tenant isolation)", %{
        tenant_admin: tenant_admin
      } do
        token = sign_in_tenant(tenant_admin)

        # Create a second site
        site2 = create_site!(name: "site2", host: "site2.com", active: true, priority: 50)

        MishkaCmsCore.Runtime.States.SiteState.save(%{
          id: site2.id,
          name: site2.name,
          host: site2.host,
          priority: site2.priority,
          active: site2.active
        })

        # Create workspace, section and note for site2 (different tenant)
        workspace2 = create_workspace!(site_id: site2.id, skip_version: true, status: :active)

        ws_version2 =
          create_workspace_version!(
            workspace_id: workspace2.id,
            site_id: site2.id,
            version_number: "1.0.0",
            status: :stable,
            published_at: DateTime.utc_now()
          )

        section2 =
          create_section!(
            workspace_version_id: ws_version2.id,
            site_id: site2.id,
            title: "Site2 Section",
            slug: "site2-section"
          )

        note2 =
          create_note!(
            workspace_version_id: ws_version2.id,
            section_id: section2.id,
            site_id: site2.id,
            title: "Site2 Note",
            content: "Note on site2"
          )

        # Tenant admin from site1 tries to create issue for site2's note
        params = %{
          "type" => "issue",
          "attributes" => %{
            "note_id" => note2.id,
            "title" => "Cross-site Issue on Note",
            "description" => "Trying to create issue for different site's note",
            "issue_type" => "suggestion"
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

        # Should fail - tenant cannot create issues for other sites' content
        assert response.status in [400, 403, 404, 422]
      end
    end

    describe "TENANT ADMIN - PATCH /v1/tenant/admin/mishka-document/issue/:id (update)" do
      test "updates issue", %{site: site, tenant_admin: tenant_admin} do
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
            slug: "test-section"
          )

        issue =
          create_issue!(
            site_id: site.id,
            section_id: section.id,
            reporter_id: tenant_admin.id,
            title: "Original Title",
            description: "Original description",
            issue_type: :typo
          )

        params = %{
          "type" => "issue",
          "attributes" => %{
            "title" => "Updated Title",
            "description" => "Updated description"
          }
        }

        response =
          make_api_request(
            "#{@tenant_path}/#{issue.id}",
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
        assert body["data"]["attributes"]["description"] == "Updated description"
      end

      test "tenant CANNOT update issue to reference section from different site", %{
        site: site,
        tenant_admin: tenant_admin
      } do
        token = sign_in_tenant(tenant_admin)

        # Create workspace and section for site1
        workspace1 = create_workspace!(site_id: site.id, skip_version: true, status: :active)

        ws_version1 =
          create_workspace_version!(
            workspace_id: workspace1.id,
            site_id: site.id,
            version_number: "1.0.0",
            status: :stable,
            published_at: DateTime.utc_now()
          )

        section1 =
          create_section!(
            workspace_version_id: ws_version1.id,
            site_id: site.id,
            title: "Site1 Section",
            slug: "site1-section"
          )

        # Create issue on site1
        issue =
          create_issue!(
            site_id: site.id,
            section_id: section1.id,
            reporter_id: tenant_admin.id,
            title: "Original Issue",
            description: "Original description",
            issue_type: :typo
          )

        # Create a second site with a section
        site2 = create_site!(name: "site2", host: "site2.com", active: true, priority: 50)

        MishkaCmsCore.Runtime.States.SiteState.save(%{
          id: site2.id,
          name: site2.name,
          host: site2.host,
          priority: site2.priority,
          active: site2.active
        })

        workspace2 = create_workspace!(site_id: site2.id, skip_version: true, status: :active)

        ws_version2 =
          create_workspace_version!(
            workspace_id: workspace2.id,
            site_id: site2.id,
            version_number: "1.0.0",
            status: :stable,
            published_at: DateTime.utc_now()
          )

        section2 =
          create_section!(
            workspace_version_id: ws_version2.id,
            site_id: site2.id,
            title: "Site2 Section",
            slug: "site2-section"
          )

        # Try to update issue to reference site2's section
        params = %{
          "type" => "issue",
          "attributes" => %{
            "section_id" => section2.id
          }
        }

        response =
          make_api_request(
            "#{@tenant_path}/#{issue.id}",
            params,
            method: :patch,
            headers: [
              {"authorization", "Bearer #{token}"},
              {"content-type", "application/vnd.api+json"}
            ]
          )

        # Should fail - tenant cannot update to reference different site's content
        assert response.status in [400, 403, 422]
      end

      test "tenant CANNOT update issue to reference note from different site", %{
        site: site,
        tenant_admin: tenant_admin
      } do
        token = sign_in_tenant(tenant_admin)

        # Create workspace and section for site1
        workspace1 = create_workspace!(site_id: site.id, skip_version: true, status: :active)

        ws_version1 =
          create_workspace_version!(
            workspace_id: workspace1.id,
            site_id: site.id,
            version_number: "1.0.0",
            status: :stable,
            published_at: DateTime.utc_now()
          )

        section1 =
          create_section!(
            workspace_version_id: ws_version1.id,
            site_id: site.id,
            title: "Site1 Section",
            slug: "site1-section"
          )

        # Create issue on site1
        issue =
          create_issue!(
            site_id: site.id,
            section_id: section1.id,
            reporter_id: tenant_admin.id,
            title: "Original Issue",
            description: "Original description",
            issue_type: :typo
          )

        # Create a second site with a note
        site2 = create_site!(name: "site2", host: "site2.com", active: true, priority: 50)

        MishkaCmsCore.Runtime.States.SiteState.save(%{
          id: site2.id,
          name: site2.name,
          host: site2.host,
          priority: site2.priority,
          active: site2.active
        })

        workspace2 = create_workspace!(site_id: site2.id, skip_version: true, status: :active)

        ws_version2 =
          create_workspace_version!(
            workspace_id: workspace2.id,
            site_id: site2.id,
            version_number: "1.0.0",
            status: :stable,
            published_at: DateTime.utc_now()
          )

        section2 =
          create_section!(
            workspace_version_id: ws_version2.id,
            site_id: site2.id,
            title: "Site2 Section",
            slug: "site2-section"
          )

        note2 =
          create_note!(
            workspace_version_id: ws_version2.id,
            section_id: section2.id,
            site_id: site2.id,
            title: "Site2 Note",
            content: "Note on site2"
          )

        # Try to update issue to reference site2's note
        params = %{
          "type" => "issue",
          "attributes" => %{
            "note_id" => note2.id
          }
        }

        response =
          make_api_request(
            "#{@tenant_path}/#{issue.id}",
            params,
            method: :patch,
            headers: [
              {"authorization", "Bearer #{token}"},
              {"content-type", "application/vnd.api+json"}
            ]
          )

        # Should fail - tenant cannot update to reference different site's content
        assert response.status in [400, 403, 422]
      end
    end

    describe "TENANT ADMIN - PATCH /v1/tenant/admin/mishka-document/issue/:id/mark-in-progress (mark_in_progress)" do
      test "marks issue as in_progress", %{site: site, tenant_admin: tenant_admin} do
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
            slug: "test-section"
          )

        issue =
          create_issue!(
            site_id: site.id,
            section_id: section.id,
            reporter_id: tenant_admin.id,
            title: "Issue to Progress",
            description: "Working on this",
            issue_type: :typo
          )

        response =
          make_api_request(
            "#{@tenant_path}/#{issue.id}/mark-in-progress",
            %{},
            method: :patch,
            headers: [
              {"authorization", "Bearer #{token}"}
            ]
          )

        assert response.status == 200
        body = Jason.decode!(response.resp_body)
        assert body["data"]["attributes"]["status"] == "in_progress"
      end
    end

    describe "TENANT ADMIN - PATCH /v1/tenant/admin/mishka-document/issue/:id/mark-resolved (mark_resolved)" do
      test "marks issue as resolved", %{site: site, tenant_admin: tenant_admin} do
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
            slug: "test-section"
          )

        issue =
          create_issue!(
            site_id: site.id,
            section_id: section.id,
            reporter_id: tenant_admin.id,
            title: "Issue to Resolve",
            description: "This will be resolved",
            issue_type: :typo
          )

        response =
          make_api_request(
            "#{@tenant_path}/#{issue.id}/mark-resolved",
            %{},
            method: :patch,
            headers: [
              {"authorization", "Bearer #{token}"}
            ]
          )

        assert response.status == 200
        body = Jason.decode!(response.resp_body)
        assert body["data"]["attributes"]["status"] == "resolved"
      end
    end

    describe "TENANT ADMIN - PATCH /v1/tenant/admin/mishka-document/issue/:id/mark-closed (mark_closed)" do
      test "marks issue as closed", %{site: site, tenant_admin: tenant_admin} do
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
            slug: "test-section"
          )

        issue =
          create_issue!(
            site_id: site.id,
            section_id: section.id,
            reporter_id: tenant_admin.id,
            title: "Issue to Close",
            description: "This will be closed",
            issue_type: :typo
          )

        response =
          make_api_request(
            "#{@tenant_path}/#{issue.id}/mark-closed",
            %{},
            method: :patch,
            headers: [
              {"authorization", "Bearer #{token}"}
            ]
          )

        assert response.status == 200
        body = Jason.decode!(response.resp_body)
        assert body["data"]["attributes"]["status"] == "closed"
      end
    end

    describe "TENANT ADMIN - PATCH /v1/tenant/admin/mishka-document/issue/:id/reopen (reopen)" do
      test "reopens a closed issue", %{site: site, tenant_admin: tenant_admin} do
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
            slug: "test-section"
          )

        issue =
          create_issue!(
            site_id: site.id,
            section_id: section.id,
            reporter_id: tenant_admin.id,
            title: "Issue to Reopen",
            description: "This will be reopened",
            issue_type: :typo,
            status: :closed
          )

        response =
          make_api_request(
            "#{@tenant_path}/#{issue.id}/reopen",
            %{},
            method: :patch,
            headers: [
              {"authorization", "Bearer #{token}"}
            ]
          )

        assert response.status == 200
        body = Jason.decode!(response.resp_body)
        assert body["data"]["attributes"]["status"] == "open"
      end
    end

    describe "TENANT ADMIN - DELETE /v1/tenant/admin/mishka-document/issue/:id/archive (destroy)" do
      test "archives issue (soft delete)", %{site: site, tenant_admin: tenant_admin} do
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
            slug: "test-section"
          )

        issue =
          create_issue!(
            site_id: site.id,
            section_id: section.id,
            reporter_id: tenant_admin.id,
            title: "Issue to Archive",
            description: "This will be archived",
            issue_type: :typo
          )

        response =
          make_api_request(
            "#{@tenant_path}/#{issue.id}/archive",
            %{},
            method: :delete,
            headers: [
              {"authorization", "Bearer #{token}"}
            ]
          )

        assert response.status == 200
      end
    end

    describe "TENANT ADMIN - GET /v1/tenant/admin/mishka-document/issue/archived (index :archived)" do
      test "lists archived issues", %{site: site, tenant_admin: tenant_admin} do
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
            slug: "test-section"
          )

        # Create and archive an issue
        issue =
          create_issue!(
            site_id: site.id,
            section_id: section.id,
            reporter_id: tenant_admin.id,
            title: "Archived Issue",
            description: "This is archived",
            issue_type: :typo
          )

        issue
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
        assert hd(body["data"])["id"] == issue.id
      end
    end

    describe "TENANT ADMIN - GET /v1/tenant/admin/mishka-document/issue/archived/:id (get :get_archived)" do
      test "gets archived issue by id", %{site: site, tenant_admin: tenant_admin} do
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
            slug: "test-section"
          )

        # Create and archive an issue
        issue =
          create_issue!(
            site_id: site.id,
            section_id: section.id,
            reporter_id: tenant_admin.id,
            title: "Archived Issue",
            description: "This is archived",
            issue_type: :typo
          )

        issue
        |> Ash.Changeset.for_destroy(:destroy, %{}, tenant: site.id, authorize?: false)
        |> Ash.destroy!()

        response =
          make_api_request(
            "#{@tenant_path}/archived/#{issue.id}",
            %{},
            method: :get,
            headers: [
              {"authorization", "Bearer #{token}"}
            ]
          )

        assert response.status == 200
        body = Jason.decode!(response.resp_body)
        assert body["data"]["id"] == issue.id
        assert body["data"]["attributes"]["title"] == "Archived Issue"
      end
    end

    describe "TENANT ADMIN - PATCH /v1/tenant/admin/mishka-document/issue/:id/unarchive (unarchive)" do
      test "unarchives issue", %{site: site, tenant_admin: tenant_admin} do
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
            slug: "test-section"
          )

        # Create and archive an issue
        issue =
          create_issue!(
            site_id: site.id,
            section_id: section.id,
            reporter_id: tenant_admin.id,
            title: "Issue to Unarchive",
            description: "This will be unarchived",
            issue_type: :typo
          )

        issue
        |> Ash.Changeset.for_destroy(:destroy, %{}, tenant: site.id, authorize?: false)
        |> Ash.destroy!()

        response =
          make_api_request(
            "#{@tenant_path}/#{issue.id}/unarchive",
            %{},
            method: :patch,
            headers: [
              {"authorization", "Bearer #{token}"}
            ]
          )

        assert response.status == 200
        body = Jason.decode!(response.resp_body)
        assert body["data"]["attributes"]["archived_at"] == nil
      end
    end

    describe "TENANT ADMIN - DELETE /v1/tenant/admin/mishka-document/issue/:id/permanent (permanent_destroy)" do
      test "permanently deletes issue from database", %{site: site, tenant_admin: tenant_admin} do
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
            slug: "test-section"
          )

        issue =
          create_issue!(
            site_id: site.id,
            section_id: section.id,
            reporter_id: tenant_admin.id,
            title: "Issue to Delete Permanently",
            description: "This will be deleted",
            issue_type: :typo
          )

        response =
          make_api_request(
            "#{@tenant_path}/#{issue.id}/permanent",
            %{},
            method: :delete,
            headers: [
              {"authorization", "Bearer #{token}"}
            ]
          )

        assert response.status == 200
      end
    end

    describe "MASTER ADMIN - GET /v1/master/admin/mishka-document/issue (index :master_read)" do
      test "returns issues from all sites", %{site: site, master_user: master_user} do
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

        # Create user for site2
        user2 =
          create_user!(
            email: "user2@example.com",
            password: @password,
            password_confirmation: @password,
            site_id: site2.id
          )

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

        section1 =
          create_section!(
            workspace_version_id: ws_v1.id,
            site_id: site.id,
            title: "Site 1 Section",
            slug: "site1-section"
          )

        _issue1 =
          create_issue!(
            site_id: site.id,
            section_id: section1.id,
            reporter_id: master_user.id,
            title: "Issue on Site 1",
            description: "First site issue",
            issue_type: :typo
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

        section2 =
          create_section!(
            workspace_version_id: ws_v2.id,
            site_id: site2.id,
            title: "Site 2 Section",
            slug: "site2-section"
          )

        _issue2 =
          create_issue!(
            site_id: site2.id,
            section_id: section2.id,
            reporter_id: user2.id,
            title: "Issue on Site 2",
            description: "Second site issue",
            issue_type: :broken_link
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
        # Should see issues from both sites
        assert length(body["data"]) == 2
      end
    end

    describe "MASTER ADMIN - GET /v1/master/admin/mishka-document/issue/:id (get :master_get)" do
      test "gets issue by id from any site", %{site: site, master_user: master_user} do
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
            slug: "test-section"
          )

        issue =
          create_issue!(
            site_id: site.id,
            section_id: section.id,
            reporter_id: master_user.id,
            title: "Test Issue",
            description: "Test description",
            issue_type: :typo
          )

        response =
          make_api_request(
            "#{@master_path}/#{issue.id}",
            %{},
            method: :get,
            headers: [
              {"authorization", "Bearer #{token}"},
              {"x-no-tenant", "true"}
            ]
          )

        assert response.status == 200
        body = Jason.decode!(response.resp_body)
        assert body["data"]["id"] == issue.id
        assert body["data"]["attributes"]["title"] == "Test Issue"
      end

      test "loads master_comments relationship with pagination", %{
        site: site,
        master_user: master_user
      } do
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
            slug: "test-section"
          )

        issue =
          create_issue!(
            site_id: site.id,
            section_id: section.id,
            reporter_id: master_user.id,
            title: "Test Issue",
            description: "Issue with comments",
            issue_type: :typo
          )

        # Create 10 comments
        1..10
        |> Enum.each(fn i ->
          MishkaDocument.IssueComment
          |> Ash.Changeset.for_create(
            :master_create,
            %{
              issue_id: issue.id,
              contributor_id: master_user.id,
              content: "Master Comment #{i}",
              site_id: site.id
            },
            authorize?: false
          )
          |> Ash.create!(authorize?: false)
        end)

        response =
          make_api_request(
            "#{@master_path}/#{issue.id}?include=master_comments&included_page[master_comments][limit]=5",
            %{},
            method: :get,
            headers: [
              {"authorization", "Bearer #{token}"},
              {"x-no-tenant", "true"}
            ]
          )

        assert response.status == 200
        body = Jason.decode!(response.resp_body)
        assert body["data"]["id"] == issue.id

        # Verify paginated master_comments are included
        assert is_list(body["included"])
        comments = Enum.filter(body["included"], &(&1["type"] == "issue_comment"))
        assert length(comments) == 5
      end
    end

    describe "MASTER ADMIN - POST /v1/master/admin/mishka-document/issue (master_create)" do
      test "creates issue for specified site", %{site: site, master_user: master_user} do
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
            slug: "test-section"
          )

        params = %{
          "type" => "issue",
          "attributes" => %{
            "site_id" => site.id,
            "section_id" => section.id,
            "reporter_id" => master_user.id,
            "title" => "Master Created Issue",
            "description" => "Issue created by master",
            "issue_type" => "typo"
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
        assert body["data"]["attributes"]["title"] == "Master Created Issue"
      end

      test "master CAN create issue for ANY site (cross-site access)", %{
        site: _site1,
        master_user: master_user
      } do
        token = sign_in_master(master_user)

        # Create a second site - master should be able to create issues for it
        site2 = create_site!(name: "site2", host: "site2.com", active: true, priority: 50)

        MishkaCmsCore.Runtime.States.SiteState.save(%{
          id: site2.id,
          name: site2.name,
          host: site2.host,
          priority: site2.priority,
          active: site2.active
        })

        # Create workspace and section for site2
        workspace2 = create_workspace!(site_id: site2.id, skip_version: true, status: :active)

        ws_version2 =
          create_workspace_version!(
            workspace_id: workspace2.id,
            site_id: site2.id,
            version_number: "1.0.0",
            status: :stable,
            published_at: DateTime.utc_now()
          )

        section2 =
          create_section!(
            workspace_version_id: ws_version2.id,
            site_id: site2.id,
            title: "Site2 Section",
            slug: "site2-section"
          )

        # Master creates issue for site2's content
        params = %{
          "type" => "issue",
          "attributes" => %{
            "site_id" => site2.id,
            "section_id" => section2.id,
            "reporter_id" => master_user.id,
            "title" => "Master Cross-Site Issue",
            "description" => "Master can create issues for any site",
            "issue_type" => "typo"
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

        # Should succeed - master can create for any site
        assert response.status == 201
        body = Jason.decode!(response.resp_body)
        assert body["data"]["attributes"]["title"] == "Master Cross-Site Issue"
      end
    end

    describe "MASTER ADMIN - PATCH /v1/master/admin/mishka-document/issue/:id (master_update)" do
      test "updates issue on any site", %{site: site, master_user: master_user} do
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
            slug: "test-section"
          )

        issue =
          create_issue!(
            site_id: site.id,
            section_id: section.id,
            reporter_id: master_user.id,
            title: "Original Title",
            description: "Original description",
            issue_type: :typo
          )

        params = %{
          "type" => "issue",
          "attributes" => %{
            "title" => "Master Updated Title"
          }
        }

        response =
          make_api_request(
            "#{@master_path}/#{issue.id}",
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

    describe "MASTER ADMIN - DELETE /v1/master/admin/mishka-document/issue/:id/archive (master_destroy)" do
      test "archives issue from any site", %{site: site, master_user: master_user} do
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
            slug: "test-section"
          )

        issue =
          create_issue!(
            site_id: site.id,
            section_id: section.id,
            reporter_id: master_user.id,
            title: "Issue to Archive",
            description: "This will be archived",
            issue_type: :typo
          )

        response =
          make_api_request(
            "#{@master_path}/#{issue.id}/archive",
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

    describe "MASTER ADMIN - GET /v1/master/admin/mishka-document/issue/archived (index :master_archived)" do
      test "lists archived issues from all sites", %{site: site, master_user: master_user} do
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
            slug: "test-section"
          )

        # Create and archive an issue
        issue =
          create_issue!(
            site_id: site.id,
            section_id: section.id,
            reporter_id: master_user.id,
            title: "Archived Issue",
            description: "This is archived",
            issue_type: :typo
          )

        issue
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
        assert hd(body["data"])["id"] == issue.id
      end
    end

    describe "MASTER ADMIN - GET /v1/master/admin/mishka-document/issue/archived/:id (get :master_get_archived)" do
      test "gets archived issue by id from any site", %{site: site, master_user: master_user} do
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
            slug: "test-section"
          )

        # Create and archive an issue
        issue =
          create_issue!(
            site_id: site.id,
            section_id: section.id,
            reporter_id: master_user.id,
            title: "Archived Issue",
            description: "This is archived",
            issue_type: :typo
          )

        issue
        |> Ash.Changeset.for_destroy(:destroy, %{}, tenant: site.id, authorize?: false)
        |> Ash.destroy!()

        response =
          make_api_request(
            "#{@master_path}/archived/#{issue.id}",
            %{},
            method: :get,
            headers: [
              {"authorization", "Bearer #{token}"},
              {"x-no-tenant", "true"}
            ]
          )

        assert response.status == 200
        body = Jason.decode!(response.resp_body)
        assert body["data"]["id"] == issue.id
        assert body["data"]["attributes"]["title"] == "Archived Issue"
      end
    end

    describe "MASTER ADMIN - PATCH /v1/master/admin/mishka-document/issue/:id/unarchive (master_unarchive)" do
      test "unarchives issue from any site", %{site: site, master_user: master_user} do
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
            slug: "test-section"
          )

        # Create and archive an issue
        issue =
          create_issue!(
            site_id: site.id,
            section_id: section.id,
            reporter_id: master_user.id,
            title: "Issue to Unarchive",
            description: "This will be unarchived",
            issue_type: :typo
          )

        issue
        |> Ash.Changeset.for_destroy(:destroy, %{}, tenant: site.id, authorize?: false)
        |> Ash.destroy!()

        response =
          make_api_request(
            "#{@master_path}/#{issue.id}/unarchive",
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
      end
    end

    describe "MASTER ADMIN - DELETE /v1/master/admin/mishka-document/issue/:id/permanent (master_permanent_destroy)" do
      test "permanently deletes issue from database", %{site: site, master_user: master_user} do
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
            slug: "test-section"
          )

        issue =
          create_issue!(
            site_id: site.id,
            section_id: section.id,
            reporter_id: master_user.id,
            title: "Issue to Delete Permanently",
            description: "This will be deleted",
            issue_type: :typo
          )

        response =
          make_api_request(
            "#{@master_path}/#{issue.id}/permanent",
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
  end
end
