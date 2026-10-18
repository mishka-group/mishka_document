# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_document/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaDocument.Test.IssueCommentTest do
  @moduledoc """
  Tests for MishkaDocument.IssueComment resource.
  """
  use MishkaDocument.DataCase, async: false

  if Code.ensure_loaded?(MishkaDocument) do
    alias MishkaDocument.IssueComment

    describe "resource configuration" do
      test "uses correct table name" do
        assert AshPostgres.DataLayer.Info.table(IssueComment) ==
                 "mishka_document_issue_comments"
      end

      test "uses UUID v7 for primary keys" do
        comment = create_issue_comment!()
        assert {:ok, _uuid} = Ecto.UUID.cast(comment.id)
        assert String.length(comment.id) == 36
      end

      test "has multitenancy with site_id" do
        assert Ash.Resource.Info.multitenancy_strategy(IssueComment) == :attribute
        assert Ash.Resource.Info.multitenancy_attribute(IssueComment) == :site_id
        assert Ash.Resource.Info.multitenancy_global?(IssueComment) == false
      end

      test "is not global - always site-specific" do
        refute Ash.Resource.Info.multitenancy_global?(IssueComment)
      end
    end

    describe "create action" do
      test "creates comment with valid attributes" do
        site = create_site!()
        issue = create_issue!(site_id: site.id)
        contributor = create_user!()

        comment =
          IssueComment
          |> Ash.Changeset.for_create(
            :create,
            %{
              issue_id: issue.id,
              content: "Test comment"
            },
            tenant: site.id,
            actor: contributor,
            authorize?: false
          )
          |> Ash.create!()

        assert comment.content == "Test comment"
        assert comment.issue_id == issue.id
        assert comment.contributor_id == contributor.id
        assert comment.site_id == site.id
      end

      test "auto-assigns site_id from tenant" do
        site = create_site!()
        issue = create_issue!(site_id: site.id)
        contributor = create_user!()

        comment =
          IssueComment
          |> Ash.Changeset.for_create(
            :create,
            %{
              issue_id: issue.id,
              content: "Test comment"
            },
            tenant: site.id,
            actor: contributor,
            authorize?: false
          )
          |> Ash.create!()

        assert comment.site_id == site.id
      end

      test "auto-assigns contributor from actor" do
        site = create_site!()
        issue = create_issue!(site_id: site.id)
        contributor = create_user!()

        comment =
          IssueComment
          |> Ash.Changeset.for_create(
            :create,
            %{
              issue_id: issue.id,
              content: "Test comment"
            },
            tenant: site.id,
            actor: contributor,
            authorize?: false
          )
          |> Ash.create!()

        assert comment.contributor_id == contributor.id
      end

      test "requires issue_id" do
        site = create_site!()
        contributor = create_user!()

        assert_raise Ash.Error.Invalid, fn ->
          IssueComment
          |> Ash.Changeset.for_create(
            :create,
            %{
              content: "Test comment"
            },
            tenant: site.id,
            actor: contributor,
            authorize?: false
          )
          |> Ash.create!()
        end
      end

      test "requires content" do
        site = create_site!()
        issue = create_issue!(site_id: site.id)
        contributor = create_user!()

        assert_raise Ash.Error.Invalid, fn ->
          IssueComment
          |> Ash.Changeset.for_create(
            :create,
            %{
              issue_id: issue.id
            },
            tenant: site.id,
            actor: contributor,
            authorize?: false
          )
          |> Ash.create!()
        end
      end

      test "fails without actor when contributor is required" do
        site = create_site!()
        issue = create_issue!(site_id: site.id)

        # Without actor, contributor cannot be set, and since contributor is required,
        # the creation should fail
        assert_raise Ash.Error.Invalid, ~r/contributor is required/, fn ->
          IssueComment
          |> Ash.Changeset.for_create(
            :create,
            %{
              issue_id: issue.id,
              content: "Test comment"
            },
            tenant: site.id
          )
          |> Ash.create!()
        end
      end
    end

    describe "master_create action" do
      test "creates comment with explicit site_id" do
        site = create_site!()
        issue = create_issue!(site_id: site.id)
        contributor = create_user!()

        comment =
          IssueComment
          |> Ash.Changeset.for_create(
            :master_create,
            %{
              issue_id: issue.id,
              content: "Test comment",
              contributor_id: contributor.id,
              site_id: site.id
            },
            authorize?: false
          )
          |> Ash.create!()

        assert comment.site_id == site.id
        assert comment.content == "Test comment"
      end

      test "requires explicit site_id" do
        issue = create_issue!()
        contributor = create_user!()

        assert_raise Ash.Error.Invalid, fn ->
          IssueComment
          |> Ash.Changeset.for_create(
            :master_create,
            %{
              issue_id: issue.id,
              content: "Test comment",
              contributor_id: contributor.id
            },
            authorize?: false
          )
          |> Ash.create!()
        end
      end
    end

    describe "update action" do
      test "updates comment content" do
        comment = create_issue_comment!()

        updated_comment =
          comment
          |> Ash.Changeset.for_update(
            :update,
            %{
              content: "Updated content"
            },
            tenant: comment.site_id,
            authorize?: false
          )
          |> Ash.update!()

        assert updated_comment.content == "Updated content"
      end

      test "only accepts content (not contributor_id or site_id)" do
        comment = create_issue_comment!()
        other_user = create_user!()

        # contributor_id is not in accept list
        assert_raise Ash.Error.Invalid, ~r/No such input/, fn ->
          comment
          |> Ash.Changeset.for_update(
            :update,
            %{
              content: "Updated",
              contributor_id: other_user.id
            },
            tenant: comment.site_id,
            authorize?: false
          )
          |> Ash.update!()
        end
      end
    end

    describe "master_update action" do
      test "updates comment attributes" do
        comment = create_issue_comment!()

        updated_comment =
          comment
          |> Ash.Changeset.for_update(:master_update, %{content: "Master Updated"},
            authorize?: false
          )
          |> Ash.update!()

        assert updated_comment.content == "Master Updated"
      end
    end

    describe "read actions" do
      test "default read returns comments within tenant" do
        site = create_site!()
        comment = create_issue_comment!(site_id: site.id)

        comments =
          IssueComment
          |> Ash.read!(tenant: site.id, authorize?: false)

        assert Enum.any?(comments, fn c -> c.id == comment.id end)
      end

      test "default read respects tenant isolation" do
        site1 = create_site!()
        site2 = create_site!()

        comment1 = create_issue_comment!(site_id: site1.id)
        _comment2 = create_issue_comment!(site_id: site2.id)

        comments =
          IssueComment
          |> Ash.read!(tenant: site1.id, authorize?: false)

        assert Enum.any?(comments, fn c -> c.id == comment1.id end)
        refute Enum.any?(comments, fn c -> c.site_id == site2.id end)
      end

      test "master_read bypasses tenant filtering" do
        site1 = create_site!()
        site2 = create_site!()

        comment1 = create_issue_comment!(site_id: site1.id)
        comment2 = create_issue_comment!(site_id: site2.id)

        result =
          IssueComment
          |> Ash.Query.for_read(:master_read, %{}, authorize?: false)
          |> Ash.read!()

        all_comment_ids = Enum.map(result.results, & &1.id)
        assert comment1.id in all_comment_ids
        assert comment2.id in all_comment_ids
      end

      test "master_get retrieves comment from any tenant" do
        comment = create_issue_comment!()

        fetched_comment =
          Ash.get!(IssueComment, comment.id, action: :master_get, authorize?: false)

        assert fetched_comment.id == comment.id
      end

      test "by_issue filters comments by issue_id" do
        site = create_site!()
        issue = create_issue!(site_id: site.id)
        comment = create_issue_comment!(site_id: site.id, issue_id: issue.id)
        _other_comment = create_issue_comment!(site_id: site.id)

        result =
          IssueComment
          |> Ash.Query.for_read(:by_issue, %{issue_id: issue.id},
            tenant: site.id,
            authorize?: false
          )
          |> Ash.read!()

        assert length(result.results) == 1
        assert Enum.at(result.results, 0).id == comment.id
      end

      test "by_issue sorts comments by inserted_at asc" do
        site = create_site!()
        issue = create_issue!(site_id: site.id)

        comment1 = create_issue_comment!(site_id: site.id, issue_id: issue.id)
        Process.sleep(10)
        comment2 = create_issue_comment!(site_id: site.id, issue_id: issue.id)

        result =
          IssueComment
          |> Ash.Query.for_read(:by_issue, %{issue_id: issue.id},
            tenant: site.id,
            authorize?: false
          )
          |> Ash.read!()

        comment_ids = Enum.map(result.results, & &1.id)
        assert comment_ids == [comment1.id, comment2.id]
      end

      test "by_contributor filters comments by contributor_id" do
        site = create_site!()
        contributor = create_user!()
        comment = create_issue_comment!(site_id: site.id, contributor_id: contributor.id)
        _other_comment = create_issue_comment!(site_id: site.id)

        result =
          IssueComment
          |> Ash.Query.for_read(:by_contributor, %{contributor_id: contributor.id},
            tenant: site.id,
            authorize?: false
          )
          |> Ash.read!()

        assert length(result.results) == 1
        assert Enum.at(result.results, 0).id == comment.id
      end

      test "by_contributor sorts comments by inserted_at desc" do
        site = create_site!()
        contributor = create_user!()

        comment1 = create_issue_comment!(site_id: site.id, contributor_id: contributor.id)
        Process.sleep(10)
        comment2 = create_issue_comment!(site_id: site.id, contributor_id: contributor.id)

        result =
          IssueComment
          |> Ash.Query.for_read(:by_contributor, %{contributor_id: contributor.id},
            tenant: site.id,
            authorize?: false
          )
          |> Ash.read!()

        comment_ids = Enum.map(result.results, & &1.id)
        assert comment_ids == [comment2.id, comment1.id]
      end
    end

    describe "destroy action (soft delete)" do
      test "archives comment by setting archived_at" do
        comment = create_issue_comment!()

        comment
        |> Ash.Changeset.for_destroy(:destroy, %{}, tenant: comment.site_id, authorize?: false)
        |> Ash.destroy!()

        # Comment should not appear in default read
        comments = IssueComment |> Ash.read!(tenant: comment.site_id, authorize?: false)
        refute Enum.any?(comments, fn c -> c.id == comment.id end)

        # But should be retrievable via archived read
        archived_comment =
          Ash.get!(IssueComment, comment.id,
            action: :get_archived,
            tenant: comment.site_id,
            authorize?: false
          )

        assert %DateTime{} = archived_comment.archived_at
      end

      test "prevents archiving already archived comment" do
        comment = create_issue_comment!()

        # First archive
        archived_comment =
          comment
          |> Ash.Changeset.for_destroy(:destroy, %{},
            tenant: comment.site_id,
            authorize?: false
          )
          |> Ash.destroy!(return_destroyed?: true)

        # Try to archive again
        assert_raise Ash.Error.Invalid, ~r/already archived/, fn ->
          archived_comment
          |> Ash.Changeset.for_destroy(:destroy, %{},
            tenant: comment.site_id,
            authorize?: false
          )
          |> Ash.destroy!()
        end
      end
    end

    describe "master_destroy action" do
      test "soft deletes comment (master users)" do
        comment = create_issue_comment!()

        destroyed_comment =
          comment
          |> Ash.Changeset.for_destroy(:master_destroy, %{}, authorize?: false)
          |> Ash.destroy!(return_destroyed?: true)

        assert %DateTime{} = destroyed_comment.archived_at
      end
    end

    describe "archived reads" do
      test "archived returns archived comments" do
        site = create_site!()
        comment = create_issue_comment!(site_id: site.id)

        # Archive the comment
        comment
        |> Ash.Changeset.for_destroy(:destroy, %{}, tenant: site.id, authorize?: false)
        |> Ash.destroy!()

        result =
          IssueComment
          |> Ash.Query.for_read(:archived, %{}, tenant: site.id, authorize?: false)
          |> Ash.read!()

        assert Enum.any?(result.results, fn c -> c.id == comment.id end)
      end

      test "get_archived retrieves single archived comment" do
        comment = create_issue_comment!()

        # Archive the comment
        comment
        |> Ash.Changeset.for_destroy(:destroy, %{},
          tenant: comment.site_id,
          authorize?: false
        )
        |> Ash.destroy!()

        archived_comment =
          Ash.get!(IssueComment, comment.id,
            action: :get_archived,
            tenant: comment.site_id,
            authorize?: false
          )

        assert archived_comment.id == comment.id
        assert %DateTime{} = archived_comment.archived_at
      end

      test "master_get_archived retrieves archived comment from any tenant" do
        comment = create_issue_comment!()

        # Archive the comment
        comment
        |> Ash.Changeset.for_destroy(:destroy, %{},
          tenant: comment.site_id,
          authorize?: false
        )
        |> Ash.destroy!()

        archived_comment =
          Ash.get!(IssueComment, comment.id, action: :master_get_archived, authorize?: false)

        assert archived_comment.id == comment.id
        assert %DateTime{} = archived_comment.archived_at
      end

      test "master_archived returns all archived comments system-wide" do
        site1 = create_site!()
        site2 = create_site!()

        comment1 = create_issue_comment!(site_id: site1.id)
        comment2 = create_issue_comment!(site_id: site2.id)

        # Archive both comments
        comment1
        |> Ash.Changeset.for_destroy(:destroy, %{}, tenant: site1.id, authorize?: false)
        |> Ash.destroy!()

        comment2
        |> Ash.Changeset.for_destroy(:destroy, %{}, tenant: site2.id, authorize?: false)
        |> Ash.destroy!()

        result =
          IssueComment
          |> Ash.Query.for_read(:master_archived, %{}, authorize?: false)
          |> Ash.read!()

        archived_comment_ids = Enum.map(result.results, & &1.id)
        assert comment1.id in archived_comment_ids
        assert comment2.id in archived_comment_ids
      end
    end

    describe "unarchive action" do
      test "restores archived comment" do
        comment = create_issue_comment!()

        # Archive the comment
        comment
        |> Ash.Changeset.for_destroy(:destroy, %{},
          tenant: comment.site_id,
          authorize?: false
        )
        |> Ash.destroy!()

        # Get archived comment
        archived_comment =
          Ash.get!(IssueComment, comment.id,
            action: :get_archived,
            tenant: comment.site_id,
            authorize?: false
          )

        # Unarchive it
        unarchived_comment =
          archived_comment
          |> Ash.Changeset.for_update(:unarchive, %{},
            tenant: comment.site_id,
            authorize?: false
          )
          |> Ash.update!()

        assert unarchived_comment.archived_at == nil

        # Should appear in default read again
        comments = IssueComment |> Ash.read!(tenant: comment.site_id, authorize?: false)
        assert Enum.any?(comments, fn c -> c.id == comment.id end)
      end
    end

    describe "master_unarchive action" do
      test "restores archived comment (master users)" do
        comment = create_issue_comment!()

        # Archive the comment
        comment
        |> Ash.Changeset.for_destroy(:destroy, %{},
          tenant: comment.site_id,
          authorize?: false
        )
        |> Ash.destroy!()

        # Fetch the archived comment
        archived_comment =
          Ash.get!(IssueComment, comment.id, action: :master_get_archived, authorize?: false)

        # Unarchive via master action
        unarchived_comment =
          archived_comment
          |> Ash.Changeset.for_update(:master_unarchive, %{}, authorize?: false)
          |> Ash.update!()

        assert unarchived_comment.archived_at == nil
      end
    end

    describe "permanent_destroy action" do
      test "permanently deletes comment" do
        comment = create_issue_comment!()
        comment_id = comment.id
        site_id = comment.site_id

        comment
        |> Ash.Changeset.for_destroy(:permanent_destroy, %{},
          tenant: site_id,
          authorize?: false
        )
        |> Ash.destroy!()

        # Comment should not exist in any read action
        result = Ash.get(IssueComment, comment_id, action: :master_get, authorize?: false)
        assert match?({:error, _}, result)
      end

      test "permanent_destroy removes comment even from archived reads" do
        comment = create_issue_comment!()
        comment_id = comment.id
        site_id = comment.site_id

        # Archive first
        comment
        |> Ash.Changeset.for_destroy(:destroy, %{}, tenant: site_id, authorize?: false)
        |> Ash.destroy!()

        # Get archived comment
        archived_comment =
          Ash.get!(IssueComment, comment_id,
            action: :get_archived,
            tenant: site_id,
            authorize?: false
          )

        # Permanently destroy
        archived_comment
        |> Ash.Changeset.for_destroy(:permanent_destroy, %{},
          tenant: site_id,
          authorize?: false
        )
        |> Ash.destroy!()

        # Should not exist anywhere
        result = Ash.get(IssueComment, comment_id, action: :master_get, authorize?: false)
        assert match?({:error, _}, result)
      end
    end

    describe "master_permanent_destroy action" do
      test "permanently deletes comment (master users)" do
        comment = create_issue_comment!()
        comment_id = comment.id

        comment
        |> Ash.Changeset.for_destroy(:master_permanent_destroy, %{}, authorize?: false)
        |> Ash.destroy!()

        # Comment should not exist
        result = Ash.get(IssueComment, comment_id, action: :master_get, authorize?: false)
        assert match?({:error, _}, result)
      end
    end

    # A master writes on any site's issue, and that site's admins read it but cannot change it.
    # Every actor here holds admin permissions, so a refusal is the authorship rule, not the policy.
    describe "a comment a master wrote" do
      @tenant_actions [:update, :destroy, :unarchive, :permanent_destroy]
      @master_actions [
        :master_update,
        :master_destroy,
        :master_unarchive,
        :master_permanent_destroy
      ]

      setup do
        site = create_site!()

        %{
          site: site,
          issue: create_issue!(site_id: site.id),
          master: create_user_with_permissions!(["admin:dashboard:*"]),
          tenant: create_user_with_permissions!(["admin:dashboard:*"], site_id: site.id)
        }
      end

      test "is read-only to an admin of its site", ctx do
        for action <- @tenant_actions do
          comment = prepared!(comment_by!(ctx, ctx.master), action)
          before = state(comment)

          result = act(comment, action, actor: ctx.tenant, tenant: ctx.site.id)

          assert match?({:error, %Ash.Error.Invalid{}}, result), "#{action} was not refused"
          assert result |> elem(1) |> Exception.message() =~ "written by a master admin"
          assert state(comment) == before, "#{action} changed the comment"
        end
      end

      test "stays read-only to a tenant actor when authorization is skipped", ctx do
        for action <- @tenant_actions do
          comment = prepared!(comment_by!(ctx, ctx.master), action)

          result = act(comment, action, actor: ctx.tenant, tenant: ctx.site.id, authorize?: false)

          assert match?({:error, %Ash.Error.Invalid{}}, result), "#{action} was not refused"
        end
      end

      test "leaves an admin of the site every action on a comment one of its users wrote", ctx do
        for action <- @tenant_actions do
          comment = prepared!(comment_by!(ctx, ctx.tenant), action)

          assert match?({:ok, _}, act(comment, action, actor: ctx.tenant, tenant: ctx.site.id)),
                 "#{action} was refused"

          assert state(comment) == expected(comment, action), "#{action} did not take effect"
        end
      end

      test "can be changed by a master through every action, as can any other comment", ctx do
        for author <- [ctx.master, ctx.tenant], action <- @master_actions do
          comment = prepared!(comment_by!(ctx, author), action)

          assert match?({:ok, _}, act(comment, action, actor: ctx.master)),
                 "#{action} was refused"

          assert state(comment) == expected(comment, action), "#{action} did not take effect"
        end

        for action <- @tenant_actions do
          comment = prepared!(comment_by!(ctx, ctx.master), action)

          assert match?({:ok, _}, act(comment, action, actor: ctx.master, tenant: ctx.site.id)),
                 "#{action} was refused to a master"
        end
      end

      test "is not refused to a call with no actor", ctx do
        for action <- @tenant_actions do
          comment = prepared!(comment_by!(ctx, ctx.master), action)

          assert match?({:ok, _}, act(comment, action, tenant: ctx.site.id, authorize?: false)),
                 "#{action} was refused"
        end
      end

      test "is marked authored_by_master?, and nothing else is", ctx do
        orphaned_author = create_user!()
        orphan = comment_by!(ctx, orphaned_author)
        Ash.destroy!(orphaned_author, authorize?: false)

        comments =
          [comment_by!(ctx, ctx.master), comment_by!(ctx, ctx.tenant), orphan]
          |> Ash.load!(:authored_by_master?, tenant: ctx.site.id, authorize?: false)

        assert Enum.map(comments, & &1.authored_by_master?) == [true, false, false]
      end
    end

    defp comment_by!(%{site: site, issue: issue}, author) do
      create_issue_comment!(site_id: site.id, issue_id: issue.id, contributor_id: author.id)
    end

    defp prepared!(comment, action) when action in [:unarchive, :master_unarchive] do
      Ash.destroy!(comment, action: :master_destroy, authorize?: false)
      Ash.get!(IssueComment, comment.id, action: :master_get_archived, authorize?: false)
    end

    defp prepared!(comment, _action), do: comment

    defp act(comment, action, opts) when action in [:update, :master_update],
      do: Ash.update(comment, %{content: "Rewritten"}, [action: action] ++ opts)

    defp act(comment, action, opts) when action in [:unarchive, :master_unarchive],
      do: Ash.update(comment, %{}, [action: action] ++ opts)

    defp act(comment, action, opts),
      do: Ash.destroy(comment, [action: action, return_destroyed?: true] ++ opts)

    defp state(comment) do
      case Ash.get(IssueComment, comment.id, action: :master_get, authorize?: false) do
        {:ok, row} -> {row.content, not is_nil(row.archived_at)}
        {:error, _not_found} -> :gone
      end
    end

    defp expected(_comment, action) when action in [:update, :master_update],
      do: {"Rewritten", false}

    defp expected(comment, action) when action in [:destroy, :master_destroy],
      do: {comment.content, true}

    defp expected(comment, action) when action in [:unarchive, :master_unarchive],
      do: {comment.content, false}

    defp expected(_comment, _permanent_destroy), do: :gone

    describe "relationships" do
      test "belongs_to site" do
        comment = create_issue_comment!()

        comment_with_site = Ash.load!(comment, :site, tenant: comment.site_id, authorize?: false)

        assert comment_with_site.site.id == comment.site_id
      end

      test "belongs_to issue" do
        site = create_site!()
        issue = create_issue!(site_id: site.id)
        comment = create_issue_comment!(site_id: site.id, issue_id: issue.id)

        comment_with_issue = Ash.load!(comment, :issue, tenant: site.id, authorize?: false)

        assert comment_with_issue.issue.id == comment.issue_id
      end

      test "belongs_to contributor" do
        contributor = create_user!()
        comment = create_issue_comment!(contributor_id: contributor.id)

        # Note: Contributor relationship is cross-domain (User)
        # Just verify the contributor_id is set correctly
        assert comment.contributor_id == contributor.id
      end

      test "cascade delete when issue is permanently destroyed" do
        site = create_site!()
        issue = create_issue!(site_id: site.id)
        comment = create_issue_comment!(site_id: site.id, issue_id: issue.id)
        comment_id = comment.id

        # Permanently destroy issue (hard delete)
        issue
        |> Ash.Changeset.for_destroy(:permanent_destroy, %{},
          tenant: site.id,
          authorize?: false
        )
        |> Ash.destroy!()

        # Comment should be deleted via database-level cascade
        result = Ash.get(IssueComment, comment_id, action: :master_get, authorize?: false)
        assert match?({:error, _}, result)
      end

      test "comment remains when issue is archived (soft delete)" do
        site = create_site!()
        issue = create_issue!(site_id: site.id)
        comment = create_issue_comment!(site_id: site.id, issue_id: issue.id)
        comment_id = comment.id

        # Archive issue (soft delete)
        issue
        |> Ash.Changeset.for_destroy(:destroy, %{}, tenant: site.id, authorize?: false)
        |> Ash.destroy!()

        # Comment should still exist (soft delete doesn't cascade)
        fetched_comment =
          Ash.get!(IssueComment, comment_id, tenant: site.id, authorize?: false)

        assert fetched_comment.id == comment_id
        assert fetched_comment.issue_id == issue.id
      end
    end

    describe "timestamps" do
      test "sets inserted_at on creation" do
        comment = create_issue_comment!()
        assert %DateTime{} = comment.inserted_at
      end

      test "sets updated_at on creation" do
        comment = create_issue_comment!()
        assert %DateTime{} = comment.updated_at
      end

      test "updates updated_at on modification" do
        comment = create_issue_comment!()
        original_updated_at = comment.updated_at

        # Small delay to ensure timestamp difference
        Process.sleep(10)

        updated_comment =
          comment
          |> Ash.Changeset.for_update(
            :update,
            %{content: "Updated"},
            tenant: comment.site_id,
            authorize?: false
          )
          |> Ash.update!()

        assert DateTime.compare(updated_comment.updated_at, original_updated_at) == :gt
      end
    end
  end
end
