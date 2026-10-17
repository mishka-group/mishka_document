# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_document/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaDocumentWeb.Api.Json.TagTest do
  @moduledoc """
  Comprehensive tests for MishkaDocument.Tag JSON API endpoints.
  """
  use MishkaDocument.ConnCase
  import MishkaDocument.Test.Factory

  @moduletag :unit
  @moduletag :capture_log

  if Code.ensure_loaded?(MishkaDocument) do
    @password "Password123!"
    @master_base_url "/api/json/v1/master/admin/mishka-document/tag"
    @tenant_base_url "/api/json/v1/tenant/admin/mishka-document/tag"
    @api_user_path "/api/json/v1/auth/user"

    setup do
      MishkaCmsCore.Runtime.States.SiteState.clear()
      :ok = Swoosh.TestAssertions.set_swoosh_global()

      Application.put_env(:ash_json_api, MishkaDocument, router: MishkaDocument.TestRouter)

      # Create site for testing
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
      permission =
        Ash.create!(
          MishkaCmsCore.Accounts.Permission,
          %{
            name: "admin:api:*",
            description: "Full API access"
          },
          authorize?: false
        )

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
          %{permission_ids: [permission.id]},
          authorize?: false
        )
        |> Ash.update!()

      # Create tenant admin user for site
      admin_user =
        create_user!(
          email: "admin@example.com",
          password: @password,
          password_confirmation: @password,
          site_id: site.id
        )
        |> Ash.Changeset.for_update(
          :assign_permissions,
          %{permission_ids: [permission.id]},
          authorize?: false,
          tenant: site.id
        )
        |> Ash.update!()

      on_exit(fn ->
        MishkaCmsCore.Runtime.States.SiteState.delete(site.id)
        MishkaCmsCore.Runtime.States.SiteState.delete(site2.id)
        MishkaCmsCore.Runtime.States.SiteState.clear()
      end)

      {:ok, site: site, site2: site2, master_user: master_user, admin_user: admin_user}
    end

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
          method: :post,
          headers: [{"x-no-tenant", "true"}]
        )

      assert sign_in_response.status in [200, 201]

      body = Jason.decode!(sign_in_response.resp_body)
      body["meta"]["token"]
    end

    defp sign_in_user(user) do
      sign_in_response =
        make_api_request(
          "#{@api_user_path}/sign-in",
          %{
            "type" => "user",
            "attributes" => %{
              "email" => to_string(user.email),
              "password" => @password
            }
          },
          method: :post
        )

      assert sign_in_response.status in [200, 201]

      body = Jason.decode!(sign_in_response.resp_body)
      body["meta"]["token"]
    end

    describe "/api/json/v1/master/admin/mishka-document/tag - master admin routes" do
      test "POST / - creates tag for specific site (master_create)", %{
        site: site,
        master_user: master_user
      } do
        token = sign_in_master(master_user)

        response =
          make_api_request(
            @master_base_url,
            %{
              "type" => "tag",
              "attributes" => %{
                "name" => "Master Tag",
                "slug" => "master-tag",
                "site_id" => site.id
              }
            },
            method: :post,
            headers: [
              {"authorization", "Bearer #{token}"},
              {"x-no-tenant", "true"}
            ]
          )

        assert response.status in [200, 201]

        body = Jason.decode!(response.resp_body)
        assert body["data"]["attributes"]["name"] == "Master Tag"
        assert body["data"]["attributes"]["slug"] == "master-tag"
      end

      test "GET / - lists all tags system-wide (master_read)", %{
        site: site,
        master_user: master_user
      } do
        # Create tags
        tag1 = create_document_tag!(site_id: site.id, name: "Tag 1", slug: "tag-1")
        tag2 = create_document_tag!(site_id: site.id, name: "Tag 2", slug: "tag-2")

        token = sign_in_master(master_user)

        response =
          make_api_request(
            @master_base_url,
            %{},
            method: :get,
            headers: [
              {"authorization", "Bearer #{token}"},
              {"x-no-tenant", "true"}
            ]
          )

        assert response.status == 200

        body = Jason.decode!(response.resp_body)
        tag_ids = Enum.map(body["data"], & &1["id"])

        assert tag1.id in tag_ids
        assert tag2.id in tag_ids
      end

      test "GET /:id - retrieves single tag (master_get)", %{
        site: site,
        master_user: master_user
      } do
        tag = create_document_tag!(site_id: site.id, name: "Specific Tag", slug: "specific-tag")

        token = sign_in_master(master_user)

        response =
          make_api_request(
            "#{@master_base_url}/#{tag.id}",
            %{},
            method: :get,
            headers: [
              {"authorization", "Bearer #{token}"},
              {"x-no-tenant", "true"}
            ]
          )

        assert response.status == 200

        body = Jason.decode!(response.resp_body)
        assert body["data"]["id"] == tag.id
        assert body["data"]["attributes"]["name"] == "Specific Tag"
      end

      test "PATCH /:id - updates tag (master_update)", %{
        site: site,
        master_user: master_user
      } do
        tag = create_document_tag!(site_id: site.id, name: "Original Name", slug: "original")

        token = sign_in_master(master_user)

        response =
          make_api_request(
            "#{@master_base_url}/#{tag.id}",
            %{
              "type" => "tag",
              "attributes" => %{
                "name" => "Updated Name"
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
        assert body["data"]["attributes"]["name"] == "Updated Name"
      end

      test "DELETE /:id/archive - archives tag (master_destroy)", %{
        site: site,
        master_user: master_user
      } do
        tag = create_document_tag!(site_id: site.id, name: "Tag to Archive", slug: "archive-me")

        token = sign_in_master(master_user)

        response =
          make_api_request(
            "#{@master_base_url}/#{tag.id}/archive",
            %{},
            method: :delete,
            headers: [
              {"authorization", "Bearer #{token}"},
              {"x-no-tenant", "true"}
            ]
          )

        assert response.status in [200, 204]
      end

      test "GET /archived - lists archived tags (master_archived)", %{
        site: site,
        master_user: master_user
      } do
        tag = create_document_tag!(site_id: site.id, name: "Archived Tag", slug: "archived")

        # Archive the tag
        tag
        |> Ash.Changeset.for_destroy(:destroy, %{}, tenant: site.id, authorize?: false)
        |> Ash.destroy!()

        token = sign_in_master(master_user)

        response =
          make_api_request(
            "#{@master_base_url}/archived",
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
        assert hd(body["data"])["attributes"]["name"] == "Archived Tag"
      end

      test "GET /archived/:id - retrieves single archived tag (master_get_archived)", %{
        site: site,
        master_user: master_user
      } do
        tag = create_document_tag!(site_id: site.id, name: "Archived Tag", slug: "archived")

        # Archive the tag
        tag
        |> Ash.Changeset.for_destroy(:destroy, %{}, tenant: site.id, authorize?: false)
        |> Ash.destroy!()

        token = sign_in_master(master_user)

        response =
          make_api_request(
            "#{@master_base_url}/archived/#{tag.id}",
            %{},
            method: :get,
            headers: [
              {"authorization", "Bearer #{token}"},
              {"x-no-tenant", "true"}
            ]
          )

        assert response.status == 200

        body = Jason.decode!(response.resp_body)
        assert body["data"]["id"] == tag.id
        assert body["data"]["attributes"]["name"] == "Archived Tag"
      end

      test "PATCH /:id/unarchive - unarchives tag (master_unarchive)", %{
        site: site,
        master_user: master_user
      } do
        tag = create_document_tag!(site_id: site.id, name: "Tag", slug: "tag")

        # Archive it first
        tag
        |> Ash.Changeset.for_destroy(:destroy, %{}, tenant: site.id, authorize?: false)
        |> Ash.destroy!()

        token = sign_in_master(master_user)

        response =
          make_api_request(
            "#{@master_base_url}/#{tag.id}/unarchive",
            %{},
            method: :patch,
            headers: [
              {"authorization", "Bearer #{token}"},
              {"x-no-tenant", "true"}
            ]
          )

        assert response.status == 200

        body = Jason.decode!(response.resp_body)
        assert body["data"]["id"] == tag.id
        assert is_nil(body["data"]["attributes"]["archived_at"])
      end

      test "DELETE /:id/permanent - permanently deletes tag (master_permanent_destroy)", %{
        site: site,
        master_user: master_user
      } do
        tag = create_document_tag!(site_id: site.id, name: "Tag", slug: "tag")
        tag_id = tag.id

        token = sign_in_master(master_user)

        response =
          make_api_request(
            "#{@master_base_url}/#{tag_id}/permanent",
            %{},
            method: :delete,
            headers: [
              {"authorization", "Bearer #{token}"},
              {"x-no-tenant", "true"}
            ]
          )

        assert response.status in [200, 204]

        # Verify it's gone
        get_response =
          make_api_request(
            "#{@master_base_url}/#{tag_id}",
            %{},
            method: :get,
            headers: [
              {"authorization", "Bearer #{token}"},
              {"x-no-tenant", "true"}
            ]
          )

        assert get_response.status == 404
      end
    end

    describe "/api/json/v1/tenant/admin/mishka-document/tag - tenant admin routes" do
      test "POST / - creates tag in tenant context (create)", %{
        site: site,
        admin_user: admin_user
      } do
        token = sign_in_user(admin_user)

        response =
          make_api_request(
            @tenant_base_url,
            %{
              "type" => "tag",
              "attributes" => %{
                "name" => "Tenant Tag",
                "slug" => "tenant-tag"
              }
            },
            method: :post,
            headers: [
              {"authorization", "Bearer #{token}"},
              {"x-tenant-id", site.id}
            ]
          )

        assert response.status in [200, 201]

        body = Jason.decode!(response.resp_body)
        assert body["data"]["attributes"]["name"] == "Tenant Tag"
      end

      test "GET / - lists tags for current tenant only (read)", %{
        site: site,
        site2: site2,
        admin_user: admin_user
      } do
        # Create tag in site
        tag1 = create_document_tag!(site_id: site.id, name: "Site Tag", slug: "site-tag")
        # Create tag in site2
        _tag2 = create_document_tag!(site_id: site2.id, name: "Site2 Tag", slug: "site2-tag")

        token = sign_in_user(admin_user)

        response =
          make_api_request(
            @tenant_base_url,
            %{},
            method: :get,
            headers: [
              {"authorization", "Bearer #{token}"},
              {"x-tenant-id", site.id}
            ]
          )

        assert response.status == 200

        body = Jason.decode!(response.resp_body)
        tag_ids = Enum.map(body["data"], & &1["id"])

        assert tag1.id in tag_ids
        # Should only see tag from site, not site2
        assert length(body["data"]) == 1
      end

      test "GET /:id - retrieves single tag in tenant context (read)", %{
        site: site,
        admin_user: admin_user
      } do
        tag = create_document_tag!(site_id: site.id, name: "Specific Tag", slug: "specific")

        token = sign_in_user(admin_user)

        response =
          make_api_request(
            "#{@tenant_base_url}/#{tag.id}",
            %{},
            method: :get,
            headers: [
              {"authorization", "Bearer #{token}"},
              {"x-tenant-id", site.id}
            ]
          )

        assert response.status == 200

        body = Jason.decode!(response.resp_body)
        assert body["data"]["id"] == tag.id
        assert body["data"]["attributes"]["name"] == "Specific Tag"
      end

      test "PATCH /:id - updates tag in tenant context (update)", %{
        site: site,
        admin_user: admin_user
      } do
        tag = create_document_tag!(site_id: site.id, name: "Original Name", slug: "original")

        token = sign_in_user(admin_user)

        response =
          make_api_request(
            "#{@tenant_base_url}/#{tag.id}",
            %{
              "type" => "tag",
              "attributes" => %{
                "name" => "Updated Name"
              }
            },
            method: :patch,
            headers: [
              {"authorization", "Bearer #{token}"},
              {"x-tenant-id", site.id}
            ]
          )

        assert response.status == 200

        body = Jason.decode!(response.resp_body)
        assert body["data"]["attributes"]["name"] == "Updated Name"
      end

      test "DELETE /:id/archive - archives tag in tenant context (destroy)", %{
        site: site,
        admin_user: admin_user
      } do
        tag = create_document_tag!(site_id: site.id, name: "Tag to Archive", slug: "archive")

        token = sign_in_user(admin_user)

        response =
          make_api_request(
            "#{@tenant_base_url}/#{tag.id}/archive",
            %{},
            method: :delete,
            headers: [
              {"authorization", "Bearer #{token}"},
              {"x-tenant-id", site.id}
            ]
          )

        assert response.status in [200, 204]
      end

      test "GET /archived - lists archived tags in tenant context (archived)", %{
        site: site,
        admin_user: admin_user
      } do
        tag = create_document_tag!(site_id: site.id, name: "Archived Tag", slug: "archived")

        # Archive the tag
        tag
        |> Ash.Changeset.for_destroy(:destroy, %{}, tenant: site.id, authorize?: false)
        |> Ash.destroy!()

        token = sign_in_user(admin_user)

        response =
          make_api_request(
            "#{@tenant_base_url}/archived",
            %{},
            method: :get,
            headers: [
              {"authorization", "Bearer #{token}"},
              {"x-tenant-id", site.id}
            ]
          )

        assert response.status == 200

        body = Jason.decode!(response.resp_body)
        assert length(body["data"]) == 1
      end

      test "GET /archived/:id - retrieves single archived tag in tenant context (get_archived)",
           %{
             site: site,
             admin_user: admin_user
           } do
        tag = create_document_tag!(site_id: site.id, name: "Archived Tag", slug: "archived")

        # Archive the tag
        tag
        |> Ash.Changeset.for_destroy(:destroy, %{}, tenant: site.id, authorize?: false)
        |> Ash.destroy!()

        token = sign_in_user(admin_user)

        response =
          make_api_request(
            "#{@tenant_base_url}/archived/#{tag.id}",
            %{},
            method: :get,
            headers: [
              {"authorization", "Bearer #{token}"},
              {"x-tenant-id", site.id}
            ]
          )

        assert response.status == 200

        body = Jason.decode!(response.resp_body)
        assert body["data"]["id"] == tag.id
        assert body["data"]["attributes"]["name"] == "Archived Tag"
      end

      test "PATCH /:id/unarchive - unarchives tag in tenant context (unarchive)", %{
        site: site,
        admin_user: admin_user
      } do
        tag = create_document_tag!(site_id: site.id, name: "Tag", slug: "tag")

        # Archive it first
        tag
        |> Ash.Changeset.for_destroy(:destroy, %{}, tenant: site.id, authorize?: false)
        |> Ash.destroy!()

        token = sign_in_user(admin_user)

        response =
          make_api_request(
            "#{@tenant_base_url}/#{tag.id}/unarchive",
            %{},
            method: :patch,
            headers: [
              {"authorization", "Bearer #{token}"},
              {"x-tenant-id", site.id}
            ]
          )

        assert response.status == 200

        body = Jason.decode!(response.resp_body)
        assert body["data"]["id"] == tag.id
      end

      test "DELETE /:id/permanent - permanently deletes tag in tenant context (permanent_destroy)",
           %{
             site: site,
             admin_user: admin_user
           } do
        tag = create_document_tag!(site_id: site.id, name: "Tag", slug: "tag")
        tag_id = tag.id

        token = sign_in_user(admin_user)

        response =
          make_api_request(
            "#{@tenant_base_url}/#{tag_id}/permanent",
            %{},
            method: :delete,
            headers: [
              {"authorization", "Bearer #{token}"},
              {"x-tenant-id", site.id}
            ]
          )

        assert response.status in [200, 204]

        # Verify it's gone
        get_response =
          make_api_request(
            "#{@tenant_base_url}/#{tag_id}",
            %{},
            method: :get,
            headers: [
              {"authorization", "Bearer #{token}"},
              {"x-tenant-id", site.id}
            ]
          )

        assert get_response.status == 404
      end

      test "supports filtering by name", %{site: site, admin_user: admin_user} do
        token = sign_in_user(admin_user)

        create_document_tag!(site_id: site.id, name: "Elixir", slug: "elixir")
        create_document_tag!(site_id: site.id, name: "Phoenix", slug: "phoenix")

        response =
          make_api_request(
            "#{@tenant_base_url}?filter[name]=Elixir",
            %{},
            method: :get,
            headers: [
              {"authorization", "Bearer #{token}"},
              {"x-tenant-id", site.id}
            ]
          )

        assert response.status == 200
        body = Jason.decode!(response.resp_body)
        assert length(body["data"]) == 1
        assert hd(body["data"])["attributes"]["name"] == "Elixir"
      end

      test "supports pagination", %{site: site, admin_user: admin_user} do
        token = sign_in_user(admin_user)

        for i <- 1..25 do
          create_document_tag!(site_id: site.id, name: "Tag #{i}", slug: "tag-#{i}")
        end

        response =
          make_api_request(
            "#{@tenant_base_url}?page[limit]=10",
            %{},
            method: :get,
            headers: [
              {"authorization", "Bearer #{token}"},
              {"x-tenant-id", site.id}
            ]
          )

        assert response.status == 200
        body = Jason.decode!(response.resp_body)
        assert length(body["data"]) == 10
        # Verify pagination is working (we requested limit 10, got 10)
      end
    end

    describe "/api/json/v1/user/mishka-document/tag - user public routes" do
      test "GET / - lists all tags (public_list)", %{site: site} do
        # Create some tags
        tag1 = create_document_tag!(site_id: site.id, name: "Public Tag 1", slug: "public-tag-1")
        tag2 = create_document_tag!(site_id: site.id, name: "Public Tag 2", slug: "public-tag-2")

        response =
          make_api_request(
            "/api/json/v1/user/mishka-document/tag",
            %{},
            method: :get,
            headers: [{"x-tenant-id", site.id}]
          )

        assert response.status == 200

        body = Jason.decode!(response.resp_body)
        tag_ids = Enum.map(body["data"], & &1["id"])

        assert tag1.id in tag_ids
        assert tag2.id in tag_ids
      end

      test "GET /:id - retrieves single tag (public_get)", %{site: site} do
        tag =
          create_document_tag!(
            site_id: site.id,
            name: "Specific Public Tag",
            slug: "specific-public-tag"
          )

        response =
          make_api_request(
            "/api/json/v1/user/mishka-document/tag/#{tag.id}",
            %{},
            method: :get,
            headers: [{"x-tenant-id", site.id}]
          )

        assert response.status == 200

        body = Jason.decode!(response.resp_body)
        assert body["data"]["id"] == tag.id
        assert body["data"]["attributes"]["name"] == "Specific Public Tag"
      end

      test "GET / - does not show archived tags (public_list)", %{site: site} do
        active_tag =
          create_document_tag!(site_id: site.id, name: "Active Tag", slug: "active-tag")

        archived_tag =
          create_document_tag!(site_id: site.id, name: "Archived Tag", slug: "archived-tag")

        archived_tag
        |> Ash.Changeset.for_destroy(:destroy, %{}, tenant: site.id, authorize?: false)
        |> Ash.destroy!()

        response =
          make_api_request(
            "/api/json/v1/user/mishka-document/tag",
            %{},
            method: :get,
            headers: [{"x-tenant-id", site.id}]
          )

        assert response.status == 200

        body = Jason.decode!(response.resp_body)
        tag_ids = Enum.map(body["data"], & &1["id"])

        # Should only see active tag
        assert active_tag.id in tag_ids
        refute archived_tag.id in tag_ids
      end
    end

    describe "PAGINATED INCLUDES - Fetching related sections and language variants with pagination" do
      test "master admin can fetch tag with paginated master_sections", %{
        master_user: master_user,
        site: site
      } do
        token = sign_in_master(master_user)

        # Create workspace and version for sections
        workspace =
          Ash.create!(
            MishkaDocument.Workspace,
            %{
              name: "Test Workspace",
              slug: "test-workspace",
              status: :active,
              language: "en"
            },
            authorize?: false,
            tenant: site.id
          )

        workspace_version =
          Ash.create!(
            MishkaDocument.WorkspaceVersion,
            %{
              workspace_id: workspace.id,
              version_number: "1.0.0",
              status: :stable,
              published_at: DateTime.utc_now()
            },
            authorize?: false,
            tenant: site.id
          )

        # Create a tag
        tag =
          create_document_tag!(
            site_id: site.id,
            name: "Documentation Tag",
            slug: "documentation-tag"
          )

        # Create 25 sections and link them to the tag
        section_ids =
          Enum.map(1..25, fn i ->
            section =
              Ash.create!(
                MishkaDocument.Section,
                %{
                  workspace_version_id: workspace_version.id,
                  title: "Section #{i}",
                  slug: "section-#{i}",
                  content: "Content #{i}",
                  content_review_status: :approved,
                  technical_review_status: :approved,
                  language: "en"
                },
                authorize?: false,
                tenant: site.id
              )

            # Link section to tag via SectionTag join table
            MishkaDocument.SectionTag
            |> Ash.Changeset.for_create(
              :assign,
              %{
                section_id: section.id,
                tag_id: tag.id
              },
              authorize?: false,
              tenant: site.id
            )
            |> Ash.create!()

            section.id
          end)

        # Fetch tag with paginated master_sections (limit 30 to get all)
        response =
          make_api_request(
            "#{@master_base_url}/#{tag.id}?include=master_sections&included_page[master_sections][limit]=30&included_page[master_sections][offset]=0",
            %{},
            method: :get,
            headers: [
              {"authorization", "Bearer #{token}"},
              {"x-no-tenant", "true"}
            ]
          )

        assert response.status == 200
        body = Jason.decode!(response.resp_body)

        # Verify tag data
        assert body["data"]["id"] == tag.id
        assert body["data"]["attributes"]["name"] == "Documentation Tag"

        # Verify master_sections relationship data is present
        relationship_sections = body["data"]["relationships"]["master_sections"]["data"] || []
        assert length(relationship_sections) == 25, "All 25 sections should be in relationships"

        # Verify the relationship section IDs match what we created
        relationship_section_ids = Enum.map(relationship_sections, & &1["id"])
        assert Enum.all?(section_ids, &(&1 in relationship_section_ids))

        # Verify pagination links exist
        assert body["data"]["relationships"]["master_sections"]["links"]["first"] |> is_binary()
      end

      test "tenant admin can fetch tag with paginated tenant_sections", %{
        admin_user: admin_user,
        site: site
      } do
        token = sign_in_user(admin_user)

        # Create workspace and version for sections
        workspace =
          Ash.create!(
            MishkaDocument.Workspace,
            %{
              name: "Tutorial Workspace",
              slug: "tutorial-workspace",
              status: :active,
              language: "en"
            },
            actor: admin_user,
            context: %{shared: %{admin_surface: :api}},
            tenant: site.id
          )

        workspace_version =
          Ash.create!(
            MishkaDocument.WorkspaceVersion,
            %{
              workspace_id: workspace.id,
              version_number: "1.0.0",
              status: :stable,
              published_at: DateTime.utc_now()
            },
            actor: admin_user,
            context: %{shared: %{admin_surface: :api}},
            tenant: site.id
          )

        # Create a tag
        tag = create_document_tag!(site_id: site.id, name: "Tutorial Tag", slug: "tutorial-tag")

        # Create 15 sections and link them to the tag
        section_ids =
          Enum.map(1..15, fn i ->
            section =
              Ash.create!(
                MishkaDocument.Section,
                %{
                  workspace_version_id: workspace_version.id,
                  title: "Tutorial #{i}",
                  slug: "tutorial-#{i}",
                  content: "Content #{i}",
                  content_review_status: :approved,
                  technical_review_status: :approved,
                  language: "en"
                },
                actor: admin_user,
                context: %{shared: %{admin_surface: :api}},
                tenant: site.id
              )

            # Link section to tag
            MishkaDocument.SectionTag
            |> Ash.Changeset.for_create(
              :assign,
              %{
                section_id: section.id,
                tag_id: tag.id
              },
              actor: admin_user,
              context: %{shared: %{admin_surface: :api}},
              tenant: site.id
            )
            |> Ash.create!()

            section.id
          end)

        # Fetch tag with paginated tenant_sections (limit 20 to get all)
        response =
          make_api_request(
            "#{@tenant_base_url}/#{tag.id}?include=tenant_sections&included_page[tenant_sections][limit]=20&included_page[tenant_sections][offset]=0",
            %{},
            method: :get,
            headers: [
              {"authorization", "Bearer #{token}"},
              {"x-tenant-id", site.id}
            ]
          )

        assert response.status == 200
        body = Jason.decode!(response.resp_body)

        # Verify tag data
        assert body["data"]["id"] == tag.id
        assert body["data"]["attributes"]["name"] == "Tutorial Tag"

        # Verify tenant_sections relationship data is present
        relationship_sections = body["data"]["relationships"]["tenant_sections"]["data"] || []
        assert length(relationship_sections) == 15, "All 15 sections should be in relationships"

        # Verify the relationship section IDs match what we created
        relationship_section_ids = Enum.map(relationship_sections, & &1["id"])
        assert Enum.all?(section_ids, &(&1 in relationship_section_ids))

        # Verify pagination links exist
        assert body["data"]["relationships"]["tenant_sections"]["links"]["first"] |> is_binary()
      end

      test "public user can fetch tag with paginated sections", %{site: site} do
        # Create workspace and version for sections
        workspace =
          Ash.create!(
            MishkaDocument.Workspace,
            %{
              name: "News Workspace",
              slug: "news-workspace",
              status: :active,
              language: "en"
            },
            authorize?: false,
            tenant: site.id
          )

        workspace_version =
          Ash.create!(
            MishkaDocument.WorkspaceVersion,
            %{
              workspace_id: workspace.id,
              version_number: "1.0.0",
              status: :stable,
              published_at: DateTime.utc_now()
            },
            authorize?: false,
            tenant: site.id
          )

        # Create a tag
        tag = create_document_tag!(site_id: site.id, name: "News Tag", slug: "news-tag")

        # Create 20 published sections and link them to the tag
        section_ids =
          Enum.map(1..20, fn i ->
            section =
              Ash.create!(
                MishkaDocument.Section,
                %{
                  workspace_version_id: workspace_version.id,
                  title: "News #{i}",
                  slug: "news-#{i}",
                  content: "Content #{i}",
                  content_review_status: :approved,
                  technical_review_status: :approved,
                  language: "en"
                },
                authorize?: false,
                tenant: site.id
              )

            # Link section to tag
            MishkaDocument.SectionTag
            |> Ash.Changeset.for_create(
              :assign,
              %{
                section_id: section.id,
                tag_id: tag.id
              },
              authorize?: false,
              tenant: site.id
            )
            |> Ash.create!()

            section.id
          end)

        # Fetch tag with paginated sections (no authentication, limit 25 to get all)
        response =
          make_api_request(
            "/api/json/v1/user/mishka-document/tag/#{tag.id}?include=sections&included_page[sections][limit]=25&included_page[sections][offset]=0",
            %{},
            method: :get,
            headers: [{"x-tenant-id", site.id}]
          )

        assert response.status == 200
        body = Jason.decode!(response.resp_body)

        # Verify tag data
        assert body["data"]["id"] == tag.id
        assert body["data"]["attributes"]["name"] == "News Tag"

        # Verify sections relationship data is present
        relationship_sections = body["data"]["relationships"]["sections"]["data"] || []

        assert length(relationship_sections) == 20,
               "All 20 published sections should be in relationships"

        # Verify the relationship section IDs match what we created
        relationship_section_ids = Enum.map(relationship_sections, & &1["id"])
        assert Enum.all?(section_ids, &(&1 in relationship_section_ids))

        # Verify pagination links exist
        assert body["data"]["relationships"]["sections"]["links"]["first"] |> is_binary()
      end

      test "public user only sees published sections in tag relationships", %{site: site} do
        # Create workspace and version for sections
        workspace =
          Ash.create!(
            MishkaDocument.Workspace,
            %{
              name: "Mixed Workspace",
              slug: "mixed-workspace",
              status: :active,
              language: "en"
            },
            authorize?: false,
            tenant: site.id
          )

        workspace_version =
          Ash.create!(
            MishkaDocument.WorkspaceVersion,
            %{
              workspace_id: workspace.id,
              version_number: "1.0.0",
              status: :stable,
              published_at: DateTime.utc_now()
            },
            authorize?: false,
            tenant: site.id
          )

        # Create a tag
        tag = create_document_tag!(site_id: site.id, name: "Mixed Tag", slug: "mixed-tag")

        # Create published section (approved for public viewing)
        published_section =
          Ash.create!(
            MishkaDocument.Section,
            %{
              workspace_version_id: workspace_version.id,
              title: "Published Section",
              slug: "published-section",
              content: "Content",
              content_review_status: :approved,
              technical_review_status: :approved,
              language: "en"
            },
            authorize?: false,
            tenant: site.id
          )

        # Create draft section (not approved - public users should not see it)
        draft_section =
          Ash.create!(
            MishkaDocument.Section,
            %{
              workspace_version_id: workspace_version.id,
              title: "Draft Section",
              slug: "draft-section",
              content: "Content",
              content_review_status: :pending,
              technical_review_status: :pending,
              language: "en"
            },
            authorize?: false,
            tenant: site.id
          )

        # Link both sections to tag
        for section <- [published_section, draft_section] do
          MishkaDocument.SectionTag
          |> Ash.Changeset.for_create(
            :assign,
            %{
              section_id: section.id,
              tag_id: tag.id
            },
            authorize?: false,
            tenant: site.id
          )
          |> Ash.create!()
        end

        # Fetch tag with sections as public user (must specify limit for pagination)
        response =
          make_api_request(
            "/api/json/v1/user/mishka-document/tag/#{tag.id}?include=sections&included_page[sections][limit]=100",
            %{},
            method: :get,
            headers: [{"x-tenant-id", site.id}]
          )

        assert response.status == 200
        body = Jason.decode!(response.resp_body)

        # Verify only published section is returned
        relationship_sections = body["data"]["relationships"]["sections"]["data"] || []
        relationship_section_ids = Enum.map(relationship_sections, & &1["id"])

        # Should only see published section, not draft
        assert published_section.id in relationship_section_ids
        refute draft_section.id in relationship_section_ids
      end

      test "master admin can fetch tag with language_variants", %{
        master_user: master_user,
        site: site
      } do
        token = sign_in_master(master_user)

        # Create English tag
        tag_en =
          create_document_tag!(
            site_id: site.id,
            name: "Documentation",
            slug: "documentation-en",
            language: "en"
          )

        # The first tag is the group; its translations name it.
        language_group_id = tag_en.language_group_id

        # Create Spanish variant
        tag_es =
          create_document_tag!(
            site_id: site.id,
            name: "Documentación",
            slug: "documentacion-es",
            language: "es",
            language_group_id: language_group_id
          )

        # Create French variant
        tag_fr =
          create_document_tag!(
            site_id: site.id,
            name: "Documentation",
            slug: "documentation-fr",
            language: "fr",
            language_group_id: language_group_id
          )

        # Fetch English tag with master_language_variants
        response =
          make_api_request(
            "#{@master_base_url}/#{tag_en.id}?include=master_language_variants&included_page[master_language_variants][limit]=10",
            %{},
            method: :get,
            headers: [
              {"authorization", "Bearer #{token}"},
              {"x-no-tenant", "true"}
            ]
          )

        assert response.status == 200
        body = Jason.decode!(response.resp_body)

        # Verify tag data
        assert body["data"]["id"] == tag_en.id
        assert body["data"]["attributes"]["language"] == "en"

        # Verify master_language_variants relationship includes all variants
        relationship_variants =
          body["data"]["relationships"]["master_language_variants"]["data"] || []

        variant_ids = Enum.map(relationship_variants, & &1["id"])

        # Should include all 3 tags (including self)
        assert tag_en.id in variant_ids
        assert tag_es.id in variant_ids
        assert tag_fr.id in variant_ids
        assert length(variant_ids) == 3
      end

      test "tenant admin can fetch tag with tenant_language_variants", %{
        admin_user: admin_user,
        site: site
      } do
        token = sign_in_user(admin_user)

        # Create English tag
        tag_en =
          create_document_tag!(
            site_id: site.id,
            name: "Tutorial",
            slug: "tutorial-en",
            language: "en"
          )

        # The first tag is the group; its translations name it.
        language_group_id = tag_en.language_group_id

        # Create German variant
        tag_de =
          create_document_tag!(
            site_id: site.id,
            name: "Tutorial",
            slug: "tutorial-de",
            language: "de",
            language_group_id: language_group_id
          )

        # Fetch English tag with tenant_language_variants
        response =
          make_api_request(
            "#{@tenant_base_url}/#{tag_en.id}?include=tenant_language_variants&included_page[tenant_language_variants][limit]=10",
            %{},
            method: :get,
            headers: [
              {"authorization", "Bearer #{token}"},
              {"x-tenant-id", site.id}
            ]
          )

        assert response.status == 200
        body = Jason.decode!(response.resp_body)

        # Verify tag data
        assert body["data"]["id"] == tag_en.id
        assert body["data"]["attributes"]["language"] == "en"

        # Verify tenant_language_variants relationship includes all variants
        relationship_variants =
          body["data"]["relationships"]["tenant_language_variants"]["data"] || []

        variant_ids = Enum.map(relationship_variants, & &1["id"])

        # Should include both tags
        assert tag_en.id in variant_ids
        assert tag_de.id in variant_ids
        assert length(variant_ids) == 2
      end

      test "public user can fetch tag with language_variants", %{site: site} do
        # Create English tag
        tag_en =
          create_document_tag!(
            site_id: site.id,
            name: "Getting Started",
            slug: "getting-started-en",
            language: "en"
          )

        # The first tag is the group; its translations name it.
        language_group_id = tag_en.language_group_id

        # Create Japanese variant
        tag_ja =
          create_document_tag!(
            site_id: site.id,
            name: "はじめに",
            slug: "getting-started-ja",
            language: "ja",
            language_group_id: language_group_id
          )

        # Fetch English tag with language_variants (no authentication)
        response =
          make_api_request(
            "/api/json/v1/user/mishka-document/tag/#{tag_en.id}?include=language_variants&included_page[language_variants][limit]=10",
            %{},
            method: :get,
            headers: [{"x-tenant-id", site.id}]
          )

        assert response.status == 200
        body = Jason.decode!(response.resp_body)

        # Verify tag data
        assert body["data"]["id"] == tag_en.id
        assert body["data"]["attributes"]["language"] == "en"

        # Verify language_variants relationship includes all variants
        relationship_variants = body["data"]["relationships"]["language_variants"]["data"] || []
        variant_ids = Enum.map(relationship_variants, & &1["id"])

        # Should include both tags
        assert tag_en.id in variant_ids
        assert tag_ja.id in variant_ids
        assert length(variant_ids) == 2
      end
    end

    describe "Multi-tenancy security and isolation" do
      test "tenant admin CANNOT create tag for another site", %{
        site: site,
        site2: site2,
        admin_user: admin_user
      } do
        token = sign_in_user(admin_user)

        # Try to create tag with site2's ID (should fail or be ignored)
        response =
          make_api_request(
            @tenant_base_url,
            %{
              "type" => "tag",
              "attributes" => %{
                "name" => "Cross-Site Tag",
                "slug" => "cross-site",
                "site_id" => site2.id
              }
            },
            method: :post,
            headers: [
              {"authorization", "Bearer #{token}"},
              {"x-tenant-id", site.id}
            ]
          )

        assert response.status in [400, 403, 422]
      end

      test "tenant admin CANNOT read tags from another site", %{
        site: site,
        site2: site2,
        admin_user: admin_user
      } do
        # Create tag in site2
        site2_tag = create_document_tag!(site_id: site2.id, name: "Site2 Tag", slug: "site2-tag")

        token = sign_in_user(admin_user)

        # Try to read site2's tag with site tenant context
        response =
          make_api_request(
            "#{@tenant_base_url}/#{site2_tag.id}",
            %{},
            method: :get,
            headers: [
              {"authorization", "Bearer #{token}"},
              {"x-tenant-id", site.id}
            ]
          )

        # Should not be able to read it
        assert response.status == 404
      end

      test "tenant admin CANNOT update tags from another site", %{
        site: site,
        site2: site2,
        admin_user: admin_user
      } do
        # Create tag in site2
        site2_tag = create_document_tag!(site_id: site2.id, name: "Site2 Tag", slug: "site2-tag")

        token = sign_in_user(admin_user)

        # Try to update site2's tag
        response =
          make_api_request(
            "#{@tenant_base_url}/#{site2_tag.id}",
            %{
              "type" => "tag",
              "attributes" => %{
                "name" => "Hacked Name"
              }
            },
            method: :patch,
            headers: [
              {"authorization", "Bearer #{token}"},
              {"x-tenant-id", site.id}
            ]
          )

        # Should not be able to update it
        assert response.status in [404, 403]

        # Verify tag was not modified
        unchanged_tag =
          Ash.get!(MishkaDocument.Tag, site2_tag.id, tenant: site2.id, authorize?: false)

        assert unchanged_tag.name == "Site2 Tag"
      end

      test "tenant admin CANNOT delete tags from another site", %{
        site: site,
        site2: site2,
        admin_user: admin_user
      } do
        # Create tag in site2
        site2_tag = create_document_tag!(site_id: site2.id, name: "Site2 Tag", slug: "site2-tag")

        token = sign_in_user(admin_user)

        # Try to delete site2's tag
        response =
          make_api_request(
            "#{@tenant_base_url}/#{site2_tag.id}/archive",
            %{},
            method: :delete,
            headers: [
              {"authorization", "Bearer #{token}"},
              {"x-tenant-id", site.id}
            ]
          )

        # Should not be able to delete it
        assert response.status in [404, 403]

        # Verify tag still exists
        still_exists =
          Ash.get!(MishkaDocument.Tag, site2_tag.id, tenant: site2.id, authorize?: false)

        assert still_exists.id == site2_tag.id
        assert is_nil(still_exists.archived_at)
      end

      test "master admin CAN create tags for any site", %{
        site: site,
        site2: site2,
        master_user: master_user
      } do
        token = sign_in_master(master_user)

        # Create tag for site
        response1 =
          make_api_request(
            @master_base_url,
            %{
              "type" => "tag",
              "attributes" => %{
                "name" => "Site1 Tag",
                "slug" => "site1-tag",
                "site_id" => site.id
              }
            },
            method: :post,
            headers: [
              {"authorization", "Bearer #{token}"},
              {"x-no-tenant", "true"}
            ]
          )

        assert response1.status in [200, 201]
        body1 = Jason.decode!(response1.resp_body)
        assert body1["data"]["attributes"]["site_id"] == site.id

        # Create tag for site2
        response2 =
          make_api_request(
            @master_base_url,
            %{
              "type" => "tag",
              "attributes" => %{
                "name" => "Site2 Tag",
                "slug" => "site2-tag",
                "site_id" => site2.id
              }
            },
            method: :post,
            headers: [
              {"authorization", "Bearer #{token}"},
              {"x-no-tenant", "true"}
            ]
          )

        assert response2.status in [200, 201]
        body2 = Jason.decode!(response2.resp_body)
        assert body2["data"]["attributes"]["site_id"] == site2.id
      end

      test "master admin CAN read tags from any site", %{
        site: site,
        site2: site2,
        master_user: master_user
      } do
        # Create tags in different sites
        site1_tag = create_document_tag!(site_id: site.id, name: "Site1 Tag", slug: "site1-tag")
        site2_tag = create_document_tag!(site_id: site2.id, name: "Site2 Tag", slug: "site2-tag")

        token = sign_in_master(master_user)

        # Read tag from site
        response1 =
          make_api_request(
            "#{@master_base_url}/#{site1_tag.id}",
            %{},
            method: :get,
            headers: [
              {"authorization", "Bearer #{token}"},
              {"x-no-tenant", "true"}
            ]
          )

        assert response1.status == 200
        body1 = Jason.decode!(response1.resp_body)
        assert body1["data"]["id"] == site1_tag.id

        # Read tag from site2
        response2 =
          make_api_request(
            "#{@master_base_url}/#{site2_tag.id}",
            %{},
            method: :get,
            headers: [
              {"authorization", "Bearer #{token}"},
              {"x-no-tenant", "true"}
            ]
          )

        assert response2.status == 200
        body2 = Jason.decode!(response2.resp_body)
        assert body2["data"]["id"] == site2_tag.id
      end

      test "master admin CAN update tags from any site", %{
        site2: site2,
        master_user: master_user
      } do
        # Create tag in site2
        site2_tag = create_document_tag!(site_id: site2.id, name: "Original", slug: "original")

        token = sign_in_master(master_user)

        # Update tag from site2
        response =
          make_api_request(
            "#{@master_base_url}/#{site2_tag.id}",
            %{
              "type" => "tag",
              "attributes" => %{
                "name" => "Updated by Master"
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
        assert body["data"]["attributes"]["name"] == "Updated by Master"

        # Verify it was actually updated
        updated_tag =
          Ash.get!(MishkaDocument.Tag, site2_tag.id, tenant: site2.id, authorize?: false)

        assert updated_tag.name == "Updated by Master"
      end

      test "master admin CAN delete tags from any site", %{
        site2: site2,
        master_user: master_user
      } do
        # Create tag in site2
        site2_tag = create_document_tag!(site_id: site2.id, name: "Tag", slug: "tag")

        token = sign_in_master(master_user)

        # Delete tag from site2
        response =
          make_api_request(
            "#{@master_base_url}/#{site2_tag.id}/archive",
            %{},
            method: :delete,
            headers: [
              {"authorization", "Bearer #{token}"},
              {"x-no-tenant", "true"}
            ]
          )

        assert response.status in [200, 204]

        # Verify it was archived
        archived_tag =
          Ash.get!(MishkaDocument.Tag, site2_tag.id,
            action: :master_get,
            authorize?: false
          )

        assert %DateTime{} = archived_tag.archived_at
      end
    end
  end
end
