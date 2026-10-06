defmodule MishkaDocument.Test.SectionTest do
  @moduledoc """
  Tests for MishkaDocument.Section resource.
  """
  use MishkaDocument.DataCase, async: false

  if Code.ensure_loaded?(MishkaDocument) do
    alias MishkaDocument.Section

    describe "resource configuration" do
      test "uses correct table name" do
        assert AshPostgres.DataLayer.Info.table(Section) == "mishka_document_sections"
      end

      test "uses UUID v7 for primary keys" do
        section = create_section!()
        assert is_binary(section.id)
        assert String.length(section.id) == 36
      end
    end

    describe "create action" do
      test "creates section with valid attributes" do
        site = create_site!()
        workspace = create_workspace!(site_id: site.id)
        version = create_workspace_version!(workspace_id: workspace.id, site_id: site.id)

        section =
          Section
          |> Ash.Changeset.for_create(
            :create,
            %{
              title: "Getting Started",
              slug: "getting-started",
              content: "Welcome to our documentation",
              workspace_version_id: version.id
            },
            tenant: site.id,
            authorize?: false
          )
          |> Ash.create!()

        assert section.title == "Getting Started"
        assert section.slug == "getting-started"
        assert section.workspace_version_id == version.id
      end

      test "auto-assigns site_id from tenant context" do
        site = create_site!()
        workspace = create_workspace!(site_id: site.id)
        version = create_workspace_version!(workspace_id: workspace.id, site_id: site.id)

        section =
          Section
          |> Ash.Changeset.for_create(
            :create,
            %{
              title: "Test",
              slug: "test",
              workspace_version_id: version.id
            },
            tenant: site.id,
            authorize?: false
          )
          |> Ash.create!()

        assert section.site_id == site.id
      end

      test "defaults content_review_status to pending" do
        section = create_section!()
        assert section.content_review_status == :pending
      end

      test "defaults technical_review_status to pending" do
        section = create_section!()
        assert section.technical_review_status == :pending
      end

      test "defaults language to 'en'" do
        section = create_section!()
        assert section.language == "en"
      end

      test "defaults order_position to 0" do
        section = create_section!()
        assert section.order_position == 0
      end

      test "defaults permissions to none" do
        site = create_site!()
        workspace = create_workspace!(site_id: site.id)
        version = create_workspace_version!(workspace_id: workspace.id, site_id: site.id)

        section =
          Section
          |> Ash.Changeset.for_create(
            :create,
            %{title: "Open", slug: "open", workspace_version_id: version.id},
            tenant: site.id,
            authorize?: false
          )
          |> Ash.create!()

        assert section.permissions == []
      end

      test "accepts permissions, each trimmed, downcased and once" do
        section = create_section!(permissions: ["  Docs:Read ", "docs:read", "DOCS:WRITE"])
        assert section.permissions == ["docs:read", "docs:write"]
      end
    end

    describe "master_create action" do
      test "creates section with explicit site_id" do
        site = create_site!()
        workspace = create_workspace!(site_id: site.id)
        version = create_workspace_version!(workspace_id: workspace.id, site_id: site.id)

        section =
          Section
          |> Ash.Changeset.for_create(
            :master_create,
            %{
              title: "Master Section",
              slug: "master-section",
              workspace_version_id: version.id,
              site_id: site.id
            },
            authorize?: false
          )
          |> Ash.create!()

        assert section.title == "Master Section"
        assert section.site_id == site.id
      end

      test "requires explicit site_id" do
        workspace = create_workspace!()

        version =
          create_workspace_version!(workspace_id: workspace.id, site_id: workspace.site_id)

        assert_raise Ash.Error.Invalid, fn ->
          Section
          |> Ash.Changeset.for_create(
            :master_create,
            %{
              title: "Missing Site",
              slug: "missing-site",
              workspace_version_id: version.id
            },
            authorize?: false
          )
          |> Ash.create!()
        end
      end
    end

    describe "update action" do
      test "updates section attributes" do
        site = create_site!()
        section = create_section!(site_id: site.id)

        updated =
          section
          |> Ash.Changeset.for_update(
            :update,
            %{title: "Updated Title", content: "New content"},
            tenant: site.id,
            authorize?: false
          )
          |> Ash.update!()

        assert updated.title == "Updated Title"
        assert updated.content == "New content"
      end

      test "updates and clears permissions" do
        site = create_site!()
        section = create_section!(site_id: site.id)

        update = fn record, permissions ->
          record
          |> Ash.Changeset.for_update(:update, %{permissions: permissions},
            tenant: site.id,
            authorize?: false
          )
          |> Ash.update!()
        end

        locked = update.(section, ["Members:Read"])
        assert locked.permissions == ["members:read"]
        assert update.(locked, []).permissions == []
      end

      # Note: Section does not have validation to prevent updating archived sections
      # (unlike Workspace which has `validate absent(:archived_at)`)

      test "prevents site_id changes" do
        site1 = create_site!()
        section = create_section!(site_id: site1.id)

        updated =
          section
          |> Ash.Changeset.for_update(
            :update,
            %{title: "Updated"},
            tenant: site1.id,
            authorize?: false
          )
          |> Ash.update!()

        assert updated.site_id == site1.id
      end
    end

    describe "master_update action" do
      test "updates section for master users" do
        site = create_site!()
        section = create_section!(title: "Original", site_id: site.id)

        # Fetch the record first using master_get (bypasses tenant)
        record = Ash.get!(Section, section.id, action: :master_get, authorize?: false)

        updated =
          record
          |> Ash.Changeset.for_update(:master_update, %{title: "Master Updated"},
            authorize?: false
          )
          |> Ash.update!()

        assert updated.title == "Master Updated"
      end
    end

    describe "read actions with multitenancy" do
      test "tenant read only shows sections for that tenant" do
        site1 = create_site!()
        site2 = create_site!()

        section1 = create_section!(title: "Site 1", site_id: site1.id)
        _section2 = create_section!(title: "Site 2", site_id: site2.id)

        # Query with site1 tenant should only return site1 sections
        sections =
          Section
          |> Ash.Query.set_tenant(site1.id)
          |> Ash.Query.page(limit: 100)
          |> Ash.read!(authorize?: false)

        section_ids = Enum.map(sections.results, & &1.id)

        assert section1.id in section_ids
        refute Enum.any?(sections.results, fn s -> s.title == "Site 2" end)
      end

      test "master_read bypasses multitenancy" do
        site1 = create_site!()
        site2 = create_site!()

        section1 = create_section!(title: "Site 1", site_id: site1.id)
        section2 = create_section!(title: "Site 2", site_id: site2.id)

        # Query without tenant should return all sections
        sections =
          Section
          |> Ash.Query.for_read(:master_read, %{}, authorize?: false)
          |> Ash.Query.page(limit: 100)
          |> Ash.read!()

        section_ids = Enum.map(sections.results, & &1.id)

        assert section1.id in section_ids
        assert section2.id in section_ids
      end
    end

    describe "archival (soft delete)" do
      test "destroy archives section instead of deleting" do
        site = create_site!()
        section = create_section!(site_id: site.id)
        section_id = section.id

        # Archive the section
        _archived =
          section
          |> Ash.Changeset.for_destroy(:destroy, %{}, tenant: site.id, authorize?: false)
          |> Ash.destroy!(return_destroyed?: true)

        # Should not appear in regular queries
        sections =
          Section
          |> Ash.Query.set_tenant(site.id)
          |> Ash.Query.page(limit: 100)
          |> Ash.read!(authorize?: false)

        refute Enum.any?(sections.results, fn s -> s.id == section_id end)

        # Should appear in archived query
        archived_sections =
          Section
          |> Ash.Query.for_read(:archived, %{}, tenant: site.id, authorize?: false)
          |> Ash.Query.page(limit: 100)
          |> Ash.read!()

        assert Enum.any?(archived_sections.results, fn s -> s.id == section_id end)
      end

      test "unarchive restores archived section" do
        site = create_site!()
        section = create_section!(site_id: site.id)

        # Archive
        archived =
          section
          |> Ash.Changeset.for_destroy(:destroy, %{}, tenant: site.id, authorize?: false)
          |> Ash.destroy!(return_destroyed?: true)

        # Unarchive
        restored =
          archived
          |> Ash.Changeset.for_update(:unarchive, %{}, tenant: site.id, authorize?: false)
          |> Ash.update!()

        assert is_nil(restored.archived_at)

        # Should appear in regular queries again
        sections =
          Section
          |> Ash.Query.set_tenant(site.id)
          |> Ash.Query.page(limit: 100)
          |> Ash.read!(authorize?: false)

        assert Enum.any?(sections.results, fn s -> s.id == restored.id end)
      end
    end

    # Note: permanent_destroy not tested as Section has AshPaperTrail versioning enabled
    # which conflicts with permanent deletion. Use regular destroy (archival) instead.

    describe "relationships" do
      test "belongs_to workspace_version" do
        site = create_site!()
        section = create_section!(site_id: site.id)

        section_with_version =
          Ash.load!(section, :workspace_version, tenant: site.id, authorize?: false)

        assert section_with_version.workspace_version.id == section.workspace_version_id
      end

      test "loads workspace through workspace_version (tenant read)" do
        site = create_site!()
        workspace = create_workspace!(name: "Test Workspace", site_id: site.id)
        version = create_workspace_version!(workspace_id: workspace.id, site_id: site.id)
        section = create_section!(workspace_version_id: version.id, site_id: site.id)

        # Load workspace through workspace_version using tenant read
        section_with_workspace =
          Ash.load!(section, [workspace_version: :workspace], tenant: site.id, authorize?: false)

        assert section_with_workspace.workspace_version.workspace.id == workspace.id
        assert section_with_workspace.workspace_version.workspace.name == "Test Workspace"
      end

      test "loads workspace through workspace_version (master_read)" do
        site = create_site!()
        workspace = create_workspace!(name: "Master Workspace", site_id: site.id)
        version = create_workspace_version!(workspace_id: workspace.id, site_id: site.id)
        section = create_section!(workspace_version_id: version.id, site_id: site.id)

        # Load section using master_read
        fetched_section =
          Ash.get!(Section, section.id, action: :master_get, authorize?: false)

        # A master is a user with no site; a call with no actor loads no master_* relationship.
        section_with_workspace =
          Ash.load!(fetched_section, [master_workspace_version: :master_workspace],
            action: :master_read,
            actor: create_user!(),
            authorize?: false
          )

        assert section_with_workspace.master_workspace_version.master_workspace.id == workspace.id

        assert section_with_workspace.master_workspace_version.master_workspace.name ==
                 "Master Workspace"
      end

      test "loads workspace through workspace_version (public_list)" do
        site = create_site!()
        workspace = create_workspace!(name: "Public Workspace", site_id: site.id)
        version = create_workspace_version!(workspace_id: workspace.id, site_id: site.id)

        section =
          create_section!(
            workspace_version_id: version.id,
            site_id: site.id,
            content_review_status: :approved,
            technical_review_status: :approved
          )

        # Load section using public_get
        fetched_section =
          Ash.get!(Section, section.id, action: :public_get, tenant: site.id, authorize?: false)

        # Load workspace through workspace_version
        section_with_workspace =
          Ash.load!(fetched_section, [workspace_version: :workspace],
            tenant: site.id,
            authorize?: false
          )

        assert section_with_workspace.workspace_version.workspace.id == workspace.id
        assert section_with_workspace.workspace_version.workspace.name == "Public Workspace"
      end

      test "belongs_to site" do
        site = create_site!()
        section = create_section!(site_id: site.id)

        section_with_site = Ash.load!(section, :site, tenant: section.site_id, authorize?: false)

        assert section_with_site.site.id == site.id
        assert section_with_site.site.host == site.host
      end

      test "has_many child_sections" do
        site = create_site!()
        parent_section = create_section!(title: "Parent", site_id: site.id)

        child1 =
          create_section!(
            title: "Child 1",
            parent_section_id: parent_section.id,
            workspace_version_id: parent_section.workspace_version_id,
            site_id: site.id
          )

        child2 =
          create_section!(
            title: "Child 2",
            parent_section_id: parent_section.id,
            workspace_version_id: parent_section.workspace_version_id,
            site_id: site.id
          )

        parent_with_children =
          Ash.load!(parent_section, :child_sections, tenant: site.id, authorize?: false)

        child_ids = Enum.map(parent_with_children.child_sections, & &1.id) |> Enum.sort()
        assert child1.id in child_ids
        assert child2.id in child_ids
      end

      test "language_variants relationship" do
        site = create_site!()
        workspace = create_workspace!(site_id: site.id)
        version = create_workspace_version!(workspace_id: workspace.id, site_id: site.id)

        english =
          create_section!(language: "en", workspace_version_id: version.id, site_id: site.id)

        language_group_id = english.language_group_id

        _persian =
          create_section!(
            language: "fa",
            language_group_id: language_group_id,
            workspace_version_id: version.id,
            site_id: site.id
          )

        _arabic =
          create_section!(
            language: "ar",
            language_group_id: language_group_id,
            workspace_version_id: version.id,
            site_id: site.id
          )

        variants_query =
          Section
          |> Ash.Query.set_tenant(site.id)
          |> Ash.Query.page(limit: 10)

        english_with_variants =
          Ash.load!(english, [language_variants: variants_query],
            tenant: english.site_id,
            authorize?: false
          )

        languages =
          Enum.map(english_with_variants.language_variants.results, & &1.language) |> Enum.sort()

        assert languages == ["ar", "en", "fa"]
      end
    end

    describe "identities" do
      test "unique_slug_per_version prevents duplicate slugs within a workspace version" do
        site = create_site!()
        workspace = create_workspace!(site_id: site.id)
        version = create_workspace_version!(workspace_id: workspace.id, site_id: site.id)

        _section1 =
          create_section!(
            slug: "unique-slug",
            workspace_version_id: version.id,
            site_id: site.id
          )

        assert_raise Ash.Error.Invalid, fn ->
          create_section!(
            slug: "unique-slug",
            workspace_version_id: version.id,
            site_id: site.id
          )
        end
      end

      test "allows same slug in different workspace versions" do
        site = create_site!()
        workspace = create_workspace!(site_id: site.id)
        version1 = create_workspace_version!(workspace_id: workspace.id, site_id: site.id)
        version2 = create_workspace_version!(workspace_id: workspace.id, site_id: site.id)

        section1 =
          create_section!(
            slug: "same-slug",
            workspace_version_id: version1.id,
            site_id: site.id
          )

        section2 =
          create_section!(
            slug: "same-slug",
            workspace_version_id: version2.id,
            site_id: site.id
          )

        assert section1.slug == section2.slug
        assert section1.workspace_version_id != section2.workspace_version_id
      end
    end

    describe "database constraints" do
      test "enforces slug length constraints" do
        site = create_site!()

        # Empty slug should fail
        assert_raise Ash.Error.Invalid, fn ->
          create_section!(slug: "", site_id: site.id)
        end

        # Slug too long (> 255) should fail
        long_slug = String.duplicate("a", 256)

        assert_raise Ash.Error.Invalid, fn ->
          create_section!(slug: long_slug, site_id: site.id)
        end
      end

      test "enforces order_position non-negative constraint" do
        site = create_site!()

        assert_raise Ash.Error.Invalid, fn ->
          create_section!(order_position: -1, site_id: site.id)
        end
      end
    end

    describe "public actions" do
      test "public_list action lists approved sections" do
        site = create_site!()

        _section =
          create_section!(
            site_id: site.id,
            content_review_status: :approved,
            technical_review_status: :approved
          )

        # Public actions still require tenant context but don't require authorization
        sections =
          Section
          |> Ash.Query.for_read(:public_list, %{}, tenant: site.id, authorize?: false)
          |> Ash.Query.page(limit: 100)
          |> Ash.read!()

        assert length(sections.results) > 0
      end

      test "public_get action retrieves single approved section" do
        site = create_site!()

        section =
          create_section!(
            title: "Public",
            site_id: site.id,
            content_review_status: :approved,
            technical_review_status: :approved
          )

        # Public actions still require tenant context but don't require authorization
        {:ok, fetched} =
          Ash.get(Section, section.id, action: :public_get, tenant: site.id, authorize?: false)

        assert fetched.id == section.id
        assert fetched.title == "Public"
      end
    end

    describe "contributors_count calculation" do
      test "counts unique contributors from EventLog (Section and Note changes)" do
        site = create_site!()
        workspace = create_workspace!(site_id: site.id)
        version = create_workspace_version!(workspace_id: workspace.id, site_id: site.id)

        # Create users
        user1 = create_user!(email: "contributor1@test.com")
        user2 = create_user!(email: "contributor2@test.com")

        # User 1: Creates a section (generates EventLog with actor)
        section =
          MishkaDocument.Section
          |> Ash.Changeset.for_create(
            :create,
            %{
              workspace_version_id: version.id,
              title: "Test Section",
              slug: "test-section-contributors"
            },
            actor: user1,
            tenant: site.id,
            authorize?: false
          )
          |> Ash.create!()

        # User 1: Updates the section (should still count as 1 unique contributor)
        section
        |> Ash.Changeset.for_update(
          :update,
          %{title: "Updated Section"},
          actor: user1,
          tenant: site.id,
          authorize?: false
        )
        |> Ash.update!()

        # User 2: Creates a note for this section (generates EventLog with section_id in metadata)
        MishkaDocument.Note
        |> Ash.Changeset.for_create(
          :create,
          %{
            section_id: section.id,
            title: "Note by User 2",
            content: "Note content"
          },
          actor: user2,
          tenant: site.id,
          authorize?: false
        )
        |> Ash.create!()

        # Load section with contributors_count
        section_with_count =
          Ash.get!(Section, section.id,
            tenant: site.id,
            authorize?: false,
            load: [:contributors_count]
          )

        # User1 (section create + update) + User2 (note create) = 2 unique contributors
        assert section_with_count.contributors_count == 2
      end

      test "returns 0 when section created without actor" do
        site = create_site!()
        # create_section! doesn't pass an actor, so no EventLog entry has actor_id
        section = create_section!(site_id: site.id)

        section_with_count =
          Ash.get!(Section, section.id,
            tenant: site.id,
            authorize?: false,
            load: [:contributors_count]
          )

        # No actor in EventLog entries = 0 contributors
        assert section_with_count.contributors_count == 0
      end

      test "only counts create and update actions, not destroy" do
        site = create_site!()
        workspace = create_workspace!(site_id: site.id)
        version = create_workspace_version!(workspace_id: workspace.id, site_id: site.id)

        user = create_user!(email: "destroyer@test.com")

        # User creates a section
        section =
          MishkaDocument.Section
          |> Ash.Changeset.for_create(
            :create,
            %{
              workspace_version_id: version.id,
              title: "Section to test",
              slug: "section-to-test"
            },
            actor: user,
            tenant: site.id,
            authorize?: false
          )
          |> Ash.create!()

        # Create a note then destroy it (destroy action should not count as contribution)
        note =
          MishkaDocument.Note
          |> Ash.Changeset.for_create(
            :create,
            %{
              section_id: section.id,
              title: "Note to archive",
              content: "Content"
            },
            actor: user,
            tenant: site.id,
            authorize?: false
          )
          |> Ash.create!()

        # Archive the note
        note
        |> Ash.Changeset.for_destroy(:destroy, %{},
          actor: user,
          tenant: site.id,
          authorize?: false
        )
        |> Ash.destroy!()

        section_with_count =
          Ash.get!(Section, section.id,
            tenant: site.id,
            authorize?: false,
            load: [:contributors_count]
          )

        # User has 1 section create + 1 note create = still 1 unique contributor
        assert section_with_count.contributors_count == 1
      end
    end

    describe "content_word_count calculation" do
      test "counts words in content field" do
        site = create_site!()

        section =
          create_section!(
            site_id: site.id,
            title: "Test Section",
            content: "This is a test section with multiple words in the content"
          )

        section_with_count =
          Ash.get!(Section, section.id,
            tenant: site.id,
            authorize?: false,
            load: [:content_word_count]
          )

        # "This is a test section with multiple words in the content" = 11 words
        assert section_with_count.content_word_count == 11
      end

      test "returns 0 for nil content" do
        site = create_site!()

        section =
          create_section!(
            site_id: site.id,
            title: "Test Section",
            content: nil
          )

        section_with_count =
          Ash.get!(Section, section.id,
            tenant: site.id,
            authorize?: false,
            load: [:content_word_count]
          )

        assert section_with_count.content_word_count == 0
      end

      test "returns 0 for empty content" do
        site = create_site!()

        section =
          create_section!(
            site_id: site.id,
            title: "Test Section",
            content: "   "
          )

        section_with_count =
          Ash.get!(Section, section.id,
            tenant: site.id,
            authorize?: false,
            load: [:content_word_count]
          )

        assert section_with_count.content_word_count == 0
      end

      test "handles multiple spaces between words" do
        site = create_site!()

        section =
          create_section!(
            site_id: site.id,
            title: "Test Section",
            content: "Word1    Word2     Word3"
          )

        section_with_count =
          Ash.get!(Section, section.id,
            tenant: site.id,
            authorize?: false,
            load: [:content_word_count]
          )

        assert section_with_count.content_word_count == 3
      end
    end

    describe "master_update with tag_ids via master_tags relationship" do
      test "assigns tags through manage_relationship" do
        site = create_site!()
        workspace = create_workspace!(site_id: site.id)
        version = create_workspace_version!(workspace_id: workspace.id, site_id: site.id)

        section =
          Section
          |> Ash.Changeset.for_create(
            :create,
            %{
              title: "Test Section",
              slug: "test-section-fill-template",
              content: "Test content",
              workspace_version_id: version.id
            },
            tenant: site.id,
            authorize?: false
          )
          |> Ash.create!()

        tag =
          MishkaDocument.Tag
          |> Ash.Changeset.for_create(
            :master_create,
            %{
              name: "Fill Template Tag",
              slug: "fill-template-tag",
              language: "en",
              site_id: site.id
            },
            authorize?: false
          )
          |> Ash.create!()

        master_user = create_user!()

        assert {:ok, updated_section} =
                 section
                 |> Ash.Changeset.for_update(
                   :master_update,
                   %{tag_ids: [tag.id]},
                   actor: master_user,
                   authorize?: false
                 )
                 |> Ash.update()

        loaded = Ash.load!(updated_section, [:master_tags], actor: master_user, authorize?: false)
        assert length(loaded.master_tags) == 1
        assert hd(loaded.master_tags).id == tag.id
      end

      test "removes tags through manage_relationship" do
        site = create_site!()
        workspace = create_workspace!(site_id: site.id)
        version = create_workspace_version!(workspace_id: workspace.id, site_id: site.id)

        section =
          Section
          |> Ash.Changeset.for_create(
            :create,
            %{
              title: "Test Section 2",
              slug: "test-section-remove-tags",
              content: "Test removing tags",
              workspace_version_id: version.id
            },
            tenant: site.id,
            authorize?: false
          )
          |> Ash.create!()

        tag =
          MishkaDocument.Tag
          |> Ash.Changeset.for_create(
            :master_create,
            %{
              name: "Removable Tag",
              slug: "removable-tag",
              language: "en",
              site_id: site.id
            },
            authorize?: false
          )
          |> Ash.create!()

        master_user = create_user!()

        {:ok, section_with_tag} =
          section
          |> Ash.Changeset.for_update(
            :master_update,
            %{tag_ids: [tag.id]},
            actor: master_user,
            authorize?: false
          )
          |> Ash.update()

        loaded =
          Ash.load!(section_with_tag, [:master_tags], actor: master_user, authorize?: false)

        assert length(loaded.master_tags) == 1

        {:ok, section_without_tags} =
          section_with_tag
          |> Ash.Changeset.for_update(
            :master_update,
            %{tag_ids: []},
            actor: master_user,
            authorize?: false
          )
          |> Ash.update()

        loaded =
          Ash.load!(section_without_tags, [:master_tags], actor: master_user, authorize?: false)

        assert Enum.empty?(loaded.master_tags)
      end
    end
  end
end
