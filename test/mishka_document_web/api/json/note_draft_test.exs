# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_document/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaDocumentWeb.Api.Json.NoteDraftTest do
  @moduledoc """
  Comprehensive tests for NoteDraft JSON API endpoints.

  Tests all tenant admin and master admin note draft endpoints,
  including the automatic note creation/update when both reviews are approved.
  """

  use MishkaDocument.ConnCase
  import MishkaDocument.Test.Factory
  require Ash.Query

  @moduletag :unit
  @moduletag :capture_log

  if Code.ensure_loaded?(MishkaDocument) do
    @password "Password123!"
    @api_user_path "/api/json/v1/auth/user"
    @tenant_path "/api/json/v1/tenant/admin/mishka-document/note-draft"
    @master_path "/api/json/v1/master/admin/mishka-document/note-draft"

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

    defp sign_in_tenant(tenant_admin) do
      sign_in_response =
        make_api_request(
          "#{@api_user_path}/sign-in",
          %{
            "type" => "user",
            "attributes" => %{
              "email" => to_string(tenant_admin.email),
              "password" => @password
            }
          }
        )

      assert sign_in_response.status == 201
      %{"meta" => %{"token" => token}} = Jason.decode!(sign_in_response.resp_body)
      token
    end

    describe "TENANT ADMIN - POST /v1/tenant/admin/mishka-document/note-draft (create)" do
      test "creates new note draft", %{site: site, tenant_admin: tenant_admin} do
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
            slug: "test-section",
            content: "Section content"
          )

        note =
          create_note!(
            section_id: section.id,
            site_id: site.id,
            title: "Original Note",
            content: "Original content"
          )

        params = %{
          "type" => "note_draft",
          "attributes" => %{
            "workspace_version_id" => ws_version.id,
            "section_id" => section.id,
            "source_note_id" => note.id,
            "title" => "Draft Note Title",
            "content" => "Draft note content",
            "change_version" => "1.0.1",
            "version_increment_type" => "minor"
          }
        }

        response =
          make_api_request(
            @tenant_path,
            params,
            method: :post,
            headers: [
              {"authorization", "Bearer #{token}"},
              {"x-site-id", site.id},
              {"content-type", "application/vnd.api+json"}
            ]
          )

        assert response.status == 201
        body = Jason.decode!(response.resp_body)
        assert body["data"]["attributes"]["title"] == "Draft Note Title"
        assert body["data"]["attributes"]["content"] == "Draft note content"
        assert body["data"]["attributes"]["content_review_status"] == "pending"
        assert body["data"]["attributes"]["technical_review_status"] == "pending"
      end
    end

    describe "TENANT ADMIN - GET /v1/tenant/admin/mishka-document/note-draft/:id (read)" do
      test "returns note draft by id", %{site: site, tenant_admin: tenant_admin} do
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
            slug: "test-section",
            content: "Section content"
          )

        note =
          create_note!(
            section_id: section.id,
            site_id: site.id,
            title: "Original Note",
            content: "Original content"
          )

        draft =
          MishkaDocument.NoteDraft
          |> Ash.Changeset.for_create(
            :master_create,
            %{
              workspace_version_id: ws_version.id,
              section_id: section.id,
              source_note_id: note.id,
              title: "Draft Title",
              content: "Draft content",
              change_version: "1.0.1",
              version_increment_type: :minor,
              site_id: site.id
            },
            authorize?: false
          )
          |> Ash.create!(authorize?: false)

        response =
          make_api_request(
            "#{@tenant_path}/#{draft.id}",
            %{},
            method: :get,
            headers: [
              {"authorization", "Bearer #{token}"},
              {"x-site-id", site.id}
            ]
          )

        assert response.status == 200
        body = Jason.decode!(response.resp_body)
        assert body["data"]["id"] == draft.id
        assert body["data"]["attributes"]["title"] == "Draft Title"
      end
    end

    describe "TENANT ADMIN - PATCH /v1/tenant/admin/mishka-document/note-draft/:id (update)" do
      test "updates note draft", %{site: site, tenant_admin: tenant_admin} do
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
            slug: "test-section",
            content: "Section content"
          )

        note =
          create_note!(
            section_id: section.id,
            site_id: site.id,
            title: "Original Note",
            content: "Original content"
          )

        draft =
          MishkaDocument.NoteDraft
          |> Ash.Changeset.for_create(
            :master_create,
            %{
              workspace_version_id: ws_version.id,
              section_id: section.id,
              source_note_id: note.id,
              title: "Draft Title",
              content: "Draft content",
              change_version: "1.0.1",
              version_increment_type: :minor,
              site_id: site.id
            },
            authorize?: false
          )
          |> Ash.create!(authorize?: false)

        params = %{
          "type" => "note_draft",
          "attributes" => %{
            "title" => "Updated Draft Title",
            "content" => "Updated draft content"
          }
        }

        response =
          make_api_request(
            "#{@tenant_path}/#{draft.id}",
            params,
            method: :patch,
            headers: [
              {"authorization", "Bearer #{token}"},
              {"x-site-id", site.id},
              {"content-type", "application/vnd.api+json"}
            ]
          )

        assert response.status == 200
        body = Jason.decode!(response.resp_body)
        assert body["data"]["attributes"]["title"] == "Updated Draft Title"
        assert body["data"]["attributes"]["content"] == "Updated draft content"
      end
    end

    describe "AUTO-APPLY - note draft updates existing note when both approvals granted" do
      test "automatically updates source note when both reviews approved", %{
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
            slug: "test-section",
            content: "Section content",
            content_review_status: :approved,
            technical_review_status: :approved
          )

        # Create original note
        note =
          create_note!(
            section_id: section.id,
            site_id: site.id,
            title: "Original Note Title",
            content: "Original note content",
            content_review_status: :approved,
            technical_review_status: :approved
          )

        # Create draft for the note
        draft =
          MishkaDocument.NoteDraft
          |> Ash.Changeset.for_create(
            :master_create,
            %{
              workspace_version_id: ws_version.id,
              section_id: section.id,
              source_note_id: note.id,
              title: "Updated Note Title",
              content: "Updated note content",
              change_version: "1.0.1",
              version_increment_type: :minor,
              site_id: site.id,
              content_review_status: :pending,
              technical_review_status: :pending
            },
            authorize?: false
          )
          |> Ash.create!(authorize?: false)

        # Approve both reviews via API
        params = %{
          "type" => "note_draft",
          "attributes" => %{
            "content_review_status" => "approved",
            "technical_review_status" => "approved"
          }
        }

        response =
          make_api_request(
            "#{@tenant_path}/#{draft.id}",
            params,
            method: :patch,
            headers: [
              {"authorization", "Bearer #{token}"},
              {"x-site-id", site.id},
              {"content-type", "application/vnd.api+json"}
            ]
          )

        assert response.status == 200
        body = Jason.decode!(response.resp_body)

        # Verify draft is marked as applied
        assert {:ok, %DateTime{}, _offset} =
                 DateTime.from_iso8601(body["data"]["attributes"]["applied_at"])

        # Verify the note was updated with draft changes
        updated_note =
          Ash.get!(MishkaDocument.Note, note.id, tenant: site.id, authorize?: false)

        assert updated_note.title == "Updated Note Title"
        assert updated_note.content == "Updated note content"
      end
    end

    describe "AUTO-APPLY - note draft creates new note when both approvals granted" do
      test "automatically creates new note when both reviews approved and no source_note_id",
           %{site: site, tenant_admin: tenant_admin} do
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
            slug: "test-section",
            content: "Section content",
            content_review_status: :approved,
            technical_review_status: :approved
          )

        # Create draft WITHOUT source_note_id (new note)
        draft =
          MishkaDocument.NoteDraft
          |> Ash.Changeset.for_create(
            :master_create,
            %{
              workspace_version_id: ws_version.id,
              section_id: section.id,
              title: "New Note Title",
              content: "New note content",
              change_version: "1.0.0",
              version_increment_type: :minor,
              site_id: site.id,
              content_review_status: :pending,
              technical_review_status: :pending
            },
            authorize?: false
          )
          |> Ash.create!(authorize?: false)

        # Approve both reviews via API
        params = %{
          "type" => "note_draft",
          "attributes" => %{
            "content_review_status" => "approved",
            "technical_review_status" => "approved"
          }
        }

        response =
          make_api_request(
            "#{@tenant_path}/#{draft.id}",
            params,
            method: :patch,
            headers: [
              {"authorization", "Bearer #{token}"},
              {"x-site-id", site.id},
              {"content-type", "application/vnd.api+json"}
            ]
          )

        assert response.status == 200
        body = Jason.decode!(response.resp_body)

        # Verify draft is marked as applied
        assert {:ok, %DateTime{}, _offset} =
                 DateTime.from_iso8601(body["data"]["attributes"]["applied_at"])

        # Verify a new note was created
        notes =
          MishkaDocument.Note
          |> Ash.Query.filter(section_id == ^section.id)
          |> Ash.Query.filter(title == "New Note Title")
          |> Ash.read!(tenant: site.id, authorize?: false)

        assert length(notes) == 1
        new_note = hd(notes)
        assert new_note.title == "New Note Title"
        assert new_note.content == "New note content"
        assert new_note.content_review_status == :approved
        assert new_note.technical_review_status == :approved
      end
    end

    describe "AUTO-APPLY - partial approval does NOT trigger auto-apply" do
      test "does not apply when only content review is approved", %{
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
            slug: "test-section",
            content: "Section content"
          )

        note =
          create_note!(
            section_id: section.id,
            site_id: site.id,
            title: "Original Note",
            content: "Original content"
          )

        draft =
          MishkaDocument.NoteDraft
          |> Ash.Changeset.for_create(
            :master_create,
            %{
              workspace_version_id: ws_version.id,
              section_id: section.id,
              source_note_id: note.id,
              title: "Updated Note",
              content: "Updated content",
              change_version: "1.0.1",
              version_increment_type: :minor,
              site_id: site.id,
              content_review_status: :pending,
              technical_review_status: :pending
            },
            authorize?: false
          )
          |> Ash.create!(authorize?: false)

        # Approve only content review
        params = %{
          "type" => "note_draft",
          "attributes" => %{
            "content_review_status" => "approved"
          }
        }

        response =
          make_api_request(
            "#{@tenant_path}/#{draft.id}",
            params,
            method: :patch,
            headers: [
              {"authorization", "Bearer #{token}"},
              {"x-site-id", site.id},
              {"content-type", "application/vnd.api+json"}
            ]
          )

        assert response.status == 200
        body = Jason.decode!(response.resp_body)

        # Verify draft is NOT marked as applied
        assert body["data"]["attributes"]["applied_at"] == nil

        # Verify note was NOT updated
        unchanged_note =
          Ash.get!(MishkaDocument.Note, note.id, tenant: site.id, authorize?: false)

        assert unchanged_note.title == "Original Note"
        assert unchanged_note.content == "Original content"
      end
    end

    describe "MULTI-TENANCY - isolation between sites" do
      test "cannot access note drafts from other sites", %{
        site: site1,
        tenant_admin: tenant_admin
      } do
        token = sign_in_tenant(tenant_admin)

        # Create second site
        site2 = create_site!(name: "site2", host: "site2.com", active: true, priority: 50)

        MishkaCmsCore.Runtime.States.SiteState.save(%{
          id: site2.id,
          name: site2.name,
          host: site2.host,
          priority: site2.priority,
          active: site2.active
        })

        # Create workspace/section/note in site2
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
            slug: "site2-section",
            content: "Site2 content"
          )

        note2 =
          create_note!(
            section_id: section2.id,
            site_id: site2.id,
            title: "Site2 Note",
            content: "Site2 note content"
          )

        # Create draft in site2
        draft2 =
          MishkaDocument.NoteDraft
          |> Ash.Changeset.for_create(
            :master_create,
            %{
              workspace_version_id: ws_version2.id,
              section_id: section2.id,
              source_note_id: note2.id,
              title: "Site2 Draft",
              content: "Site2 draft content",
              change_version: "1.0.1",
              version_increment_type: :minor,
              site_id: site2.id
            },
            authorize?: false
          )
          |> Ash.create!(authorize?: false)

        # Try to access site2's draft from site1 context
        response =
          make_api_request(
            "#{@tenant_path}/#{draft2.id}",
            %{},
            method: :get,
            headers: [
              {"authorization", "Bearer #{token}"},
              {"x-site-id", site1.id}
            ]
          )

        # Should return 404 or error due to multi-tenancy isolation
        assert response.status in [404, 403, 500]
      end
    end

    describe "MASTER ADMIN - master_create and master_read" do
      test "master can create and read drafts across all sites", %{
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
            slug: "test-section",
            content: "Section content"
          )

        note =
          create_note!(
            section_id: section.id,
            site_id: site.id,
            title: "Test Note",
            content: "Test content"
          )

        # Master creates draft
        params = %{
          "type" => "note_draft",
          "attributes" => %{
            "workspace_version_id" => ws_version.id,
            "section_id" => section.id,
            "source_note_id" => note.id,
            "title" => "Master Draft",
            "content" => "Master draft content",
            "change_version" => "1.0.1",
            "version_increment_type" => "minor",
            "site_id" => site.id
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
        draft_id = body["data"]["id"]

        # Master reads the draft
        read_response =
          make_api_request(
            "#{@master_path}/#{draft_id}",
            %{},
            method: :get,
            headers: [
              {"authorization", "Bearer #{token}"},
              {"x-no-tenant", "true"}
            ]
          )

        assert read_response.status == 200
        read_body = Jason.decode!(read_response.resp_body)
        assert read_body["data"]["id"] == draft_id
      end
    end

    describe "TENANT ADMIN - GET /v1/tenant/admin/mishka-document/note-draft (index :read)" do
      test "lists all note drafts for tenant", %{site: site, tenant_admin: tenant_admin} do
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
            slug: "test-section",
            content: "Section content"
          )

        note =
          create_note!(
            section_id: section.id,
            site_id: site.id,
            title: "Test Note",
            content: "Test content"
          )

        # Create multiple drafts
        _draft1 =
          MishkaDocument.NoteDraft
          |> Ash.Changeset.for_create(
            :master_create,
            %{
              workspace_version_id: ws_version.id,
              section_id: section.id,
              source_note_id: note.id,
              title: "Draft 1",
              content: "Draft 1 content",
              change_version: "1.0.1",
              version_increment_type: :minor,
              site_id: site.id
            },
            authorize?: false
          )
          |> Ash.create!(authorize?: false)

        _draft2 =
          MishkaDocument.NoteDraft
          |> Ash.Changeset.for_create(
            :master_create,
            %{
              workspace_version_id: ws_version.id,
              section_id: section.id,
              title: "Draft 2",
              content: "Draft 2 content",
              change_version: "1.0.1",
              version_increment_type: :minor,
              site_id: site.id
            },
            authorize?: false
          )
          |> Ash.create!(authorize?: false)

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
      end
    end

    describe "TENANT ADMIN - GET /v1/tenant/admin/mishka-document/note-draft/archived (archived)" do
      test "lists archived note drafts", %{site: site, tenant_admin: tenant_admin} do
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
            slug: "test-section",
            content: "Section content"
          )

        draft =
          MishkaDocument.NoteDraft
          |> Ash.Changeset.for_create(
            :master_create,
            %{
              workspace_version_id: ws_version.id,
              section_id: section.id,
              title: "Draft to Archive",
              content: "Draft content",
              change_version: "1.0.1",
              version_increment_type: :minor,
              site_id: site.id
            },
            authorize?: false
          )
          |> Ash.create!(authorize?: false)

        # Archive the draft
        draft
        |> Ash.Changeset.for_destroy(:destroy, %{}, tenant: site.id, authorize?: false)
        |> Ash.destroy!()

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
        assert hd(body["data"])["id"] == draft.id
      end
    end

    describe "TENANT ADMIN - GET /v1/tenant/admin/mishka-document/note-draft/archived/:id (get_archived)" do
      test "retrieves archived note draft by id", %{site: site, tenant_admin: tenant_admin} do
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
            slug: "test-section",
            content: "Section content"
          )

        draft =
          MishkaDocument.NoteDraft
          |> Ash.Changeset.for_create(
            :master_create,
            %{
              workspace_version_id: ws_version.id,
              section_id: section.id,
              title: "Archived Draft",
              content: "Archived content",
              change_version: "1.0.1",
              version_increment_type: :minor,
              site_id: site.id
            },
            authorize?: false
          )
          |> Ash.create!(authorize?: false)

        # Archive the draft
        draft
        |> Ash.Changeset.for_destroy(:destroy, %{}, tenant: site.id, authorize?: false)
        |> Ash.destroy!()

        response =
          make_api_request(
            "#{@tenant_path}/archived/#{draft.id}",
            %{},
            method: :get,
            headers: [
              {"authorization", "Bearer #{token}"},
              {"x-site-id", site.id}
            ]
          )

        assert response.status == 200
        body = Jason.decode!(response.resp_body)
        assert body["data"]["id"] == draft.id
      end
    end

    describe "TENANT ADMIN - PATCH /v1/tenant/admin/mishka-document/note-draft/:id/unarchive (unarchive)" do
      test "unarchives archived note draft", %{site: site, tenant_admin: tenant_admin} do
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
            slug: "test-section",
            content: "Section content"
          )

        draft =
          MishkaDocument.NoteDraft
          |> Ash.Changeset.for_create(
            :master_create,
            %{
              workspace_version_id: ws_version.id,
              section_id: section.id,
              title: "Draft to Unarchive",
              content: "Draft content",
              change_version: "1.0.1",
              version_increment_type: :minor,
              site_id: site.id
            },
            authorize?: false
          )
          |> Ash.create!(authorize?: false)

        # Archive the draft first
        draft
        |> Ash.Changeset.for_destroy(:destroy, %{}, tenant: site.id, authorize?: false)
        |> Ash.destroy!()

        # Unarchive via API
        params = %{
          "type" => "note_draft",
          "attributes" => %{}
        }

        response =
          make_api_request(
            "#{@tenant_path}/#{draft.id}/unarchive",
            params,
            method: :patch,
            headers: [
              {"authorization", "Bearer #{token}"},
              {"x-site-id", site.id},
              {"content-type", "application/vnd.api+json"}
            ]
          )

        assert response.status == 200

        # Verify it's no longer archived
        read_response =
          make_api_request(
            "#{@tenant_path}/#{draft.id}",
            %{},
            method: :get,
            headers: [
              {"authorization", "Bearer #{token}"},
              {"x-site-id", site.id}
            ]
          )

        assert read_response.status == 200
      end
    end

    describe "TENANT ADMIN - DELETE /v1/tenant/admin/mishka-document/note-draft/:id/archive (destroy)" do
      test "archives note draft (soft delete)", %{site: site, tenant_admin: tenant_admin} do
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
            slug: "test-section",
            content: "Section content"
          )

        draft =
          MishkaDocument.NoteDraft
          |> Ash.Changeset.for_create(
            :master_create,
            %{
              workspace_version_id: ws_version.id,
              section_id: section.id,
              title: "Draft to Archive",
              content: "Draft content",
              change_version: "1.0.1",
              version_increment_type: :minor,
              site_id: site.id
            },
            authorize?: false
          )
          |> Ash.create!(authorize?: false)

        response =
          make_api_request(
            "#{@tenant_path}/#{draft.id}/archive",
            %{},
            method: :delete,
            headers: [
              {"authorization", "Bearer #{token}"},
              {"x-site-id", site.id}
            ]
          )

        assert response.status in [200, 204]

        # Verify it's archived by trying to get it
        get_response =
          make_api_request(
            "#{@tenant_path}/#{draft.id}",
            %{},
            method: :get,
            headers: [
              {"authorization", "Bearer #{token}"},
              {"x-site-id", site.id}
            ]
          )

        # Should not find it in normal list
        assert get_response.status in [404, 500]
      end
    end

    describe "TENANT ADMIN - DELETE /v1/tenant/admin/mishka-document/note-draft/:id/permanent (permanent_destroy)" do
      test "permanently deletes note draft", %{site: site, tenant_admin: tenant_admin} do
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
            slug: "test-section",
            content: "Section content"
          )

        draft =
          MishkaDocument.NoteDraft
          |> Ash.Changeset.for_create(
            :master_create,
            %{
              workspace_version_id: ws_version.id,
              section_id: section.id,
              title: "Draft to Delete",
              content: "Draft content",
              change_version: "1.0.1",
              version_increment_type: :minor,
              site_id: site.id
            },
            authorize?: false
          )
          |> Ash.create!(authorize?: false)

        draft_id = draft.id

        response =
          make_api_request(
            "#{@tenant_path}/#{draft_id}/permanent",
            %{},
            method: :delete,
            headers: [
              {"authorization", "Bearer #{token}"},
              {"x-site-id", site.id}
            ]
          )

        assert response.status in [200, 204]

        # Verify it's completely gone
        result =
          Ash.get(MishkaDocument.NoteDraft, draft_id,
            tenant: site.id,
            authorize?: false,
            action: :master_get
          )

        assert {:error, _} = result
      end
    end

    describe "MASTER ADMIN - GET /v1/master/admin/mishka-document/note-draft (master_read)" do
      test "lists all note drafts across all sites", %{site: site, master_user: master_user} do
        token = sign_in_master(master_user)

        # Create site2
        site2 = create_site!(name: "site2", host: "site2.com", active: true, priority: 50)

        MishkaCmsCore.Runtime.States.SiteState.save(%{
          id: site2.id,
          name: site2.name,
          host: site2.host,
          priority: site2.priority,
          active: site2.active
        })

        # Create drafts in both sites
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
            title: "Section 1",
            slug: "section-1",
            content: "Content 1"
          )

        _draft1 =
          MishkaDocument.NoteDraft
          |> Ash.Changeset.for_create(
            :master_create,
            %{
              workspace_version_id: ws_version1.id,
              section_id: section1.id,
              title: "Site1 Draft",
              content: "Site1 content",
              change_version: "1.0.1",
              version_increment_type: :minor,
              site_id: site.id
            },
            authorize?: false
          )
          |> Ash.create!(authorize?: false)

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
            title: "Section 2",
            slug: "section-2",
            content: "Content 2"
          )

        _draft2 =
          MishkaDocument.NoteDraft
          |> Ash.Changeset.for_create(
            :master_create,
            %{
              workspace_version_id: ws_version2.id,
              section_id: section2.id,
              title: "Site2 Draft",
              content: "Site2 content",
              change_version: "1.0.1",
              version_increment_type: :minor,
              site_id: site2.id
            },
            authorize?: false
          )
          |> Ash.create!(authorize?: false)

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
        # Should see drafts from both sites
        assert length(body["data"]) >= 2
      end
    end

    describe "MASTER ADMIN - DELETE /v1/master/admin/mishka-document/note-draft/:id/archive (master_destroy)" do
      test "archives note draft as master admin", %{site: site, master_user: master_user} do
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
            slug: "test-section",
            content: "Section content"
          )

        draft =
          MishkaDocument.NoteDraft
          |> Ash.Changeset.for_create(
            :master_create,
            %{
              workspace_version_id: ws_version.id,
              section_id: section.id,
              title: "Draft to Archive",
              content: "Draft content",
              change_version: "1.0.1",
              version_increment_type: :minor,
              site_id: site.id
            },
            authorize?: false
          )
          |> Ash.create!(authorize?: false)

        params = %{
          "type" => "note_draft",
          "attributes" => %{
            "id" => draft.id
          }
        }

        response =
          make_api_request(
            "#{@master_path}/#{draft.id}/archive",
            params,
            method: :delete,
            headers: [
              {"authorization", "Bearer #{token}"},
              {"x-no-tenant", "true"}
            ]
          )

        assert response.status in [200, 204]
      end
    end

    describe "MASTER ADMIN - DELETE /v1/master/admin/mishka-document/note-draft/:id/permanent (master_permanent_destroy)" do
      test "permanently deletes note draft as master admin", %{
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
            slug: "test-section",
            content: "Section content"
          )

        draft =
          MishkaDocument.NoteDraft
          |> Ash.Changeset.for_create(
            :master_create,
            %{
              workspace_version_id: ws_version.id,
              section_id: section.id,
              title: "Draft to Delete",
              content: "Draft content",
              change_version: "1.0.1",
              version_increment_type: :minor,
              site_id: site.id
            },
            authorize?: false
          )
          |> Ash.create!(authorize?: false)

        draft_id = draft.id

        params = %{
          "type" => "note_draft",
          "attributes" => %{
            "id" => draft_id
          }
        }

        response =
          make_api_request(
            "#{@master_path}/#{draft_id}/permanent",
            params,
            method: :delete,
            headers: [
              {"authorization", "Bearer #{token}"},
              {"x-no-tenant", "true"}
            ]
          )

        assert response.status in [200, 204]

        # Verify it's completely gone
        result =
          Ash.get(MishkaDocument.NoteDraft, draft_id,
            authorize?: false,
            action: :master_get
          )

        assert {:error, _} = result
      end
    end

    describe "content_word_count calculation" do
      test "counts words in content field", %{site: site} do
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
            slug: "test-section",
            content: "Section content"
          )

        draft =
          MishkaDocument.NoteDraft
          |> Ash.Changeset.for_create(
            :master_create,
            %{
              workspace_version_id: ws_version.id,
              section_id: section.id,
              title: "Test Note Draft",
              content: "This is a draft note with multiple test words inside",
              change_version: "1.0.1",
              version_increment_type: :minor,
              site_id: site.id
            },
            authorize?: false
          )
          |> Ash.create!(authorize?: false)

        draft_with_count =
          Ash.get!(MishkaDocument.NoteDraft, draft.id,
            tenant: site.id,
            authorize?: false,
            load: [:content_word_count]
          )

        # "This is a draft note with multiple test words inside" = 10 words
        assert draft_with_count.content_word_count == 10
      end
    end
  end
end
