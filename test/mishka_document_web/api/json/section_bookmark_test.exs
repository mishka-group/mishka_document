defmodule MishkaDocumentWeb.Api.Json.SectionBookmarkTest do
  @moduledoc """
  Comprehensive tests for SectionBookmark JSON API endpoints.

  Tests user bookmark functionality for documentation sections.
  """
  use MishkaDocument.ConnCase
  import MishkaDocument.Test.Factory

  @moduletag :unit
  @moduletag :capture_log

  if Code.ensure_loaded?(MishkaDocument) do
    @password "Password123!"
    @api_user_path "/api/json/v1/auth/user"
    @api_bookmark_path "/api/json/v1/user/mishka-document/section-bookmark"
    @api_my_bookmarks_path "/api/json/v1/user/mishka-document/section-bookmark/my-bookmarks"

    setup do
      MishkaCmsCore.Runtime.States.SiteState.clear()
      :ok = Swoosh.TestAssertions.set_swoosh_global()

      Application.put_env(:ash_json_api, MishkaDocument, router: MishkaDocument.TestRouter)

      # Create site for testing
      site = create_site!(name: "localhost", host: "localhost", active: true, priority: 50)

      MishkaCmsCore.Runtime.States.SiteState.save(%{
        id: site.id,
        name: site.name,
        host: site.host,
        priority: site.priority,
        active: site.active
      })

      # Create users for testing
      user1 =
        create_user!(
          email: "user1@example.com",
          password: @password,
          password_confirmation: @password,
          site_id: site.id
        )

      user2 =
        create_user!(
          email: "user2@example.com",
          password: @password,
          password_confirmation: @password,
          site_id: site.id
        )

      on_exit(fn ->
        MishkaCmsCore.Runtime.States.SiteState.delete(site.id)
        MishkaCmsCore.Runtime.States.SiteState.clear()
      end)

      {:ok, site: site, user1: user1, user2: user2}
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

    describe "POST /section-bookmark - Create bookmark" do
      test "user can bookmark a documentation section", %{site: site, user1: user1} do
        token = sign_in_user(user1)

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
            title: "Getting Started",
            slug: "getting-started",
            content: "Welcome to our docs",
            content_review_status: :approved,
            technical_review_status: :approved
          )

        response =
          make_api_request(
            @api_bookmark_path,
            %{
              "type" => "section_bookmark",
              "attributes" => %{
                "section_id" => section.id
              }
            },
            method: :post,
            headers: [{"authorization", "Bearer #{token}"}]
          )

        assert response.status == 201
        body = Jason.decode!(response.resp_body)
        assert body["data"]["id"]
        assert body["data"]["type"] == "section_bookmark"
      end

      test "bookmark includes timestamps", %{site: site, user1: user1} do
        token = sign_in_user(user1)

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
            @api_bookmark_path,
            %{
              "type" => "section_bookmark",
              "attributes" => %{
                "section_id" => section.id
              }
            },
            method: :post,
            headers: [{"authorization", "Bearer #{token}"}]
          )

        assert response.status == 201
        body = Jason.decode!(response.resp_body)
        assert body["data"]["attributes"]["inserted_at"]
        assert body["data"]["attributes"]["updated_at"]
      end

      test "cannot bookmark without authentication", %{site: site} do
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
            title: "API Reference",
            slug: "api-reference",
            content: "API documentation",
            content_review_status: :approved,
            technical_review_status: :approved
          )

        response =
          make_api_request(
            @api_bookmark_path,
            %{
              "type" => "section_bookmark",
              "attributes" => %{
                "section_id" => section.id
              }
            },
            method: :post,
            headers: []
          )

        assert response.status in [401, 403]
      end

      test "cannot bookmark non-existent section", %{user1: user1} do
        token = sign_in_user(user1)
        fake_section_id = Ash.UUID.generate()

        response =
          make_api_request(
            @api_bookmark_path,
            %{
              "type" => "section_bookmark",
              "attributes" => %{
                "section_id" => fake_section_id
              }
            },
            method: :post,
            headers: [{"authorization", "Bearer #{token}"}]
          )

        assert response.status in [400, 404, 422]
      end

      test "user CANNOT bookmark section from different site (tenant isolation)", %{
        user1: user1
      } do
        token = sign_in_user(user1)

        # Create a second site
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
            slug: "site2-section",
            content: "Content from site2",
            content_review_status: :approved,
            technical_review_status: :approved
          )

        # User from site1 tries to bookmark section from site2
        response =
          make_api_request(
            @api_bookmark_path,
            %{
              "type" => "section_bookmark",
              "attributes" => %{
                "section_id" => section2.id
              }
            },
            method: :post,
            headers: [
              {"authorization", "Bearer #{token}"},
              {"content-type", "application/vnd.api+json"}
            ]
          )

        # Should fail - user cannot bookmark sections from other sites
        assert response.status in [400, 403, 422]
      end
    end

    describe "POST /section-bookmark - Upsert behavior" do
      test "bookmarking same section twice returns existing bookmark", %{site: site, user1: user1} do
        token = sign_in_user(user1)

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
            title: "Tutorial",
            slug: "tutorial",
            content: "Step by step guide",
            content_review_status: :approved,
            technical_review_status: :approved
          )

        # First bookmark
        response1 =
          make_api_request(
            @api_bookmark_path,
            %{
              "type" => "section_bookmark",
              "attributes" => %{
                "section_id" => section.id
              }
            },
            method: :post,
            headers: [{"authorization", "Bearer #{token}"}]
          )

        assert response1.status == 201
        body1 = Jason.decode!(response1.resp_body)
        _bookmark_id_1 = body1["data"]["id"]

        # Second bookmark of same section - should upsert
        response2 =
          make_api_request(
            @api_bookmark_path,
            %{
              "type" => "section_bookmark",
              "attributes" => %{
                "section_id" => section.id
              }
            },
            method: :post,
            headers: [{"authorization", "Bearer #{token}"}]
          )

        # Should return existing or create new depending on upsert timing
        assert response2.status in [200, 201]
        body2 = Jason.decode!(response2.resp_body)
        assert body2["data"]["id"]

        # Verify only one bookmark exists for this user+section
        my_bookmarks =
          make_api_request(
            @api_my_bookmarks_path,
            %{},
            method: :get,
            headers: [{"authorization", "Bearer #{token}"}]
          )

        assert my_bookmarks.status == 200
        bookmarks_body = Jason.decode!(my_bookmarks.resp_body)
        assert length(bookmarks_body["data"]) == 1
      end
    end

    describe "GET /my-bookmarks - List user's bookmarks" do
      test "user can list their bookmarks", %{site: site, user1: user1} do
        token = sign_in_user(user1)

        workspace = create_workspace!(site_id: site.id, skip_version: true, status: :active)

        ws_version =
          create_workspace_version!(
            workspace_id: workspace.id,
            site_id: site.id,
            version_number: "1.0.0",
            status: :stable,
            published_at: DateTime.utc_now()
          )

        # Create multiple sections and bookmark them
        section1 =
          create_section!(
            workspace_version_id: ws_version.id,
            site_id: site.id,
            title: "Section 1",
            slug: "section-1",
            content: "Content 1",
            content_review_status: :approved,
            technical_review_status: :approved
          )

        section2 =
          create_section!(
            workspace_version_id: ws_version.id,
            site_id: site.id,
            title: "Section 2",
            slug: "section-2",
            content: "Content 2",
            content_review_status: :approved,
            technical_review_status: :approved
          )

        section3 =
          create_section!(
            workspace_version_id: ws_version.id,
            site_id: site.id,
            title: "Section 3",
            slug: "section-3",
            content: "Content 3",
            content_review_status: :approved,
            technical_review_status: :approved
          )

        # Create bookmarks
        MishkaDocument.SectionBookmark
        |> Ash.Changeset.for_create(:create, %{section_id: section1.id}, actor: user1)
        |> Ash.create!()

        MishkaDocument.SectionBookmark
        |> Ash.Changeset.for_create(:create, %{section_id: section2.id}, actor: user1)
        |> Ash.create!()

        MishkaDocument.SectionBookmark
        |> Ash.Changeset.for_create(:create, %{section_id: section3.id}, actor: user1)
        |> Ash.create!()

        response =
          make_api_request(
            @api_my_bookmarks_path,
            %{},
            method: :get,
            headers: [{"authorization", "Bearer #{token}"}]
          )

        assert response.status == 200
        body = Jason.decode!(response.resp_body)
        assert length(body["data"]) == 3
      end

      test "user only sees their own bookmarks, not other users' bookmarks", %{
        site: site,
        user1: user1,
        user2: user2
      } do
        token1 = sign_in_user(user1)
        token2 = sign_in_user(user2)

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
            title: "User 1 Section",
            slug: "user1-section",
            content: "Content for user 1",
            content_review_status: :approved,
            technical_review_status: :approved
          )

        section2 =
          create_section!(
            workspace_version_id: ws_version.id,
            site_id: site.id,
            title: "User 2 Section",
            slug: "user2-section",
            content: "Content for user 2",
            content_review_status: :approved,
            technical_review_status: :approved
          )

        # User 1 bookmarks section1
        MishkaDocument.SectionBookmark
        |> Ash.Changeset.for_create(:create, %{section_id: section1.id}, actor: user1)
        |> Ash.create!()

        # User 2 bookmarks section2
        MishkaDocument.SectionBookmark
        |> Ash.Changeset.for_create(:create, %{section_id: section2.id}, actor: user2)
        |> Ash.create!()

        # User 1 fetches their bookmarks
        response1 =
          make_api_request(
            @api_my_bookmarks_path,
            %{},
            method: :get,
            headers: [{"authorization", "Bearer #{token1}"}]
          )

        assert response1.status == 200
        body1 = Jason.decode!(response1.resp_body)
        assert length(body1["data"]) == 1

        # User 2 fetches their bookmarks
        response2 =
          make_api_request(
            @api_my_bookmarks_path,
            %{},
            method: :get,
            headers: [{"authorization", "Bearer #{token2}"}]
          )

        assert response2.status == 200
        body2 = Jason.decode!(response2.resp_body)
        assert length(body2["data"]) == 1
      end

      test "unauthenticated users cannot list bookmarks" do
        response =
          make_api_request(
            @api_my_bookmarks_path,
            %{},
            method: :get,
            headers: []
          )

        assert response.status in [401, 403]
      end

      test "empty list when user has no bookmarks", %{user1: user1} do
        token = sign_in_user(user1)

        response =
          make_api_request(
            @api_my_bookmarks_path,
            %{},
            method: :get,
            headers: [{"authorization", "Bearer #{token}"}]
          )

        assert response.status == 200
        body = Jason.decode!(response.resp_body)
        assert body["data"] == []
      end
    end

    describe "DELETE /section-bookmark - Remove bookmark" do
      test "user can remove their own bookmark", %{site: site, user1: user1} do
        token = sign_in_user(user1)

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
            title: "To Remove",
            slug: "to-remove",
            content: "Will be removed",
            content_review_status: :approved,
            technical_review_status: :approved
          )

        bookmark =
          MishkaDocument.SectionBookmark
          |> Ash.Changeset.for_create(:create, %{section_id: section.id}, actor: user1)
          |> Ash.create!()

        # Verify bookmark exists
        list_response =
          make_api_request(
            @api_my_bookmarks_path,
            %{},
            method: :get,
            headers: [{"authorization", "Bearer #{token}"}]
          )

        assert list_response.status == 200
        list_body = Jason.decode!(list_response.resp_body)
        assert length(list_body["data"]) == 1

        # Remove bookmark
        remove_response =
          make_api_request(
            "#{@api_bookmark_path}/#{bookmark.id}",
            %{
              "type" => "section_bookmark",
              "attributes" => %{
                "id" => bookmark.id
              }
            },
            method: :delete,
            headers: [{"authorization", "Bearer #{token}"}]
          )

        assert remove_response.status in [200, 204]

        # Verify bookmark is removed
        verify_response =
          make_api_request(
            @api_my_bookmarks_path,
            %{},
            method: :get,
            headers: [{"authorization", "Bearer #{token}"}]
          )

        assert verify_response.status == 200
        verify_body = Jason.decode!(verify_response.resp_body)
        assert verify_body["data"] == []
      end

      test "user cannot remove another user's bookmark", %{site: site, user1: user1, user2: user2} do
        token1 = sign_in_user(user1)
        token2 = sign_in_user(user2)

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
            title: "User 1 Bookmark",
            slug: "user1-bookmark",
            content: "User 1's content",
            content_review_status: :approved,
            technical_review_status: :approved
          )

        # User 1 creates bookmark
        bookmark =
          MishkaDocument.SectionBookmark
          |> Ash.Changeset.for_create(:create, %{section_id: section.id}, actor: user1)
          |> Ash.create!()

        # User 2 tries to remove User 1's bookmark
        response =
          make_api_request(
            "#{@api_bookmark_path}/#{bookmark.id}",
            %{
              "type" => "section_bookmark",
              "attributes" => %{
                "id" => bookmark.id
              }
            },
            method: :delete,
            headers: [{"authorization", "Bearer #{token2}"}]
          )

        assert response.status in [403, 404]

        # Verify bookmark still exists for user1
        verify_response =
          make_api_request(
            @api_my_bookmarks_path,
            %{},
            method: :get,
            headers: [{"authorization", "Bearer #{token1}"}]
          )

        assert verify_response.status == 200
        verify_body = Jason.decode!(verify_response.resp_body)
        assert length(verify_body["data"]) == 1
      end

      test "cannot remove bookmark without authentication", %{site: site, user1: user1} do
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
            title: "Protected Bookmark",
            slug: "protected",
            content: "Protected content",
            content_review_status: :approved,
            technical_review_status: :approved
          )

        bookmark =
          MishkaDocument.SectionBookmark
          |> Ash.Changeset.for_create(:create, %{section_id: section.id}, actor: user1)
          |> Ash.create!()

        response =
          make_api_request(
            "#{@api_bookmark_path}/#{bookmark.id}",
            %{
              "type" => "section_bookmark",
              "attributes" => %{
                "id" => bookmark.id
              }
            },
            method: :delete,
            headers: []
          )

        assert response.status in [401, 403]
      end
    end

    describe "Multiple users bookmarking same section" do
      test "multiple users can bookmark the same section independently", %{
        site: site,
        user1: user1,
        user2: user2
      } do
        token1 = sign_in_user(user1)
        token2 = sign_in_user(user2)

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
            title: "Popular Section",
            slug: "popular",
            content: "Everyone bookmarks this",
            content_review_status: :approved,
            technical_review_status: :approved
          )

        # User 1 bookmarks
        response1 =
          make_api_request(
            @api_bookmark_path,
            %{
              "type" => "section_bookmark",
              "attributes" => %{
                "section_id" => section.id
              }
            },
            method: :post,
            headers: [{"authorization", "Bearer #{token1}"}]
          )

        assert response1.status == 201

        # User 2 bookmarks same section
        response2 =
          make_api_request(
            @api_bookmark_path,
            %{
              "type" => "section_bookmark",
              "attributes" => %{
                "section_id" => section.id
              }
            },
            method: :post,
            headers: [{"authorization", "Bearer #{token2}"}]
          )

        assert response2.status == 201

        # Verify both users have the bookmark
        user1_bookmarks =
          make_api_request(
            @api_my_bookmarks_path,
            %{},
            method: :get,
            headers: [{"authorization", "Bearer #{token1}"}]
          )

        assert user1_bookmarks.status == 200
        user1_body = Jason.decode!(user1_bookmarks.resp_body)
        assert length(user1_body["data"]) == 1

        user2_bookmarks =
          make_api_request(
            @api_my_bookmarks_path,
            %{},
            method: :get,
            headers: [{"authorization", "Bearer #{token2}"}]
          )

        assert user2_bookmarks.status == 200
        user2_body = Jason.decode!(user2_bookmarks.resp_body)
        assert length(user2_body["data"]) == 1
      end
    end

    describe "Section approval filtering" do
      test "my_bookmarks only returns approved sections", %{site: site, user1: user1} do
        token = sign_in_user(user1)

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
        approved_section =
          create_section!(
            workspace_version_id: ws_version.id,
            site_id: site.id,
            title: "Approved Section",
            slug: "approved",
            content: "Approved content",
            content_review_status: :approved,
            technical_review_status: :approved
          )

        # Create pending section
        pending_section =
          create_section!(
            workspace_version_id: ws_version.id,
            site_id: site.id,
            title: "Pending Section",
            slug: "pending",
            content: "Pending content",
            content_review_status: :pending,
            technical_review_status: :approved
          )

        # Bookmark both sections
        MishkaDocument.SectionBookmark
        |> Ash.Changeset.for_create(:create, %{section_id: approved_section.id}, actor: user1)
        |> Ash.create!()

        MishkaDocument.SectionBookmark
        |> Ash.Changeset.for_create(:create, %{section_id: pending_section.id}, actor: user1)
        |> Ash.create!()

        # Fetch my bookmarks - should only return approved section
        response =
          make_api_request(
            @api_my_bookmarks_path,
            %{},
            method: :get,
            headers: [{"authorization", "Bearer #{token}"}]
          )

        assert response.status == 200
        body = Jason.decode!(response.resp_body)
        # Should only return 1 bookmark (the approved one)
        assert length(body["data"]) == 1
      end
    end

    describe "Pagination" do
      test "supports pagination for my_bookmarks", %{site: site, user1: user1} do
        token = sign_in_user(user1)

        workspace = create_workspace!(site_id: site.id, skip_version: true, status: :active)

        ws_version =
          create_workspace_version!(
            workspace_id: workspace.id,
            site_id: site.id,
            version_number: "1.0.0",
            status: :stable,
            published_at: DateTime.utc_now()
          )

        # Create 25 sections and bookmark them
        for i <- 1..25 do
          section =
            create_section!(
              workspace_version_id: ws_version.id,
              site_id: site.id,
              title: "Section #{i}",
              slug: "section-#{i}",
              content: "Content #{i}",
              content_review_status: :approved,
              technical_review_status: :approved
            )

          MishkaDocument.SectionBookmark
          |> Ash.Changeset.for_create(:create, %{section_id: section.id}, actor: user1)
          |> Ash.create!()
        end

        # First page (default limit is 20)
        response1 =
          make_api_request(
            @api_my_bookmarks_path,
            %{},
            method: :get,
            headers: [{"authorization", "Bearer #{token}"}]
          )

        assert response1.status == 200
        body1 = Jason.decode!(response1.resp_body)
        assert length(body1["data"]) == 20

        # Second page with limit
        response2 =
          make_api_request(
            "#{@api_my_bookmarks_path}?page[limit]=10&page[offset]=20",
            %{},
            method: :get,
            headers: [{"authorization", "Bearer #{token}"}]
          )

        assert response2.status == 200
        body2 = Jason.decode!(response2.resp_body)
        assert length(body2["data"]) == 5
      end
    end
  end
end
