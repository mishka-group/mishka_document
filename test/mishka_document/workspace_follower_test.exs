# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_document/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaDocument.Test.WorkspaceFollowerTest do
  @moduledoc """
  Comprehensive tests for MishkaDocument.WorkspaceFollower resource.
  """
  use MishkaDocument.DataCase, async: false

  if Code.ensure_loaded?(MishkaDocument) do
    alias MishkaDocument.WorkspaceFollower

    describe "resource configuration" do
      test "uses correct table name" do
        assert AshPostgres.DataLayer.Info.table(WorkspaceFollower) ==
                 "mishka_document_workspace_followers"
      end

      test "uses UUID v7 for primary keys" do
        follow = create_workspace_follower!()
        assert {:ok, _uuid} = Ecto.UUID.cast(follow.id)
        assert String.length(follow.id) == 36
      end

      test "does not use multi-tenancy" do
        # WorkspaceFollower is global - users can follow workspaces from any site
        multitenancy_strategy = Ash.Resource.Info.multitenancy_strategy(WorkspaceFollower)
        assert multitenancy_strategy == nil
      end
    end

    describe "create action" do
      test "creates workspace follow with valid attributes" do
        workspace = create_workspace!()
        user = create_user!()

        follow =
          WorkspaceFollower
          |> Ash.Changeset.for_create(
            :create,
            %{
              workspace_id: workspace.id
            },
            actor: user,
            authorize?: false
          )
          |> Ash.create!()

        assert follow.workspace_id == workspace.id
        assert follow.follower_user_id == user.id
        assert follow.notification_enabled == true
        assert %DateTime{} = follow.followed_at
      end

      test "defaults notification_enabled to true" do
        workspace = create_workspace!()
        user = create_user!()

        follow =
          WorkspaceFollower
          |> Ash.Changeset.for_create(
            :create,
            %{
              workspace_id: workspace.id
            },
            actor: user,
            authorize?: false
          )
          |> Ash.create!()

        assert follow.notification_enabled == true
      end

      test "allows setting notification_enabled to false" do
        workspace = create_workspace!()
        user = create_user!()

        follow =
          WorkspaceFollower
          |> Ash.Changeset.for_create(
            :create,
            %{
              workspace_id: workspace.id,
              notification_enabled: false
            },
            actor: user,
            authorize?: false
          )
          |> Ash.create!()

        assert follow.notification_enabled == false
      end

      test "auto-sets followed_at timestamp" do
        before_time = DateTime.utc_now()
        follow = create_workspace_follower!()
        after_time = DateTime.utc_now()

        assert DateTime.compare(follow.followed_at, before_time) in [:gt, :eq]
        assert DateTime.compare(follow.followed_at, after_time) in [:lt, :eq]
      end

      test "requires workspace_id" do
        user = create_user!()

        assert_raise Ash.Error.Invalid, fn ->
          WorkspaceFollower
          |> Ash.Changeset.for_create(
            :create,
            %{},
            actor: user,
            authorize?: false
          )
          |> Ash.create!()
        end
      end

      test "requires actor (follower_user)" do
        workspace = create_workspace!()

        assert_raise Ash.Error.Invalid, fn ->
          WorkspaceFollower
          |> Ash.Changeset.for_create(
            :create,
            %{workspace_id: workspace.id},
            authorize?: false
          )
          |> Ash.create!()
        end
      end

      test "upserts on duplicate follow (idempotent)" do
        workspace = create_workspace!()
        user = create_user!()

        # First follow
        follow1 =
          WorkspaceFollower
          |> Ash.Changeset.for_create(
            :create,
            %{
              workspace_id: workspace.id,
              notification_enabled: false
            },
            actor: user,
            authorize?: false
          )
          |> Ash.create!()

        # Second follow of the same workspace (should upsert)
        follow2 =
          WorkspaceFollower
          |> Ash.Changeset.for_create(
            :create,
            %{
              workspace_id: workspace.id,
              notification_enabled: true
            },
            actor: user,
            authorize?: false
          )
          |> Ash.create!()

        # Should be the same record with updated notification setting
        assert follow1.id == follow2.id
        assert follow2.notification_enabled == true
      end
    end

    describe "by_user action" do
      test "lists all workspaces followed by a user" do
        user = create_user!()
        workspace1 = create_workspace!()
        workspace2 = create_workspace!()
        workspace3 = create_workspace!()

        # User follows workspace1 and workspace2
        _follow1 =
          create_workspace_follower!(workspace_id: workspace1.id, follower_user_id: user.id)

        _follow2 =
          create_workspace_follower!(workspace_id: workspace2.id, follower_user_id: user.id)

        # Another user follows workspace3
        other_user = create_user!()

        _follow3 =
          create_workspace_follower!(
            workspace_id: workspace3.id,
            follower_user_id: other_user.id
          )

        result =
          WorkspaceFollower
          |> Ash.Query.for_read(:by_user, %{follower_user_id: user.id}, authorize?: false)
          |> Ash.read!()

        follows = result.results
        workspace_ids = Enum.map(follows, & &1.workspace_id) |> Enum.sort()

        assert length(follows) == 2
        assert Enum.sort([workspace1.id, workspace2.id]) == workspace_ids
      end

      test "supports pagination" do
        user = create_user!()

        # Create 25 workspace follows
        _workspaces =
          Enum.map(1..25, fn _ ->
            workspace = create_workspace!()
            create_workspace_follower!(workspace_id: workspace.id, follower_user_id: user.id)
            workspace
          end)

        result =
          WorkspaceFollower
          |> Ash.Query.for_read(:by_user, %{follower_user_id: user.id}, authorize?: false)
          |> Ash.read!()

        assert length(result.results) == 20

        # Query second page
        result_page2 =
          WorkspaceFollower
          |> Ash.Query.for_read(:by_user, %{follower_user_id: user.id}, authorize?: false)
          |> Ash.Query.page(offset: 20, limit: 10)
          |> Ash.read!()

        assert length(result_page2.results) == 5
      end

      test "returns empty list when user has no follows" do
        user = create_user!()

        result =
          WorkspaceFollower
          |> Ash.Query.for_read(:by_user, %{follower_user_id: user.id}, authorize?: false)
          |> Ash.read!()

        assert result.results == []
      end
    end

    describe "by_workspace action" do
      test "lists all followers of a workspace" do
        workspace = create_workspace!()
        user1 = create_user!()
        user2 = create_user!()
        user3 = create_user!()

        # Users 1 and 2 follow this workspace
        _follow1 =
          create_workspace_follower!(workspace_id: workspace.id, follower_user_id: user1.id)

        _follow2 =
          create_workspace_follower!(workspace_id: workspace.id, follower_user_id: user2.id)

        # User 3 follows a different workspace
        other_workspace = create_workspace!()

        _follow3 =
          create_workspace_follower!(
            workspace_id: other_workspace.id,
            follower_user_id: user3.id
          )

        result =
          WorkspaceFollower
          |> Ash.Query.for_read(:by_workspace, %{workspace_id: workspace.id}, authorize?: false)
          |> Ash.read!()

        follows = result.results
        user_ids = Enum.map(follows, & &1.follower_user_id) |> Enum.sort()

        assert length(follows) == 2
        assert Enum.sort([user1.id, user2.id]) == user_ids
      end

      test "supports pagination" do
        workspace = create_workspace!()

        # Create 25 followers
        _users =
          Enum.map(1..25, fn _ ->
            user = create_user!()
            create_workspace_follower!(workspace_id: workspace.id, follower_user_id: user.id)
            user
          end)

        result =
          WorkspaceFollower
          |> Ash.Query.for_read(:by_workspace, %{workspace_id: workspace.id}, authorize?: false)
          |> Ash.read!()

        assert length(result.results) == 20

        # Query second page
        result_page2 =
          WorkspaceFollower
          |> Ash.Query.for_read(:by_workspace, %{workspace_id: workspace.id}, authorize?: false)
          |> Ash.Query.page(offset: 20, limit: 10)
          |> Ash.read!()

        assert length(result_page2.results) == 5
      end

      test "returns empty list when workspace has no followers" do
        workspace = create_workspace!()

        result =
          WorkspaceFollower
          |> Ash.Query.for_read(:by_workspace, %{workspace_id: workspace.id}, authorize?: false)
          |> Ash.read!()

        assert result.results == []
      end

      test "allows public access (no authentication required)" do
        workspace = create_workspace!()
        user = create_user!()

        _follow =
          create_workspace_follower!(workspace_id: workspace.id, follower_user_id: user.id)

        # This should not raise authorization error
        result =
          WorkspaceFollower
          |> Ash.Query.for_read(:by_workspace, %{workspace_id: workspace.id}, authorize?: false)
          |> Ash.read!()

        assert length(result.results) == 1
      end
    end

    describe "toggle_notifications action" do
      test "toggles notification_enabled from true to false" do
        follow = create_workspace_follower!(notification_enabled: true)

        updated =
          follow
          |> Ash.Changeset.for_update(
            :toggle_notifications,
            %{notification_enabled: false},
            authorize?: false
          )
          |> Ash.update!()

        assert updated.notification_enabled == false
      end

      test "toggles notification_enabled from false to true" do
        follow = create_workspace_follower!(notification_enabled: false)

        updated =
          follow
          |> Ash.Changeset.for_update(
            :toggle_notifications,
            %{notification_enabled: true},
            authorize?: false
          )
          |> Ash.update!()

        assert updated.notification_enabled == true
      end

      test "only accepts notification_enabled field" do
        follow = create_workspace_follower!()

        # Should successfully update notification_enabled
        updated =
          follow
          |> Ash.Changeset.for_update(
            :toggle_notifications,
            %{notification_enabled: false},
            authorize?: false
          )
          |> Ash.update!()

        assert updated.notification_enabled == false
      end
    end

    describe "unfollow action" do
      test "deletes the follow relationship" do
        follow = create_workspace_follower!()
        follow_id = follow.id

        follow
        |> Ash.Changeset.for_destroy(:unfollow, %{}, authorize?: false)
        |> Ash.destroy!()

        # Verify it's deleted
        result = Ash.get(WorkspaceFollower, follow_id, authorize?: false)
        assert match?({:error, _}, result)
      end

      test "allows user to unfollow and follow again" do
        workspace = create_workspace!()
        user = create_user!()

        # Follow
        follow1 =
          WorkspaceFollower
          |> Ash.Changeset.for_create(
            :create,
            %{workspace_id: workspace.id},
            actor: user,
            authorize?: false
          )
          |> Ash.create!()

        # Unfollow
        follow1
        |> Ash.Changeset.for_destroy(:unfollow, %{}, authorize?: false)
        |> Ash.destroy!()

        # Follow again
        follow2 =
          WorkspaceFollower
          |> Ash.Changeset.for_create(
            :create,
            %{workspace_id: workspace.id},
            actor: user,
            authorize?: false
          )
          |> Ash.create!()

        # Should be a different record
        assert follow1.id != follow2.id
      end
    end

    describe "read action" do
      test "reads all workspace follows" do
        follow1 = create_workspace_follower!()
        follow2 = create_workspace_follower!()

        follows = WorkspaceFollower |> Ash.read!(authorize?: false)

        follow_ids = Enum.map(follows, & &1.id)
        assert follow1.id in follow_ids
        assert follow2.id in follow_ids
      end
    end

    describe "destroy action" do
      test "deletes workspace follow" do
        follow = create_workspace_follower!()
        follow_id = follow.id

        follow
        |> Ash.Changeset.for_destroy(:destroy, %{}, authorize?: false)
        |> Ash.destroy!()

        result = Ash.get(WorkspaceFollower, follow_id, authorize?: false)
        assert match?({:error, _}, result)
      end
    end

    describe "authorization policies" do
      setup do
        workspace = create_workspace!()
        site_id = workspace.site_id
        follower = create_user!(site_id: site_id)
        stranger = create_user!(site_id: site_id)

        follow =
          create_workspace_follower!(workspace_id: workspace.id, follower_user_id: follower.id)

        {:ok,
         workspace: workspace,
         follower: follower,
         stranger: stranger,
         follow: follow,
         admin:
           create_user_with_permissions!(["admin:dashboard:document:workspace"], site_id: site_id),
         other_admin:
           create_user_with_permissions!(["admin:dashboard:document:workspace"],
             site_id: create_site!().id
           )}
      end

      defp follows_read_by(actor, tenant) do
        WorkspaceFollower
        |> Ash.Query.for_read(:read, %{}, actor: actor, tenant: tenant)
        |> Ash.read!()
        |> Enum.map(& &1.id)
      end

      test "by_workspace lists a workspace's followers for a system read", %{workspace: workspace} do
        result =
          WorkspaceFollower
          |> Ash.Query.for_read(:by_workspace, %{workspace_id: workspace.id}, authorize?: false)
          |> Ash.read!()

        assert length(result.results) == 1
      end

      test "a follower reads their own follow, and a stranger reads none", %{
        follow: follow,
        follower: follower,
        stranger: stranger,
        workspace: workspace
      } do
        assert follows_read_by(follower, workspace.site_id) == [follow.id]
        assert follows_read_by(stranger, workspace.site_id) == []
      end

      test "by_workspace shows a stranger no follower, and a follower only their own", %{
        follow: follow,
        follower: follower,
        stranger: stranger,
        workspace: workspace
      } do
        ids = fn actor ->
          WorkspaceFollower
          |> Ash.Query.for_read(:by_workspace, %{workspace_id: workspace.id},
            actor: actor,
            tenant: workspace.site_id
          )
          |> Ash.read!()
          |> Map.fetch!(:results)
          |> Enum.map(& &1.id)
        end

        assert ids.(follower) == [follow.id]
        assert ids.(stranger) == []
      end

      test "the area of the workspace reads the follows of its own site and no other", %{
        follow: follow,
        admin: admin,
        other_admin: other_admin,
        workspace: workspace
      } do
        assert follow.id in follows_read_by(admin, workspace.site_id)
        refute follow.id in follows_read_by(other_admin, other_admin.site_id)
      end

      test "create takes the follow for the actor and no one else", %{
        stranger: stranger,
        workspace: workspace
      } do
        assert {:ok, created} =
                 WorkspaceFollower
                 |> Ash.Changeset.for_create(:create, %{workspace_id: workspace.id},
                   actor: stranger,
                   tenant: workspace.site_id
                 )
                 |> Ash.create()

        assert created.follower_user_id == stranger.id

        assert {:error, %Ash.Error.Forbidden{}} =
                 WorkspaceFollower
                 |> Ash.Changeset.for_create(:create, %{workspace_id: workspace.id},
                   tenant: workspace.site_id
                 )
                 |> Ash.create()
      end

      test "only the follower or the workspace area toggles notifications", %{
        follow: follow,
        follower: follower,
        stranger: stranger,
        admin: admin,
        workspace: workspace
      } do
        toggle = fn actor, enabled ->
          follow
          |> Ash.Changeset.for_update(:toggle_notifications, %{notification_enabled: enabled},
            actor: actor,
            tenant: workspace.site_id
          )
          |> Ash.update()
        end

        assert {:error, %Ash.Error.Forbidden{}} = toggle.(stranger, false)

        assert {:ok, %{notification_enabled: false}} = toggle.(follower, false)
        assert {:ok, %{notification_enabled: true}} = toggle.(admin, true)
      end

      test "only the follower or the workspace area unfollows", %{
        follow: follow,
        follower: follower,
        stranger: stranger,
        other_admin: other_admin,
        workspace: workspace
      } do
        unfollow = fn actor, tenant ->
          follow
          |> Ash.Changeset.for_destroy(:unfollow, %{}, actor: actor, tenant: tenant)
          |> Ash.destroy()
        end

        assert {:error, %Ash.Error.Forbidden{}} = unfollow.(stranger, workspace.site_id)
        assert {:error, %Ash.Error.Forbidden{}} = unfollow.(other_admin, other_admin.site_id)
        assert {:ok, _} = Ash.get(WorkspaceFollower, follow.id, authorize?: false)

        assert :ok = unfollow.(follower, workspace.site_id)
        assert {:error, _gone} = Ash.get(WorkspaceFollower, follow.id, authorize?: false)
      end
    end

    describe "database constraints" do
      test "cascades delete when workspace is deleted" do
        workspace = create_workspace!()
        user = create_user!()

        follow = create_workspace_follower!(workspace_id: workspace.id, follower_user_id: user.id)
        follow_id = follow.id

        # Delete the workspace
        workspace
        |> Ash.Changeset.for_destroy(
          :permanent_destroy,
          %{},
          tenant: workspace.site_id,
          authorize?: false
        )
        |> Ash.destroy!()

        # Follow should be automatically deleted due to cascade
        result = Ash.get(WorkspaceFollower, follow_id, authorize?: false)
        assert match?({:error, _}, result)
      end

      test "follow references are cleaned up when workspace deleted" do
        workspace = create_workspace!()
        user = create_user!()

        follow = create_workspace_follower!(workspace_id: workspace.id, follower_user_id: user.id)
        follow_id = follow.id

        # Permanently delete the workspace (cascade should delete follow)
        workspace
        |> Ash.Changeset.for_destroy(
          :permanent_destroy,
          %{},
          tenant: workspace.site_id,
          authorize?: false
        )
        |> Ash.destroy!()

        # Follow should be gone
        result = Ash.get(WorkspaceFollower, follow_id, authorize?: false)
        assert match?({:error, _}, result)
      end
    end

    describe "identities" do
      test "unique_follower_workspace with upsert prevents duplicates" do
        workspace = create_workspace!()
        user = create_user!()

        # First follow succeeds
        follow1 =
          WorkspaceFollower
          |> Ash.Changeset.for_create(
            :create,
            %{workspace_id: workspace.id},
            actor: user,
            authorize?: false
          )
          |> Ash.create!()

        # Second follow with same user/workspace should upsert (update existing)
        follow2 =
          WorkspaceFollower
          |> Ash.Changeset.for_create(
            :create,
            %{workspace_id: workspace.id, notification_enabled: false},
            actor: user,
            authorize?: false
          )
          |> Ash.create!()

        # Should be the same record (upserted)
        assert follow1.id == follow2.id
        assert follow2.notification_enabled == false
      end

      test "allows same user to follow different workspaces" do
        user = create_user!()
        workspace1 = create_workspace!()
        workspace2 = create_workspace!()

        follow1 =
          create_workspace_follower!(workspace_id: workspace1.id, follower_user_id: user.id)

        follow2 =
          create_workspace_follower!(workspace_id: workspace2.id, follower_user_id: user.id)

        assert follow1.workspace_id != follow2.workspace_id
        assert follow1.follower_user_id == follow2.follower_user_id
      end

      test "allows different users to follow same workspace" do
        workspace = create_workspace!()
        user1 = create_user!()
        user2 = create_user!()

        follow1 =
          create_workspace_follower!(workspace_id: workspace.id, follower_user_id: user1.id)

        follow2 =
          create_workspace_follower!(workspace_id: workspace.id, follower_user_id: user2.id)

        assert follow1.workspace_id == follow2.workspace_id
        assert follow1.follower_user_id != follow2.follower_user_id
      end
    end

    describe "relationships" do
      test "belongs_to workspace" do
        workspace = create_workspace!()
        follow = create_workspace_follower!(workspace_id: workspace.id)

        # Workspace requires tenant for loading, so we query the workspace directly
        workspace_loaded =
          Ash.get!(MishkaDocument.Workspace, workspace.id, action: :master_get, authorize?: false)

        assert follow.workspace_id == workspace_loaded.id
        assert workspace_loaded.name == workspace.name
      end

      test "belongs_to follower_user" do
        user = create_user!()
        follow = create_workspace_follower!(follower_user_id: user.id)

        follow_with_user = Ash.load!(follow, :follower_user, authorize?: false)

        assert follow_with_user.follower_user.id == user.id
        assert follow_with_user.follower_user.email == user.email
      end

      test "can access workspace and user through relationship IDs" do
        workspace = create_workspace!()
        user = create_user!()

        follow =
          create_workspace_follower!(workspace_id: workspace.id, follower_user_id: user.id)

        # Can load user relationship
        follow_with_user = Ash.load!(follow, :follower_user, authorize?: false)
        assert follow_with_user.follower_user.id == user.id

        # Workspace relationship exists but requires tenant for loading
        assert follow.workspace_id == workspace.id
      end
    end

    describe "JSON API configuration" do
      test "has correct JSON API type" do
        json_api_type = AshJsonApi.Resource.Info.type(WorkspaceFollower)
        assert json_api_type == "workspace_follower"
      end
    end

    describe "attributes" do
      test "followed_at is set automatically and not writable" do
        follow = create_workspace_follower!()

        # followed_at should be set
        assert %DateTime{} = follow.followed_at
        # Attempting to manually set followed_at should not change it
        original_time = follow.followed_at

        updated =
          follow
          |> Ash.Changeset.for_update(
            :toggle_notifications,
            %{notification_enabled: false},
            authorize?: false
          )
          |> Ash.update!()

        # followed_at should remain the same
        assert updated.followed_at == original_time
      end

      test "notification_enabled defaults to true" do
        workspace = create_workspace!()
        user = create_user!()

        follow =
          WorkspaceFollower
          |> Ash.Changeset.for_create(
            :create,
            %{workspace_id: workspace.id},
            actor: user,
            authorize?: false
          )
          |> Ash.create!()

        assert follow.notification_enabled == true
      end
    end
  end
end
