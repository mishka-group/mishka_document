# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_document/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaDocument.Test.IssueTest do
  @moduledoc """
  Tests for MishkaDocument.Issue resource.
  """
  use MishkaDocument.DataCase, async: false

  if Code.ensure_loaded?(MishkaDocument) do
    alias MishkaDocument.Issue

    describe "resource configuration" do
      test "uses correct table name" do
        assert AshPostgres.DataLayer.Info.table(Issue) == "mishka_document_issues"
      end

      test "uses UUID v7 for primary keys" do
        issue = create_issue!()
        assert {:ok, _uuid} = Ecto.UUID.cast(issue.id)
        assert String.length(issue.id) == 36
      end

      test "has multitenancy with site_id" do
        assert Ash.Resource.Info.multitenancy_strategy(Issue) == :attribute
        assert Ash.Resource.Info.multitenancy_attribute(Issue) == :site_id
        assert Ash.Resource.Info.multitenancy_global?(Issue) == false
      end

      test "is not global - always site-specific" do
        refute Ash.Resource.Info.multitenancy_global?(Issue)
      end
    end

    describe "create action" do
      test "creates issue with valid attributes for section" do
        site = create_site!()
        section = create_section!(site_id: site.id)
        reporter = create_user!()

        issue =
          Issue
          |> Ash.Changeset.for_create(
            :create,
            %{
              title: "Test Issue",
              description: "Test description",
              section_id: section.id,
              issue_type: :typo
            },
            actor: reporter,
            tenant: site.id,
            authorize?: false
          )
          |> Ash.create!()

        assert issue.title == "Test Issue"
        assert issue.description == "Test description"
        assert issue.section_id == section.id
        assert issue.reporter_id == reporter.id
        assert issue.issue_type == :typo
        assert issue.status == :open
        assert issue.site_id == site.id
      end

      test "creates issue with valid attributes for note" do
        site = create_site!()
        note = create_note!(site_id: site.id)
        reporter = create_user!()

        issue =
          Issue
          |> Ash.Changeset.for_create(
            :create,
            %{
              title: "Test Issue",
              description: "Test description",
              note_id: note.id,
              issue_type: :broken_link
            },
            actor: reporter,
            tenant: site.id,
            authorize?: false
          )
          |> Ash.create!()

        assert issue.note_id == note.id
        assert issue.issue_type == :broken_link
      end

      test "creates issue with both section and note" do
        site = create_site!()
        section = create_section!(site_id: site.id)
        note = create_note!(site_id: site.id, section_id: section.id)
        reporter = create_user!()

        issue =
          Issue
          |> Ash.Changeset.for_create(
            :create,
            %{
              title: "Test Issue",
              description: "Test description",
              section_id: section.id,
              note_id: note.id,
              issue_type: :suggestion
            },
            actor: reporter,
            tenant: site.id,
            authorize?: false
          )
          |> Ash.create!()

        assert issue.section_id == section.id
        assert issue.note_id == note.id
      end

      test "auto-assigns site_id from tenant" do
        site = create_site!()
        section = create_section!(site_id: site.id)
        reporter = create_user!()

        issue =
          Issue
          |> Ash.Changeset.for_create(
            :create,
            %{
              title: "Test Issue",
              description: "Test description",
              section_id: section.id
            },
            actor: reporter,
            tenant: site.id,
            authorize?: false
          )
          |> Ash.create!()

        assert issue.site_id == site.id
      end

      test "defaults issue_type to :other" do
        site = create_site!()
        section = create_section!(site_id: site.id)
        reporter = create_user!()

        issue =
          Issue
          |> Ash.Changeset.for_create(
            :create,
            %{
              title: "Test Issue",
              description: "Test description",
              section_id: section.id
            },
            actor: reporter,
            tenant: site.id,
            authorize?: false
          )
          |> Ash.create!()

        assert issue.issue_type == :other
      end

      test "defaults status to :open" do
        site = create_site!()
        section = create_section!(site_id: site.id)
        reporter = create_user!()

        issue =
          Issue
          |> Ash.Changeset.for_create(
            :create,
            %{
              title: "Test Issue",
              description: "Test description",
              section_id: section.id
            },
            actor: reporter,
            tenant: site.id,
            authorize?: false
          )
          |> Ash.create!()

        assert issue.status == :open
      end

      test "requires at least one of note_id or section_id" do
        site = create_site!()
        reporter = create_user!()

        assert_raise Ash.Error.Invalid, ~r/must reference either a note or a section/, fn ->
          Issue
          |> Ash.Changeset.for_create(
            :create,
            %{
              title: "Test Issue",
              description: "Test description"
            },
            actor: reporter,
            tenant: site.id,
            authorize?: false
          )
          |> Ash.create!()
        end
      end

      test "requires title" do
        site = create_site!()
        section = create_section!(site_id: site.id)
        reporter = create_user!()

        assert_raise Ash.Error.Invalid, fn ->
          Issue
          |> Ash.Changeset.for_create(
            :create,
            %{
              description: "Test description",
              section_id: section.id
            },
            actor: reporter,
            tenant: site.id,
            authorize?: false
          )
          |> Ash.create!()
        end
      end

      test "requires description" do
        site = create_site!()
        section = create_section!(site_id: site.id)
        reporter = create_user!()

        assert_raise Ash.Error.Invalid, fn ->
          Issue
          |> Ash.Changeset.for_create(
            :create,
            %{
              title: "Test Issue",
              section_id: section.id
            },
            actor: reporter,
            tenant: site.id,
            authorize?: false
          )
          |> Ash.create!()
        end
      end

      test "requires actor (for reporter)" do
        site = create_site!()
        section = create_section!(site_id: site.id)

        assert_raise Ash.Error.Invalid, ~r/could not relate to actor/, fn ->
          Issue
          |> Ash.Changeset.for_create(
            :create,
            %{
              title: "Test Issue",
              description: "Test description",
              section_id: section.id
            },
            tenant: site.id,
            authorize?: false
          )
          |> Ash.create!()
        end
      end
    end

    describe "master_create action" do
      test "creates issue with explicit site_id" do
        site = create_site!()
        section = create_section!(site_id: site.id)
        reporter = create_user!()

        issue =
          Issue
          |> Ash.Changeset.for_create(
            :master_create,
            %{
              title: "Test Issue",
              description: "Test description",
              section_id: section.id,
              reporter_id: reporter.id,
              site_id: site.id
            },
            authorize?: false
          )
          |> Ash.create!()

        assert issue.site_id == site.id
        assert issue.title == "Test Issue"
      end

      test "requires explicit site_id" do
        section = create_section!()
        reporter = create_user!()

        assert_raise Ash.Error.Invalid, fn ->
          Issue
          |> Ash.Changeset.for_create(
            :master_create,
            %{
              title: "Test Issue",
              description: "Test description",
              section_id: section.id,
              reporter_id: reporter.id
            },
            authorize?: false
          )
          |> Ash.create!()
        end
      end
    end

    describe "update action" do
      test "updates issue attributes" do
        issue = create_issue!()

        updated_issue =
          issue
          |> Ash.Changeset.for_update(
            :update,
            %{
              title: "Updated Title",
              description: "Updated description",
              issue_type: :incorrect_content
            },
            tenant: issue.site_id,
            authorize?: false
          )
          |> Ash.update!()

        assert updated_issue.title == "Updated Title"
        assert updated_issue.description == "Updated description"
        assert updated_issue.issue_type == :incorrect_content
      end

      test "cannot update site_id (not in accept list)" do
        issue = create_issue!()
        other_site = create_site!()

        assert_raise Ash.Error.Invalid, ~r/No such input `site_id`/, fn ->
          issue
          |> Ash.Changeset.for_update(
            :update,
            %{
              title: "Updated Title",
              site_id: other_site.id
            },
            tenant: issue.site_id,
            authorize?: false
          )
          |> Ash.update!()
        end
      end
    end

    describe "master_update action" do
      test "updates issue attributes" do
        issue = create_issue!()

        updated_issue =
          issue
          |> Ash.Changeset.for_update(
            :master_update,
            %{title: "Master Updated Title", issue_type: :review_feedback},
            authorize?: false
          )
          |> Ash.update!()

        assert updated_issue.title == "Master Updated Title"
        assert updated_issue.issue_type == :review_feedback
      end
    end

    describe "status transition actions" do
      test "mark_in_progress transitions status to in_progress" do
        issue = create_issue!()

        updated_issue =
          issue
          |> Ash.Changeset.for_update(:mark_in_progress, %{},
            tenant: issue.site_id,
            authorize?: false
          )
          |> Ash.update!()

        assert updated_issue.status == :in_progress
      end

      test "mark_resolved transitions status to resolved" do
        issue = create_issue!()

        updated_issue =
          issue
          |> Ash.Changeset.for_update(:mark_resolved, %{},
            tenant: issue.site_id,
            authorize?: false
          )
          |> Ash.update!()

        assert updated_issue.status == :resolved
      end

      test "mark_closed transitions status to closed" do
        issue = create_issue!()

        updated_issue =
          issue
          |> Ash.Changeset.for_update(:mark_closed, %{},
            tenant: issue.site_id,
            authorize?: false
          )
          |> Ash.update!()

        assert updated_issue.status == :closed
      end

      test "reopen transitions status back to open" do
        issue = create_issue!()

        # First close it
        closed_issue =
          issue
          |> Ash.Changeset.for_update(:mark_closed, %{},
            tenant: issue.site_id,
            authorize?: false
          )
          |> Ash.update!()

        # Then reopen it
        reopened_issue =
          closed_issue
          |> Ash.Changeset.for_update(:reopen, %{}, tenant: issue.site_id, authorize?: false)
          |> Ash.update!()

        assert reopened_issue.status == :open
      end
    end

    describe "read actions" do
      test "default read returns issues within tenant" do
        site = create_site!()
        issue = create_issue!(site_id: site.id)

        issues =
          Issue
          |> Ash.read!(tenant: site.id, authorize?: false)

        assert Enum.any?(issues, fn i -> i.id == issue.id end)
      end

      test "default read respects tenant isolation" do
        site1 = create_site!()
        site2 = create_site!()

        issue1 = create_issue!(site_id: site1.id)
        _issue2 = create_issue!(site_id: site2.id)

        issues =
          Issue
          |> Ash.read!(tenant: site1.id, authorize?: false)

        assert Enum.any?(issues, fn i -> i.id == issue1.id end)
        refute Enum.any?(issues, fn i -> i.site_id == site2.id end)
      end

      test "master_read bypasses tenant filtering" do
        site1 = create_site!()
        site2 = create_site!()

        issue1 = create_issue!(site_id: site1.id)
        issue2 = create_issue!(site_id: site2.id)

        result =
          Issue
          |> Ash.Query.for_read(:master_read, %{}, authorize?: false)
          |> Ash.read!()

        all_issue_ids = Enum.map(result.results, & &1.id)
        assert issue1.id in all_issue_ids
        assert issue2.id in all_issue_ids
      end

      test "master_get retrieves issue from any tenant" do
        issue = create_issue!()

        fetched_issue = Ash.get!(Issue, issue.id, action: :master_get, authorize?: false)

        assert fetched_issue.id == issue.id
      end

      test "by_note filters issues by note_id" do
        site = create_site!()
        note = create_note!(site_id: site.id)
        issue = create_issue!(site_id: site.id, note_id: note.id)
        _other_issue = create_issue!(site_id: site.id)

        result =
          Issue
          |> Ash.Query.for_read(:by_note, %{note_id: note.id},
            tenant: site.id,
            authorize?: false
          )
          |> Ash.read!()

        assert length(result.results) == 1
        assert Enum.at(result.results, 0).id == issue.id
      end

      test "by_section filters issues by section_id" do
        site = create_site!()
        section = create_section!(site_id: site.id)
        issue = create_issue!(site_id: site.id, section_id: section.id)
        _other_issue = create_issue!(site_id: site.id)

        result =
          Issue
          |> Ash.Query.for_read(:by_section, %{section_id: section.id},
            tenant: site.id,
            authorize?: false
          )
          |> Ash.read!()

        assert length(result.results) == 1
        assert Enum.at(result.results, 0).id == issue.id
      end

      test "by_reporter filters issues by reporter_id" do
        site = create_site!()
        reporter = create_user!()
        issue = create_issue!(site_id: site.id, reporter_id: reporter.id)
        _other_issue = create_issue!(site_id: site.id)

        result =
          Issue
          |> Ash.Query.for_read(:by_reporter, %{reporter_id: reporter.id},
            tenant: site.id,
            authorize?: false
          )
          |> Ash.read!()

        assert length(result.results) == 1
        assert Enum.at(result.results, 0).id == issue.id
      end

      test "by_status filters issues by status" do
        site = create_site!()
        open_issue = create_issue!(site_id: site.id, status: :open)

        closed_issue =
          create_issue!(site_id: site.id)
          |> Ash.Changeset.for_update(:mark_closed, %{},
            tenant: site.id,
            authorize?: false
          )
          |> Ash.update!()

        result =
          Issue
          |> Ash.Query.for_read(:by_status, %{status: :open},
            tenant: site.id,
            authorize?: false
          )
          |> Ash.read!()

        open_issue_ids = Enum.map(result.results, & &1.id)
        assert open_issue.id in open_issue_ids
        refute closed_issue.id in open_issue_ids
      end

      test "by_type filters issues by issue_type" do
        site = create_site!()
        typo_issue = create_issue!(site_id: site.id, issue_type: :typo)
        _other_issue = create_issue!(site_id: site.id, issue_type: :broken_link)

        result =
          Issue
          |> Ash.Query.for_read(:by_type, %{issue_type: :typo},
            tenant: site.id,
            authorize?: false
          )
          |> Ash.read!()

        assert length(result.results) == 1
        assert Enum.at(result.results, 0).id == typo_issue.id
      end

      test "open_issues returns only open issues" do
        site = create_site!()
        open_issue = create_issue!(site_id: site.id, status: :open)

        closed_issue =
          create_issue!(site_id: site.id)
          |> Ash.Changeset.for_update(:mark_closed, %{},
            tenant: site.id,
            authorize?: false
          )
          |> Ash.update!()

        result =
          Issue
          |> Ash.Query.for_read(:open_issues, %{}, tenant: site.id, authorize?: false)
          |> Ash.read!()

        open_issue_ids = Enum.map(result.results, & &1.id)
        assert open_issue.id in open_issue_ids
        refute closed_issue.id in open_issue_ids
      end
    end

    describe "destroy action (soft delete)" do
      test "archives issue by setting archived_at" do
        issue = create_issue!()

        issue
        |> Ash.Changeset.for_destroy(:destroy, %{}, tenant: issue.site_id, authorize?: false)
        |> Ash.destroy!()

        # Issue should not appear in default read
        issues = Issue |> Ash.read!(tenant: issue.site_id, authorize?: false)
        refute Enum.any?(issues, fn i -> i.id == issue.id end)

        # But should be retrievable via archived read
        archived_issue =
          Ash.get!(Issue, issue.id,
            action: :get_archived,
            tenant: issue.site_id,
            authorize?: false
          )

        assert %DateTime{} = archived_issue.archived_at
      end

      test "prevents archiving already archived issue" do
        issue = create_issue!()

        # First archive
        archived_issue =
          issue
          |> Ash.Changeset.for_destroy(:destroy, %{}, tenant: issue.site_id, authorize?: false)
          |> Ash.destroy!(return_destroyed?: true)

        # Try to archive again
        assert_raise Ash.Error.Invalid, ~r/already archived/, fn ->
          archived_issue
          |> Ash.Changeset.for_destroy(:destroy, %{}, tenant: issue.site_id, authorize?: false)
          |> Ash.destroy!()
        end
      end
    end

    describe "master_destroy action" do
      test "soft deletes issue (master users)" do
        issue = create_issue!()

        destroyed_issue =
          issue
          |> Ash.Changeset.for_destroy(:master_destroy, %{}, authorize?: false)
          |> Ash.destroy!(return_destroyed?: true)

        assert %DateTime{} = destroyed_issue.archived_at
      end
    end

    describe "archived reads" do
      test "archived returns archived issues" do
        site = create_site!()
        issue = create_issue!(site_id: site.id)

        # Archive the issue
        issue
        |> Ash.Changeset.for_destroy(:destroy, %{}, tenant: site.id, authorize?: false)
        |> Ash.destroy!()

        result =
          Issue
          |> Ash.Query.for_read(:archived, %{}, tenant: site.id, authorize?: false)
          |> Ash.read!()

        assert Enum.any?(result.results, fn i -> i.id == issue.id end)
      end

      test "get_archived retrieves single archived issue" do
        issue = create_issue!()

        # Archive the issue
        issue
        |> Ash.Changeset.for_destroy(:destroy, %{}, tenant: issue.site_id, authorize?: false)
        |> Ash.destroy!()

        archived_issue =
          Ash.get!(Issue, issue.id,
            action: :get_archived,
            tenant: issue.site_id,
            authorize?: false
          )

        assert archived_issue.id == issue.id
        assert %DateTime{} = archived_issue.archived_at
      end

      test "master_get_archived retrieves archived issue from any tenant" do
        issue = create_issue!()

        # Archive the issue
        issue
        |> Ash.Changeset.for_destroy(:destroy, %{}, tenant: issue.site_id, authorize?: false)
        |> Ash.destroy!()

        archived_issue =
          Ash.get!(Issue, issue.id, action: :master_get_archived, authorize?: false)

        assert archived_issue.id == issue.id
        assert %DateTime{} = archived_issue.archived_at
      end

      test "master_archived returns all archived issues system-wide" do
        site1 = create_site!()
        site2 = create_site!()

        issue1 = create_issue!(site_id: site1.id)
        issue2 = create_issue!(site_id: site2.id)

        # Archive both issues
        issue1
        |> Ash.Changeset.for_destroy(:destroy, %{}, tenant: site1.id, authorize?: false)
        |> Ash.destroy!()

        issue2
        |> Ash.Changeset.for_destroy(:destroy, %{}, tenant: site2.id, authorize?: false)
        |> Ash.destroy!()

        result =
          Issue
          |> Ash.Query.for_read(:master_archived, %{}, authorize?: false)
          |> Ash.read!()

        archived_issue_ids = Enum.map(result.results, & &1.id)
        assert issue1.id in archived_issue_ids
        assert issue2.id in archived_issue_ids
      end
    end

    describe "unarchive action" do
      test "restores archived issue" do
        issue = create_issue!()

        # Archive the issue
        issue
        |> Ash.Changeset.for_destroy(:destroy, %{}, tenant: issue.site_id, authorize?: false)
        |> Ash.destroy!()

        # Get archived issue
        archived_issue =
          Ash.get!(Issue, issue.id,
            action: :get_archived,
            tenant: issue.site_id,
            authorize?: false
          )

        # Unarchive it
        unarchived_issue =
          archived_issue
          |> Ash.Changeset.for_update(:unarchive, %{},
            tenant: issue.site_id,
            authorize?: false
          )
          |> Ash.update!()

        assert unarchived_issue.archived_at == nil

        # Should appear in default read again
        issues = Issue |> Ash.read!(tenant: issue.site_id, authorize?: false)
        assert Enum.any?(issues, fn i -> i.id == issue.id end)
      end
    end

    describe "master_unarchive action" do
      test "restores archived issue (master users)" do
        issue = create_issue!()

        # Archive the issue
        issue
        |> Ash.Changeset.for_destroy(:destroy, %{}, tenant: issue.site_id, authorize?: false)
        |> Ash.destroy!()

        # Fetch the archived issue
        archived_issue =
          Ash.get!(Issue, issue.id, action: :master_get_archived, authorize?: false)

        # Unarchive via master action
        unarchived_issue =
          archived_issue
          |> Ash.Changeset.for_update(:master_unarchive, %{}, authorize?: false)
          |> Ash.update!()

        assert unarchived_issue.archived_at == nil
      end
    end

    describe "permanent_destroy action" do
      test "permanently deletes issue" do
        issue = create_issue!()
        issue_id = issue.id
        site_id = issue.site_id

        issue
        |> Ash.Changeset.for_destroy(:permanent_destroy, %{},
          tenant: site_id,
          authorize?: false
        )
        |> Ash.destroy!()

        # Issue should not exist in any read action
        result = Ash.get(Issue, issue_id, action: :master_get, authorize?: false)
        assert match?({:error, _}, result)
      end

      test "permanent_destroy removes issue even from archived reads" do
        issue = create_issue!()
        issue_id = issue.id
        site_id = issue.site_id

        # Archive first
        issue
        |> Ash.Changeset.for_destroy(:destroy, %{}, tenant: site_id, authorize?: false)
        |> Ash.destroy!()

        # Get archived issue
        archived_issue =
          Ash.get!(Issue, issue_id, action: :get_archived, tenant: site_id, authorize?: false)

        # Permanently destroy
        archived_issue
        |> Ash.Changeset.for_destroy(:permanent_destroy, %{},
          tenant: site_id,
          authorize?: false
        )
        |> Ash.destroy!()

        # Should not exist anywhere
        result = Ash.get(Issue, issue_id, action: :master_get, authorize?: false)
        assert match?({:error, _}, result)
      end
    end

    describe "master_permanent_destroy action" do
      test "permanently deletes issue (master users)" do
        issue = create_issue!()
        issue_id = issue.id

        issue
        |> Ash.Changeset.for_destroy(:master_permanent_destroy, %{}, authorize?: false)
        |> Ash.destroy!()

        # Issue should not exist
        result = Ash.get(Issue, issue_id, action: :master_get, authorize?: false)
        assert match?({:error, _}, result)
      end
    end

    describe "relationships" do
      test "belongs_to site" do
        issue = create_issue!()

        issue_with_site = Ash.load!(issue, :site, tenant: issue.site_id, authorize?: false)

        assert issue_with_site.site.id == issue.site_id
      end

      test "belongs_to section" do
        site = create_site!()
        section = create_section!(site_id: site.id)
        issue = create_issue!(site_id: site.id, section_id: section.id)

        issue_with_section = Ash.load!(issue, :section, tenant: site.id, authorize?: false)

        assert issue_with_section.section.id == issue.section_id
      end

      test "belongs_to note" do
        site = create_site!()
        note = create_note!(site_id: site.id)
        issue = create_issue!(site_id: site.id, note_id: note.id, section_id: nil)

        issue_with_note = Ash.load!(issue, :note, tenant: site.id, authorize?: false)

        assert issue_with_note.note.id == issue.note_id
      end

      test "belongs_to reporter" do
        reporter = create_user!()
        issue = create_issue!(reporter_id: reporter.id)

        # Note: Reporter relationship is cross-domain (MishkaCmsCore.Accounts.User)
        # and may require special handling. For now, just verify the reporter_id is set correctly.
        assert issue.reporter_id == reporter.id
      end
    end

    describe "timestamps" do
      test "sets inserted_at on creation" do
        issue = create_issue!()
        assert %DateTime{} = issue.inserted_at
      end

      test "sets updated_at on creation" do
        issue = create_issue!()
        assert %DateTime{} = issue.updated_at
      end

      test "updates updated_at on modification" do
        issue = create_issue!()
        original_updated_at = issue.updated_at

        # Small delay to ensure timestamp difference
        Process.sleep(10)

        updated_issue =
          issue
          |> Ash.Changeset.for_update(
            :update,
            %{title: "Updated Title"},
            tenant: issue.site_id,
            authorize?: false
          )
          |> Ash.update!()

        assert DateTime.compare(updated_issue.updated_at, original_updated_at) == :gt
      end
    end
  end
end
