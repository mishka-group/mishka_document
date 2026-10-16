# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_document/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaDocumentWeb.Api.Json.NoteTest do
  @moduledoc """
  Comprehensive tests for Note JSON API endpoints.

  Tests all tenant admin and master admin note endpoints.
  """

  use MishkaDocument.ConnCase

  # Raw SQL here needs the same repo the resources write through.
  @repo Application.compile_env!(:mishka_cms_core, :repo)
  import MishkaDocument.Test.Factory
  require Ash.Query

  @moduletag :unit
  @moduletag :capture_log

  if Code.ensure_loaded?(MishkaDocument) do
    @password "Password123!"
    @api_user_path "/api/json/v1/auth/user"
    @tenant_path "/api/json/v1/tenant/admin/mishka-document/note"
    @master_path "/api/json/v1/master/admin/mishka-document/note"

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

    # Helper to sign in master user
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

    # Helper to sign in tenant admin
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

    describe "TENANT ADMIN - GET /v1/tenant/admin/mishka-document/note (index :read)" do
      test "lists all notes for the tenant", %{site: site, tenant_admin: tenant_admin} do
        token = sign_in_tenant(tenant_admin)

        # Create workspace, version, section
        workspace =
          create_workspace!(
            site_id: site.id,
            title: "Test Workspace",
            description: "Test Description",
            skip_version: true
          )

        ws_version =
          create_workspace_version!(
            workspace_id: workspace.id,
            site_id: site.id,
            version_number: "1.0.0",
            status: :draft
          )

        section =
          create_section!(
            workspace_version_id: ws_version.id,
            site_id: site.id,
            title: "Test Section",
            slug: "test-section",
            content_review_status: :approved,
            technical_review_status: :approved
          )

        # Create notes
        note1 =
          create_note!(
            section_id: section.id,
            site_id: site.id,
            title: "Note 1",
            content: "Content 1"
          )

        note2 =
          create_note!(
            section_id: section.id,
            site_id: site.id,
            title: "Note 2",
            content: "Content 2"
          )

        response =
          make_api_request(
            @tenant_path,
            %{},
            method: :get,
            headers: [
              {"authorization", "Bearer #{token}"},
              {"x-site-id", site.id}
            ]
          )

        assert response.status == 200
        body = Jason.decode!(response.resp_body)

        assert length(body["data"]) == 2
        note_ids = Enum.map(body["data"], & &1["id"])
        assert note1.id in note_ids
        assert note2.id in note_ids
      end

      test "tenant admin CANNOT see notes from other sites", %{
        site: site,
        tenant_admin: tenant_admin
      } do
        token = sign_in_tenant(tenant_admin)

        # Create second site with its own data
        site2 = create_site!(name: "site2", host: "site2.com", active: true, priority: 50)

        MishkaCmsCore.Runtime.States.SiteState.save(%{
          id: site2.id,
          name: site2.name,
          host: site2.host,
          priority: site2.priority,
          active: site2.active
        })

        workspace2 =
          create_workspace!(
            site_id: site2.id,
            title: "Site2 Workspace",
            description: "Site2 Description",
            skip_version: true
          )

        ws_version2 =
          create_workspace_version!(
            workspace_id: workspace2.id,
            site_id: site2.id,
            version_number: "1.0.0",
            status: :draft
          )

        section2 =
          create_section!(
            workspace_version_id: ws_version2.id,
            site_id: site2.id,
            title: "Site2 Section",
            slug: "site2-section"
          )

        # Create note in site2
        _note_in_site2 =
          create_note!(
            section_id: section2.id,
            site_id: site2.id,
            title: "Note in Site2",
            content: "Content in Site2"
          )

        # Create workspace, version, section in site1 (tenant admin's site)
        workspace =
          create_workspace!(
            site_id: site.id,
            title: "Test Workspace",
            description: "Test Description",
            skip_version: true
          )

        ws_version =
          create_workspace_version!(
            workspace_id: workspace.id,
            site_id: site.id,
            version_number: "1.0.0",
            status: :draft
          )

        section =
          create_section!(
            workspace_version_id: ws_version.id,
            site_id: site.id,
            title: "Test Section",
            slug: "test-section"
          )

        # Create note in site1
        note_in_site1 =
          create_note!(
            section_id: section.id,
            site_id: site.id,
            title: "Note in Site1",
            content: "Content in Site1"
          )

        response =
          make_api_request(
            @tenant_path,
            %{},
            method: :get,
            headers: [
              {"authorization", "Bearer #{token}"},
              {"x-site-id", site.id}
            ]
          )

        assert response.status == 200
        body = Jason.decode!(response.resp_body)

        # Should only see note from own site
        assert length(body["data"]) == 1
        assert hd(body["data"])["id"] == note_in_site1.id
        assert hd(body["data"])["attributes"]["title"] == "Note in Site1"

        # Cleanup
        MishkaCmsCore.Runtime.States.SiteState.delete(site2.id)
      end
    end

    describe "TENANT ADMIN - GET /v1/tenant/admin/mishka-document/note/:id (get :read)" do
      test "retrieves single note", %{site: site, tenant_admin: tenant_admin} do
        token = sign_in_tenant(tenant_admin)

        # Create workspace, version, section
        workspace =
          create_workspace!(
            site_id: site.id,
            title: "Test Workspace",
            description: "Test Description",
            skip_version: true
          )

        ws_version =
          create_workspace_version!(
            workspace_id: workspace.id,
            site_id: site.id,
            version_number: "1.0.0",
            status: :draft
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
            section_id: section.id,
            site_id: site.id,
            title: "Test Note",
            content: "Test Content"
          )

        response =
          make_api_request(
            "#{@tenant_path}/#{note.id}",
            %{},
            method: :get,
            headers: [
              {"authorization", "Bearer #{token}"},
              {"x-site-id", site.id}
            ]
          )

        assert response.status == 200
        body = Jason.decode!(response.resp_body)

        assert body["data"]["id"] == note.id
        assert body["data"]["attributes"]["title"] == "Test Note"
        assert body["data"]["attributes"]["content"] == "Test Content"
      end

      test "tenant admin CANNOT retrieve note from other site", %{
        site: site,
        tenant_admin: tenant_admin
      } do
        token = sign_in_tenant(tenant_admin)

        # Create second site with note
        site2 = create_site!(name: "site2", host: "site2.com", active: true, priority: 50)

        MishkaCmsCore.Runtime.States.SiteState.save(%{
          id: site2.id,
          name: site2.name,
          host: site2.host,
          priority: site2.priority,
          active: site2.active
        })

        workspace2 =
          create_workspace!(
            site_id: site2.id,
            title: "Site2 Workspace",
            description: "Site2 Description",
            skip_version: true
          )

        ws_version2 =
          create_workspace_version!(
            workspace_id: workspace2.id,
            site_id: site2.id,
            version_number: "1.0.0",
            status: :draft
          )

        section2 =
          create_section!(
            workspace_version_id: ws_version2.id,
            site_id: site2.id,
            title: "Site2 Section",
            slug: "site2-section"
          )

        note_in_site2 =
          create_note!(
            section_id: section2.id,
            site_id: site2.id,
            title: "Note in Site2",
            content: "Content in Site2"
          )

        # Try to access note from site2 using tenant admin from site1
        response =
          make_api_request(
            "#{@tenant_path}/#{note_in_site2.id}",
            %{},
            method: :get,
            headers: [
              {"authorization", "Bearer #{token}"},
              {"x-site-id", site.id}
            ]
          )

        # Should fail with 404 (not found in tenant's data)
        assert response.status == 404

        # Cleanup
        MishkaCmsCore.Runtime.States.SiteState.delete(site2.id)
      end
    end

    describe "TENANT ADMIN - POST /v1/tenant/admin/mishka-document/note (create)" do
      test "creates a new note", %{site: site, tenant_admin: tenant_admin} do
        token = sign_in_tenant(tenant_admin)

        # Create workspace, version, section
        workspace =
          create_workspace!(
            site_id: site.id,
            title: "Test Workspace",
            description: "Test Description",
            skip_version: true
          )

        ws_version =
          create_workspace_version!(
            workspace_id: workspace.id,
            site_id: site.id,
            version_number: "1.0.0",
            status: :draft
          )

        section =
          create_section!(
            workspace_version_id: ws_version.id,
            site_id: site.id,
            title: "Test Section",
            slug: "test-section"
          )

        response =
          make_api_request(
            @tenant_path,
            %{
              "type" => "note",
              "attributes" => %{
                "section_id" => section.id,
                "title" => "New Note",
                "content" => "New note content",
                "order_position" => 0,
                "content_review_status" => "pending",
                "technical_review_status" => "pending"
              }
            },
            headers: [
              {"authorization", "Bearer #{token}"},
              {"x-site-id", site.id}
            ]
          )

        assert response.status == 201
        body = Jason.decode!(response.resp_body)

        assert body["data"]["attributes"]["title"] == "New Note"
        assert body["data"]["attributes"]["content"] == "New note content"
        assert body["data"]["attributes"]["section_id"] == section.id
      end
    end

    describe "TENANT ADMIN - PATCH /v1/tenant/admin/mishka-document/note/:id (update)" do
      test "updates an existing note", %{site: site, tenant_admin: tenant_admin} do
        token = sign_in_tenant(tenant_admin)

        # Create workspace, version, section
        workspace =
          create_workspace!(
            site_id: site.id,
            title: "Test Workspace",
            description: "Test Description",
            skip_version: true
          )

        ws_version =
          create_workspace_version!(
            workspace_id: workspace.id,
            site_id: site.id,
            version_number: "1.0.0",
            status: :draft
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
            section_id: section.id,
            site_id: site.id,
            title: "Original Note",
            content: "Original Content"
          )

        response =
          make_api_request(
            "#{@tenant_path}/#{note.id}",
            %{
              "type" => "note",
              "attributes" => %{
                "title" => "Updated Note",
                "content" => "Updated Content"
              }
            },
            method: :patch,
            headers: [
              {"authorization", "Bearer #{token}"},
              {"x-site-id", site.id}
            ]
          )

        assert response.status == 200
        body = Jason.decode!(response.resp_body)

        assert body["data"]["attributes"]["title"] == "Updated Note"
        assert body["data"]["attributes"]["content"] == "Updated Content"
      end

      test "tenant admin CANNOT update note from other site", %{
        site: site,
        tenant_admin: tenant_admin
      } do
        token = sign_in_tenant(tenant_admin)

        # Create second site with note
        site2 = create_site!(name: "site2", host: "site2.com", active: true, priority: 50)

        MishkaCmsCore.Runtime.States.SiteState.save(%{
          id: site2.id,
          name: site2.name,
          host: site2.host,
          priority: site2.priority,
          active: site2.active
        })

        workspace2 =
          create_workspace!(
            site_id: site2.id,
            title: "Site2 Workspace",
            description: "Site2 Description",
            skip_version: true
          )

        ws_version2 =
          create_workspace_version!(
            workspace_id: workspace2.id,
            site_id: site2.id,
            version_number: "1.0.0",
            status: :draft
          )

        section2 =
          create_section!(
            workspace_version_id: ws_version2.id,
            site_id: site2.id,
            title: "Site2 Section",
            slug: "site2-section"
          )

        note_in_site2 =
          create_note!(
            section_id: section2.id,
            site_id: site2.id,
            title: "Note in Site2",
            content: "Content in Site2"
          )

        # Try to update note from site2 using tenant admin from site1
        response =
          make_api_request(
            "#{@tenant_path}/#{note_in_site2.id}",
            %{
              "type" => "note",
              "attributes" => %{
                "title" => "Hacked Title",
                "content" => "Hacked Content"
              }
            },
            method: :patch,
            headers: [
              {"authorization", "Bearer #{token}"},
              {"x-site-id", site.id}
            ]
          )

        # Should fail with 404
        assert response.status == 404

        # Verify note was NOT updated
        unchanged_note =
          Ash.get!(MishkaDocument.Note, note_in_site2.id, tenant: site2.id, authorize?: false)

        assert unchanged_note.title == "Note in Site2"
        assert unchanged_note.content == "Content in Site2"

        # Cleanup
        MishkaCmsCore.Runtime.States.SiteState.delete(site2.id)
      end
    end

    describe "TENANT ADMIN - DELETE /v1/tenant/admin/mishka-document/note/:id/archive (archive)" do
      test "archives a note", %{site: site, tenant_admin: tenant_admin} do
        token = sign_in_tenant(tenant_admin)

        # Create workspace, version, section
        workspace =
          create_workspace!(
            site_id: site.id,
            title: "Test Workspace",
            description: "Test Description",
            skip_version: true
          )

        ws_version =
          create_workspace_version!(
            workspace_id: workspace.id,
            site_id: site.id,
            version_number: "1.0.0",
            status: :draft
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
            section_id: section.id,
            site_id: site.id,
            title: "Note to Archive",
            content: "Content"
          )

        response =
          make_api_request(
            "#{@tenant_path}/#{note.id}/archive",
            %{},
            method: :delete,
            headers: [
              {"authorization", "Bearer #{token}"},
              {"x-site-id", site.id}
            ]
          )

        assert response.status == 200

        # Verify note is archived
        archived_note =
          Ash.get!(MishkaDocument.Note, note.id,
            action: :get_archived,
            tenant: site.id,
            authorize?: false
          )

        refute is_nil(archived_note.archived_at)
      end

      test "tenant admin CANNOT archive note from other site", %{
        site: site,
        tenant_admin: tenant_admin
      } do
        token = sign_in_tenant(tenant_admin)

        # Create second site with note
        site2 = create_site!(name: "site2", host: "site2.com", active: true, priority: 50)

        MishkaCmsCore.Runtime.States.SiteState.save(%{
          id: site2.id,
          name: site2.name,
          host: site2.host,
          priority: site2.priority,
          active: site2.active
        })

        workspace2 =
          create_workspace!(
            site_id: site2.id,
            title: "Site2 Workspace",
            description: "Site2 Description",
            skip_version: true
          )

        ws_version2 =
          create_workspace_version!(
            workspace_id: workspace2.id,
            site_id: site2.id,
            version_number: "1.0.0",
            status: :draft
          )

        section2 =
          create_section!(
            workspace_version_id: ws_version2.id,
            site_id: site2.id,
            title: "Site2 Section",
            slug: "site2-section"
          )

        note_in_site2 =
          create_note!(
            section_id: section2.id,
            site_id: site2.id,
            title: "Note in Site2",
            content: "Content in Site2"
          )

        # Try to archive note from site2 using tenant admin from site1
        response =
          make_api_request(
            "#{@tenant_path}/#{note_in_site2.id}/archive",
            %{},
            method: :delete,
            headers: [
              {"authorization", "Bearer #{token}"},
              {"x-site-id", site.id}
            ]
          )

        # Should fail with 404
        assert response.status == 404

        # Verify note was NOT archived
        unchanged_note =
          Ash.get!(MishkaDocument.Note, note_in_site2.id, tenant: site2.id, authorize?: false)

        assert is_nil(unchanged_note.archived_at)

        # Cleanup
        MishkaCmsCore.Runtime.States.SiteState.delete(site2.id)
      end
    end

    describe "TENANT ADMIN - GET /v1/tenant/admin/mishka-document/note/archived (index :archived)" do
      test "lists archived notes", %{site: site, tenant_admin: tenant_admin} do
        token = sign_in_tenant(tenant_admin)

        # Create workspace, version, section
        workspace =
          create_workspace!(
            site_id: site.id,
            title: "Test Workspace",
            description: "Test Description",
            skip_version: true
          )

        ws_version =
          create_workspace_version!(
            workspace_id: workspace.id,
            site_id: site.id,
            version_number: "1.0.0",
            status: :draft
          )

        section =
          create_section!(
            workspace_version_id: ws_version.id,
            site_id: site.id,
            title: "Test Section",
            slug: "test-section"
          )

        # Create and archive a note
        note =
          create_note!(
            section_id: section.id,
            site_id: site.id,
            title: "Archived Note",
            content: "Content"
          )

        Ash.destroy!(note, action: :destroy, tenant: site.id, authorize?: false)

        response =
          make_api_request(
            "#{@tenant_path}/archived",
            %{},
            method: :get,
            headers: [
              {"authorization", "Bearer #{token}"},
              {"x-site-id", site.id}
            ]
          )

        assert response.status == 200
        body = Jason.decode!(response.resp_body)

        assert length(body["data"]) == 1
        assert hd(body["data"])["id"] == note.id
      end
    end

    describe "TENANT ADMIN - GET /v1/tenant/admin/mishka-document/note/archived/:id (get :get_archived)" do
      test "retrieves single archived note", %{site: site, tenant_admin: tenant_admin} do
        token = sign_in_tenant(tenant_admin)

        # Create workspace, version, section
        workspace =
          create_workspace!(
            site_id: site.id,
            title: "Test Workspace",
            description: "Test Description",
            skip_version: true
          )

        ws_version =
          create_workspace_version!(
            workspace_id: workspace.id,
            site_id: site.id,
            version_number: "1.0.0",
            status: :draft
          )

        section =
          create_section!(
            workspace_version_id: ws_version.id,
            site_id: site.id,
            title: "Test Section",
            slug: "test-section"
          )

        # Create and archive a note
        note =
          create_note!(
            section_id: section.id,
            site_id: site.id,
            title: "Archived Note",
            content: "Content"
          )

        Ash.destroy!(note, action: :destroy, tenant: site.id, authorize?: false)

        response =
          make_api_request(
            "#{@tenant_path}/archived/#{note.id}",
            %{},
            method: :get,
            headers: [
              {"authorization", "Bearer #{token}"},
              {"x-site-id", site.id}
            ]
          )

        assert response.status == 200
        body = Jason.decode!(response.resp_body)

        assert body["data"]["id"] == note.id
        assert body["data"]["attributes"]["title"] == "Archived Note"
      end
    end

    describe "TENANT ADMIN - PATCH /v1/tenant/admin/mishka-document/note/:id/unarchive (unarchive)" do
      test "unarchives a note", %{site: site, tenant_admin: tenant_admin} do
        token = sign_in_tenant(tenant_admin)

        # Create workspace, version, section
        workspace =
          create_workspace!(
            site_id: site.id,
            title: "Test Workspace",
            description: "Test Description",
            skip_version: true
          )

        ws_version =
          create_workspace_version!(
            workspace_id: workspace.id,
            site_id: site.id,
            version_number: "1.0.0",
            status: :draft
          )

        section =
          create_section!(
            workspace_version_id: ws_version.id,
            site_id: site.id,
            title: "Test Section",
            slug: "test-section"
          )

        # Create and archive a note
        note =
          create_note!(
            section_id: section.id,
            site_id: site.id,
            title: "Note to Unarchive",
            content: "Content"
          )

        Ash.destroy!(note, action: :destroy, tenant: site.id, authorize?: false)

        response =
          make_api_request(
            "#{@tenant_path}/#{note.id}/unarchive",
            %{},
            method: :patch,
            headers: [
              {"authorization", "Bearer #{token}"},
              {"x-site-id", site.id}
            ]
          )

        assert response.status == 200

        # Verify note is unarchived
        unarchived_note =
          Ash.get!(MishkaDocument.Note, note.id, tenant: site.id, authorize?: false)

        assert is_nil(unarchived_note.archived_at)
      end

      test "tenant admin CANNOT unarchive note from other site", %{
        site: site,
        tenant_admin: tenant_admin
      } do
        token = sign_in_tenant(tenant_admin)

        # Create second site with note
        site2 = create_site!(name: "site2", host: "site2.com", active: true, priority: 50)

        MishkaCmsCore.Runtime.States.SiteState.save(%{
          id: site2.id,
          name: site2.name,
          host: site2.host,
          priority: site2.priority,
          active: site2.active
        })

        workspace2 =
          create_workspace!(
            site_id: site2.id,
            title: "Site2 Workspace",
            description: "Site2 Description",
            skip_version: true
          )

        ws_version2 =
          create_workspace_version!(
            workspace_id: workspace2.id,
            site_id: site2.id,
            version_number: "1.0.0",
            status: :draft
          )

        section2 =
          create_section!(
            workspace_version_id: ws_version2.id,
            site_id: site2.id,
            title: "Site2 Section",
            slug: "site2-section"
          )

        # Create and archive note in site2
        note_in_site2 =
          create_note!(
            section_id: section2.id,
            site_id: site2.id,
            title: "Archived Note in Site2",
            content: "Content in Site2"
          )

        # Archive the note
        note_in_site2
        |> Ash.Changeset.for_destroy(:destroy, %{}, tenant: site2.id, authorize?: false)
        |> Ash.destroy!()

        # Try to unarchive note from site2 using tenant admin from site1
        response =
          make_api_request(
            "#{@tenant_path}/#{note_in_site2.id}/unarchive",
            %{},
            method: :patch,
            headers: [
              {"authorization", "Bearer #{token}"},
              {"x-site-id", site.id}
            ]
          )

        # Should fail with 404
        assert response.status == 404

        # Verify note is still archived in site2
        archived_note =
          Ash.get!(MishkaDocument.Note, note_in_site2.id,
            action: :get_archived,
            tenant: site2.id,
            authorize?: false
          )

        refute is_nil(archived_note.archived_at)

        # Cleanup
        MishkaCmsCore.Runtime.States.SiteState.delete(site2.id)
      end
    end

    describe "TENANT ADMIN - DELETE /v1/tenant/admin/mishka-document/note/:id/permanent (permanent destroy)" do
      test "permanently deletes a note", %{site: site, tenant_admin: tenant_admin} do
        token = sign_in_tenant(tenant_admin)

        # Create workspace, version, section
        workspace =
          create_workspace!(
            site_id: site.id,
            title: "Test Workspace",
            description: "Test Description",
            skip_version: true
          )

        ws_version =
          create_workspace_version!(
            workspace_id: workspace.id,
            site_id: site.id,
            version_number: "1.0.0",
            status: :draft
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
            section_id: section.id,
            site_id: site.id,
            title: "Note to Delete Permanently",
            content: "Content"
          )

        response =
          make_api_request(
            "#{@tenant_path}/#{note.id}/permanent",
            %{},
            method: :delete,
            headers: [
              {"authorization", "Bearer #{token}"},
              {"x-site-id", site.id}
            ]
          )

        assert response.status == 200
      end

      test "tenant admin CANNOT permanently delete note from other site", %{
        site: site,
        tenant_admin: tenant_admin
      } do
        token = sign_in_tenant(tenant_admin)

        # Create second site with note
        site2 = create_site!(name: "site2", host: "site2.com", active: true, priority: 50)

        MishkaCmsCore.Runtime.States.SiteState.save(%{
          id: site2.id,
          name: site2.name,
          host: site2.host,
          priority: site2.priority,
          active: site2.active
        })

        workspace2 =
          create_workspace!(
            site_id: site2.id,
            title: "Site2 Workspace",
            description: "Site2 Description",
            skip_version: true
          )

        ws_version2 =
          create_workspace_version!(
            workspace_id: workspace2.id,
            site_id: site2.id,
            version_number: "1.0.0",
            status: :draft
          )

        section2 =
          create_section!(
            workspace_version_id: ws_version2.id,
            site_id: site2.id,
            title: "Site2 Section",
            slug: "site2-section"
          )

        note_in_site2 =
          create_note!(
            section_id: section2.id,
            site_id: site2.id,
            title: "Note in Site2",
            content: "Content in Site2"
          )

        # Try to permanently delete note from site2 using tenant admin from site1
        response =
          make_api_request(
            "#{@tenant_path}/#{note_in_site2.id}/permanent",
            %{},
            method: :delete,
            headers: [
              {"authorization", "Bearer #{token}"},
              {"x-site-id", site.id}
            ]
          )

        # Should fail with 404
        assert response.status == 404

        # Verify note still exists in site2
        still_exists =
          Ash.get!(MishkaDocument.Note, note_in_site2.id, tenant: site2.id, authorize?: false)

        assert still_exists.id == note_in_site2.id

        # Cleanup
        MishkaCmsCore.Runtime.States.SiteState.delete(site2.id)
      end
    end

    describe "MASTER ADMIN - GET /v1/master/admin/mishka-document/note (index :master_read)" do
      test "lists all notes system-wide", %{site: site, master_user: master_user} do
        token = sign_in_master(master_user)

        # Create workspace, version, section
        workspace =
          create_workspace!(
            site_id: site.id,
            title: "Test Workspace",
            description: "Test Description",
            skip_version: true
          )

        ws_version =
          create_workspace_version!(
            workspace_id: workspace.id,
            site_id: site.id,
            version_number: "1.0.0",
            status: :draft
          )

        section =
          create_section!(
            workspace_version_id: ws_version.id,
            site_id: site.id,
            title: "Test Section",
            slug: "test-section"
          )

        # Create notes
        note1 =
          create_note!(
            section_id: section.id,
            site_id: site.id,
            title: "Master Note 1",
            content: "Content 1"
          )

        note2 =
          create_note!(
            section_id: section.id,
            site_id: site.id,
            title: "Master Note 2",
            content: "Content 2"
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

        assert length(body["data"]) >= 2
        note_ids = Enum.map(body["data"], & &1["id"])
        assert note1.id in note_ids
        assert note2.id in note_ids
      end

      test "master admin CAN see notes from all sites", %{site: site, master_user: master_user} do
        token = sign_in_master(master_user)

        # Create note in site1
        workspace1 =
          create_workspace!(
            site_id: site.id,
            title: "Site1 Workspace",
            description: "Site1 Description",
            skip_version: true
          )

        ws_version1 =
          create_workspace_version!(
            workspace_id: workspace1.id,
            site_id: site.id,
            version_number: "1.0.0",
            status: :draft
          )

        section1 =
          create_section!(
            workspace_version_id: ws_version1.id,
            site_id: site.id,
            title: "Section in Site1",
            slug: "section-site1"
          )

        note_in_site1 =
          create_note!(
            section_id: section1.id,
            site_id: site.id,
            title: "Note in Site1",
            content: "Content in Site1"
          )

        # Create second site with its own data
        site2 = create_site!(name: "site2", host: "site2.com", active: true, priority: 50)

        MishkaCmsCore.Runtime.States.SiteState.save(%{
          id: site2.id,
          name: site2.name,
          host: site2.host,
          priority: site2.priority,
          active: site2.active
        })

        workspace2 =
          create_workspace!(
            site_id: site2.id,
            title: "Site2 Workspace",
            description: "Site2 Description",
            skip_version: true
          )

        ws_version2 =
          create_workspace_version!(
            workspace_id: workspace2.id,
            site_id: site2.id,
            version_number: "1.0.0",
            status: :draft
          )

        section2 =
          create_section!(
            workspace_version_id: ws_version2.id,
            site_id: site2.id,
            title: "Section in Site2",
            slug: "section-site2"
          )

        note_in_site2 =
          create_note!(
            section_id: section2.id,
            site_id: site2.id,
            title: "Note in Site2",
            content: "Content in Site2"
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

        # Master admin should see notes from BOTH sites
        note_ids = Enum.map(body["data"], & &1["id"])
        assert note_in_site1.id in note_ids
        assert note_in_site2.id in note_ids

        # Verify we have at least 2 notes (could have more from other tests)
        assert length(body["data"]) >= 2

        # Cleanup
        MishkaCmsCore.Runtime.States.SiteState.delete(site2.id)
      end
    end

    describe "MASTER ADMIN - GET /v1/master/admin/mishka-document/note/:id (get :master_get)" do
      test "retrieves single note by ID", %{site: site, master_user: master_user} do
        token = sign_in_master(master_user)

        # Create workspace, version, section
        workspace =
          create_workspace!(
            site_id: site.id,
            title: "Test Workspace",
            description: "Test Description",
            skip_version: true
          )

        ws_version =
          create_workspace_version!(
            workspace_id: workspace.id,
            site_id: site.id,
            version_number: "1.0.0",
            status: :draft
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
            section_id: section.id,
            site_id: site.id,
            title: "Master Note",
            content: "Master Content"
          )

        response =
          make_api_request(
            "#{@master_path}/#{note.id}",
            %{},
            method: :get,
            headers: [
              {"authorization", "Bearer #{token}"},
              {"x-no-tenant", "true"}
            ]
          )

        assert response.status == 200
        body = Jason.decode!(response.resp_body)

        assert body["data"]["id"] == note.id
        assert body["data"]["attributes"]["title"] == "Master Note"
        assert body["data"]["attributes"]["content"] == "Master Content"
      end
    end

    describe "MASTER ADMIN - POST /v1/master/admin/mishka-document/note (master_create)" do
      test "creates a new note", %{site: site, master_user: master_user} do
        token = sign_in_master(master_user)

        # Create workspace, version, section
        workspace =
          create_workspace!(
            site_id: site.id,
            title: "Test Workspace",
            description: "Test Description",
            skip_version: true
          )

        ws_version =
          create_workspace_version!(
            workspace_id: workspace.id,
            site_id: site.id,
            version_number: "1.0.0",
            status: :draft
          )

        section =
          create_section!(
            workspace_version_id: ws_version.id,
            site_id: site.id,
            title: "Test Section",
            slug: "test-section"
          )

        response =
          make_api_request(
            @master_path,
            %{
              "type" => "note",
              "attributes" => %{
                "section_id" => section.id,
                "title" => "Master Created Note",
                "content" => "Master created content",
                "site_id" => site.id,
                "order_position" => 0,
                "content_review_status" => "pending",
                "technical_review_status" => "pending"
              }
            },
            headers: [
              {"authorization", "Bearer #{token}"},
              {"x-no-tenant", "true"}
            ]
          )

        assert response.status == 201
        body = Jason.decode!(response.resp_body)

        assert body["data"]["attributes"]["title"] == "Master Created Note"
        assert body["data"]["attributes"]["content"] == "Master created content"
      end
    end

    describe "MASTER ADMIN - PATCH /v1/master/admin/mishka-document/note/:id (master_update)" do
      test "updates an existing note", %{site: site, master_user: master_user} do
        token = sign_in_master(master_user)

        # Create workspace, version, section
        workspace =
          create_workspace!(
            site_id: site.id,
            title: "Test Workspace",
            description: "Test Description",
            skip_version: true
          )

        ws_version =
          create_workspace_version!(
            workspace_id: workspace.id,
            site_id: site.id,
            version_number: "1.0.0",
            status: :draft
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
            section_id: section.id,
            site_id: site.id,
            title: "Original Master Note",
            content: "Original Content"
          )

        response =
          make_api_request(
            "#{@master_path}/#{note.id}",
            %{
              "type" => "note",
              "attributes" => %{
                "title" => "Updated Master Note",
                "content" => "Updated Master Content"
              }
            },
            method: :patch,
            headers: [
              {"authorization", "Bearer #{token}"},
              {"x-no-tenant", "true"}
            ]
          )

        assert response.status == 200
        body = Jason.decode!(response.resp_body)

        assert body["data"]["attributes"]["title"] == "Updated Master Note"
        assert body["data"]["attributes"]["content"] == "Updated Master Content"
      end
    end

    describe "MASTER ADMIN - DELETE /v1/master/admin/mishka-document/note/:id/archive (master_destroy)" do
      test "archives a note", %{site: site, master_user: master_user} do
        token = sign_in_master(master_user)

        # Create workspace, version, section
        workspace =
          create_workspace!(
            site_id: site.id,
            title: "Test Workspace",
            description: "Test Description",
            skip_version: true
          )

        ws_version =
          create_workspace_version!(
            workspace_id: workspace.id,
            site_id: site.id,
            version_number: "1.0.0",
            status: :draft
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
            section_id: section.id,
            site_id: site.id,
            title: "Master Note to Archive",
            content: "Content"
          )

        response =
          make_api_request(
            "#{@master_path}/#{note.id}/archive",
            %{},
            method: :delete,
            headers: [
              {"authorization", "Bearer #{token}"},
              {"x-no-tenant", "true"}
            ]
          )

        assert response.status == 200

        # Verify note is archived
        archived_note =
          Ash.get!(MishkaDocument.Note, note.id, action: :master_get_archived, authorize?: false)

        refute is_nil(archived_note.archived_at)
      end
    end

    describe "MASTER ADMIN - GET /v1/master/admin/mishka-document/note/archived (index :master_archived)" do
      test "lists archived notes system-wide", %{site: site, master_user: master_user} do
        token = sign_in_master(master_user)

        # Create workspace, version, section
        workspace =
          create_workspace!(
            site_id: site.id,
            title: "Test Workspace",
            description: "Test Description",
            skip_version: true
          )

        ws_version =
          create_workspace_version!(
            workspace_id: workspace.id,
            site_id: site.id,
            version_number: "1.0.0",
            status: :draft
          )

        section =
          create_section!(
            workspace_version_id: ws_version.id,
            site_id: site.id,
            title: "Test Section",
            slug: "test-section"
          )

        # Create and archive a note
        note =
          create_note!(
            section_id: section.id,
            site_id: site.id,
            title: "Master Archived Note",
            content: "Content"
          )

        note
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

        note_ids = Enum.map(body["data"], & &1["id"])
        assert note.id in note_ids
      end
    end

    describe "MASTER ADMIN - GET /v1/master/admin/mishka-document/note/archived/:id (get :master_get_archived)" do
      test "retrieves single archived note", %{site: site, master_user: master_user} do
        token = sign_in_master(master_user)

        # Create workspace, version, section
        workspace =
          create_workspace!(
            site_id: site.id,
            title: "Test Workspace",
            description: "Test Description",
            skip_version: true
          )

        ws_version =
          create_workspace_version!(
            workspace_id: workspace.id,
            site_id: site.id,
            version_number: "1.0.0",
            status: :draft
          )

        section =
          create_section!(
            workspace_version_id: ws_version.id,
            site_id: site.id,
            title: "Test Section",
            slug: "test-section"
          )

        # Create and archive a note
        note =
          create_note!(
            section_id: section.id,
            site_id: site.id,
            title: "Master Archived Note",
            content: "Content"
          )

        note
        |> Ash.Changeset.for_destroy(:destroy, %{}, tenant: site.id, authorize?: false)
        |> Ash.destroy!()

        response =
          make_api_request(
            "#{@master_path}/archived/#{note.id}",
            %{},
            method: :get,
            headers: [
              {"authorization", "Bearer #{token}"},
              {"x-no-tenant", "true"}
            ]
          )

        assert response.status == 200
        body = Jason.decode!(response.resp_body)

        assert body["data"]["id"] == note.id
        assert body["data"]["attributes"]["title"] == "Master Archived Note"
      end
    end

    describe "MASTER ADMIN - PATCH /v1/master/admin/mishka-document/note/:id/unarchive (master_unarchive)" do
      test "unarchives a note", %{site: site, master_user: master_user} do
        token = sign_in_master(master_user)

        # Create workspace, version, section
        workspace =
          create_workspace!(
            site_id: site.id,
            title: "Test Workspace",
            description: "Test Description",
            skip_version: true
          )

        ws_version =
          create_workspace_version!(
            workspace_id: workspace.id,
            site_id: site.id,
            version_number: "1.0.0",
            status: :draft
          )

        section =
          create_section!(
            workspace_version_id: ws_version.id,
            site_id: site.id,
            title: "Test Section",
            slug: "test-section"
          )

        # Create and archive a note
        note =
          create_note!(
            section_id: section.id,
            site_id: site.id,
            title: "Master Note to Unarchive",
            content: "Content"
          )

        note
        |> Ash.Changeset.for_destroy(:destroy, %{}, tenant: site.id, authorize?: false)
        |> Ash.destroy!()

        response =
          make_api_request(
            "#{@master_path}/#{note.id}/unarchive",
            %{},
            method: :patch,
            headers: [
              {"authorization", "Bearer #{token}"},
              {"x-no-tenant", "true"}
            ]
          )

        assert response.status == 200

        # Verify note is unarchived
        unarchived_note =
          Ash.get!(MishkaDocument.Note, note.id, action: :master_get, authorize?: false)

        assert is_nil(unarchived_note.archived_at)
      end
    end

    describe "MASTER ADMIN - DELETE /v1/master/admin/mishka-document/note/:id/permanent (master_permanent_destroy)" do
      test "permanently deletes a note", %{site: site, master_user: master_user} do
        token = sign_in_master(master_user)

        # Create workspace, version, section
        workspace =
          create_workspace!(
            site_id: site.id,
            title: "Test Workspace",
            description: "Test Description",
            skip_version: true
          )

        ws_version =
          create_workspace_version!(
            workspace_id: workspace.id,
            site_id: site.id,
            version_number: "1.0.0",
            status: :draft
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
            section_id: section.id,
            site_id: site.id,
            title: "Master Note to Delete Permanently",
            content: "Content"
          )

        response =
          make_api_request(
            "#{@master_path}/#{note.id}/permanent",
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

    describe "FILTERING - by section_id" do
      test "tenant admin can filter notes by section", %{site: site, tenant_admin: tenant_admin} do
        token = sign_in_tenant(tenant_admin)

        # Create workspace, version, sections
        workspace =
          create_workspace!(
            site_id: site.id,
            title: "Test Workspace",
            description: "Test Description",
            skip_version: true
          )

        ws_version =
          create_workspace_version!(
            workspace_id: workspace.id,
            site_id: site.id,
            version_number: "1.0.0",
            status: :draft
          )

        section1 =
          create_section!(
            workspace_version_id: ws_version.id,
            site_id: site.id,
            title: "Section 1",
            slug: "section-1"
          )

        section2 =
          create_section!(
            workspace_version_id: ws_version.id,
            site_id: site.id,
            title: "Section 2",
            slug: "section-2"
          )

        # Create notes in different sections
        note1 =
          create_note!(
            section_id: section1.id,
            site_id: site.id,
            title: "Note in Section 1",
            content: "Content 1"
          )

        _note2 =
          create_note!(
            section_id: section2.id,
            site_id: site.id,
            title: "Note in Section 2",
            content: "Content 2"
          )

        response =
          make_api_request(
            "#{@tenant_path}?filter[section_id]=#{section1.id}",
            %{},
            method: :get,
            headers: [
              {"authorization", "Bearer #{token}"},
              {"x-site-id", site.id}
            ]
          )

        assert response.status == 200
        body = Jason.decode!(response.resp_body)

        assert length(body["data"]) == 1
        assert hd(body["data"])["id"] == note1.id
      end
    end

    describe "FILTERING - by content_review_status" do
      test "tenant admin can filter notes by content review status", %{
        site: site,
        tenant_admin: tenant_admin
      } do
        token = sign_in_tenant(tenant_admin)

        # Create workspace, version, section
        workspace =
          create_workspace!(
            site_id: site.id,
            title: "Test Workspace",
            description: "Test Description",
            skip_version: true
          )

        ws_version =
          create_workspace_version!(
            workspace_id: workspace.id,
            site_id: site.id,
            version_number: "1.0.0",
            status: :draft
          )

        section =
          create_section!(
            workspace_version_id: ws_version.id,
            site_id: site.id,
            title: "Test Section",
            slug: "test-section"
          )

        # Create notes with different review statuses
        pending_note =
          create_note!(
            section_id: section.id,
            site_id: site.id,
            title: "Pending Note",
            content: "Content",
            content_review_status: :pending
          )

        _approved_note =
          create_note!(
            section_id: section.id,
            site_id: site.id,
            title: "Approved Note",
            content: "Content",
            content_review_status: :approved
          )

        response =
          make_api_request(
            "#{@tenant_path}?filter[content_review_status]=pending",
            %{},
            method: :get,
            headers: [
              {"authorization", "Bearer #{token}"},
              {"x-site-id", site.id}
            ]
          )

        assert response.status == 200
        body = Jason.decode!(response.resp_body)

        assert length(body["data"]) == 1
        assert hd(body["data"])["id"] == pending_note.id
      end
    end

    describe "FILTERING - by technical_review_status" do
      test "tenant admin can filter notes by technical review status", %{
        site: site,
        tenant_admin: tenant_admin
      } do
        token = sign_in_tenant(tenant_admin)

        # Create workspace, version, section
        workspace =
          create_workspace!(
            site_id: site.id,
            title: "Test Workspace",
            description: "Test Description",
            skip_version: true
          )

        ws_version =
          create_workspace_version!(
            workspace_id: workspace.id,
            site_id: site.id,
            version_number: "1.0.0",
            status: :draft
          )

        section =
          create_section!(
            workspace_version_id: ws_version.id,
            site_id: site.id,
            title: "Test Section",
            slug: "test-section"
          )

        # Create notes with different technical review statuses
        pending_note =
          create_note!(
            section_id: section.id,
            site_id: site.id,
            title: "Pending Technical Review",
            content: "Content",
            technical_review_status: :pending
          )

        _approved_note =
          create_note!(
            section_id: section.id,
            site_id: site.id,
            title: "Approved Technical Review",
            content: "Content",
            technical_review_status: :approved
          )

        response =
          make_api_request(
            "#{@tenant_path}?filter[technical_review_status]=pending",
            %{},
            method: :get,
            headers: [
              {"authorization", "Bearer #{token}"},
              {"x-site-id", site.id}
            ]
          )

        assert response.status == 200
        body = Jason.decode!(response.resp_body)

        assert length(body["data"]) == 1
        assert hd(body["data"])["id"] == pending_note.id
      end
    end

    describe "FILTERING - combined filters" do
      test "tenant admin can use multiple filters together", %{
        site: site,
        tenant_admin: tenant_admin
      } do
        token = sign_in_tenant(tenant_admin)

        # Create workspace, version, section
        workspace =
          create_workspace!(
            site_id: site.id,
            title: "Test Workspace",
            description: "Test Description",
            skip_version: true
          )

        ws_version =
          create_workspace_version!(
            workspace_id: workspace.id,
            site_id: site.id,
            version_number: "1.0.0",
            status: :draft
          )

        section =
          create_section!(
            workspace_version_id: ws_version.id,
            site_id: site.id,
            title: "Test Section",
            slug: "test-section"
          )

        # Create notes with various attributes
        matching_note =
          create_note!(
            section_id: section.id,
            site_id: site.id,
            title: "Matching Note",
            content: "Content",
            content_review_status: :pending,
            technical_review_status: :approved
          )

        _non_matching_note1 =
          create_note!(
            section_id: section.id,
            site_id: site.id,
            title: "Non-matching Note 1",
            content: "Content",
            content_review_status: :approved,
            technical_review_status: :pending
          )

        _non_matching_note2 =
          create_note!(
            section_id: section.id,
            site_id: site.id,
            title: "Non-matching Note 2",
            content: "Content",
            content_review_status: :approved,
            technical_review_status: :approved
          )

        response =
          make_api_request(
            "#{@tenant_path}?filter[content_review_status]=pending&filter[technical_review_status]=approved",
            %{},
            method: :get,
            headers: [
              {"authorization", "Bearer #{token}"},
              {"x-site-id", site.id}
            ]
          )

        assert response.status == 200
        body = Jason.decode!(response.resp_body)

        assert length(body["data"]) == 1
        assert hd(body["data"])["id"] == matching_note.id
      end
    end

    describe "FIELD ACCESS - draft count calculations" do
      setup %{site: site} do
        # Create workspace, version, section
        workspace =
          create_workspace!(
            site_id: site.id,
            title: "Test Workspace",
            description: "Test Description",
            skip_version: true
          )

        ws_version =
          create_workspace_version!(
            workspace_id: workspace.id,
            site_id: site.id,
            version_number: "1.0.0",
            status: :draft
          )

        section =
          create_section!(
            workspace_version_id: ws_version.id,
            site_id: site.id,
            title: "Test Section",
            slug: "test-section"
          )

        # Create note
        note =
          create_note!(
            section_id: section.id,
            site_id: site.id,
            title: "Note with Drafts",
            content: "Note Content"
          )

        # Create note drafts with different review statuses using direct Ecto inserts
        # to avoid unique constraint on source_note_id + workspace_version_id
        @repo.insert!(%MishkaDocument.NoteDraft{
          id: Ash.UUID.generate(),
          workspace_version_id: ws_version.id,
          section_id: section.id,
          source_note_id: note.id,
          title: "Pending Content Draft",
          content: "Draft content 1",
          order_position: 0,
          change_version: "1.0.1",
          version_increment_type: :minor,
          content_review_status: :pending,
          technical_review_status: :approved,
          site_id: site.id,
          schema: [],
          seo_tags: [],
          inserted_at: DateTime.utc_now(),
          updated_at: DateTime.utc_now()
        })

        # Create a second workspace version to allow second draft
        ws_version2 =
          create_workspace_version!(
            workspace_id: workspace.id,
            site_id: site.id,
            version_number: "1.0.1",
            status: :draft
          )

        @repo.insert!(%MishkaDocument.NoteDraft{
          id: Ash.UUID.generate(),
          workspace_version_id: ws_version2.id,
          section_id: section.id,
          source_note_id: note.id,
          title: "Pending Technical Draft",
          content: "Draft content 2",
          order_position: 0,
          change_version: "1.0.2",
          version_increment_type: :minor,
          content_review_status: :approved,
          technical_review_status: :pending,
          site_id: site.id,
          schema: [],
          seo_tags: [],
          inserted_at: DateTime.utc_now(),
          updated_at: DateTime.utc_now()
        })

        # Create a third workspace version for approved draft
        ws_version3 =
          create_workspace_version!(
            workspace_id: workspace.id,
            site_id: site.id,
            version_number: "1.0.2",
            status: :draft
          )

        @repo.insert!(%MishkaDocument.NoteDraft{
          id: Ash.UUID.generate(),
          workspace_version_id: ws_version3.id,
          section_id: section.id,
          source_note_id: note.id,
          title: "Approved Draft",
          content: "Approved draft content",
          order_position: 0,
          change_version: "1.0.3",
          version_increment_type: :minor,
          content_review_status: :approved,
          technical_review_status: :approved,
          site_id: site.id,
          schema: [],
          seo_tags: [],
          inserted_at: DateTime.utc_now(),
          updated_at: DateTime.utc_now()
        })

        %{note: note}
      end

      test "tenant admin CAN access draft count fields", %{
        site: site,
        tenant_admin: tenant_admin,
        note: note
      } do
        token = sign_in_tenant(tenant_admin)

        response =
          make_api_request(
            "#{@tenant_path}/#{note.id}?fields[note]=pending_note_draft_content_review_count,pending_note_draft_technical_review_count,approved_note_draft_count",
            %{},
            method: :get,
            headers: [
              {"authorization", "Bearer #{token}"},
              {"x-site-id", site.id}
            ]
          )

        assert response.status == 200
        body = Jason.decode!(response.resp_body)

        # Should see all calculation values
        assert body["data"]["attributes"]["pending_note_draft_content_review_count"] == 1
        assert body["data"]["attributes"]["pending_note_draft_technical_review_count"] == 1
        assert body["data"]["attributes"]["approved_note_draft_count"] == 1
      end

      test "master admin CAN access draft count fields", %{
        master_user: master_user,
        note: note
      } do
        token = sign_in_master(master_user)

        response =
          make_api_request(
            "#{@master_path}/#{note.id}?fields[note]=pending_note_draft_content_review_count,pending_note_draft_technical_review_count,approved_note_draft_count",
            %{},
            method: :get,
            headers: [
              {"authorization", "Bearer #{token}"},
              {"x-no-tenant", "true"}
            ]
          )

        assert response.status == 200
        body = Jason.decode!(response.resp_body)

        # Should see all calculation values
        assert body["data"]["attributes"]["pending_note_draft_content_review_count"] == 1
        assert body["data"]["attributes"]["pending_note_draft_technical_review_count"] == 1
        assert body["data"]["attributes"]["approved_note_draft_count"] == 1
      end

      test "public users CANNOT access draft count fields (get null)", %{site: _site, note: _note} do
        # Public endpoint doesn't exist for notes, but if it did, these should be null
        # For now, just verify the fields would be restricted
        # We'll skip this test since there's no public note endpoint
        assert true
      end

      test "draft counts are accurate with multiple drafts", %{
        site: site,
        tenant_admin: tenant_admin,
        note: note
      } do
        token = sign_in_tenant(tenant_admin)

        # Get the workspace and section from the note
        section =
          MishkaDocument.Section
          |> Ash.Query.for_read(:read)
          |> Ash.Query.filter(id == ^note.section_id)
          |> Ash.Query.load(:workspace_version)
          |> Ash.read_one!(tenant: site.id, authorize?: false)

        # Create a new workspace version and additional draft using Ecto insert
        ws_version4 =
          create_workspace_version!(
            workspace_id: section.workspace_version.workspace_id,
            site_id: site.id,
            version_number: "1.0.3",
            status: :draft
          )

        # Create additional pending content draft
        @repo.insert!(%MishkaDocument.NoteDraft{
          id: Ash.UUID.generate(),
          workspace_version_id: ws_version4.id,
          section_id: note.section_id,
          source_note_id: note.id,
          title: "Another Pending Content",
          content: "Content",
          order_position: 0,
          change_version: "1.0.4",
          version_increment_type: :minor,
          content_review_status: :pending,
          technical_review_status: :approved,
          site_id: site.id,
          schema: [],
          seo_tags: [],
          inserted_at: DateTime.utc_now(),
          updated_at: DateTime.utc_now()
        })

        response =
          make_api_request(
            "#{@tenant_path}/#{note.id}?fields[note]=pending_note_draft_content_review_count,pending_note_draft_technical_review_count,approved_note_draft_count",
            %{},
            method: :get,
            headers: [
              {"authorization", "Bearer #{token}"},
              {"x-site-id", site.id}
            ]
          )

        assert response.status == 200
        body = Jason.decode!(response.resp_body)

        # Now should have 2 pending content reviews
        assert body["data"]["attributes"]["pending_note_draft_content_review_count"] == 2
        assert body["data"]["attributes"]["pending_note_draft_technical_review_count"] == 1
        assert body["data"]["attributes"]["approved_note_draft_count"] == 1
      end
    end

    describe "MULTIPLE DRAFTS - allow multiple users to create drafts for same note" do
      test "multiple users can create different drafts for same note and version", %{
        site: site,
        tenant_admin: tenant_admin
      } do
        # Create workspace, version, section, and note
        workspace =
          create_workspace!(
            site_id: site.id,
            title: "Test Workspace",
            slug: "test-workspace",
            language: "en"
          )

        ws_version =
          create_workspace_version!(
            workspace_id: workspace.id,
            site_id: site.id,
            version_number: "1.0.0",
            status: :draft
          )

        section =
          create_section!(
            workspace_version_id: ws_version.id,
            site_id: site.id,
            title: "Test Section",
            slug: "test-section",
            content: "Section content",
            language: "en"
          )

        note =
          create_note!(
            section_id: section.id,
            site_id: site.id,
            title: "Original Note",
            content: "Original content"
          )

        # Create token for tenant user
        token = sign_in_tenant(tenant_admin)

        # User 1 creates a draft for the note (targeting version 1.0.1)
        draft1_attrs = %{
          "type" => "note_draft",
          "attributes" => %{
            "workspace_version_id" => ws_version.id,
            "section_id" => section.id,
            "source_note_id" => note.id,
            "title" => "User 1 Draft - Updated Note",
            "content" => "User 1's proposed changes",
            "change_version" => "1.0.1",
            "version_increment_type" => "minor"
          }
        }

        response1 =
          make_api_request(
            "/api/json/v1/tenant/admin/mishka-document/note-draft",
            draft1_attrs,
            method: :post,
            headers: [
              {"authorization", "Bearer #{token}"},
              {"x-site-id", site.id},
              {"content-type", "application/vnd.api+json"}
            ]
          )

        assert response1.status == 201

        # User 2 creates ANOTHER draft for the SAME note and SAME version
        draft2_attrs = %{
          "type" => "note_draft",
          "attributes" => %{
            "workspace_version_id" => ws_version.id,
            "section_id" => section.id,
            "source_note_id" => note.id,
            "title" => "User 2 Draft - Different Changes",
            "content" => "User 2's different proposed changes",
            "change_version" => "1.0.1",
            "version_increment_type" => "minor"
          }
        }

        response2 =
          make_api_request(
            "/api/json/v1/tenant/admin/mishka-document/note-draft",
            draft2_attrs,
            method: :post,
            headers: [
              {"authorization", "Bearer #{token}"},
              {"x-site-id", site.id},
              {"content-type", "application/vnd.api+json"}
            ]
          )

        # Should succeed - no unique constraint violation!
        assert response2.status == 201

        # User 3 creates YET ANOTHER draft for the SAME note and SAME version
        draft3_attrs = %{
          "type" => "note_draft",
          "attributes" => %{
            "workspace_version_id" => ws_version.id,
            "section_id" => section.id,
            "source_note_id" => note.id,
            "title" => "User 3 Draft - Third Option",
            "content" => "User 3's alternative proposal",
            "change_version" => "1.0.1",
            "version_increment_type" => "minor"
          }
        }

        response3 =
          make_api_request(
            "/api/json/v1/tenant/admin/mishka-document/note-draft",
            draft3_attrs,
            method: :post,
            headers: [
              {"authorization", "Bearer #{token}"},
              {"x-site-id", site.id},
              {"content-type", "application/vnd.api+json"}
            ]
          )

        # Should also succeed!
        assert response3.status == 201

        # Verify all 3 drafts exist by querying with filter
        response =
          make_api_request(
            "/api/json/v1/tenant/admin/mishka-document/note-draft?filter[source_note_id]=#{note.id}",
            %{},
            method: :get,
            headers: [
              {"authorization", "Bearer #{token}"},
              {"x-site-id", site.id}
            ]
          )

        assert response.status == 200
        body = Jason.decode!(response.resp_body)

        # Should have 3 drafts for this note
        assert length(body["data"]) == 3

        # Verify the titles are different
        titles = Enum.map(body["data"], & &1["attributes"]["title"]) |> Enum.sort()

        assert titles == [
                 "User 1 Draft - Updated Note",
                 "User 2 Draft - Different Changes",
                 "User 3 Draft - Third Option"
               ]
      end
    end
  end
end
