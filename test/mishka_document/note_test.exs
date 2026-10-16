# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_document/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaDocument.Test.NoteTest do
  @moduledoc """
  Tests for MishkaDocument.Note resource.
  """
  use MishkaDocument.DataCase, async: false

  if Code.ensure_loaded?(MishkaDocument) do
    alias MishkaDocument.Note

    describe "resource configuration" do
      test "uses correct table name" do
        assert AshPostgres.DataLayer.Info.table(Note) == "mishka_document_notes"
      end

      test "uses UUID v7 for primary keys" do
        note = create_note!()
        assert is_binary(note.id)
        assert String.length(note.id) == 36
      end

      test "uses multitenancy with site_id" do
        assert Ash.Resource.Info.multitenancy_strategy(Note) == :attribute
        assert Ash.Resource.Info.multitenancy_attribute(Note) == :site_id
        assert Ash.Resource.Info.multitenancy_global?(Note) == false
      end

      test "has archival enabled" do
        extensions = Ash.Resource.Info.extensions(Note)
        assert AshArchival.Resource in extensions
      end
    end

    describe "create action" do
      test "creates note with valid attributes" do
        site = create_site!()
        section = create_section!(site_id: site.id)

        note =
          Note
          |> Ash.Changeset.for_create(
            :create,
            %{
              section_id: section.id,
              title: "Test Note",
              content: "Test content"
            },
            tenant: site.id,
            authorize?: false
          )
          |> Ash.create!()

        assert note.title == "Test Note"
        assert note.content == "Test content"
        assert note.section_id == section.id
        assert note.site_id == site.id
      end

      test "auto-assigns site_id from tenant" do
        site = create_site!()
        section = create_section!(site_id: site.id)

        note =
          Note
          |> Ash.Changeset.for_create(
            :create,
            %{
              section_id: section.id,
              title: "Test",
              content: "Content"
            },
            tenant: site.id,
            authorize?: false
          )
          |> Ash.create!()

        assert note.site_id == site.id
      end

      test "sets default values" do
        note = create_note!()

        assert note.order_position == 0
        assert note.change_version == "0.0.1"
        assert note.content_review_status == :pending
        assert note.technical_review_status == :pending
        assert note.schema == []
        assert note.seo_tags == []
      end

      test "requires section_id" do
        site = create_site!()

        assert_raise Ash.Error.Invalid, fn ->
          Note
          |> Ash.Changeset.for_create(
            :create,
            %{
              title: "Test",
              content: "Content"
            },
            tenant: site.id,
            authorize?: false
          )
          |> Ash.create!()
        end
      end

      test "requires title" do
        site = create_site!()
        section = create_section!(site_id: site.id)

        assert_raise Ash.Error.Invalid, fn ->
          Note
          |> Ash.Changeset.for_create(
            :create,
            %{
              section_id: section.id,
              content: "Content"
            },
            tenant: site.id,
            authorize?: false
          )
          |> Ash.create!()
        end
      end

      test "requires content" do
        site = create_site!()
        section = create_section!(site_id: site.id)

        assert_raise Ash.Error.Invalid, fn ->
          Note
          |> Ash.Changeset.for_create(
            :create,
            %{
              section_id: section.id,
              title: "Test"
            },
            tenant: site.id,
            authorize?: false
          )
          |> Ash.create!()
        end
      end
    end

    describe "master_create action" do
      test "creates note with explicit site_id" do
        site = create_site!()
        section = create_section!(site_id: site.id)

        note =
          Note
          |> Ash.Changeset.for_create(
            :master_create,
            %{
              section_id: section.id,
              title: "Test Note",
              content: "Test content",
              site_id: site.id
            },
            authorize?: false
          )
          |> Ash.create!()

        assert note.title == "Test Note"
        assert note.site_id == site.id
      end

      test "requires explicit site_id" do
        section = create_section!()

        assert_raise Ash.Error.Invalid, fn ->
          Note
          |> Ash.Changeset.for_create(
            :master_create,
            %{
              section_id: section.id,
              title: "Test",
              content: "Content"
            },
            authorize?: false
          )
          |> Ash.create!()
        end
      end
    end

    describe "read actions" do
      test "default read returns notes in tenant" do
        site = create_site!()
        note = create_note!(site_id: site.id)

        notes =
          Note
          |> Ash.read!(tenant: site.id, authorize?: false)

        assert Enum.any?(notes, fn n -> n.id == note.id end)
      end

      test "default read respects tenant isolation" do
        site1 = create_site!()
        site2 = create_site!()
        note1 = create_note!(site_id: site1.id)
        _note2 = create_note!(site_id: site2.id)

        notes =
          Note
          |> Ash.read!(tenant: site1.id, authorize?: false)

        note_ids = Enum.map(notes, & &1.id)
        assert note1.id in note_ids
        refute Enum.any?(notes, fn n -> n.site_id == site2.id end)
      end

      test "master_read bypasses tenant filtering" do
        site1 = create_site!()
        site2 = create_site!()
        note1 = create_note!(site_id: site1.id)
        note2 = create_note!(site_id: site2.id)

        result =
          Note
          |> Ash.Query.for_read(:master_read, %{}, authorize?: false)
          |> Ash.read!()

        note_ids = Enum.map(result.results, & &1.id)
        assert note1.id in note_ids
        assert note2.id in note_ids
      end

      test "master_get bypasses tenant filtering" do
        note = create_note!()

        fetched_note = Ash.get!(Note, note.id, action: :master_get, authorize?: false)
        assert fetched_note.id == note.id
      end

      test "by_section filters by section_id" do
        site = create_site!()
        section1 = create_section!(site_id: site.id)
        section2 = create_section!(site_id: site.id)

        note1 = create_note!(section_id: section1.id, site_id: site.id)
        _note2 = create_note!(section_id: section2.id, site_id: site.id)

        result =
          Note
          |> Ash.Query.for_read(:by_section, %{section_id: section1.id},
            tenant: site.id,
            authorize?: false
          )
          |> Ash.read!()

        assert length(result.results) == 1
        assert Enum.at(result.results, 0).id == note1.id
      end

      test "public_list only returns approved notes" do
        site = create_site!()
        section = create_section!(site_id: site.id)

        approved_note =
          create_note!(
            section_id: section.id,
            site_id: site.id,
            content_review_status: :approved,
            technical_review_status: :approved
          )

        _pending_note =
          create_note!(
            section_id: section.id,
            site_id: site.id,
            content_review_status: :pending,
            technical_review_status: :pending
          )

        notes =
          Note
          |> Ash.Query.for_read(:public_list, %{}, tenant: site.id, authorize?: false)
          |> Ash.read!()

        note_ids = Enum.map(notes, & &1.id)
        assert approved_note.id in note_ids
        refute Enum.any?(notes, fn n -> n.content_review_status == :pending end)
      end

      test "public_get only returns approved note" do
        site = create_site!()

        approved_note =
          create_note!(
            site_id: site.id,
            content_review_status: :approved,
            technical_review_status: :approved
          )

        pending_note =
          create_note!(
            site_id: site.id,
            content_review_status: :pending,
            technical_review_status: :pending
          )

        # Can get approved note
        fetched =
          Ash.get!(Note, approved_note.id,
            action: :public_get,
            tenant: site.id,
            authorize?: false
          )

        assert fetched.id == approved_note.id

        # Cannot get pending note
        result =
          Ash.get(Note, pending_note.id,
            action: :public_get,
            tenant: site.id,
            authorize?: false
          )

        assert match?({:error, _}, result)
      end
    end

    describe "update action" do
      test "updates note attributes" do
        note = create_note!()

        updated_note =
          note
          |> Ash.Changeset.for_update(
            :update,
            %{
              title: "Updated Title",
              content: "Updated Content"
            },
            tenant: note.site_id,
            authorize?: false
          )
          |> Ash.update!()

        assert updated_note.title == "Updated Title"
        assert updated_note.content == "Updated Content"
      end

      test "can update review statuses" do
        note = create_note!()

        updated_note =
          note
          |> Ash.Changeset.for_update(
            :update,
            %{
              content_review_status: :approved,
              technical_review_status: :approved
            },
            tenant: note.site_id,
            authorize?: false
          )
          |> Ash.update!()

        assert updated_note.content_review_status == :approved
        assert updated_note.technical_review_status == :approved
      end

      test "cannot update site_id (not in accept list)" do
        note = create_note!()
        other_site = create_site!()

        # site_id is not in the accept list, attempting to include it raises error
        assert_raise Ash.Error.Invalid, ~r/No such input `site_id`/, fn ->
          note
          |> Ash.Changeset.for_update(
            :update,
            %{
              title: "New Title",
              site_id: other_site.id
            },
            tenant: note.site_id,
            authorize?: false
          )
          |> Ash.update!()
        end
      end
    end

    describe "destroy action (soft delete)" do
      test "archives note by setting archived_at" do
        note = create_note!()

        note
        |> Ash.Changeset.for_destroy(:destroy, %{}, tenant: note.site_id, authorize?: false)
        |> Ash.destroy!()

        # Note should still exist but be archived
        archived_note =
          Ash.get!(Note, note.id, action: :get_archived, tenant: note.site_id, authorize?: false)

        assert archived_note.archived_at != nil
        assert archived_note.content_review_status == :archived
        assert archived_note.technical_review_status == :archived
      end

      test "archived note not returned in default read" do
        site = create_site!()
        note = create_note!(site_id: site.id)

        note
        |> Ash.Changeset.for_destroy(:destroy, %{}, tenant: site.id, authorize?: false)
        |> Ash.destroy!()

        notes =
          Note
          |> Ash.read!(tenant: site.id, authorize?: false)

        refute Enum.any?(notes, fn n -> n.id == note.id end)
      end

      test "archived note returned in archived read action" do
        site = create_site!()
        note = create_note!(site_id: site.id)

        note
        |> Ash.Changeset.for_destroy(:destroy, %{}, tenant: site.id, authorize?: false)
        |> Ash.destroy!()

        result =
          Note
          |> Ash.Query.for_read(:archived, %{}, tenant: site.id, authorize?: false)
          |> Ash.read!()

        assert Enum.any?(result.results, fn n -> n.id == note.id end)
      end

      test "cannot archive already archived note" do
        note = create_note!()

        note
        |> Ash.Changeset.for_destroy(:destroy, %{}, tenant: note.site_id, authorize?: false)
        |> Ash.destroy!()

        archived_note =
          Ash.get!(Note, note.id, action: :get_archived, tenant: note.site_id, authorize?: false)

        assert_raise Ash.Error.Invalid, fn ->
          archived_note
          |> Ash.Changeset.for_destroy(:destroy, %{}, tenant: note.site_id, authorize?: false)
          |> Ash.destroy!()
        end
      end
    end

    describe "unarchive action" do
      test "restores archived note" do
        note = create_note!()

        # Archive it
        note
        |> Ash.Changeset.for_destroy(:destroy, %{}, tenant: note.site_id, authorize?: false)
        |> Ash.destroy!()

        # Get archived note
        archived_note =
          Ash.get!(Note, note.id, action: :get_archived, tenant: note.site_id, authorize?: false)

        # Unarchive it
        unarchived_note =
          archived_note
          |> Ash.Changeset.for_update(:unarchive, %{}, tenant: note.site_id, authorize?: false)
          |> Ash.update!()

        assert unarchived_note.archived_at == nil
        assert unarchived_note.content_review_status == :pending
        assert unarchived_note.technical_review_status == :pending
      end

      test "unarchived note appears in default read" do
        site = create_site!()
        note = create_note!(site_id: site.id)

        # Archive
        note
        |> Ash.Changeset.for_destroy(:destroy, %{}, tenant: site.id, authorize?: false)
        |> Ash.destroy!()

        # Unarchive
        archived_note =
          Ash.get!(Note, note.id, action: :get_archived, tenant: site.id, authorize?: false)

        archived_note
        |> Ash.Changeset.for_update(:unarchive, %{}, tenant: site.id, authorize?: false)
        |> Ash.update!()

        # Should appear in default read
        notes =
          Note
          |> Ash.read!(tenant: site.id, authorize?: false)

        assert Enum.any?(notes, fn n -> n.id == note.id end)
      end
    end

    describe "permanent_destroy action" do
      test "permanently deletes note" do
        note = create_note!()
        note_id = note.id

        note
        |> Ash.Changeset.for_destroy(:permanent_destroy, %{},
          tenant: note.site_id,
          authorize?: false
        )
        |> Ash.destroy!()

        # Note should be completely gone
        result = Ash.get(Note, note_id, action: :master_get, authorize?: false)
        assert match?({:error, _}, result)
      end

      test "permanent_destroy removes note even from archived reads" do
        site = create_site!()
        note = create_note!(site_id: site.id)
        note_id = note.id

        note
        |> Ash.Changeset.for_destroy(:permanent_destroy, %{}, tenant: site.id, authorize?: false)
        |> Ash.destroy!()

        result =
          Ash.get(Note, note_id, action: :get_archived, tenant: site.id, authorize?: false)

        assert match?({:error, _}, result)
      end
    end

    describe "relationships" do
      test "belongs_to site" do
        note = create_note!()

        note_with_site = Ash.load!(note, :site, tenant: note.site_id, authorize?: false)

        assert note_with_site.site.id == note.site_id
      end

      test "belongs_to section" do
        note = create_note!()

        note_with_section =
          Ash.load!(note, :section, tenant: note.site_id, authorize?: false)

        assert note_with_section.section.id == note.section_id
      end
    end

    describe "check constraints" do
      test "title cannot be empty string" do
        site = create_site!()
        section = create_section!(site_id: site.id)

        assert_raise Ash.Error.Invalid, fn ->
          Note
          |> Ash.Changeset.for_create(
            :create,
            %{
              section_id: section.id,
              title: "",
              content: "Content"
            },
            tenant: site.id,
            authorize?: false
          )
          |> Ash.create!()
        end
      end

      test "content cannot be empty string" do
        site = create_site!()
        section = create_section!(site_id: site.id)

        assert_raise Ash.Error.Invalid, fn ->
          Note
          |> Ash.Changeset.for_create(
            :create,
            %{
              section_id: section.id,
              title: "Title",
              content: ""
            },
            tenant: site.id,
            authorize?: false
          )
          |> Ash.create!()
        end
      end

      test "order_position must be non-negative" do
        site = create_site!()
        section = create_section!(site_id: site.id)

        assert_raise Ash.Error.Invalid, fn ->
          Note
          |> Ash.Changeset.for_create(
            :create,
            %{
              section_id: section.id,
              title: "Title",
              content: "Content",
              order_position: -1
            },
            tenant: site.id,
            authorize?: false
          )
          |> Ash.create!()
        end
      end
    end

    describe "timestamps" do
      test "sets inserted_at on creation" do
        note = create_note!()
        assert note.inserted_at != nil
        assert %DateTime{} = note.inserted_at
      end

      test "sets updated_at on creation" do
        note = create_note!()
        assert note.updated_at != nil
        assert %DateTime{} = note.updated_at
      end

      test "updates updated_at on modification" do
        note = create_note!()
        original_updated_at = note.updated_at

        # Small delay to ensure timestamp difference
        :timer.sleep(10)

        updated_note =
          note
          |> Ash.Changeset.for_update(
            :update,
            %{title: "New Title"},
            tenant: note.site_id,
            authorize?: false
          )
          |> Ash.update!()

        assert DateTime.compare(updated_note.updated_at, original_updated_at) == :gt
      end
    end

    describe "content_word_count calculation" do
      test "counts words in content field" do
        site = create_site!()

        note =
          create_note!(
            site_id: site.id,
            title: "Test Note",
            content: "This is a test note with some content here"
          )

        note_with_count =
          Ash.get!(Note, note.id,
            tenant: site.id,
            authorize?: false,
            load: [:content_word_count]
          )

        # "This is a test note with some content here" = 9 words
        assert note_with_count.content_word_count == 9
      end
    end
  end
end
