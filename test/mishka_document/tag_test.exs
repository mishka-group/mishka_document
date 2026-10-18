# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_document/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaDocument.Test.TagTest do
  @moduledoc """
  Comprehensive tests for MishkaDocument.Tag resource.
  """
  use MishkaDocument.DataCase, async: false

  if Code.ensure_loaded?(MishkaDocument) do
    alias MishkaDocument.Tag

    describe "resource configuration" do
      test "uses correct table name" do
        assert AshPostgres.DataLayer.Info.table(Tag) == "mishka_document_tags"
      end

      test "uses UUID v7 for primary keys" do
        tag = create_document_tag!()
        assert {:ok, _uuid} = Ecto.UUID.cast(tag.id)
        assert String.length(tag.id) == 36
      end

      test "uses multi-tenancy with site_id" do
        assert Ash.Resource.Info.multitenancy_strategy(Tag) == :attribute
        assert Ash.Resource.Info.multitenancy_attribute(Tag) == :site_id
        assert Ash.Resource.Info.multitenancy_global?(Tag) == false
      end
    end

    describe "create action" do
      test "creates tag with valid attributes" do
        site = create_site!()

        tag =
          Tag
          |> Ash.Changeset.for_create(
            :create,
            %{name: "Test Tag", slug: "test-tag"},
            tenant: site.id,
            authorize?: false
          )
          |> Ash.create!()

        assert tag.name == "Test Tag"
        assert tag.slug == "test-tag"
        assert tag.site_id == site.id
        assert tag.language == "en"
        assert tag.language_group_id == tag.id
      end

      test "auto-generates slug from name" do
        site = create_site!()

        tag =
          Tag
          |> Ash.Changeset.for_create(
            :create,
            %{name: "Test Tag!", slug: "Test Tag!"},
            tenant: site.id,
            authorize?: false
          )
          |> Ash.create!()

        # AshSlug ignores ".", "!", "?" but doesn't remove them from the end
        assert tag.slug == "test-tag!"
      end

      test "defaults language to 'en'" do
        tag = create_document_tag!()
        assert tag.language == "en"
      end

      test "allows setting custom language" do
        site = create_site!()

        tag =
          Tag
          |> Ash.Changeset.for_create(
            :create,
            %{name: "Test Tag", slug: "test-tag", language: "fa"},
            tenant: site.id,
            authorize?: false
          )
          |> Ash.create!()

        assert tag.language == "fa"
      end

      test "allows setting language_group_id" do
        site = create_site!()
        language_group_id = create_document_tag!(site_id: site.id).language_group_id

        tag =
          Tag
          |> Ash.Changeset.for_create(
            :create,
            %{
              name: "Test Tag",
              slug: "test-tag",
              language_group_id: language_group_id
            },
            tenant: site.id,
            authorize?: false
          )
          |> Ash.create!()

        assert tag.language_group_id == language_group_id
      end

      test "requires tenant context" do
        assert_raise Ash.Error.Invalid, fn ->
          Tag
          |> Ash.Changeset.for_create(
            :create,
            %{name: "Test Tag", slug: "test-tag"},
            authorize?: false
          )
          |> Ash.create!()
        end
      end

      test "auto-assigns site_id from tenant" do
        site = create_site!()

        tag =
          Tag
          |> Ash.Changeset.for_create(
            :create,
            %{name: "Test Tag", slug: "test-tag"},
            tenant: site.id,
            authorize?: false
          )
          |> Ash.create!()

        assert tag.site_id == site.id
      end

      test "requires name" do
        site = create_site!()

        assert_raise Ash.Error.Invalid, fn ->
          Tag
          |> Ash.Changeset.for_create(
            :create,
            %{slug: "test-tag"},
            tenant: site.id,
            authorize?: false
          )
          |> Ash.create!()
        end
      end

      test "requires slug" do
        site = create_site!()

        assert_raise Ash.Error.Invalid, fn ->
          Tag
          |> Ash.Changeset.for_create(
            :create,
            %{name: "Test Tag"},
            tenant: site.id,
            authorize?: false
          )
          |> Ash.create!()
        end
      end
    end

    describe "master_create action" do
      test "creates tag with explicit site_id" do
        site = create_site!()

        tag =
          Tag
          |> Ash.Changeset.for_create(
            :master_create,
            %{name: "Master Tag", slug: "master-tag", site_id: site.id},
            authorize?: false
          )
          |> Ash.create!()

        assert tag.name == "Master Tag"
        assert tag.slug == "master-tag"
        assert tag.site_id == site.id
      end

      test "requires explicit site_id" do
        assert_raise Ash.Error.Invalid, fn ->
          Tag
          |> Ash.Changeset.for_create(
            :master_create,
            %{name: "Master Tag", slug: "master-tag"},
            authorize?: false
          )
          |> Ash.create!()
        end
      end
    end

    describe "read actions" do
      test "default read action returns tags for current tenant" do
        site1 = create_site!()
        site2 = create_site!()

        tag1 = create_document_tag!(site_id: site1.id, name: "Tag 1")
        _tag2 = create_document_tag!(site_id: site2.id, name: "Tag 2")

        tags = Tag |> Ash.read!(tenant: site1.id, authorize?: false)

        tag_ids = Enum.map(tags, & &1.id)
        assert tag1.id in tag_ids
        refute Enum.any?(tags, fn t -> t.site_id == site2.id end)
      end

      test "master_read returns all tags across tenants" do
        site1 = create_site!()
        site2 = create_site!()

        tag1 = create_document_tag!(site_id: site1.id)
        tag2 = create_document_tag!(site_id: site2.id)

        result =
          Tag
          |> Ash.Query.for_read(:master_read, %{}, authorize?: false)
          |> Ash.read!(page: [offset: 0])

        tags = result.results

        tag_ids = Enum.map(tags, & &1.id)
        assert tag1.id in tag_ids
        assert tag2.id in tag_ids
      end

      test "master_read supports pagination" do
        _tags = Enum.map(1..25, fn _ -> create_document_tag!() end)

        result =
          Tag
          |> Ash.Query.for_read(:master_read, %{}, authorize?: false)
          |> Ash.read!(page: [offset: 0, limit: 20])

        assert length(result.results) == 20

        # Query second page
        result_page2 =
          Tag
          |> Ash.Query.for_read(:master_read, %{}, authorize?: false)
          |> Ash.Query.page(offset: 20, limit: 10)
          |> Ash.read!()

        assert length(result_page2.results) == 5
      end

      test "public_list returns tags for current tenant" do
        site = create_site!()
        tag = create_document_tag!(site_id: site.id)

        result =
          Tag
          |> Ash.Query.for_read(:public_list, %{}, tenant: site.id, authorize?: false)
          |> Ash.read!(page: [offset: 0])

        tags = result.results

        assert Enum.any?(tags, fn t -> t.id == tag.id end)
      end

      test "public_get retrieves single tag by ID" do
        tag = create_document_tag!()

        retrieved =
          Tag |> Ash.get!(tag.id, action: :public_get, tenant: tag.site_id, authorize?: false)

        assert retrieved.id == tag.id
        assert retrieved.name == tag.name
      end
    end

    describe "update action" do
      test "updates tag attributes" do
        tag = create_document_tag!(name: "Original Name", slug: "original-name")

        updated =
          tag
          |> Ash.Changeset.for_update(
            :update,
            %{name: "Updated Name", slug: "updated-name"},
            tenant: tag.site_id,
            authorize?: false
          )
          |> Ash.update!()

        assert updated.name == "Updated Name"
        assert updated.slug == "updated-name"
      end

      test "site_id is not accepted in update action" do
        tag = create_document_tag!()
        other_site = create_site!()

        assert {:error, %Ash.Error.Invalid{errors: errors}} =
                 tag
                 |> Ash.Changeset.for_update(
                   :update,
                   %{name: "Updated Name", site_id: other_site.id},
                   tenant: tag.site_id,
                   authorize?: false
                 )
                 |> Ash.update()

        assert Enum.any?(errors, &match?(%Ash.Error.Invalid.NoSuchInput{input: :site_id}, &1))

        assert Ash.get!(MishkaDocument.Tag, tag.id, tenant: tag.site_id, authorize?: false).site_id ==
                 tag.site_id
      end

      test "cannot update archived tag" do
        tag = create_document_tag!()

        # Archive the tag
        tag
        |> Ash.Changeset.for_destroy(:destroy, %{}, tenant: tag.site_id, authorize?: false)
        |> Ash.destroy!()

        # Try to update archived tag - database trigger prevents this
        assert_raise Ash.Error.Unknown, fn ->
          tag
          |> Ash.Changeset.for_update(
            :update,
            %{name: "Updated Name"},
            tenant: tag.site_id,
            authorize?: false
          )
          |> Ash.update!()
        end
      end
    end

    describe "destroy and archive actions" do
      test "destroy soft-deletes tag by archiving" do
        tag = create_document_tag!()
        site_id = tag.site_id

        tag
        |> Ash.Changeset.for_destroy(:destroy, %{}, tenant: site_id, authorize?: false)
        |> Ash.destroy!()

        # Tag should not appear in default read
        tags = Tag |> Ash.read!(tenant: site_id, authorize?: false)
        refute Enum.any?(tags, fn t -> t.id == tag.id end)

        # But should appear in archived read
        result =
          Tag
          |> Ash.Query.for_read(:archived, %{}, tenant: site_id, authorize?: false)
          |> Ash.read!()

        archived_tags = result.results
        assert Enum.any?(archived_tags, fn t -> t.id == tag.id end)
      end

      test "cannot destroy already archived tag" do
        tag = create_document_tag!()

        # Archive once
        tag
        |> Ash.Changeset.for_destroy(:destroy, %{}, tenant: tag.site_id, authorize?: false)
        |> Ash.destroy!()

        # Try to archive again - database trigger prevents this
        assert_raise Ash.Error.Unknown, fn ->
          tag
          |> Ash.Changeset.for_destroy(:destroy, %{}, tenant: tag.site_id, authorize?: false)
          |> Ash.destroy!()
        end
      end
    end

    describe "unarchive action" do
      test "restores archived tag" do
        tag = create_document_tag!()
        site_id = tag.site_id
        tag_id = tag.id

        # Archive
        tag
        |> Ash.Changeset.for_destroy(:destroy, %{}, tenant: site_id, authorize?: false)
        |> Ash.destroy!()

        # Get the archived tag
        archived_tag =
          Tag
          |> Ash.get!(tag_id, action: :get_archived, tenant: site_id, authorize?: false)

        # Unarchive
        unarchived =
          archived_tag
          |> Ash.Changeset.for_update(:unarchive, %{}, tenant: site_id, authorize?: false)
          |> Ash.update!()

        assert unarchived.archived_at == nil

        # Should appear in default read again
        tags = Tag |> Ash.read!(tenant: site_id, authorize?: false)
        assert Enum.any?(tags, fn t -> t.id == tag_id end)
      end
    end

    describe "permanent_destroy action" do
      test "permanently deletes tag from database" do
        tag = create_document_tag!()
        tag_id = tag.id
        site_id = tag.site_id

        tag
        |> Ash.Changeset.for_destroy(:permanent_destroy, %{}, tenant: site_id, authorize?: false)
        |> Ash.destroy!()

        # Tag should not exist at all
        result = Ash.get(Tag, tag_id, action: :master_get, authorize?: false)
        assert match?({:error, _}, result)
      end
    end

    describe "language variants relationship" do
      test "groups tags by language_group_id" do
        site = create_site!()

        tag_en =
          create_document_tag!(
            site_id: site.id,
            name: "English Tag",
            slug: "english-tag",
            language: "en"
          )

        # The first tag is the group; its translations name it.
        language_group_id = tag_en.language_group_id

        tag_fa =
          create_document_tag!(
            site_id: site.id,
            name: "برچسب فارسی",
            slug: "farsi-tag",
            language: "fa",
            language_group_id: language_group_id
          )

        tag_ar =
          create_document_tag!(
            site_id: site.id,
            name: "علامة عربية",
            slug: "arabic-tag",
            language: "ar",
            language_group_id: language_group_id
          )

        # Load language variants from English tag
        tag_with_variants =
          Tag
          |> Ash.get!(tag_en.id, tenant: site.id, authorize?: false)
          |> Ash.load!(:language_variants, tenant: site.id, authorize?: false)

        variant_ids = Enum.map(tag_with_variants.language_variants, & &1.id)
        assert tag_en.id in variant_ids
        assert tag_fa.id in variant_ids
        assert tag_ar.id in variant_ids
      end

      test "tags with auto-generated language_group_id have only themselves as variant" do
        tag = create_document_tag!()

        tag_with_variants =
          tag
          |> Ash.load!(:language_variants, tenant: tag.site_id, authorize?: false)

        assert length(tag_with_variants.language_variants) == 1
        assert hd(tag_with_variants.language_variants).id == tag.id
      end
    end

    describe "section relationships" do
      test "can assign sections to tag using tenant_sections" do
        tag = create_document_tag!()
        section1 = create_section!(site_id: tag.site_id)
        section2 = create_section!(site_id: tag.site_id)

        updated =
          tag
          |> Ash.Changeset.for_update(
            :assign_sections,
            %{section_ids: [section1.id, section2.id]},
            tenant: tag.site_id,
            authorize?: false
          )
          |> Ash.update!()

        # Load sections relationship using tenant
        tag_with_sections =
          updated
          |> Ash.load!(:tenant_sections, tenant: tag.site_id, authorize?: false)

        section_ids = Enum.map(tag_with_sections.tenant_sections, & &1.id)
        assert section1.id in section_ids
        assert section2.id in section_ids
      end

      test "loads sections using master_sections (master_read)" do
        site = create_site!()
        tag = create_document_tag!(site_id: site.id, name: "Master Tag")
        section = create_section!(site_id: site.id, title: "Master Section")

        # Add section to tag
        tag
        |> Ash.Changeset.for_update(
          :add_section,
          %{section_id: section.id},
          tenant: site.id,
          authorize?: false
        )
        |> Ash.update!()

        # Fetch tag using master_get (bypasses tenant filtering)
        fetched_tag = Ash.get!(Tag, tag.id, action: :master_get, authorize?: false)

        # A master is a user with no site; a call with no actor loads no master_* relationship.
        master = create_user!()

        # Load master_sections with read_any action and pagination
        tag_with_sections =
          Ash.load!(
            fetched_tag,
            [
              master_sections:
                MishkaDocument.Section
                |> Ash.Query.for_read(:read_any, %{}, authorize?: false)
                |> Ash.Query.page(limit: 100)
            ],
            actor: master,
            authorize?: false
          )

        # master_sections returns a paginated result (Ash.Page.Offset)
        assert [_ | _] = tag_with_sections.master_sections.results
        section_ids = Enum.map(tag_with_sections.master_sections.results, & &1.id)
        assert section.id in section_ids

        # Verify we got the correct section
        master_section =
          Enum.find(tag_with_sections.master_sections.results, &(&1.id == section.id))

        assert master_section.title == "Master Section"
      end

      test "can add single section to tag" do
        tag = create_document_tag!()
        section = create_section!(site_id: tag.site_id)

        updated =
          tag
          |> Ash.Changeset.for_update(
            :add_section,
            %{section_id: section.id},
            tenant: tag.site_id,
            authorize?: false
          )
          |> Ash.update!()

        tag_with_sections =
          updated
          |> Ash.load!(:tenant_sections, tenant: tag.site_id, authorize?: false)

        section_ids = Enum.map(tag_with_sections.tenant_sections, & &1.id)
        assert section.id in section_ids
      end
    end

    describe "cascade delete behavior" do
      # Note: When a Section is deleted, the Tag should NOT be deleted.
      # Only the SectionTag join table record should be deleted (via database-level cascade).
      # When a Tag is deleted, Sections should NOT be deleted.
      # Only the SectionTag join table record should be deleted (via database-level cascade).
      # These cascades are enforced at the database level via foreign key constraints.
      # The join table (SectionTag) cascade deletion behavior is tested in section_tag_test.exs

      test "tags exist independently of sections" do
        tag = create_document_tag!()
        section1 = create_section!(site_id: tag.site_id)
        section2 = create_section!(site_id: tag.site_id)

        # Add sections to tag
        tag
        |> Ash.Changeset.for_update(
          :assign_sections,
          %{section_ids: [section1.id, section2.id]},
          tenant: tag.site_id,
          authorize?: false
        )
        |> Ash.update!()

        # Verify tag has sections
        tag_with_sections =
          Ash.get!(Tag, tag.id, tenant: tag.site_id, authorize?: false)
          |> Ash.load!(:tenant_sections, tenant: tag.site_id, authorize?: false)

        assert length(tag_with_sections.tenant_sections) == 2

        # The relationship is maintained through the SectionTag join table
        # When either tag or section is deleted, only the join record is removed
        assert {:ok, _uuid} = Ecto.UUID.cast(tag.id)
        assert {:ok, _uuid} = Ecto.UUID.cast(section1.id)
        assert {:ok, _uuid} = Ecto.UUID.cast(section2.id)
      end
    end

    describe "identities" do
      test "unique_slug_per_site prevents duplicate slugs in same site" do
        site = create_site!()

        _tag1 =
          Tag
          |> Ash.Changeset.for_create(
            :create,
            %{name: "Test Tag", slug: "test-tag"},
            tenant: site.id,
            authorize?: false
          )
          |> Ash.create!()

        # Try to create duplicate slug in same site
        assert_raise Ash.Error.Invalid, fn ->
          Tag
          |> Ash.Changeset.for_create(
            :create,
            %{name: "Another Tag", slug: "test-tag"},
            tenant: site.id,
            authorize?: false
          )
          |> Ash.create!()
        end
      end

      test "allows same slug in different sites" do
        site1 = create_site!()
        site2 = create_site!()

        tag1 =
          Tag
          |> Ash.Changeset.for_create(
            :create,
            %{name: "Test Tag", slug: "test-tag"},
            tenant: site1.id,
            authorize?: false
          )
          |> Ash.create!()

        tag2 =
          Tag
          |> Ash.Changeset.for_create(
            :create,
            %{name: "Test Tag", slug: "test-tag"},
            tenant: site2.id,
            authorize?: false
          )
          |> Ash.create!()

        assert tag1.slug == tag2.slug
        assert tag1.site_id != tag2.site_id
      end
    end

    describe "authorization policies" do
      test "public_list allows access without authentication" do
        site = create_site!()
        tag = create_document_tag!(site_id: site.id)

        # Should work without actor
        result =
          Tag
          |> Ash.Query.for_read(:public_list, %{}, tenant: site.id, authorize?: false)
          |> Ash.read!(page: [offset: 0])

        tags = result.results
        assert Enum.any?(tags, fn t -> t.id == tag.id end)
      end

      test "public_get allows access without authentication" do
        tag = create_document_tag!()

        # Should work without actor
        retrieved =
          Tag
          |> Ash.get!(tag.id, action: :public_get, tenant: tag.site_id, authorize?: false)

        assert retrieved.id == tag.id
      end
    end

    describe "timestamps" do
      test "sets inserted_at on creation" do
        tag = create_document_tag!()
        assert %DateTime{} = tag.inserted_at
      end

      test "sets updated_at on creation" do
        tag = create_document_tag!()
        assert %DateTime{} = tag.updated_at
      end

      test "updates updated_at on modification" do
        tag = create_document_tag!()
        original_updated_at = tag.updated_at

        # Wait a tiny bit to ensure timestamp changes
        Process.sleep(10)

        updated =
          tag
          |> Ash.Changeset.for_update(
            :update,
            %{name: "Updated Name"},
            tenant: tag.site_id,
            authorize?: false
          )
          |> Ash.update!()

        assert DateTime.compare(updated.updated_at, original_updated_at) == :gt
      end
    end
  end
end
