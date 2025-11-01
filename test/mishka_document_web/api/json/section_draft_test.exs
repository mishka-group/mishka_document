defmodule MishkaDocumentWeb.Api.Json.SectionDraftTest do
  @moduledoc """
  Comprehensive tests for SectionDraft JSON API endpoints.

  Tests all public, tenant admin, and master admin section draft endpoints,
  including the automatic section update when both reviews are approved.
  """

  use MishkaDocument.ConnCase
  import MishkaDocument.Test.Factory
  require Ash.Query

  @moduletag :unit
  @moduletag :capture_log

  if Code.ensure_loaded?(MishkaDocument) do
    @password "Password123!"
    @api_user_path "/api/json/v1/auth/user"
    @tenant_path "/api/json/v1/tenant/admin/mishka-document/section-draft"
    @master_path "/api/json/v1/master/admin/mishka-document/section-draft"

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

    describe "TENANT ADMIN - POST /v1/tenant/admin/mishka-document/section-draft (create)" do
      test "creates new section draft", %{site: site, tenant_admin: tenant_admin} do
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
            title: "Original Section",
            slug: "original",
            content_review_status: :approved,
            technical_review_status: :approved
          )

        params = %{
          "type" => "section_draft",
          "attributes" => %{
            "workspace_version_id" => ws_version.id,
            "source_section_id" => section.id,
            "title" => "Updated Section Title",
            "slug" => "updated",
            "content" => "Updated content",
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
              {"x-site-id", site.id}
            ]
          )

        assert response.status == 201
        body = Jason.decode!(response.resp_body)
        assert body["data"]["attributes"]["title"] == "Updated Section Title"
        assert body["data"]["attributes"]["content_review_status"] == "pending"
        assert body["data"]["attributes"]["technical_review_status"] == "pending"
      end
    end

    describe "TENANT ADMIN - GET /v1/tenant/admin/mishka-document/section-draft (index :read)" do
      test "returns all section drafts in current site", %{
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

        # Create 3 drafts
        Enum.each(1..3, fn i ->
          MishkaDocument.SectionDraft
          |> Ash.Changeset.for_create(
            :master_create,
            %{
              workspace_version_id: ws_version.id,
              title: "Draft #{i}",
              slug: "draft-#{i}",
              change_version: "1.0.#{i}",
              version_increment_type: :minor,
              site_id: site.id
            },
            authorize?: false
          )
          |> Ash.create!(authorize?: false)
        end)

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
        assert length(body["data"]) == 3
      end
    end

    describe "TENANT ADMIN - GET /v1/tenant/admin/mishka-document/section-draft/:id (get :read)" do
      test "returns section draft by id", %{site: site, tenant_admin: tenant_admin} do
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

        draft =
          MishkaDocument.SectionDraft
          |> Ash.Changeset.for_create(
            :master_create,
            %{
              workspace_version_id: ws_version.id,
              title: "Test Draft",
              slug: "test-draft",
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
        assert body["data"]["attributes"]["title"] == "Test Draft"
      end
    end

    describe "TENANT ADMIN - GET /v1/tenant/admin/mishka-document/section-draft?filter[status]=pending" do
      test "returns only drafts pending approval using filter", %{
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

        # Create pending draft
        MishkaDocument.SectionDraft
        |> Ash.Changeset.for_create(
          :master_create,
          %{
            workspace_version_id: ws_version.id,
            title: "Pending Draft",
            slug: "pending",
            change_version: "1.0.1",
            version_increment_type: :minor,
            site_id: site.id,
            content_review_status: :pending,
            technical_review_status: :pending
          },
          authorize?: false
        )
        |> Ash.create!(authorize?: false)

        # Create approved draft
        MishkaDocument.SectionDraft
        |> Ash.Changeset.for_create(
          :master_create,
          %{
            workspace_version_id: ws_version.id,
            title: "Approved Draft",
            slug: "approved",
            change_version: "1.0.2",
            version_increment_type: :minor,
            site_id: site.id,
            content_review_status: :approved,
            technical_review_status: :approved
          },
          authorize?: false
        )
        |> Ash.create!(authorize?: false)

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
        # Should only get the pending draft
        assert length(body["data"]) == 1
        assert hd(body["data"])["attributes"]["title"] == "Pending Draft"
      end
    end

    describe "TENANT ADMIN - GET /v1/tenant/admin/mishka-document/section-draft?filter[status]=approved" do
      test "returns only approved drafts using filter", %{site: site, tenant_admin: tenant_admin} do
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

        # Create pending draft
        MishkaDocument.SectionDraft
        |> Ash.Changeset.for_create(
          :master_create,
          %{
            workspace_version_id: ws_version.id,
            title: "Pending Draft",
            slug: "pending",
            change_version: "1.0.1",
            version_increment_type: :minor,
            site_id: site.id,
            content_review_status: :pending,
            technical_review_status: :pending
          },
          authorize?: false
        )
        |> Ash.create!(authorize?: false)

        # Create approved draft (not yet applied)
        MishkaDocument.SectionDraft
        |> Ash.Changeset.for_create(
          :master_create,
          %{
            workspace_version_id: ws_version.id,
            title: "Approved Draft",
            slug: "approved",
            change_version: "1.0.2",
            version_increment_type: :minor,
            site_id: site.id,
            content_review_status: :approved,
            technical_review_status: :approved
          },
          authorize?: false
        )
        |> Ash.create!(authorize?: false)

        response =
          make_api_request(
            "#{@tenant_path}?filter[content_review_status]=approved&filter[technical_review_status]=approved",
            %{},
            method: :get,
            headers: [
              {"authorization", "Bearer #{token}"},
              {"x-site-id", site.id}
            ]
          )

        assert response.status == 200
        body = Jason.decode!(response.resp_body)
        # Should only get the approved draft
        assert length(body["data"]) == 1
        assert hd(body["data"])["attributes"]["title"] == "Approved Draft"
      end
    end

    describe "TENANT ADMIN - GET /v1/tenant/admin/mishka-document/section-draft?filter[applied_at][is_nil]=false" do
      test "returns only applied drafts using filter", %{site: site, tenant_admin: tenant_admin} do
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

        # Create applied draft
        draft =
          MishkaDocument.SectionDraft
          |> Ash.Changeset.for_create(
            :master_create,
            %{
              workspace_version_id: ws_version.id,
              title: "Applied Draft",
              slug: "applied",
              change_version: "1.0.1",
              version_increment_type: :minor,
              site_id: site.id,
              content_review_status: :approved,
              technical_review_status: :approved
            },
            authorize?: false
          )
          |> Ash.create!(authorize?: false)

        # Manually mark as applied
        draft
        |> Ash.Changeset.for_update(:mark_applied, %{applied_at: DateTime.utc_now()},
          tenant: site.id,
          authorize?: false
        )
        |> Ash.update!()

        # Create unapplied draft
        MishkaDocument.SectionDraft
        |> Ash.Changeset.for_create(
          :master_create,
          %{
            workspace_version_id: ws_version.id,
            title: "Unapplied Draft",
            slug: "unapplied",
            change_version: "1.0.2",
            version_increment_type: :minor,
            site_id: site.id
          },
          authorize?: false
        )
        |> Ash.create!(authorize?: false)

        response =
          make_api_request(
            "#{@tenant_path}?filter[applied_at][is_nil]=false",
            %{},
            method: :get,
            headers: [
              {"authorization", "Bearer #{token}"},
              {"x-site-id", site.id}
            ]
          )

        assert response.status == 200
        body = Jason.decode!(response.resp_body)
        # Should only get the applied draft
        assert length(body["data"]) == 1
        assert hd(body["data"])["attributes"]["title"] == "Applied Draft"
      end
    end

    describe "TENANT ADMIN - GET /v1/tenant/admin/mishka-document/section-draft?filter[workspace_version_id]=:id" do
      test "returns drafts for specific workspace version using filter", %{
        site: site,
        tenant_admin: tenant_admin
      } do
        token = sign_in_tenant(tenant_admin)

        workspace = create_workspace!(site_id: site.id, skip_version: true, status: :active)

        ws_version1 =
          create_workspace_version!(
            workspace_id: workspace.id,
            site_id: site.id,
            version_number: "1.0.0",
            status: :stable,
            published_at: DateTime.utc_now()
          )

        ws_version2 =
          create_workspace_version!(
            workspace_id: workspace.id,
            site_id: site.id,
            version_number: "2.0.0",
            status: :stable,
            published_at: DateTime.utc_now()
          )

        # Create draft for version 1
        MishkaDocument.SectionDraft
        |> Ash.Changeset.for_create(
          :master_create,
          %{
            workspace_version_id: ws_version1.id,
            title: "Draft v1",
            slug: "draft-v1",
            change_version: "1.0.1",
            version_increment_type: :minor,
            site_id: site.id
          },
          authorize?: false
        )
        |> Ash.create!(authorize?: false)

        # Create draft for version 2
        MishkaDocument.SectionDraft
        |> Ash.Changeset.for_create(
          :master_create,
          %{
            workspace_version_id: ws_version2.id,
            title: "Draft v2",
            slug: "draft-v2",
            change_version: "2.0.1",
            version_increment_type: :minor,
            site_id: site.id
          },
          authorize?: false
        )
        |> Ash.create!(authorize?: false)

        response =
          make_api_request(
            "#{@tenant_path}?filter[workspace_version_id]=#{ws_version1.id}",
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
        assert hd(body["data"])["attributes"]["title"] == "Draft v1"
      end
    end

    describe "TENANT ADMIN - GET /v1/tenant/admin/mishka-document/section-draft?filter[source_section_id]=:id" do
      test "returns drafts for specific source section using filter", %{
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

        # Create draft for section 1
        MishkaDocument.SectionDraft
        |> Ash.Changeset.for_create(
          :master_create,
          %{
            workspace_version_id: ws_version.id,
            source_section_id: section1.id,
            title: "Draft for Section 1",
            slug: "draft-section-1",
            change_version: "1.0.1",
            version_increment_type: :minor,
            site_id: site.id
          },
          authorize?: false
        )
        |> Ash.create!(authorize?: false)

        # Create draft for section 2
        MishkaDocument.SectionDraft
        |> Ash.Changeset.for_create(
          :master_create,
          %{
            workspace_version_id: ws_version.id,
            source_section_id: section2.id,
            title: "Draft for Section 2",
            slug: "draft-section-2",
            change_version: "1.0.1",
            version_increment_type: :minor,
            site_id: site.id
          },
          authorize?: false
        )
        |> Ash.create!(authorize?: false)

        response =
          make_api_request(
            "#{@tenant_path}?filter[source_section_id]=#{section1.id}",
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
        assert hd(body["data"])["attributes"]["title"] == "Draft for Section 1"
      end
    end

    describe "TENANT ADMIN - PATCH /v1/tenant/admin/mishka-document/section-draft/:id (update)" do
      test "updates section draft", %{site: site, tenant_admin: tenant_admin} do
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

        draft =
          MishkaDocument.SectionDraft
          |> Ash.Changeset.for_create(
            :master_create,
            %{
              workspace_version_id: ws_version.id,
              title: "Original Title",
              slug: "original",
              change_version: "1.0.1",
              version_increment_type: :minor,
              site_id: site.id
            },
            authorize?: false
          )
          |> Ash.create!(authorize?: false)

        params = %{
          "type" => "section_draft",
          "attributes" => %{
            "title" => "Updated Title",
            "content" => "Updated content"
          }
        }

        response =
          make_api_request(
            "#{@tenant_path}/#{draft.id}",
            params,
            method: :patch,
            headers: [
              {"authorization", "Bearer #{token}"},
              {"x-site-id", site.id}
            ]
          )

        assert response.status == 200
        body = Jason.decode!(response.resp_body)
        assert body["data"]["attributes"]["title"] == "Updated Title"
        assert body["data"]["attributes"]["content"] == "Updated content"
      end
    end

    describe "TENANT ADMIN - DELETE /v1/tenant/admin/mishka-document/section-draft/:id/archive (destroy)" do
      test "archives section draft", %{site: site, tenant_admin: tenant_admin} do
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

        draft =
          MishkaDocument.SectionDraft
          |> Ash.Changeset.for_create(
            :master_create,
            %{
              workspace_version_id: ws_version.id,
              title: "To Archive",
              slug: "to-archive",
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

        assert response.status == 200
      end
    end

    describe "TENANT ADMIN - GET /v1/tenant/admin/mishka-document/section-draft/archived (index :archived)" do
      test "lists archived section drafts", %{site: site, tenant_admin: tenant_admin} do
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

        draft =
          MishkaDocument.SectionDraft
          |> Ash.Changeset.for_create(
            :master_create,
            %{
              workspace_version_id: ws_version.id,
              title: "Archived Draft",
              slug: "archived",
              change_version: "1.0.1",
              version_increment_type: :minor,
              site_id: site.id
            },
            authorize?: false
          )
          |> Ash.create!(authorize?: false)

        # Archive it
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
      end
    end

    describe "TENANT ADMIN - GET /v1/tenant/admin/mishka-document/section-draft/archived/:id (get :get_archived)" do
      test "gets archived section draft by id", %{site: site, tenant_admin: tenant_admin} do
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

        draft =
          MishkaDocument.SectionDraft
          |> Ash.Changeset.for_create(
            :master_create,
            %{
              workspace_version_id: ws_version.id,
              title: "Archived Draft",
              slug: "archived",
              change_version: "1.0.1",
              version_increment_type: :minor,
              site_id: site.id
            },
            authorize?: false
          )
          |> Ash.create!(authorize?: false)

        # Archive it
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

    describe "TENANT ADMIN - PATCH /v1/tenant/admin/mishka-document/section-draft/:id/unarchive (unarchive)" do
      test "unarchives section draft", %{site: site, tenant_admin: tenant_admin} do
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

        draft =
          MishkaDocument.SectionDraft
          |> Ash.Changeset.for_create(
            :master_create,
            %{
              workspace_version_id: ws_version.id,
              title: "To Unarchive",
              slug: "to-unarchive",
              change_version: "1.0.1",
              version_increment_type: :minor,
              site_id: site.id
            },
            authorize?: false
          )
          |> Ash.create!(authorize?: false)

        # Archive it first
        draft
        |> Ash.Changeset.for_destroy(:destroy, %{}, tenant: site.id, authorize?: false)
        |> Ash.destroy!()

        response =
          make_api_request(
            "#{@tenant_path}/#{draft.id}/unarchive",
            %{},
            method: :patch,
            headers: [
              {"authorization", "Bearer #{token}"},
              {"x-site-id", site.id}
            ]
          )

        assert response.status == 200
      end
    end

    describe "TENANT ADMIN - DELETE /v1/tenant/admin/mishka-document/section-draft/:id/permanent (permanent_destroy)" do
      test "permanently deletes section draft from database", %{
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

        draft =
          MishkaDocument.SectionDraft
          |> Ash.Changeset.for_create(
            :master_create,
            %{
              workspace_version_id: ws_version.id,
              title: "To Delete Permanently",
              slug: "to-delete",
              change_version: "1.0.1",
              version_increment_type: :minor,
              site_id: site.id
            },
            authorize?: false
          )
          |> Ash.create!(authorize?: false)

        response =
          make_api_request(
            "#{@tenant_path}/#{draft.id}/permanent",
            %{},
            method: :delete,
            headers: [
              {"authorization", "Bearer #{token}"},
              {"x-site-id", site.id}
            ]
          )

        assert response.status == 200
      end
    end

    describe "MASTER ADMIN - GET /v1/master/admin/mishka-document/section-draft (index :master_read)" do
      test "returns section drafts from all sites", %{site: site, master_user: master_user} do
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

        workspace1 = create_workspace!(site_id: site.id, skip_version: true, status: :active)
        workspace2 = create_workspace!(site_id: site2.id, skip_version: true, status: :active)

        ws_version1 =
          create_workspace_version!(
            workspace_id: workspace1.id,
            site_id: site.id,
            version_number: "1.0.0",
            status: :stable,
            published_at: DateTime.utc_now()
          )

        ws_version2 =
          create_workspace_version!(
            workspace_id: workspace2.id,
            site_id: site2.id,
            version_number: "1.0.0",
            status: :stable,
            published_at: DateTime.utc_now()
          )

        # Create draft on site 1
        MishkaDocument.SectionDraft
        |> Ash.Changeset.for_create(
          :master_create,
          %{
            workspace_version_id: ws_version1.id,
            title: "Draft Site 1",
            slug: "draft-site-1",
            change_version: "1.0.1",
            version_increment_type: :minor,
            site_id: site.id
          },
          authorize?: false
        )
        |> Ash.create!(authorize?: false)

        # Create draft on site 2
        MishkaDocument.SectionDraft
        |> Ash.Changeset.for_create(
          :master_create,
          %{
            workspace_version_id: ws_version2.id,
            title: "Draft Site 2",
            slug: "draft-site-2",
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
        assert length(body["data"]) == 2
      end
    end

    describe "MASTER ADMIN - GET /v1/master/admin/mishka-document/section-draft/:id (get :master_get)" do
      test "gets section draft by id from any site", %{site: site, master_user: master_user} do
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

        draft =
          MishkaDocument.SectionDraft
          |> Ash.Changeset.for_create(
            :master_create,
            %{
              workspace_version_id: ws_version.id,
              title: "Master Draft",
              slug: "master-draft",
              change_version: "1.0.1",
              version_increment_type: :minor,
              site_id: site.id
            },
            authorize?: false
          )
          |> Ash.create!(authorize?: false)

        response =
          make_api_request(
            "#{@master_path}/#{draft.id}",
            %{},
            method: :get,
            headers: [
              {"authorization", "Bearer #{token}"},
              {"x-no-tenant", "true"}
            ]
          )

        assert response.status == 200
        body = Jason.decode!(response.resp_body)
        assert body["data"]["id"] == draft.id
      end
    end

    describe "MASTER ADMIN - POST /v1/master/admin/mishka-document/section-draft (master_create)" do
      test "creates section draft for specified site", %{site: site, master_user: master_user} do
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
          "type" => "section_draft",
          "attributes" => %{
            "workspace_version_id" => ws_version.id,
            "site_id" => site.id,
            "title" => "Master Created Draft",
            "slug" => "master-created",
            "change_version" => "1.0.1",
            "version_increment_type" => "minor"
          }
        }

        response =
          make_api_request(
            @master_path,
            params,
            method: :post,
            headers: [
              {"authorization", "Bearer #{token}"},
              {"x-no-tenant", "true"}
            ]
          )

        assert response.status == 201
        body = Jason.decode!(response.resp_body)
        assert body["data"]["attributes"]["title"] == "Master Created Draft"
      end
    end

    describe "MASTER ADMIN - PATCH /v1/master/admin/mishka-document/section-draft/:id (master_update)" do
      test "updates section draft on any site", %{site: site, master_user: master_user} do
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

        draft =
          MishkaDocument.SectionDraft
          |> Ash.Changeset.for_create(
            :master_create,
            %{
              workspace_version_id: ws_version.id,
              title: "Original",
              slug: "original",
              change_version: "1.0.1",
              version_increment_type: :minor,
              site_id: site.id
            },
            authorize?: false
          )
          |> Ash.create!(authorize?: false)

        params = %{
          "type" => "section_draft",
          "attributes" => %{
            "title" => "Master Updated"
          }
        }

        response =
          make_api_request(
            "#{@master_path}/#{draft.id}",
            params,
            method: :patch,
            headers: [
              {"authorization", "Bearer #{token}"},
              {"x-no-tenant", "true"}
            ]
          )

        assert response.status == 200
        body = Jason.decode!(response.resp_body)
        assert body["data"]["attributes"]["title"] == "Master Updated"
      end
    end

    describe "MASTER ADMIN - DELETE /v1/master/admin/mishka-document/section-draft/:id/archive (master_destroy)" do
      test "archives section draft from any site", %{site: site, master_user: master_user} do
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

        draft =
          MishkaDocument.SectionDraft
          |> Ash.Changeset.for_create(
            :master_create,
            %{
              workspace_version_id: ws_version.id,
              title: "To Archive",
              slug: "to-archive",
              change_version: "1.0.1",
              version_increment_type: :minor,
              site_id: site.id
            },
            authorize?: false
          )
          |> Ash.create!(authorize?: false)

        response =
          make_api_request(
            "#{@master_path}/#{draft.id}/archive",
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

    describe "MASTER ADMIN - GET /v1/master/admin/mishka-document/section-draft/archived (index :master_archived)" do
      test "lists archived section drafts from all sites", %{
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

        draft =
          MishkaDocument.SectionDraft
          |> Ash.Changeset.for_create(
            :master_create,
            %{
              workspace_version_id: ws_version.id,
              title: "Archived",
              slug: "archived",
              change_version: "1.0.1",
              version_increment_type: :minor,
              site_id: site.id
            },
            authorize?: false
          )
          |> Ash.create!(authorize?: false)

        # Archive it
        draft
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
      end
    end

    describe "MASTER ADMIN - GET /v1/master/admin/mishka-document/section-draft/archived/:id (get :master_get_archived)" do
      test "gets archived section draft by id from any site", %{
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

        draft =
          MishkaDocument.SectionDraft
          |> Ash.Changeset.for_create(
            :master_create,
            %{
              workspace_version_id: ws_version.id,
              title: "Archived Draft",
              slug: "archived",
              change_version: "1.0.1",
              version_increment_type: :minor,
              site_id: site.id
            },
            authorize?: false
          )
          |> Ash.create!(authorize?: false)

        # Archive it
        draft
        |> Ash.Changeset.for_destroy(:destroy, %{}, tenant: site.id, authorize?: false)
        |> Ash.destroy!()

        response =
          make_api_request(
            "#{@master_path}/archived/#{draft.id}",
            %{},
            method: :get,
            headers: [
              {"authorization", "Bearer #{token}"},
              {"x-no-tenant", "true"}
            ]
          )

        assert response.status == 200
        body = Jason.decode!(response.resp_body)
        assert body["data"]["id"] == draft.id
      end
    end

    describe "MASTER ADMIN - PATCH /v1/master/admin/mishka-document/section-draft/:id/unarchive (master_unarchive)" do
      test "unarchives section draft from any site", %{site: site, master_user: master_user} do
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

        draft =
          MishkaDocument.SectionDraft
          |> Ash.Changeset.for_create(
            :master_create,
            %{
              workspace_version_id: ws_version.id,
              title: "To Unarchive",
              slug: "to-unarchive",
              change_version: "1.0.1",
              version_increment_type: :minor,
              site_id: site.id
            },
            authorize?: false
          )
          |> Ash.create!(authorize?: false)

        # Archive it first
        draft
        |> Ash.Changeset.for_destroy(:destroy, %{}, tenant: site.id, authorize?: false)
        |> Ash.destroy!()

        response =
          make_api_request(
            "#{@master_path}/#{draft.id}/unarchive",
            %{},
            method: :patch,
            headers: [
              {"authorization", "Bearer #{token}"},
              {"x-no-tenant", "true"}
            ]
          )

        assert response.status == 200
      end
    end

    describe "MASTER ADMIN - DELETE /v1/master/admin/mishka-document/section-draft/:id/permanent (master_permanent_destroy)" do
      test "permanently deletes section draft from database", %{
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

        draft =
          MishkaDocument.SectionDraft
          |> Ash.Changeset.for_create(
            :master_create,
            %{
              workspace_version_id: ws_version.id,
              title: "To Delete Permanently",
              slug: "to-delete",
              change_version: "1.0.1",
              version_increment_type: :minor,
              site_id: site.id
            },
            authorize?: false
          )
          |> Ash.create!(authorize?: false)

        response =
          make_api_request(
            "#{@master_path}/#{draft.id}/permanent",
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

    describe "AUTO-APPLY - section draft updates existing section when both approvals granted" do
      test "automatically updates source section when both reviews approved", %{
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

        # Create original section
        section =
          create_section!(
            workspace_version_id: ws_version.id,
            site_id: site.id,
            title: "Original Title",
            slug: "original",
            content: "Original content",
            content_review_status: :approved,
            technical_review_status: :approved
          )

        # Create draft for the section
        draft =
          MishkaDocument.SectionDraft
          |> Ash.Changeset.for_create(
            :master_create,
            %{
              workspace_version_id: ws_version.id,
              source_section_id: section.id,
              title: "Updated Title",
              slug: "updated",
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

        # Approve both reviews via API
        params = %{
          "type" => "section_draft",
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
              {"x-site-id", site.id}
            ]
          )

        assert response.status == 200
        body = Jason.decode!(response.resp_body)

        # Verify draft is marked as applied
        assert body["data"]["attributes"]["applied_at"] != nil

        # Verify the section was updated with draft changes
        updated_section =
          Ash.get!(MishkaDocument.Section, section.id, tenant: site.id, authorize?: false)

        assert updated_section.title == "Updated Title"
        assert updated_section.slug == "updated"
        assert updated_section.content == "Updated content"
      end
    end

    describe "AUTO-APPLY - section draft creates new section when both approvals granted" do
      test "automatically creates new section when both reviews approved and no source_section_id",
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

        # Create draft WITHOUT source_section_id (new section)
        draft =
          MishkaDocument.SectionDraft
          |> Ash.Changeset.for_create(
            :master_create,
            %{
              workspace_version_id: ws_version.id,
              title: "New Section Title",
              slug: "new-section",
              content: "New section content",
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
          "type" => "section_draft",
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
              {"x-site-id", site.id}
            ]
          )

        assert response.status == 200
        body = Jason.decode!(response.resp_body)

        # Verify draft is marked as applied
        assert body["data"]["attributes"]["applied_at"] != nil

        # Verify a new section was created
        sections =
          MishkaDocument.Section
          |> Ash.Query.filter(workspace_version_id == ^ws_version.id)
          |> Ash.Query.filter(slug == "new-section")
          |> Ash.read!(tenant: site.id, authorize?: false)

        assert length(sections) == 1
        new_section = hd(sections)
        assert new_section.title == "New Section Title"
        assert new_section.content == "New section content"
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
            title: "Original",
            slug: "original",
            content_review_status: :approved,
            technical_review_status: :approved
          )

        draft =
          MishkaDocument.SectionDraft
          |> Ash.Changeset.for_create(
            :master_create,
            %{
              workspace_version_id: ws_version.id,
              source_section_id: section.id,
              title: "Updated",
              slug: "updated",
              change_version: "1.0.1",
              version_increment_type: :minor,
              site_id: site.id
            },
            authorize?: false
          )
          |> Ash.create!(authorize?: false)

        # Approve ONLY content review
        params = %{
          "type" => "section_draft",
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
              {"x-site-id", site.id}
            ]
          )

        assert response.status == 200
        body = Jason.decode!(response.resp_body)

        # Verify draft is NOT applied
        assert body["data"]["attributes"]["applied_at"] == nil

        # Verify section was NOT updated
        unchanged_section =
          Ash.get!(MishkaDocument.Section, section.id, tenant: site.id, authorize?: false)

        assert unchanged_section.title == "Original"
        assert unchanged_section.slug == "original"
      end
    end

    describe "AUTO-APPLY - already applied drafts are not re-applied" do
      test "does not re-apply when already applied", %{site: site, tenant_admin: tenant_admin} do
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
            title: "Original",
            slug: "original",
            content_review_status: :approved,
            technical_review_status: :approved
          )

        # Create and immediately apply draft
        draft =
          MishkaDocument.SectionDraft
          |> Ash.Changeset.for_create(
            :master_create,
            %{
              workspace_version_id: ws_version.id,
              source_section_id: section.id,
              title: "Updated Once",
              slug: "updated-once",
              change_version: "1.0.1",
              version_increment_type: :minor,
              site_id: site.id,
              content_review_status: :approved,
              technical_review_status: :approved
            },
            authorize?: false
          )
          |> Ash.create!(authorize?: false)

        # Apply it
        params = %{
          "type" => "section_draft",
          "attributes" => %{
            "content_review_status" => "approved",
            "technical_review_status" => "approved"
          }
        }

        make_api_request(
          "#{@tenant_path}/#{draft.id}",
          params,
          method: :patch,
          headers: [
            {"authorization", "Bearer #{token}"},
            {"x-site-id", site.id}
          ]
        )

        # Verify section was updated
        section_after_first_apply =
          Ash.get!(MishkaDocument.Section, section.id, tenant: site.id, authorize?: false)

        assert section_after_first_apply.title == "Updated Once"

        # Now update the section directly
        section_after_first_apply
        |> Ash.Changeset.for_update(:update, %{title: "Manually Changed"},
          tenant: site.id,
          authorize?: false
        )
        |> Ash.update!()

        # Try to "re-apply" by updating the already-applied draft
        params2 = %{
          "type" => "section_draft",
          "attributes" => %{
            "title" => "Should Not Apply"
          }
        }

        make_api_request(
          "#{@tenant_path}/#{draft.id}",
          params2,
          method: :patch,
          headers: [
            {"authorization", "Bearer #{token}"},
            {"x-site-id", site.id}
          ]
        )

        # Verify section was NOT re-updated (manual change persists)
        final_section =
          Ash.get!(MishkaDocument.Section, section.id, tenant: site.id, authorize?: false)

        assert final_section.title == "Manually Changed"
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

        draft =
          MishkaDocument.SectionDraft
          |> Ash.Changeset.for_create(
            :master_create,
            %{
              workspace_version_id: ws_version.id,
              title: "Test Draft",
              slug: "test-draft",
              content: "This is test content with several words here",
              change_version: "1.0.0",
              version_increment_type: :minor,
              site_id: site.id
            },
            authorize?: false
          )
          |> Ash.create!(authorize?: false)

        draft_with_count =
          Ash.get!(MishkaDocument.SectionDraft, draft.id,
            tenant: site.id,
            authorize?: false,
            load: [:content_word_count]
          )

        # "This is test content with several words here" = 8 words
        assert draft_with_count.content_word_count == 8
      end
    end
  end
end
