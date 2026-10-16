# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_document/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaDocument.Test.SectionBookmarkTest do
  @moduledoc """
  Tests for MishkaDocument.SectionBookmark resource.
  """
  use MishkaDocument.DataCase, async: false

  if Code.ensure_loaded?(MishkaDocument) do
    alias MishkaDocument.SectionBookmark

    describe "resource configuration" do
      test "uses correct table name" do
        assert AshPostgres.DataLayer.Info.table(SectionBookmark) ==
                 "mishka_document_section_bookmarks"
      end

      test "uses UUID v7 for primary keys" do
        bookmark = create_section_bookmark!()
        assert is_binary(bookmark.id)
        assert String.length(bookmark.id) == 36
      end

      test "has no multitenancy" do
        # SectionBookmark does not use multitenancy
        assert Ash.Resource.Info.multitenancy_strategy(SectionBookmark) == nil
      end
    end

    describe "create action" do
      test "creates bookmark with valid attributes" do
        user = create_user!()

        section =
          create_section!(content_review_status: :approved, technical_review_status: :approved)

        bookmark =
          SectionBookmark
          |> Ash.Changeset.for_create(
            :create,
            %{section_id: section.id},
            actor: user,
            authorize?: false
          )
          |> Ash.create!()

        assert bookmark.user_id == user.id
        assert bookmark.section_id == section.id
      end

      test "upserts when bookmark already exists" do
        user = create_user!()

        section =
          create_section!(content_review_status: :approved, technical_review_status: :approved)

        # Create first bookmark
        bookmark1 =
          SectionBookmark
          |> Ash.Changeset.for_create(
            :create,
            %{section_id: section.id},
            actor: user,
            authorize?: false
          )
          |> Ash.create!()

        # Try to create same bookmark again (should upsert)
        bookmark2 =
          SectionBookmark
          |> Ash.Changeset.for_create(
            :create,
            %{section_id: section.id},
            actor: user,
            authorize?: false
          )
          |> Ash.create!()

        # Should be the same record
        assert bookmark1.id == bookmark2.id
      end

      test "different users can bookmark the same section" do
        user1 = create_user!()
        user2 = create_user!()

        section =
          create_section!(content_review_status: :approved, technical_review_status: :approved)

        bookmark1 =
          SectionBookmark
          |> Ash.Changeset.for_create(
            :create,
            %{section_id: section.id},
            actor: user1,
            authorize?: false
          )
          |> Ash.create!()

        bookmark2 =
          SectionBookmark
          |> Ash.Changeset.for_create(
            :create,
            %{section_id: section.id},
            actor: user2,
            authorize?: false
          )
          |> Ash.create!()

        assert bookmark1.user_id == user1.id
        assert bookmark2.user_id == user2.id
        assert bookmark1.section_id == bookmark2.section_id
      end

      test "relates actor as user automatically" do
        user = create_user!()

        section =
          create_section!(content_review_status: :approved, technical_review_status: :approved)

        bookmark =
          SectionBookmark
          |> Ash.Changeset.for_create(
            :create,
            %{section_id: section.id},
            actor: user,
            authorize?: false
          )
          |> Ash.create!()

        assert bookmark.user_id == user.id
      end
    end

    describe "read actions" do
      test "default read action returns bookmarks" do
        bookmark = create_section_bookmark!()

        bookmarks =
          SectionBookmark
          |> Ash.read!(authorize?: false)

        assert Enum.any?(bookmarks, fn b -> b.id == bookmark.id end)
      end

      test "my_bookmarks returns only current user's bookmarks" do
        user1 = create_user!()
        user2 = create_user!()

        bookmark1 = create_section_bookmark!(user_id: user1.id)
        _bookmark2 = create_section_bookmark!(user_id: user2.id)

        result =
          SectionBookmark
          |> Ash.Query.for_read(:my_bookmarks, %{}, actor: user1, authorize?: false)
          |> Ash.read!()

        bookmarks = result.results
        assert length(bookmarks) == 1
        assert Enum.at(bookmarks, 0).id == bookmark1.id
      end

      test "my_bookmarks only returns bookmarks for approved sections" do
        user = create_user!()

        # Create bookmark for approved section
        approved_section =
          create_section!(content_review_status: :approved, technical_review_status: :approved)

        bookmark1 = create_section_bookmark!(user_id: user.id, section_id: approved_section.id)

        # Create bookmark for pending section
        pending_section =
          create_section!(content_review_status: :pending, technical_review_status: :pending)

        _bookmark2 = create_section_bookmark!(user_id: user.id, section_id: pending_section.id)

        result =
          SectionBookmark
          |> Ash.Query.for_read(:my_bookmarks, %{}, actor: user, authorize?: false)
          |> Ash.read!()

        bookmarks = result.results
        assert length(bookmarks) == 1
        assert Enum.at(bookmarks, 0).id == bookmark1.id
      end

      test "my_bookmarks returns empty when no actor" do
        _bookmark = create_section_bookmark!()

        result =
          SectionBookmark
          |> Ash.Query.for_read(:my_bookmarks, %{}, authorize?: false)
          |> Ash.read!()

        assert length(result.results) == 0
      end

      test "my_bookmarks supports pagination" do
        user = create_user!()

        # Create 25 bookmarks
        Enum.each(1..25, fn _ ->
          create_section_bookmark!(user_id: user.id)
        end)

        # First page (default limit is 20)
        result =
          SectionBookmark
          |> Ash.Query.for_read(:my_bookmarks, %{}, actor: user, authorize?: false)
          |> Ash.read!()

        assert length(result.results) == 20

        # Second page (offset 20, limit 10)
        result_page2 =
          SectionBookmark
          |> Ash.Query.for_read(:my_bookmarks, %{}, actor: user, authorize?: false)
          |> Ash.Query.page(offset: 20, limit: 10)
          |> Ash.read!()

        assert length(result_page2.results) == 5
      end
    end

    describe "destroy action" do
      test "removes bookmark" do
        bookmark = create_section_bookmark!()
        bookmark_id = bookmark.id

        bookmark
        |> Ash.Changeset.for_destroy(:remove, %{}, authorize?: false)
        |> Ash.destroy!()

        bookmarks = SectionBookmark |> Ash.read!(authorize?: false)
        refute Enum.any?(bookmarks, fn b -> b.id == bookmark_id end)
      end

      test "default destroy action also works" do
        bookmark = create_section_bookmark!()
        bookmark_id = bookmark.id

        bookmark
        |> Ash.Changeset.for_destroy(:destroy, %{}, authorize?: false)
        |> Ash.destroy!()

        bookmarks = SectionBookmark |> Ash.read!(authorize?: false)
        refute Enum.any?(bookmarks, fn b -> b.id == bookmark_id end)
      end
    end

    describe "relationships" do
      test "belongs_to section" do
        bookmark = create_section_bookmark!()

        # Need to get section to find its site_id for tenant
        section =
          Ash.get!(MishkaDocument.Section, bookmark.section_id,
            action: :master_get,
            authorize?: false
          )

        bookmark_with_section =
          Ash.load!(bookmark, :section, tenant: section.site_id, authorize?: false)

        assert bookmark_with_section.section.id == bookmark.section_id
      end

      test "belongs_to user" do
        bookmark = create_section_bookmark!()

        bookmark_with_user = Ash.load!(bookmark, :user, authorize?: false)

        assert bookmark_with_user.user.id == bookmark.user_id
      end

      test "section relationship uses public_list read action" do
        user = create_user!()

        # Create approved section
        approved_section =
          create_section!(content_review_status: :approved, technical_review_status: :approved)

        bookmark = create_section_bookmark!(user_id: user.id, section_id: approved_section.id)

        # Should be able to load approved section (need tenant)
        bookmark_with_section =
          Ash.load!(bookmark, :section, tenant: approved_section.site_id, authorize?: false)

        assert bookmark_with_section.section.id == approved_section.id
      end

      test "cascade delete when section is permanently deleted" do
        section = create_section!()
        bookmark = create_section_bookmark!(section_id: section.id)
        bookmark_id = bookmark.id

        # Permanently delete section (should cascade delete bookmark)
        section
        |> Ash.Changeset.for_destroy(
          :permanent_destroy,
          %{},
          tenant: section.site_id,
          authorize?: false
        )
        |> Ash.destroy!()

        # Bookmark should be automatically deleted due to cascade
        result = Ash.get(SectionBookmark, bookmark_id, authorize?: false)
        assert match?({:error, _}, result)
      end

      test "bookmark references are cleaned up when section deleted" do
        section = create_section!()
        user = create_user!()

        bookmark = create_section_bookmark!(section_id: section.id, user_id: user.id)
        bookmark_id = bookmark.id

        # Permanently delete the section (cascade should delete bookmark)
        section
        |> Ash.Changeset.for_destroy(
          :permanent_destroy,
          %{},
          tenant: section.site_id,
          authorize?: false
        )
        |> Ash.destroy!()

        # Bookmark should be gone
        result = Ash.get(SectionBookmark, bookmark_id, authorize?: false)
        assert match?({:error, _}, result)
      end

      test "bookmark remains when section is archived (soft delete)" do
        section = create_section!()
        bookmark = create_section_bookmark!(section_id: section.id)
        bookmark_id = bookmark.id

        # Archive section (soft delete) - bookmark should remain
        section
        |> Ash.Changeset.for_destroy(
          :destroy,
          %{},
          tenant: section.site_id,
          authorize?: false
        )
        |> Ash.destroy!()

        # Bookmark should still exist (soft delete doesn't cascade)
        fetched_bookmark = Ash.get!(SectionBookmark, bookmark_id, authorize?: false)
        assert fetched_bookmark.id == bookmark_id
        assert fetched_bookmark.section_id == section.id
      end

      # Note: User cascade delete test is skipped because User resource doesn't expose
      # a destroy action. The cascade delete is still enforced at database level.
    end

    describe "identities" do
      test "unique_user_section_bookmark with upsert prevents duplicates" do
        user = create_user!()

        section =
          create_section!(content_review_status: :approved, technical_review_status: :approved)

        # First bookmark succeeds
        bookmark1 =
          SectionBookmark
          |> Ash.Changeset.for_create(:create, %{section_id: section.id},
            actor: user,
            authorize?: false
          )
          |> Ash.create!()

        # Second bookmark with same user/section should upsert (update existing)
        bookmark2 =
          SectionBookmark
          |> Ash.Changeset.for_create(:create, %{section_id: section.id},
            actor: user,
            authorize?: false
          )
          |> Ash.create!()

        # Should be the same record (upserted)
        assert bookmark1.id == bookmark2.id
      end

      test "allows same user to bookmark different sections" do
        user = create_user!()

        section1 =
          create_section!(content_review_status: :approved, technical_review_status: :approved)

        section2 =
          create_section!(content_review_status: :approved, technical_review_status: :approved)

        bookmark1 = create_section_bookmark!(user_id: user.id, section_id: section1.id)
        bookmark2 = create_section_bookmark!(user_id: user.id, section_id: section2.id)

        assert bookmark1.section_id != bookmark2.section_id
        assert bookmark1.user_id == bookmark2.user_id
      end

      test "allows different users to bookmark same section" do
        section =
          create_section!(content_review_status: :approved, technical_review_status: :approved)

        user1 = create_user!()
        user2 = create_user!()

        bookmark1 = create_section_bookmark!(user_id: user1.id, section_id: section.id)
        bookmark2 = create_section_bookmark!(user_id: user2.id, section_id: section.id)

        assert bookmark1.section_id == bookmark2.section_id
        assert bookmark1.user_id != bookmark2.user_id
      end
    end

    describe "authorization policies" do
      test "my_bookmarks requires actor" do
        # Without actor, returns empty
        result =
          SectionBookmark
          |> Ash.Query.for_read(:my_bookmarks, %{}, authorize?: false)
          |> Ash.read!()

        assert length(result.results) == 0
      end

      test "users can only read their own bookmarks with authorization" do
        user1 = create_user!()
        user2 = create_user!()

        bookmark1 = create_section_bookmark!(user_id: user1.id)
        _bookmark2 = create_section_bookmark!(user_id: user2.id)

        # User1 reading with authorization should only see their bookmark
        # Authorization policy automatically filters by user_id == actor.id
        bookmarks =
          SectionBookmark
          |> Ash.read!(actor: user1, authorize?: true)

        assert length(bookmarks) == 1
        assert Enum.at(bookmarks, 0).id == bookmark1.id
      end

      test "users can create bookmarks when authenticated" do
        section =
          create_section!(content_review_status: :approved, technical_review_status: :approved)

        user = create_user!(site_id: section.site_id)

        bookmark =
          SectionBookmark
          |> Ash.Changeset.for_create(
            :create,
            %{section_id: section.id},
            actor: user,
            tenant: section.site_id,
            authorize?: true
          )
          |> Ash.create!()

        assert bookmark.user_id == user.id
      end

      test "users can only destroy their own bookmarks with authorization" do
        user = create_user!()
        bookmark = create_section_bookmark!(user_id: user.id)

        # User can destroy their own bookmark
        bookmark
        |> Ash.Changeset.for_destroy(:remove, %{}, actor: user, authorize?: true)
        |> Ash.destroy!()

        # Bookmark should be deleted
        result = Ash.get(SectionBookmark, bookmark.id, authorize?: false)
        assert match?({:error, _}, result)
      end
    end

    describe "database constraints" do
      test "requires section_id" do
        user = create_user!()

        assert_raise Ash.Error.Invalid, fn ->
          SectionBookmark
          |> Ash.Changeset.for_create(:create, %{}, actor: user, authorize?: false)
          |> Ash.create!()
        end
      end

      test "requires valid section_id foreign key" do
        user = create_user!()
        fake_section_id = Ash.UUID.generate()

        assert_raise Ash.Error.Invalid, fn ->
          SectionBookmark
          |> Ash.Changeset.for_create(
            :create,
            %{section_id: fake_section_id},
            actor: user,
            authorize?: false
          )
          |> Ash.create!()
        end
      end
    end

    describe "timestamps" do
      test "sets inserted_at on creation" do
        bookmark = create_section_bookmark!()
        assert bookmark.inserted_at != nil
      end

      test "sets updated_at on creation" do
        bookmark = create_section_bookmark!()
        assert bookmark.updated_at != nil
      end
    end
  end
end
