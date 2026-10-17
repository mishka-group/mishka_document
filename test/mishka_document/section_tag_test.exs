# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_document/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaDocument.Test.SectionTagTest do
  @moduledoc """
  Tests for MishkaDocument.SectionTag resource (join table between Section and Tag).
  """
  use MishkaDocument.DataCase, async: false

  if Code.ensure_loaded?(MishkaDocument) do
    alias MishkaDocument.Section
    alias MishkaDocument.SectionTag
    alias MishkaDocument.Tag

    require Ash.Query
    import Ash.Expr

    describe "resource configuration" do
      test "uses correct table name" do
        assert AshPostgres.DataLayer.Info.table(SectionTag) == "mishka_document_section_tags"
      end

      test "has composite primary key (section_id, tag_id)" do
        section_tag = create_section_tag!()
        assert {:ok, _uuid} = Ecto.UUID.cast(section_tag.section_id)
        assert {:ok, _uuid} = Ecto.UUID.cast(section_tag.tag_id)
        assert String.length(section_tag.section_id) == 36
        assert String.length(section_tag.tag_id) == 36
      end

      test "has no multitenancy" do
        # SectionTag join table does not use multitenancy directly
        assert Ash.Resource.Info.multitenancy_strategy(SectionTag) == nil
      end

      test "has unique identity on section_id and tag_id" do
        identities = Ash.Resource.Info.identities(SectionTag)
        unique_identity = Enum.find(identities, &(&1.name == :unique_section_tag))
        assert %{keys: [:section_id, :tag_id]} = unique_identity
      end
    end

    describe "assign action (primary create)" do
      test "creates section_tag with valid section and tag" do
        site = create_site!()
        section = create_section!(site_id: site.id)
        tag = create_document_tag!(site_id: site.id)

        section_tag =
          SectionTag
          |> Ash.Changeset.for_create(
            :assign,
            %{section_id: section.id, tag_id: tag.id},
            authorize?: false
          )
          |> Ash.create!()

        assert section_tag.section_id == section.id
        assert section_tag.tag_id == tag.id
      end

      test "upserts when section_tag already exists" do
        site = create_site!()
        section = create_section!(site_id: site.id)
        tag = create_document_tag!(site_id: site.id)

        # Create first section_tag
        section_tag1 =
          SectionTag
          |> Ash.Changeset.for_create(
            :assign,
            %{section_id: section.id, tag_id: tag.id},
            authorize?: false
          )
          |> Ash.create!()

        # Try to create same section_tag again (should upsert)
        section_tag2 =
          SectionTag
          |> Ash.Changeset.for_create(
            :assign,
            %{section_id: section.id, tag_id: tag.id},
            authorize?: false
          )
          |> Ash.create!()

        # Should be the same record (same composite key)
        assert section_tag1.section_id == section_tag2.section_id
        assert section_tag1.tag_id == section_tag2.tag_id
      end

      test "same section can have multiple tags" do
        site = create_site!()
        section = create_section!(site_id: site.id)
        tag1 = create_document_tag!(site_id: site.id, name: "Tag 1")
        tag2 = create_document_tag!(site_id: site.id, name: "Tag 2")

        section_tag1 =
          SectionTag
          |> Ash.Changeset.for_create(
            :assign,
            %{section_id: section.id, tag_id: tag1.id},
            authorize?: false
          )
          |> Ash.create!()

        section_tag2 =
          SectionTag
          |> Ash.Changeset.for_create(
            :assign,
            %{section_id: section.id, tag_id: tag2.id},
            authorize?: false
          )
          |> Ash.create!()

        assert section_tag1.section_id == section_tag2.section_id
        assert section_tag1.tag_id != section_tag2.tag_id
      end

      test "same tag can be assigned to multiple sections" do
        site = create_site!()
        section1 = create_section!(site_id: site.id, title: "Section 1")
        section2 = create_section!(site_id: site.id, title: "Section 2")
        tag = create_document_tag!(site_id: site.id)

        section_tag1 =
          SectionTag
          |> Ash.Changeset.for_create(
            :assign,
            %{section_id: section1.id, tag_id: tag.id},
            authorize?: false
          )
          |> Ash.create!()

        section_tag2 =
          SectionTag
          |> Ash.Changeset.for_create(
            :assign,
            %{section_id: section2.id, tag_id: tag.id},
            authorize?: false
          )
          |> Ash.create!()

        assert section_tag1.section_id != section_tag2.section_id
        assert section_tag1.tag_id == section_tag2.tag_id
      end
    end

    describe "read actions" do
      test "default read action returns section_tags" do
        section_tag = create_section_tag!()

        section_tags = SectionTag |> Ash.read!(authorize?: false)

        assert Enum.any?(section_tags, fn st ->
                 st.section_id == section_tag.section_id and st.tag_id == section_tag.tag_id
               end)
      end

      test "can filter by section_id" do
        site = create_site!()
        section1 = create_section!(site_id: site.id)
        section2 = create_section!(site_id: site.id)
        tag = create_document_tag!(site_id: site.id)

        _section_tag1 = create_section_tag!(section_id: section1.id, tag_id: tag.id)
        _section_tag2 = create_section_tag!(section_id: section2.id, tag_id: tag.id)

        section_tags =
          SectionTag
          |> Ash.Query.filter(expr(section_id == ^section1.id))
          |> Ash.read!(authorize?: false)

        assert length(section_tags) == 1
        assert Enum.at(section_tags, 0).section_id == section1.id
      end

      test "can filter by tag_id" do
        site = create_site!()
        section = create_section!(site_id: site.id)
        tag1 = create_document_tag!(site_id: site.id, name: "Tag 1")
        tag2 = create_document_tag!(site_id: site.id, name: "Tag 2")

        _section_tag1 = create_section_tag!(section_id: section.id, tag_id: tag1.id)
        _section_tag2 = create_section_tag!(section_id: section.id, tag_id: tag2.id)

        section_tags =
          SectionTag
          |> Ash.Query.filter(expr(tag_id == ^tag1.id))
          |> Ash.read!(authorize?: false)

        assert length(section_tags) == 1
        assert Enum.at(section_tags, 0).tag_id == tag1.id
      end
    end

    describe "destroy action" do
      test "removes section_tag" do
        section_tag = create_section_tag!()

        section_tag
        |> Ash.Changeset.for_destroy(:destroy, %{}, authorize?: false)
        |> Ash.destroy!()

        section_tags = SectionTag |> Ash.read!(authorize?: false)

        refute Enum.any?(section_tags, fn st ->
                 st.section_id == section_tag.section_id and st.tag_id == section_tag.tag_id
               end)
      end

      test "destroying section_tag does not destroy section" do
        site = create_site!()
        section = create_section!(site_id: site.id)
        tag = create_document_tag!(site_id: site.id)
        section_tag = create_section_tag!(section_id: section.id, tag_id: tag.id)

        section_tag
        |> Ash.Changeset.for_destroy(:destroy, %{}, authorize?: false)
        |> Ash.destroy!()

        # Section should still exist
        fetched_section =
          Ash.get!(Section, section.id, action: :master_get, authorize?: false)

        assert fetched_section.id == section.id
      end

      test "destroying section_tag does not destroy tag" do
        site = create_site!()
        section = create_section!(site_id: site.id)
        tag = create_document_tag!(site_id: site.id)
        section_tag = create_section_tag!(section_id: section.id, tag_id: tag.id)

        section_tag
        |> Ash.Changeset.for_destroy(:destroy, %{}, authorize?: false)
        |> Ash.destroy!()

        # Tag should still exist
        fetched_tag = Ash.get!(Tag, tag.id, action: :master_get, authorize?: false)
        assert fetched_tag.id == tag.id
      end
    end

    describe "relationships" do
      test "belongs_to section" do
        site = create_site!()
        section = create_section!(site_id: site.id)
        tag = create_document_tag!(site_id: site.id)
        section_tag = create_section_tag!(section_id: section.id, tag_id: tag.id)

        section_tag_with_section =
          Ash.load!(section_tag, :section, tenant: section.site_id, authorize?: false)

        assert section_tag_with_section.section.id == section.id
      end

      test "belongs_to tag" do
        site = create_site!()
        section = create_section!(site_id: site.id)
        tag = create_document_tag!(site_id: site.id)
        section_tag = create_section_tag!(section_id: section.id, tag_id: tag.id)

        section_tag_with_tag =
          Ash.load!(section_tag, :tag, tenant: tag.site_id, authorize?: false)

        assert section_tag_with_tag.tag.id == tag.id
      end
    end

    describe "archival behavior (soft deletion)" do
      test "section_tag remains when section is archived" do
        site = create_site!()
        section = create_section!(site_id: site.id)
        tag = create_document_tag!(site_id: site.id)
        _section_tag = create_section_tag!(section_id: section.id, tag_id: tag.id)

        # Verify section_tag exists
        section_tags_before =
          SectionTag
          |> Ash.Query.filter(expr(section_id == ^section.id and tag_id == ^tag.id))
          |> Ash.read!(authorize?: false)

        assert length(section_tags_before) == 1

        # Archive section (soft delete) - section_tag should remain for potential unarchival
        section
        |> Ash.Changeset.for_destroy(
          :destroy,
          %{},
          tenant: section.site_id,
          authorize?: false
        )
        |> Ash.destroy!()

        # section_tag should still exist (soft deletion doesn't cascade to join tables)
        section_tags_after =
          SectionTag
          |> Ash.Query.filter(expr(section_id == ^section.id and tag_id == ^tag.id))
          |> Ash.read!(authorize?: false)

        assert length(section_tags_after) == 1
      end

      test "section_tag remains when tag is archived" do
        site = create_site!()
        section = create_section!(site_id: site.id)
        tag = create_document_tag!(site_id: site.id)
        _section_tag = create_section_tag!(section_id: section.id, tag_id: tag.id)

        # Verify section_tag exists
        section_tags_before =
          SectionTag
          |> Ash.Query.filter(expr(section_id == ^section.id and tag_id == ^tag.id))
          |> Ash.read!(authorize?: false)

        assert length(section_tags_before) == 1

        # Archive tag (soft delete) - section_tag should remain for potential unarchival
        tag
        |> Ash.Changeset.for_destroy(:destroy, %{}, tenant: tag.site_id, authorize?: false)
        |> Ash.destroy!()

        # section_tag should still exist (soft deletion doesn't cascade to join tables)
        section_tags_after =
          SectionTag
          |> Ash.Query.filter(expr(section_id == ^section.id and tag_id == ^tag.id))
          |> Ash.read!(authorize?: false)

        assert length(section_tags_after) == 1
      end

      test "tag still exists when section is deleted" do
        site = create_site!()
        section = create_section!(site_id: site.id)
        tag = create_document_tag!(site_id: site.id)
        _section_tag = create_section_tag!(section_id: section.id, tag_id: tag.id)

        # Archive section (soft delete)
        section
        |> Ash.Changeset.for_destroy(
          :destroy,
          %{},
          tenant: section.site_id,
          authorize?: false
        )
        |> Ash.destroy!()

        # Tag should still exist
        fetched_tag = Ash.get!(Tag, tag.id, action: :master_get, authorize?: false)
        assert fetched_tag.id == tag.id
      end

      test "section still exists when tag is deleted" do
        site = create_site!()
        section = create_section!(site_id: site.id)
        tag = create_document_tag!(site_id: site.id)
        _section_tag = create_section_tag!(section_id: section.id, tag_id: tag.id)

        # Destroy tag
        tag
        |> Ash.Changeset.for_destroy(:destroy, %{}, tenant: tag.site_id, authorize?: false)
        |> Ash.destroy!()

        # Section should still exist
        fetched_section =
          Ash.get!(Section, section.id, action: :master_get, authorize?: false)

        assert fetched_section.id == section.id
      end

      test "multiple section_tags remain when section is archived" do
        site = create_site!()
        section = create_section!(site_id: site.id)
        tag1 = create_document_tag!(site_id: site.id, name: "Tag 1")
        tag2 = create_document_tag!(site_id: site.id, name: "Tag 2")
        tag3 = create_document_tag!(site_id: site.id, name: "Tag 3")

        _section_tag1 = create_section_tag!(section_id: section.id, tag_id: tag1.id)
        _section_tag2 = create_section_tag!(section_id: section.id, tag_id: tag2.id)
        _section_tag3 = create_section_tag!(section_id: section.id, tag_id: tag3.id)

        # Verify all section_tags exist
        section_tags_before =
          SectionTag
          |> Ash.Query.filter(expr(section_id == ^section.id))
          |> Ash.read!(authorize?: false)

        assert length(section_tags_before) == 3

        # Archive section (soft delete)
        section
        |> Ash.Changeset.for_destroy(
          :destroy,
          %{},
          tenant: section.site_id,
          authorize?: false
        )
        |> Ash.destroy!()

        # All section_tags should remain (soft deletion doesn't cascade)
        section_tags_after =
          SectionTag
          |> Ash.Query.filter(expr(section_id == ^section.id))
          |> Ash.read!(authorize?: false)

        assert length(section_tags_after) == 3

        # And all tags should still exist
        assert Ash.get!(Tag, tag1.id, action: :master_get, authorize?: false)
        assert Ash.get!(Tag, tag2.id, action: :master_get, authorize?: false)
        assert Ash.get!(Tag, tag3.id, action: :master_get, authorize?: false)
      end

      test "multiple section_tags remain when tag is archived" do
        site = create_site!()
        section1 = create_section!(site_id: site.id, title: "Section 1")
        section2 = create_section!(site_id: site.id, title: "Section 2")
        section3 = create_section!(site_id: site.id, title: "Section 3")
        tag = create_document_tag!(site_id: site.id)

        _section_tag1 = create_section_tag!(section_id: section1.id, tag_id: tag.id)
        _section_tag2 = create_section_tag!(section_id: section2.id, tag_id: tag.id)
        _section_tag3 = create_section_tag!(section_id: section3.id, tag_id: tag.id)

        # Verify all section_tags exist
        section_tags_before =
          SectionTag
          |> Ash.Query.filter(expr(tag_id == ^tag.id))
          |> Ash.read!(authorize?: false)

        assert length(section_tags_before) == 3

        # Archive tag (soft delete)
        tag
        |> Ash.Changeset.for_destroy(:destroy, %{}, tenant: tag.site_id, authorize?: false)
        |> Ash.destroy!()

        # All section_tags should remain (soft deletion doesn't cascade)
        section_tags_after =
          SectionTag
          |> Ash.Query.filter(expr(tag_id == ^tag.id))
          |> Ash.read!(authorize?: false)

        assert length(section_tags_after) == 3

        # And all sections should still exist
        assert Ash.get!(Section, section1.id, action: :master_get, authorize?: false)
        assert Ash.get!(Section, section2.id, action: :master_get, authorize?: false)
        assert Ash.get!(Section, section3.id, action: :master_get, authorize?: false)
      end
    end

    describe "permanent deletion (hard delete with cascade)" do
      test "section_tag is deleted when section is permanently destroyed" do
        site = create_site!()
        section = create_section!(site_id: site.id)
        tag = create_document_tag!(site_id: site.id)
        _section_tag = create_section_tag!(section_id: section.id, tag_id: tag.id)

        # Verify section_tag exists
        section_tags_before =
          SectionTag
          |> Ash.Query.filter(expr(section_id == ^section.id and tag_id == ^tag.id))
          |> Ash.read!(authorize?: false)

        assert length(section_tags_before) == 1

        # Permanently destroy section (hard delete) - should cascade delete section_tag
        section
        |> Ash.Changeset.for_destroy(
          :permanent_destroy,
          %{},
          tenant: section.site_id,
          authorize?: false
        )
        |> Ash.destroy!()

        # section_tag should be deleted via database-level cascade
        section_tags_after =
          SectionTag
          |> Ash.Query.filter(expr(section_id == ^section.id and tag_id == ^tag.id))
          |> Ash.read!(authorize?: false)

        assert section_tags_after == []
        # Tag should still exist
        fetched_tag = Ash.get!(Tag, tag.id, action: :master_get, authorize?: false)
        assert fetched_tag.id == tag.id
      end

      test "section_tag is deleted when tag is permanently destroyed" do
        site = create_site!()
        section = create_section!(site_id: site.id)
        tag = create_document_tag!(site_id: site.id)
        _section_tag = create_section_tag!(section_id: section.id, tag_id: tag.id)

        # Verify section_tag exists
        section_tags_before =
          SectionTag
          |> Ash.Query.filter(expr(section_id == ^section.id and tag_id == ^tag.id))
          |> Ash.read!(authorize?: false)

        assert length(section_tags_before) == 1

        # Permanently destroy tag (hard delete) - should cascade delete section_tag
        tag
        |> Ash.Changeset.for_destroy(
          :permanent_destroy,
          %{},
          tenant: tag.site_id,
          authorize?: false
        )
        |> Ash.destroy!()

        # section_tag should be deleted via database-level cascade
        section_tags_after =
          SectionTag
          |> Ash.Query.filter(expr(section_id == ^section.id and tag_id == ^tag.id))
          |> Ash.read!(authorize?: false)

        assert section_tags_after == []
        # Section should still exist
        fetched_section =
          Ash.get!(Section, section.id, action: :master_get, authorize?: false)

        assert fetched_section.id == section.id
      end

      test "multiple section_tags are deleted when section is permanently destroyed" do
        site = create_site!()
        section = create_section!(site_id: site.id)
        tag1 = create_document_tag!(site_id: site.id, name: "Tag 1")
        tag2 = create_document_tag!(site_id: site.id, name: "Tag 2")
        tag3 = create_document_tag!(site_id: site.id, name: "Tag 3")

        _section_tag1 = create_section_tag!(section_id: section.id, tag_id: tag1.id)
        _section_tag2 = create_section_tag!(section_id: section.id, tag_id: tag2.id)
        _section_tag3 = create_section_tag!(section_id: section.id, tag_id: tag3.id)

        # Verify all section_tags exist
        section_tags_before =
          SectionTag
          |> Ash.Query.filter(expr(section_id == ^section.id))
          |> Ash.read!(authorize?: false)

        assert length(section_tags_before) == 3

        # Permanently destroy section (hard delete)
        section
        |> Ash.Changeset.for_destroy(
          :permanent_destroy,
          %{},
          tenant: section.site_id,
          authorize?: false
        )
        |> Ash.destroy!()

        # All section_tags should be deleted via cascade
        section_tags_after =
          SectionTag
          |> Ash.Query.filter(expr(section_id == ^section.id))
          |> Ash.read!(authorize?: false)

        assert section_tags_after == []
        # But all tags should still exist
        assert Ash.get!(Tag, tag1.id, action: :master_get, authorize?: false)
        assert Ash.get!(Tag, tag2.id, action: :master_get, authorize?: false)
        assert Ash.get!(Tag, tag3.id, action: :master_get, authorize?: false)
      end

      test "multiple section_tags are deleted when tag is permanently destroyed" do
        site = create_site!()
        section1 = create_section!(site_id: site.id, title: "Section 1")
        section2 = create_section!(site_id: site.id, title: "Section 2")
        section3 = create_section!(site_id: site.id, title: "Section 3")
        tag = create_document_tag!(site_id: site.id)

        _section_tag1 = create_section_tag!(section_id: section1.id, tag_id: tag.id)
        _section_tag2 = create_section_tag!(section_id: section2.id, tag_id: tag.id)
        _section_tag3 = create_section_tag!(section_id: section3.id, tag_id: tag.id)

        # Verify all section_tags exist
        section_tags_before =
          SectionTag
          |> Ash.Query.filter(expr(tag_id == ^tag.id))
          |> Ash.read!(authorize?: false)

        assert length(section_tags_before) == 3

        # Permanently destroy tag (hard delete)
        tag
        |> Ash.Changeset.for_destroy(
          :permanent_destroy,
          %{},
          tenant: tag.site_id,
          authorize?: false
        )
        |> Ash.destroy!()

        # All section_tags should be deleted via cascade
        section_tags_after =
          SectionTag
          |> Ash.Query.filter(expr(tag_id == ^tag.id))
          |> Ash.read!(authorize?: false)

        assert section_tags_after == []
        # But all sections should still exist
        assert Ash.get!(Section, section1.id, action: :master_get, authorize?: false)
        assert Ash.get!(Section, section2.id, action: :master_get, authorize?: false)
        assert Ash.get!(Section, section3.id, action: :master_get, authorize?: false)
      end
    end

    describe "access through Tag relationships" do
      test "can create section_tag through Tag's add_section action" do
        site = create_site!()
        section = create_section!(site_id: site.id)
        tag = create_document_tag!(site_id: site.id)

        # Add section to tag using Tag's add_section action
        tag
        |> Ash.Changeset.for_update(
          :add_section,
          %{section_id: section.id},
          tenant: site.id,
          authorize?: false
        )
        |> Ash.update!()

        # Verify section_tag was created
        section_tags =
          SectionTag
          |> Ash.Query.filter(expr(section_id == ^section.id and tag_id == ^tag.id))
          |> Ash.read!(authorize?: false)

        assert length(section_tags) == 1
      end

      test "can manage multiple section_tags through Tag's assign_sections action" do
        site = create_site!()
        section1 = create_section!(site_id: site.id, title: "Section 1")
        section2 = create_section!(site_id: site.id, title: "Section 2")
        section3 = create_section!(site_id: site.id, title: "Section 3")
        tag = create_document_tag!(site_id: site.id)

        # Assign multiple sections to tag
        tag
        |> Ash.Changeset.for_update(
          :assign_sections,
          %{section_ids: [section1.id, section2.id, section3.id]},
          tenant: site.id,
          authorize?: false
        )
        |> Ash.update!()

        # Verify all section_tags were created
        section_tags =
          SectionTag
          |> Ash.Query.filter(expr(tag_id == ^tag.id))
          |> Ash.read!(authorize?: false)

        assert length(section_tags) == 3

        section_ids = Enum.map(section_tags, & &1.section_id)
        assert section1.id in section_ids
        assert section2.id in section_ids
        assert section3.id in section_ids
      end

      test "can remove section_tag through Tag's remove_section action" do
        site = create_site!()

        # Create an approved section (sections relationship filters for approved)
        section =
          create_section!(
            site_id: site.id,
            content_review_status: :approved,
            technical_review_status: :approved
          )

        tag = create_document_tag!(site_id: site.id)

        # First add the section to the tag using add_section
        tag =
          tag
          |> Ash.Changeset.for_update(
            :add_section,
            %{section_id: section.id},
            tenant: site.id,
            authorize?: false
          )
          |> Ash.update!()

        # Verify section_tag exists
        section_tags_before =
          SectionTag
          |> Ash.Query.filter(expr(section_id == ^section.id and tag_id == ^tag.id))
          |> Ash.read!(authorize?: false)

        assert length(section_tags_before) == 1

        # Remove section from tag
        tag
        |> Ash.Changeset.for_update(
          :remove_section,
          %{section_id: section.id},
          tenant: site.id,
          authorize?: false
        )
        |> Ash.update!()

        # Verify section_tag was removed
        section_tags_after =
          SectionTag
          |> Ash.Query.filter(expr(section_id == ^section.id and tag_id == ^tag.id))
          |> Ash.read!(authorize?: false)

        assert section_tags_after == []
      end
    end

    describe "timestamps" do
      test "sets inserted_at on creation" do
        section_tag = create_section_tag!()
        assert %DateTime{} = section_tag.inserted_at
        assert %DateTime{} = section_tag.inserted_at
      end

      test "sets updated_at on creation" do
        section_tag = create_section_tag!()
        assert %DateTime{} = section_tag.updated_at
        assert %DateTime{} = section_tag.updated_at
      end
    end
  end
end
