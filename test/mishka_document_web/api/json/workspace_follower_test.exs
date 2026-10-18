# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_document/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaDocumentWeb.Api.Json.WorkspaceFollowerTest do
  @moduledoc """
  Comprehensive tests for WorkspaceFollower JSON API endpoints.
  """
  use MishkaDocument.ConnCase
  import MishkaDocument.Test.Factory

  @moduletag :unit
  @moduletag :capture_log

  if Code.ensure_loaded?(MishkaDocument) do
    @password "Password123!"
    @api_user_path "/api/json/v1/auth/user"
    @api_workspace_follow_path "/api/json/v1/user/mishka-document/workspace-follow"
    @api_my_following_path "/api/json/v1/user/mishka-document/workspace-follow/my-following"

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

    describe "POST /workspace-follow - Create follow" do
      test "user can follow a workspace", %{site: site, user1: user1} do
        token = sign_in_user(user1)
        workspace = create_workspace!(site_id: site.id, status: :active)

        response =
          make_api_request(
            @api_workspace_follow_path,
            %{
              "type" => "workspace_follower",
              "attributes" => %{
                "workspace_id" => workspace.id
              }
            },
            method: :post,
            headers: [{"authorization", "Bearer #{token}"}]
          )

        assert response.status == 201
        body = Jason.decode!(response.resp_body)
        assert body["data"]["id"]
        assert body["data"]["type"] == "workspace_follower"
        assert body["data"]["attributes"]["workspace_id"] == workspace.id
      end

      test "follow includes timestamps and notification settings", %{site: site, user1: user1} do
        token = sign_in_user(user1)
        workspace = create_workspace!(site_id: site.id, status: :active)

        response =
          make_api_request(
            @api_workspace_follow_path,
            %{
              "type" => "workspace_follower",
              "attributes" => %{
                "workspace_id" => workspace.id
              }
            },
            method: :post,
            headers: [{"authorization", "Bearer #{token}"}]
          )

        assert response.status == 201
        body = Jason.decode!(response.resp_body)

        assert {:ok, %DateTime{}, _offset} =
                 DateTime.from_iso8601(body["data"]["attributes"]["followed_at"])

        assert body["data"]["attributes"]["notification_enabled"] == true

        assert {:ok, %DateTime{}, _offset} =
                 DateTime.from_iso8601(body["data"]["attributes"]["inserted_at"])

        assert {:ok, %DateTime{}, _offset} =
                 DateTime.from_iso8601(body["data"]["attributes"]["updated_at"])
      end

      test "user can follow with notifications disabled", %{site: site, user1: user1} do
        token = sign_in_user(user1)
        workspace = create_workspace!(site_id: site.id, status: :active)

        response =
          make_api_request(
            @api_workspace_follow_path,
            %{
              "type" => "workspace_follower",
              "attributes" => %{
                "workspace_id" => workspace.id,
                "notification_enabled" => false
              }
            },
            method: :post,
            headers: [{"authorization", "Bearer #{token}"}]
          )

        assert response.status == 201
        body = Jason.decode!(response.resp_body)
        assert body["data"]["attributes"]["notification_enabled"] == false
      end

      test "unauthenticated user cannot follow workspace", %{site: site} do
        workspace = create_workspace!(site_id: site.id, status: :active)

        response =
          make_api_request(
            @api_workspace_follow_path,
            %{
              "type" => "workspace_follower",
              "attributes" => %{
                "workspace_id" => workspace.id
              }
            },
            method: :post
          )

        # Returns 403 because actor_present() check fails
        assert response.status == 403
      end

      test "user cannot follow a workspace of another site", %{user1: user1} do
        token = sign_in_user(user1)
        other_site = create_site!(name: "site-b", host: "b.localhost", active: true)
        workspace = create_workspace!(site_id: other_site.id, status: :active)

        response =
          make_api_request(
            @api_workspace_follow_path,
            %{
              "type" => "workspace_follower",
              "attributes" => %{
                "workspace_id" => workspace.id
              }
            },
            method: :post,
            headers: [{"authorization", "Bearer #{token}"}]
          )

        assert response.status == 400
        assert Ash.read!(MishkaDocument.WorkspaceFollower, authorize?: false) == []
      end
    end

    describe "POST /workspace-follow - Upsert behavior" do
      test "following same workspace twice returns existing follow", %{site: site, user1: user1} do
        token = sign_in_user(user1)
        workspace = create_workspace!(site_id: site.id, status: :active)

        # First follow
        response1 =
          make_api_request(
            @api_workspace_follow_path,
            %{
              "type" => "workspace_follower",
              "attributes" => %{
                "workspace_id" => workspace.id
              }
            },
            method: :post,
            headers: [{"authorization", "Bearer #{token}"}]
          )

        assert response1.status == 201
        body1 = Jason.decode!(response1.resp_body)
        assert body1["data"]["id"]

        # Second follow of same workspace - should upsert
        response2 =
          make_api_request(
            @api_workspace_follow_path,
            %{
              "type" => "workspace_follower",
              "attributes" => %{
                "workspace_id" => workspace.id
              }
            },
            method: :post,
            headers: [{"authorization", "Bearer #{token}"}]
          )

        # Upsert may return 200 or 201 depending on implementation
        assert response2.status in [200, 201]
        body2 = Jason.decode!(response2.resp_body)
        assert body2["data"]["id"]
      end
    end

    describe "GET /my-following - List user's following" do
      test "user can list workspaces they follow", %{site: site, user1: user1} do
        token = sign_in_user(user1)

        # Create workspaces and follow them
        workspace1 = create_workspace!(site_id: site.id, status: :active, name: "Workspace 1")
        workspace2 = create_workspace!(site_id: site.id, status: :active, name: "Workspace 2")
        workspace3 = create_workspace!(site_id: site.id, status: :active, name: "Workspace 3")

        create_workspace_follower!(workspace_id: workspace1.id, follower_user_id: user1.id)
        create_workspace_follower!(workspace_id: workspace2.id, follower_user_id: user1.id)
        create_workspace_follower!(workspace_id: workspace3.id, follower_user_id: user1.id)

        response =
          make_api_request(
            @api_my_following_path,
            %{},
            method: :get,
            headers: [{"authorization", "Bearer #{token}"}]
          )

        assert response.status == 200
        body = Jason.decode!(response.resp_body)
        assert length(body["data"]) == 3
      end

      test "user only sees their own following, not other users' following", %{
        site: site,
        user1: user1,
        user2: user2
      } do
        token = sign_in_user(user1)

        workspace1 = create_workspace!(site_id: site.id, status: :active)
        workspace2 = create_workspace!(site_id: site.id, status: :active)

        # User1 follows workspace1
        create_workspace_follower!(workspace_id: workspace1.id, follower_user_id: user1.id)

        # User2 follows workspace2
        create_workspace_follower!(workspace_id: workspace2.id, follower_user_id: user2.id)

        response =
          make_api_request(
            @api_my_following_path,
            %{},
            method: :get,
            headers: [{"authorization", "Bearer #{token}"}]
          )

        assert response.status == 200
        body = Jason.decode!(response.resp_body)
        assert length(body["data"]) == 1
      end

      test "returns empty list when user follows no workspaces", %{user1: user1} do
        token = sign_in_user(user1)

        response =
          make_api_request(
            @api_my_following_path,
            %{},
            method: :get,
            headers: [{"authorization", "Bearer #{token}"}]
          )

        assert response.status == 200
        body = Jason.decode!(response.resp_body)
        assert body["data"] == []
      end

      test "supports pagination", %{site: site, user1: user1} do
        token = sign_in_user(user1)

        # Create 25 workspaces and follow them
        for i <- 1..25 do
          workspace =
            create_workspace!(site_id: site.id, status: :active, name: "Workspace #{i}")

          create_workspace_follower!(workspace_id: workspace.id, follower_user_id: user1.id)
        end

        # Request first page with limit 10
        response =
          make_api_request(
            "#{@api_my_following_path}?page[limit]=10",
            %{},
            method: :get,
            headers: [{"authorization", "Bearer #{token}"}]
          )

        assert response.status == 200
        body = Jason.decode!(response.resp_body)
        assert length(body["data"]) == 10
      end

      test "unauthenticated user cannot list following", %{} do
        response =
          make_api_request(
            @api_my_following_path,
            %{},
            method: :get
          )

        # Returns 403 because authorization fails without actor
        assert response.status == 403
      end

      test "only shows active workspaces in my_following", %{site: site, user1: user1} do
        token = sign_in_user(user1)

        # Create active and draft workspaces
        active_workspace =
          create_workspace!(site_id: site.id, status: :active, name: "Active Workspace")

        draft_workspace =
          create_workspace!(site_id: site.id, status: :draft, name: "Draft Workspace")

        # Follow both workspaces
        create_workspace_follower!(workspace_id: active_workspace.id, follower_user_id: user1.id)
        create_workspace_follower!(workspace_id: draft_workspace.id, follower_user_id: user1.id)

        response =
          make_api_request(
            @api_my_following_path,
            %{},
            method: :get,
            headers: [{"authorization", "Bearer #{token}"}]
          )

        assert response.status == 200
        body = Jason.decode!(response.resp_body)

        # Should only see the active workspace
        assert length(body["data"]) == 1
        workspace_ids = Enum.map(body["data"], & &1["attributes"]["workspace_id"])
        assert active_workspace.id in workspace_ids
        refute draft_workspace.id in workspace_ids
      end
    end

    describe "PATCH /workspace-follow/:id - Toggle notifications" do
      test "user can enable notifications for a follow", %{site: site, user1: user1} do
        token = sign_in_user(user1)
        workspace = create_workspace!(site_id: site.id, status: :active)

        # Create follow with notifications disabled
        follow =
          create_workspace_follower!(
            workspace_id: workspace.id,
            follower_user_id: user1.id,
            notification_enabled: false
          )

        response =
          make_api_request(
            "#{@api_workspace_follow_path}/#{follow.id}",
            %{
              "type" => "workspace_follower",
              "attributes" => %{
                "notification_enabled" => true
              }
            },
            method: :patch,
            headers: [{"authorization", "Bearer #{token}"}]
          )

        assert response.status == 200
        body = Jason.decode!(response.resp_body)
        assert body["data"]["attributes"]["notification_enabled"] == true
      end

      test "user can disable notifications for a follow", %{site: site, user1: user1} do
        token = sign_in_user(user1)
        workspace = create_workspace!(site_id: site.id, status: :active)

        # Create follow with notifications enabled
        follow =
          create_workspace_follower!(
            workspace_id: workspace.id,
            follower_user_id: user1.id,
            notification_enabled: true
          )

        response =
          make_api_request(
            "#{@api_workspace_follow_path}/#{follow.id}",
            %{
              "type" => "workspace_follower",
              "attributes" => %{
                "notification_enabled" => false
              }
            },
            method: :patch,
            headers: [{"authorization", "Bearer #{token}"}]
          )

        assert response.status == 200
        body = Jason.decode!(response.resp_body)
        assert body["data"]["attributes"]["notification_enabled"] == false
      end

      test "user cannot update another user's follow", %{
        site: site,
        user1: user1,
        user2: user2
      } do
        token1 = sign_in_user(user1)
        workspace = create_workspace!(site_id: site.id, status: :active)

        # User2 follows workspace
        follow =
          create_workspace_follower!(workspace_id: workspace.id, follower_user_id: user2.id)

        # User1 tries to update user2's follow
        response =
          make_api_request(
            "#{@api_workspace_follow_path}/#{follow.id}",
            %{
              "type" => "workspace_follower",
              "attributes" => %{
                "notification_enabled" => false
              }
            },
            method: :patch,
            headers: [{"authorization", "Bearer #{token1}"}]
          )

        assert response.status in [403, 404]
      end

      test "unauthenticated user cannot toggle notifications", %{site: site, user1: user1} do
        workspace = create_workspace!(site_id: site.id, status: :active)

        follow =
          create_workspace_follower!(workspace_id: workspace.id, follower_user_id: user1.id)

        response =
          make_api_request(
            "#{@api_workspace_follow_path}/#{follow.id}",
            %{
              "type" => "workspace_follower",
              "attributes" => %{
                "notification_enabled" => false
              }
            },
            method: :patch
          )

        # Returns 403 because no actor present
        assert response.status == 403
      end
    end

    describe "DELETE /workspace-follow/:id - Unfollow" do
      test "user can unfollow a workspace", %{site: site, user1: user1} do
        token = sign_in_user(user1)
        workspace = create_workspace!(site_id: site.id, status: :active)

        follow =
          create_workspace_follower!(workspace_id: workspace.id, follower_user_id: user1.id)

        response =
          make_api_request(
            "#{@api_workspace_follow_path}/#{follow.id}",
            %{},
            method: :delete,
            headers: [{"authorization", "Bearer #{token}"}]
          )

        # DELETE with unfollow action returns 200 OK
        assert response.status == 200

        # Verify follow was removed
        list_response =
          make_api_request(
            @api_my_following_path,
            %{},
            method: :get,
            headers: [{"authorization", "Bearer #{token}"}]
          )

        list_body = Jason.decode!(list_response.resp_body)
        assert list_body["data"] == []
      end

      test "user cannot unfollow another user's follow", %{
        site: site,
        user1: user1,
        user2: user2
      } do
        token1 = sign_in_user(user1)
        workspace = create_workspace!(site_id: site.id, status: :active)

        # User2 follows workspace
        follow =
          create_workspace_follower!(workspace_id: workspace.id, follower_user_id: user2.id)

        # User1 tries to unfollow user2's follow
        response =
          make_api_request(
            "#{@api_workspace_follow_path}/#{follow.id}",
            %{},
            method: :delete,
            headers: [{"authorization", "Bearer #{token1}"}]
          )

        assert response.status in [403, 404]
      end

      test "unauthenticated user cannot unfollow", %{site: site, user1: user1} do
        workspace = create_workspace!(site_id: site.id, status: :active)

        follow =
          create_workspace_follower!(workspace_id: workspace.id, follower_user_id: user1.id)

        response =
          make_api_request(
            "#{@api_workspace_follow_path}/#{follow.id}",
            %{},
            method: :delete
          )

        # Returns 403 because no actor present
        assert response.status == 403
      end
    end

    describe "Multiple users following same workspace" do
      test "different users can follow the same workspace", %{
        site: site,
        user1: user1,
        user2: user2
      } do
        token1 = sign_in_user(user1)
        token2 = sign_in_user(user2)
        workspace = create_workspace!(site_id: site.id, status: :active)

        # User1 follows
        response1 =
          make_api_request(
            @api_workspace_follow_path,
            %{
              "type" => "workspace_follower",
              "attributes" => %{
                "workspace_id" => workspace.id
              }
            },
            method: :post,
            headers: [{"authorization", "Bearer #{token1}"}]
          )

        assert response1.status == 201

        # User2 follows the same workspace
        response2 =
          make_api_request(
            @api_workspace_follow_path,
            %{
              "type" => "workspace_follower",
              "attributes" => %{
                "workspace_id" => workspace.id
              }
            },
            method: :post,
            headers: [{"authorization", "Bearer #{token2}"}]
          )

        assert response2.status == 201

        # Verify both follows exist and are different
        body1 = Jason.decode!(response1.resp_body)
        body2 = Jason.decode!(response2.resp_body)
        assert body1["data"]["id"] != body2["data"]["id"]
      end
    end

    describe "Workspace status filtering" do
      test "user can see follow but workspace becomes inactive", %{site: site, user1: user1} do
        token = sign_in_user(user1)

        # Create an active workspace and follow it
        workspace =
          create_workspace!(site_id: site.id, status: :active, name: "Active Workspace")

        response1 =
          make_api_request(
            @api_workspace_follow_path,
            %{
              "type" => "workspace_follower",
              "attributes" => %{
                "workspace_id" => workspace.id
              }
            },
            method: :post,
            headers: [{"authorization", "Bearer #{token}"}]
          )

        assert response1.status == 201

        # Verify follow appears in user's list
        list_response1 =
          make_api_request(
            @api_my_following_path,
            %{},
            method: :get,
            headers: [{"authorization", "Bearer #{token}"}]
          )

        assert list_response1.status == 200
        body1 = Jason.decode!(list_response1.resp_body)
        assert length(body1["data"]) == 1

        # Change workspace status to draft
        Ash.update!(workspace, %{status: :draft},
          action: :update,
          authorize?: false,
          tenant: workspace.site_id
        )

        # Get following again - should not see the draft workspace
        list_response2 =
          make_api_request(
            @api_my_following_path,
            %{},
            method: :get,
            headers: [{"authorization", "Bearer #{token}"}]
          )

        assert list_response2.status == 200
        body2 = Jason.decode!(list_response2.resp_body)

        # Draft workspaces should be filtered out from my_following
        assert body2["data"] == []
      end

      test "user can see multiple follows with only active workspaces visible", %{
        site: site,
        user1: user1
      } do
        token = sign_in_user(user1)

        # Create and follow three active workspaces
        workspace1 = create_workspace!(site_id: site.id, status: :active, name: "Workspace 1")
        workspace2 = create_workspace!(site_id: site.id, status: :active, name: "Workspace 2")
        workspace3 = create_workspace!(site_id: site.id, status: :active, name: "Workspace 3")

        create_workspace_follower!(workspace_id: workspace1.id, follower_user_id: user1.id)
        create_workspace_follower!(workspace_id: workspace2.id, follower_user_id: user1.id)
        create_workspace_follower!(workspace_id: workspace3.id, follower_user_id: user1.id)

        # Verify all 3 follows appear
        list_response1 =
          make_api_request(
            @api_my_following_path,
            %{},
            method: :get,
            headers: [{"authorization", "Bearer #{token}"}]
          )

        assert list_response1.status == 200
        body1 = Jason.decode!(list_response1.resp_body)
        assert length(body1["data"]) == 3

        # Change workspace2 to draft
        Ash.update!(workspace2, %{status: :draft},
          action: :update,
          authorize?: false,
          tenant: workspace2.site_id
        )

        # Get following again - should only see 2 (workspace1 and workspace3)
        list_response2 =
          make_api_request(
            @api_my_following_path,
            %{},
            method: :get,
            headers: [{"authorization", "Bearer #{token}"}]
          )

        assert list_response2.status == 200
        body2 = Jason.decode!(list_response2.resp_body)
        assert length(body2["data"]) == 2
      end
    end

    describe "Follow ordering and metadata" do
      test "follows include followed_at timestamp", %{site: site, user1: user1} do
        token = sign_in_user(user1)

        # Create follow
        workspace = create_workspace!(site_id: site.id, status: :active)
        create_workspace_follower!(workspace_id: workspace.id, follower_user_id: user1.id)

        response =
          make_api_request(
            @api_my_following_path,
            %{},
            method: :get,
            headers: [{"authorization", "Bearer #{token}"}]
          )

        assert response.status == 200
        body = Jason.decode!(response.resp_body)
        assert length(body["data"]) == 1

        follow = hd(body["data"])

        assert {:ok, %DateTime{}, _offset} =
                 DateTime.from_iso8601(follow["attributes"]["followed_at"])
      end
    end

    describe "INCLUDES - Fetching related workspace data" do
      test "can include workspace data when listing follows", %{site: site, user1: user1} do
        token = sign_in_user(user1)

        # Create workspace with specific name
        workspace =
          create_workspace!(
            site_id: site.id,
            status: :active,
            name: "Tech Documentation",
            description: "Technical documentation workspace"
          )

        create_workspace_follower!(workspace_id: workspace.id, follower_user_id: user1.id)

        response =
          make_api_request(
            "#{@api_my_following_path}?include=workspace",
            %{},
            method: :get,
            headers: [{"authorization", "Bearer #{token}"}]
          )

        assert response.status == 200
        body = Jason.decode!(response.resp_body)

        # Verify the follow data
        assert length(body["data"]) == 1
        follow = hd(body["data"])

        # Verify workspace relationship is present
        assert follow["relationships"]["workspace"]["data"]["id"] == workspace.id
        assert follow["relationships"]["workspace"]["data"]["type"] == "workspace"

        # Verify included workspace data is present
        assert [_ | _] = body["included"]
        included_workspaces = Enum.filter(body["included"], &(&1["type"] == "workspace"))
        assert length(included_workspaces) == 1

        included_workspace = hd(included_workspaces)
        assert included_workspace["id"] == workspace.id
        assert included_workspace["attributes"]["name"] == "Tech Documentation"

        assert included_workspace["attributes"]["description"] ==
                 "Technical documentation workspace"

        assert included_workspace["attributes"]["status"] == "active"
      end

      test "can include workspace data for single follow via create", %{site: site, user1: user1} do
        token = sign_in_user(user1)

        workspace =
          create_workspace!(
            site_id: site.id,
            status: :active,
            name: "API Documentation"
          )

        response =
          make_api_request(
            "#{@api_workspace_follow_path}?include=workspace",
            %{
              "type" => "workspace_follower",
              "attributes" => %{
                "workspace_id" => workspace.id
              }
            },
            method: :post,
            headers: [{"authorization", "Bearer #{token}"}]
          )

        assert response.status == 201
        body = Jason.decode!(response.resp_body)

        # Verify workspace relationship
        assert body["data"]["relationships"]["workspace"]["data"]["id"] == workspace.id

        # Verify included workspace data
        assert [_ | _] = body["included"]
        included_workspaces = Enum.filter(body["included"], &(&1["type"] == "workspace"))
        assert length(included_workspaces) == 1

        included_workspace = hd(included_workspaces)
        assert included_workspace["id"] == workspace.id
        assert included_workspace["attributes"]["name"] == "API Documentation"
      end

      test "includes workspace data for multiple follows", %{site: site, user1: user1} do
        token = sign_in_user(user1)

        # Create multiple workspaces with different names
        workspace1 =
          create_workspace!(site_id: site.id, status: :active, name: "Workspace A")

        workspace2 =
          create_workspace!(site_id: site.id, status: :active, name: "Workspace B")

        workspace3 =
          create_workspace!(site_id: site.id, status: :active, name: "Workspace C")

        create_workspace_follower!(workspace_id: workspace1.id, follower_user_id: user1.id)
        create_workspace_follower!(workspace_id: workspace2.id, follower_user_id: user1.id)
        create_workspace_follower!(workspace_id: workspace3.id, follower_user_id: user1.id)

        response =
          make_api_request(
            "#{@api_my_following_path}?include=workspace",
            %{},
            method: :get,
            headers: [{"authorization", "Bearer #{token}"}]
          )

        assert response.status == 200
        body = Jason.decode!(response.resp_body)

        # Verify we have 3 follows
        assert length(body["data"]) == 3

        # Verify we have 3 included workspaces
        assert [_ | _] = body["included"]
        included_workspaces = Enum.filter(body["included"], &(&1["type"] == "workspace"))
        assert length(included_workspaces) == 3

        # Verify workspace names are present
        workspace_names = Enum.map(included_workspaces, & &1["attributes"]["name"])
        assert "Workspace A" in workspace_names
        assert "Workspace B" in workspace_names
        assert "Workspace C" in workspace_names
      end

      test "without include parameter, only basic follow data is returned", %{
        site: site,
        user1: user1
      } do
        token = sign_in_user(user1)

        workspace = create_workspace!(site_id: site.id, status: :active, name: "Test Workspace")
        create_workspace_follower!(workspace_id: workspace.id, follower_user_id: user1.id)

        response =
          make_api_request(
            @api_my_following_path,
            %{},
            method: :get,
            headers: [{"authorization", "Bearer #{token}"}]
          )

        assert response.status == 200
        body = Jason.decode!(response.resp_body)

        # Should have follow data
        assert length(body["data"]) == 1
        follow = hd(body["data"])
        assert follow["attributes"]["workspace_id"] == workspace.id

        # Without include parameter, included section should be nil or empty
        assert body["included"] in [nil, []]
      end
    end
  end
end
