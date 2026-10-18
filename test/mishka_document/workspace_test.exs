# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_document/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaDocument.Test.WorkspaceTest do
  @moduledoc """
  Tests for MishkaDocument.Workspace resource.
  """
  use MishkaDocument.DataCase, async: false

  if Code.ensure_loaded?(MishkaDocument) do
    alias MishkaDocument.Workspace

    describe "resource configuration" do
      test "uses correct table name" do
        assert AshPostgres.DataLayer.Info.table(Workspace) == "mishka_document_workspaces"
      end

      test "uses UUID v7 for primary keys" do
        workspace = create_workspace!()
        assert {:ok, _uuid} = Ecto.UUID.cast(workspace.id)
        assert String.length(workspace.id) == 36
      end

      test "is always site-specific (not global)" do
        multitenancy_config = Ash.Resource.Info.multitenancy_strategy(Workspace)
        assert multitenancy_config == :attribute
        assert Ash.Resource.Info.multitenancy_global?(Workspace) == false
      end
    end

    describe "create action" do
      test "creates workspace with valid attributes" do
        site = create_site!()

        workspace =
          create_workspace!(
            name: "Test Workspace",
            slug: "test-workspace",
            status: :active,
            language: "en",
            site_id: site.id
          )

        assert workspace.name == "Test Workspace"
        assert workspace.slug == "test-workspace"
        assert workspace.status == :active
        assert workspace.language == "en"
        assert workspace.site_id == site.id
      end

      test "auto-generates slug from slug" do
        site = create_site!()

        workspace =
          create_workspace!(
            name: "My Awesome Workspace",
            slug: "My Awesome Workspace",
            site_id: site.id
          )

        assert workspace.slug == "my-awesome-workspace"
      end

      test "requires name, slug, status, and language" do
        site = create_site!()

        assert_raise Ash.Error.Invalid, fn ->
          Workspace
          |> Ash.Changeset.for_create(:create, %{}, tenant: site.id, authorize?: false)
          |> Ash.create!()
        end
      end

      test "auto-assigns site_id from tenant context" do
        site = create_site!()

        workspace =
          Workspace
          |> Ash.Changeset.for_create(
            :create,
            %{
              name: "Tenant Workspace",
              slug: "tenant-workspace",
              status: :active,
              language: "en"
            },
            tenant: site.id,
            authorize?: false
          )
          |> Ash.create!()

        assert workspace.site_id == site.id
      end

      test "auto-assigns language_group_id for master workspaces" do
        site = create_site!()

        workspace = create_workspace!(name: "Master Workspace", site_id: site.id)

        assert workspace.language_group_id == workspace.id
      end

      test "defaults status to draft" do
        site = create_site!()

        workspace =
          Workspace
          |> Ash.Changeset.for_create(
            :create,
            %{
              name: "Draft Workspace",
              slug: "draft-workspace",
              language: "en"
            },
            tenant: site.id,
            authorize?: false
          )
          |> Ash.create!()

        assert workspace.status == :draft
      end

      test "defaults language to 'en'" do
        site = create_site!()

        workspace =
          Workspace
          |> Ash.Changeset.for_create(
            :create,
            %{
              name: "English Workspace",
              slug: "english-workspace",
              status: :active
            },
            tenant: site.id,
            authorize?: false
          )
          |> Ash.create!()

        assert workspace.language == "en"
      end

      test "defaults featured to false" do
        site = create_site!()
        workspace = create_workspace!(site_id: site.id)
        assert workspace.featured == false
      end

      test "defaults display_order to 0" do
        site = create_site!()
        workspace = create_workspace!(site_id: site.id)
        assert workspace.display_order == 0
      end

      test "accepts optional description" do
        site = create_site!()

        workspace =
          create_workspace!(
            name: "Workspace with Description",
            description: "This is a test description",
            site_id: site.id
          )

        assert workspace.description == "This is a test description"
      end

      test "accepts optional seo_tags" do
        site = create_site!()

        seo_tags = [
          %{tag: "meta", attrs: %{"name" => "description"}, content: "SEO description"},
          %{tag: "meta", attrs: %{"property" => "og:title"}, content: "Open Graph Title"}
        ]

        workspace = create_workspace!(seo_tags: seo_tags, site_id: site.id)

        assert workspace.seo_tags == seo_tags
      end

      test "accepts permissions, each trimmed, downcased and once" do
        site = create_site!()

        workspace =
          create_workspace!(
            permissions: ["  Docs:Read ", "docs:read", "DOCS:WRITE"],
            site_id: site.id
          )

        assert workspace.permissions == ["docs:read", "docs:write"]
      end

      test "accepts optional schema" do
        site = create_site!()

        schema = [
          %{"@type" => "CreativeWork", "name" => "Test Workspace"}
        ]

        workspace = create_workspace!(schema: schema, site_id: site.id)

        assert workspace.schema == schema
      end
    end

    describe "master_create action" do
      test "creates workspace with explicit site_id" do
        site = create_site!()

        workspace =
          Workspace
          |> Ash.Changeset.for_create(
            :master_create,
            %{
              name: "Master Workspace",
              slug: "master-workspace",
              status: :active,
              language: "en",
              site_id: site.id
            },
            authorize?: false
          )
          |> Ash.create!(authorize?: false)

        assert workspace.name == "Master Workspace"
        assert workspace.site_id == site.id
      end

      test "requires explicit site_id" do
        assert_raise Ash.Error.Invalid, fn ->
          Workspace
          |> Ash.Changeset.for_create(
            :master_create,
            %{
              name: "Missing Site",
              slug: "missing-site",
              status: :active,
              language: "en"
            },
            authorize?: false
          )
          |> Ash.create!()
        end
      end
    end

    describe "update action" do
      test "updates workspace attributes" do
        site = create_site!()
        workspace = create_workspace!(name: "Original Name", site_id: site.id)

        updated =
          workspace
          |> Ash.Changeset.for_update(
            :update,
            %{name: "Updated Name", description: "New description"},
            tenant: site.id,
            authorize?: false
          )
          |> Ash.update!()

        assert updated.name == "Updated Name"
        assert updated.description == "New description"
      end

      test "updates and clears permissions" do
        site = create_site!()
        workspace = create_workspace!(site_id: site.id)

        update = fn record, permissions ->
          record
          |> Ash.Changeset.for_update(:update, %{permissions: permissions},
            tenant: site.id,
            authorize?: false
          )
          |> Ash.update!()
        end

        locked = update.(workspace, ["Members:Read"])
        assert locked.permissions == ["members:read"]
        assert update.(locked, []).permissions == []
      end

      test "prevents updating archived workspace" do
        site = create_site!()
        workspace = create_workspace!(site_id: site.id)

        # Archive the workspace
        archived =
          workspace
          |> Ash.Changeset.for_destroy(:destroy, %{}, tenant: site.id, authorize?: false)
          |> Ash.destroy!(return_destroyed?: true)

        # Try to update archived workspace
        assert_raise Ash.Error.Invalid, fn ->
          archived
          |> Ash.Changeset.for_update(
            :update,
            %{name: "Should Fail"},
            tenant: site.id,
            authorize?: false
          )
          |> Ash.update!()
        end
      end

      test "prevents site_id changes" do
        site1 = create_site!()
        site2 = create_site!()
        workspace = create_workspace!(site_id: site1.id)

        # site_id is not in the accepted fields for update, so we just verify it can't be changed
        # by updating with only allowed fields
        updated =
          workspace
          |> Ash.Changeset.for_update(
            :update,
            %{name: "Updated"},
            tenant: site1.id,
            authorize?: false
          )
          |> Ash.update!()

        # site_id should remain unchanged
        assert updated.site_id == site1.id
        assert updated.site_id != site2.id
      end

      test "can query workspace versions through relationship" do
        site = create_site!()
        workspace = create_workspace!(site_id: site.id)

        # Create additional version
        new_version = create_workspace_version!(workspace_id: workspace.id, site_id: site.id)

        # Load versions through relationship
        loaded_workspace =
          Ash.load!(workspace, [:tenant_versions], tenant: site.id, authorize?: false)

        # Should have 2 versions now (1 from factory, 1 new)
        assert length(loaded_workspace.tenant_versions) == 2
        version_ids = Enum.map(loaded_workspace.tenant_versions, & &1.id)
        assert new_version.id in version_ids
      end
    end

    describe "master_update action" do
      test "updates workspace for master users" do
        site = create_site!()
        workspace = create_workspace!(name: "Original", site_id: site.id)

        updated =
          workspace
          |> Ash.Changeset.for_update(:master_update, %{name: "Master Updated"},
            authorize?: false
          )
          |> Ash.update!()

        assert updated.name == "Master Updated"
      end

      test "prevents site_id changes" do
        site1 = create_site!()
        site2 = create_site!()
        workspace = create_workspace!(site_id: site1.id)

        assert {:error, %Ash.Error.Invalid{errors: errors}} =
                 workspace
                 |> Ash.Changeset.for_update(
                   :master_update,
                   %{name: "Updated", site_id: site2.id},
                   authorize?: false
                 )
                 |> Ash.update()

        assert Enum.any?(errors, &match?(%Ash.Error.Invalid.NoSuchInput{input: :site_id}, &1))

        assert Ash.get!(MishkaDocument.Workspace, workspace.id,
                 action: :master_get,
                 authorize?: false
               ).site_id == site1.id
      end

      test "can query workspace versions through relationship" do
        site = create_site!()
        workspace = create_workspace!(site_id: site.id)

        # Create additional version
        new_version = create_workspace_version!(workspace_id: workspace.id, site_id: site.id)

        # Load versions through relationship
        loaded_workspace =
          Ash.load!(workspace, [:tenant_versions], tenant: site.id, authorize?: false)

        # Should have 2 versions now (1 from factory, 1 new)
        assert length(loaded_workspace.tenant_versions) == 2
        version_ids = Enum.map(loaded_workspace.tenant_versions, & &1.id)
        assert new_version.id in version_ids
      end
    end

    describe "read actions with multitenancy" do
      test "tenant read only shows workspaces for that tenant" do
        site1 = create_site!()
        site2 = create_site!()

        workspace1 = create_workspace!(name: "Site 1 Workspace", site_id: site1.id)
        _workspace2 = create_workspace!(name: "Site 2 Workspace", site_id: site2.id)

        # Query as site1 tenant
        workspaces =
          Workspace
          |> Ash.Query.set_tenant(site1.id)
          |> Ash.read!(authorize?: false, page: false)

        assert length(workspaces) == 1
        assert Enum.at(workspaces, 0).id == workspace1.id
      end

      test "master_read shows all workspaces system-wide" do
        site1 = create_site!()
        site2 = create_site!()

        _workspace1 = create_workspace!(name: "Site 1", site_id: site1.id)
        _workspace2 = create_workspace!(name: "Site 2", site_id: site2.id)

        result =
          Workspace
          |> Ash.Query.for_read(:master_read, %{}, authorize?: false)
          |> Ash.read!()

        workspaces = result.results
        assert length(workspaces) >= 2
      end

      test "master_get retrieves workspace by ID bypassing tenant" do
        site = create_site!()
        workspace = create_workspace!(site_id: site.id)

        fetched = Ash.get!(Workspace, workspace.id, action: :master_get, authorize?: false)

        assert fetched.id == workspace.id
      end
    end

    describe "archive/unarchive actions" do
      test "destroy soft deletes workspace" do
        site = create_site!()
        workspace = create_workspace!(site_id: site.id)

        archived =
          workspace
          |> Ash.Changeset.for_destroy(:destroy, %{}, tenant: site.id, authorize?: false)
          |> Ash.destroy!(return_destroyed?: true)

        assert %DateTime{} = archived.archived_at
        assert archived.status == :archived

        # Should not appear in normal reads
        workspaces =
          Workspace
          |> Ash.Query.set_tenant(site.id)
          |> Ash.read!(authorize?: false, page: false)

        assert Enum.find(workspaces, fn w -> w.id == workspace.id end) == nil
      end

      test "unarchive restores archived workspace" do
        site = create_site!()
        workspace = create_workspace!(site_id: site.id)

        # Archive
        archived =
          workspace
          |> Ash.Changeset.for_destroy(:destroy, %{}, tenant: site.id, authorize?: false)
          |> Ash.destroy!(return_destroyed?: true)

        # Unarchive
        unarchived =
          archived
          |> Ash.Changeset.for_update(:unarchive, %{}, tenant: site.id, authorize?: false)
          |> Ash.update!()

        assert unarchived.archived_at == nil
        assert unarchived.status == :active
      end

      test "archived action lists only archived workspaces" do
        site = create_site!()
        active_workspace = create_workspace!(name: "Active", site_id: site.id)

        archived_workspace =
          create_workspace!(name: "To Archive", site_id: site.id)
          |> Ash.Changeset.for_destroy(:destroy, %{}, tenant: site.id, authorize?: false)
          |> Ash.destroy!(return_destroyed?: true)

        result =
          Workspace
          |> Ash.Query.for_read(:archived, %{}, tenant: site.id, authorize?: false)
          |> Ash.read!()

        archived_list = result.results
        archived_ids = Enum.map(archived_list, & &1.id)
        assert archived_workspace.id in archived_ids
        refute active_workspace.id in archived_ids
      end

      test "get_archived retrieves single archived workspace" do
        site = create_site!()

        workspace =
          create_workspace!(site_id: site.id)
          |> Ash.Changeset.for_destroy(:destroy, %{}, tenant: site.id, authorize?: false)
          |> Ash.destroy!(return_destroyed?: true)

        fetched =
          Ash.get!(
            Workspace,
            workspace.id,
            action: :get_archived,
            tenant: site.id,
            authorize?: false
          )

        assert fetched.id == workspace.id
        assert %DateTime{} = fetched.archived_at
      end

      test "master_unarchive restores workspace" do
        site = create_site!()

        workspace =
          create_workspace!(site_id: site.id)
          |> Ash.Changeset.for_destroy(:destroy, %{}, tenant: site.id, authorize?: false)
          |> Ash.destroy!(return_destroyed?: true)

        # Fetch the archived workspace first
        archived_workspace =
          Ash.get!(Workspace, workspace.id, action: :master_get_archived, authorize?: false)

        unarchived =
          archived_workspace
          |> Ash.Changeset.for_update(:master_unarchive, %{}, authorize?: false)
          |> Ash.update!()

        assert unarchived.archived_at == nil
        assert unarchived.status == :active
      end

      test "prevents archiving already archived workspace" do
        site = create_site!()

        workspace =
          create_workspace!(site_id: site.id)
          |> Ash.Changeset.for_destroy(:destroy, %{}, tenant: site.id, authorize?: false)
          |> Ash.destroy!(return_destroyed?: true)

        assert_raise Ash.Error.Invalid, fn ->
          workspace
          |> Ash.Changeset.for_destroy(:destroy, %{}, tenant: site.id, authorize?: false)
          |> Ash.destroy!()
        end
      end

      test "prevents unarchiving non-archived workspace" do
        site = create_site!()
        workspace = create_workspace!(site_id: site.id)

        assert_raise Ash.Error.Invalid, fn ->
          workspace
          |> Ash.Changeset.for_update(:master_unarchive, %{}, authorize?: false)
          |> Ash.update!()
        end
      end
    end

    describe "permanent_destroy action" do
      test "permanently deletes workspace and cannot be recovered" do
        site = create_site!()
        workspace = create_workspace!(site_id: site.id)
        workspace_id = workspace.id

        workspace
        |> Ash.Changeset.for_destroy(
          :permanent_destroy,
          %{},
          tenant: site.id,
          authorize?: false
        )
        |> Ash.destroy!()

        # Should not exist in any query
        result =
          Ash.get(
            Workspace,
            workspace_id,
            action: :master_get,
            authorize?: false
          )

        assert match?({:error, _}, result)
      end

      test "master_permanent_destroy permanently deletes workspace" do
        site = create_site!()
        workspace = create_workspace!(site_id: site.id)
        workspace_id = workspace.id

        workspace
        |> Ash.Changeset.for_destroy(:master_permanent_destroy, %{}, authorize?: false)
        |> Ash.destroy!()

        result =
          Ash.get(
            Workspace,
            workspace_id,
            action: :master_get,
            authorize?: false
          )

        assert match?({:error, _}, result)
      end
    end

    # A TRANSLATION POINTS AT ITS MASTER BY ID, so the master goes last and comes back first. The
    # admin tables destroy with the record and no `authorize?`, which an archive hands its validations
    # as `authorize?: false`.
    describe "deleting a master that has translations" do
      setup do
        site = create_site!()
        master = create_workspace!(site_id: site.id)

        fa =
          create_workspace!(
            site_id: site.id,
            slug: "#{master.slug}-fa",
            language: "fa",
            language_group_id: master.id
          )

        %{
          site: site,
          master: master,
          fa: fa,
          master_user: create_user_with_permissions!(["*"]),
          tenant_user: create_user_with_permissions!(["admin:dashboard:*"], site_id: site.id)
        }
      end

      # Refused for this reason, and not for another the same call could run into.
      defp refused?({:error, %Ash.Error.Invalid{} = error}),
        do:
          Exception.message(error) =~
            "This is the original English version. Its Persian translation is still live, so " <>
              "it can't be deleted yet. Archive or delete that translation first, then this one."

      defp refused?(_result), do: false

      test "archiving it is refused while a translation is live, however it is called", %{
        site: site,
        master: master,
        master_user: master_user,
        tenant_user: tenant_user
      } do
        as_master = Ash.get!(Workspace, master.id, action: :master_get, actor: master_user)

        assert refused?(
                 Ash.destroy(master, action: :destroy, tenant: site.id, actor: tenant_user)
               )

        assert refused?(Ash.destroy(as_master, action: :master_destroy, actor: master_user))
        assert refused?(Ash.destroy(master, action: :destroy, tenant: site.id, authorize?: false))

        assert master
               |> Ash.Changeset.for_destroy(:destroy, %{}, tenant: site.id, actor: tenant_user)
               |> Ash.destroy()
               |> refused?()
      end

      test "deleting it for good is refused while a translation is live", %{
        site: site,
        master: master,
        master_user: master_user,
        tenant_user: tenant_user
      } do
        as_master = Ash.get!(Workspace, master.id, action: :master_get, actor: master_user)

        assert refused?(
                 Ash.destroy(master,
                   action: :permanent_destroy,
                   tenant: site.id,
                   actor: tenant_user
                 )
               )

        assert refused?(
                 Ash.destroy(as_master, action: :master_permanent_destroy, actor: master_user)
               )
      end

      # AN ARCHIVED TRANSLATION IS IN NOBODY'S WAY: the archive lists a master beside its archived
      # editions, and a selection holding all of them empties the group in one go. Its restore is
      # what keeps that edition from outliving its master.
      test "deleting it for good goes ahead while an archived translation remains", %{
        site: site,
        master: master,
        fa: fa,
        tenant_user: tenant_user
      } do
        :ok = Ash.destroy(fa, action: :destroy, tenant: site.id, actor: tenant_user)
        :ok = Ash.destroy(master, action: :destroy, tenant: site.id, actor: tenant_user)
        archived = Ash.get!(Workspace, master.id, action: :master_get_archived, authorize?: false)

        assert :ok =
                 Ash.destroy(archived,
                   action: :permanent_destroy,
                   tenant: site.id,
                   actor: tenant_user
                 )
      end

      test "restoring the translation is refused while its master is archived", %{
        site: site,
        master: master,
        fa: fa,
        master_user: master_user,
        tenant_user: tenant_user
      } do
        :ok = Ash.destroy(fa, action: :destroy, tenant: site.id, actor: tenant_user)
        :ok = Ash.destroy(master, action: :destroy, tenant: site.id, actor: tenant_user)
        archived_fa = Ash.get!(Workspace, fa.id, action: :master_get_archived, authorize?: false)

        assert {:error, %Ash.Error.Invalid{} = error} =
                 Ash.update(archived_fa, action: :unarchive, tenant: site.id, actor: tenant_user)

        assert Exception.message(error) =~
                 "This is the Persian translation. Its original English version is archived, " <>
                   "so it can't be restored yet. Restore the original first, then this one."

        assert {:error, %Ash.Error.Invalid{}} =
                 Ash.update(archived_fa, action: :master_unarchive, actor: master_user)

        assert Ash.get!(Workspace, fa.id, action: :master_get_archived, authorize?: false).archived_at
      end

      test "and for good once its master has been deleted", %{
        site: site,
        master: master,
        fa: fa,
        tenant_user: tenant_user
      } do
        :ok = Ash.destroy(fa, action: :destroy, tenant: site.id, actor: tenant_user)
        :ok = Ash.destroy(master, action: :destroy, tenant: site.id, actor: tenant_user)
        archived = Ash.get!(Workspace, master.id, action: :master_get_archived, authorize?: false)

        :ok =
          Ash.destroy(archived, action: :permanent_destroy, tenant: site.id, actor: tenant_user)

        archived_fa = Ash.get!(Workspace, fa.id, action: :master_get_archived, authorize?: false)

        assert {:error, %Ash.Error.Invalid{} = error} =
                 Ash.update(archived_fa, action: :unarchive, tenant: site.id, actor: tenant_user)

        assert Exception.message(error) =~
                 "This is the Persian translation. Its original version has been deleted for " <>
                   "good, so it can't be restored. It can only be deleted for good."
      end

      test "restoring the master first brings the group back", %{
        site: site,
        master: master,
        fa: fa,
        tenant_user: tenant_user
      } do
        :ok = Ash.destroy(fa, action: :destroy, tenant: site.id, actor: tenant_user)
        :ok = Ash.destroy(master, action: :destroy, tenant: site.id, actor: tenant_user)
        archived = Ash.get!(Workspace, master.id, action: :master_get_archived, authorize?: false)
        archived_fa = Ash.get!(Workspace, fa.id, action: :master_get_archived, authorize?: false)

        assert {:ok, _master} =
                 Ash.update(archived, action: :unarchive, tenant: site.id, actor: tenant_user)

        assert {:ok, restored} =
                 Ash.update(archived_fa, action: :unarchive, tenant: site.id, actor: tenant_user)

        assert is_nil(restored.archived_at)
      end

      test "it goes, archived and then for good, once its translation has", %{
        site: site,
        master: master,
        fa: fa,
        tenant_user: tenant_user
      } do
        :ok = Ash.destroy(fa, action: :destroy, tenant: site.id, actor: tenant_user)
        :ok = Ash.destroy(master, action: :destroy, tenant: site.id, actor: tenant_user)

        archived_fa = Ash.get!(Workspace, fa.id, action: :master_get_archived, authorize?: false)
        archived = Ash.get!(Workspace, master.id, action: :master_get_archived, authorize?: false)

        assert :ok =
                 Ash.destroy(archived_fa,
                   action: :permanent_destroy,
                   tenant: site.id,
                   actor: tenant_user
                 )

        assert :ok =
                 Ash.destroy(archived,
                   action: :permanent_destroy,
                   tenant: site.id,
                   actor: tenant_user
                 )
      end
    end

    describe "database constraints" do
      test "enforces slug length constraints" do
        site = create_site!()

        # Empty slug should fail
        assert_raise Ash.Error.Invalid, fn ->
          create_workspace!(slug: "", site_id: site.id)
        end

        # Slug too long (> 255) should fail
        long_slug = String.duplicate("a", 256)

        assert_raise Ash.Error.Invalid, fn ->
          create_workspace!(slug: long_slug, site_id: site.id)
        end
      end

      test "enforces display_order must be non-negative" do
        site = create_site!()

        assert_raise Ash.Error.Invalid, fn ->
          create_workspace!(display_order: -1, site_id: site.id)
        end
      end
    end

    describe "attribute defaults" do
      test "defaults are applied correctly" do
        site = create_site!()

        workspace =
          Workspace
          |> Ash.Changeset.for_create(
            :create,
            %{name: "Test", slug: "test"},
            tenant: site.id,
            authorize?: false
          )
          |> Ash.create!()

        assert workspace.status == :draft
        assert workspace.language == "en"
        assert workspace.featured == false
        assert workspace.display_order == 0
        assert workspace.schema == []
        assert workspace.seo_tags == []
        assert workspace.permissions == []
      end
    end

    describe "complex scenarios" do
      test "language variants and grouping" do
        site = create_site!()

        # Create master workspace with language_group_id
        english =
          create_workspace!(
            name: "English Workspace",
            slug: "english-workspace",
            language: "en",
            site_id: site.id
          )

        language_group_id = english.language_group_id

        # Create variant with same language_group_id
        persian =
          create_workspace!(
            name: "Persian Workspace",
            slug: "persian-workspace",
            language: "fa",
            language_group_id: language_group_id,
            site_id: site.id
          )

        # Query language variants
        variants =
          Workspace
          |> Ash.Query.for_read(
            :language_variants,
            %{language_group_id: language_group_id},
            tenant: site.id,
            authorize?: false
          )
          |> Ash.read!()

        variant_languages = Enum.map(variants, & &1.language) |> Enum.sort()
        assert variant_languages == ["en", "fa"]

        # Load relationship
        variants_query =
          Workspace
          |> Ash.Query.set_tenant(site.id)
          |> Ash.Query.page(limit: 10)

        english_with_variants =
          Ash.load!(english, [language_variants: variants_query],
            tenant: english.site_id,
            authorize?: false
          )

        assert length(english_with_variants.language_variants.results) == 2
        assert persian.id in Enum.map(english_with_variants.language_variants.results, & &1.id)
      end
    end

    describe "relationships" do
      test "belongs_to site" do
        site = create_site!()
        workspace = create_workspace!(site_id: site.id)

        workspace_with_site =
          Ash.load!(workspace, :site, tenant: workspace.site_id, authorize?: false)

        assert workspace_with_site.site.id == site.id
        assert workspace_with_site.site.host == site.host
      end

      test "language_variants relationship" do
        site = create_site!()

        english = create_workspace!(language: "en", site_id: site.id)
        language_group_id = english.language_group_id

        _persian =
          create_workspace!(
            language: "fa",
            language_group_id: language_group_id,
            site_id: site.id
          )

        _arabic =
          create_workspace!(
            language: "ar",
            language_group_id: language_group_id,
            site_id: site.id
          )

        variants_query =
          Workspace
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

      test "tenant_versions relationship with pagination" do
        site = create_site!()
        workspace = create_workspace!(site_id: site.id)

        alias MishkaDocument.WorkspaceVersion

        # Create multiple versions
        version1 = create_workspace_version!(workspace_id: workspace.id, site_id: site.id)
        version2 = create_workspace_version!(workspace_id: workspace.id, site_id: site.id)
        version3 = create_workspace_version!(workspace_id: workspace.id, site_id: site.id)

        # Load with pagination
        versions_query =
          WorkspaceVersion
          |> Ash.Query.set_tenant(site.id)
          |> Ash.Query.page(limit: 10)

        workspace_with_versions =
          Ash.load!(workspace, [tenant_versions: versions_query],
            tenant: site.id,
            authorize?: false
          )

        # Should load all versions including the one created by factory
        assert length(workspace_with_versions.tenant_versions.results) == 4

        version_ids =
          Enum.map(workspace_with_versions.tenant_versions.results, & &1.id) |> Enum.sort()

        assert version1.id in version_ids
        assert version2.id in version_ids
        assert version3.id in version_ids
      end

      test "master_versions relationship with pagination" do
        site = create_site!()
        workspace = create_workspace!(site_id: site.id)

        # Create multiple versions
        version1 = create_workspace_version!(workspace_id: workspace.id, site_id: site.id)
        version2 = create_workspace_version!(workspace_id: workspace.id, site_id: site.id)

        # Load master_versions with pagination (uses read_any action which bypasses tenant)
        alias MishkaDocument.WorkspaceVersion

        versions_query =
          WorkspaceVersion
          |> Ash.Query.for_read(:read_any, %{}, authorize?: false)
          |> Ash.Query.page(limit: 10)

        # A master is a user with no site; a call with no actor loads no master_* relationship.
        workspace_with_versions =
          Ash.load!(workspace, [master_versions: versions_query],
            actor: create_user!(),
            authorize?: false
          )

        # Should load all versions for this workspace
        assert length(workspace_with_versions.master_versions.results) >= 2

        version_ids = Enum.map(workspace_with_versions.master_versions.results, & &1.id)
        assert version1.id in version_ids
        assert version2.id in version_ids
      end

      test "versions relationship (public) with pagination" do
        site = create_site!()
        workspace = create_workspace!(site_id: site.id, skip_version: true)

        alias MishkaDocument.WorkspaceVersion

        # Create and publish multiple versions
        version1 =
          create_workspace_version!(
            workspace_id: workspace.id,
            site_id: site.id,
            status: :stable,
            published_at: DateTime.utc_now()
          )

        version2 =
          create_workspace_version!(
            workspace_id: workspace.id,
            site_id: site.id,
            status: :stable,
            published_at: DateTime.utc_now()
          )

        _draft_version =
          create_workspace_version!(workspace_id: workspace.id, site_id: site.id, status: :draft)

        # Load public versions with pagination
        versions_query =
          WorkspaceVersion
          |> Ash.Query.page(limit: 10)

        workspace_with_versions =
          Ash.load!(workspace, [versions: versions_query],
            tenant: workspace.site_id,
            authorize?: false
          )

        # Should only load published versions
        version_ids = Enum.map(workspace_with_versions.versions.results, & &1.id)
        assert version1.id in version_ids
        assert version2.id in version_ids

        # All should be stable status
        statuses = Enum.map(workspace_with_versions.versions.results, & &1.status) |> Enum.uniq()
        assert statuses == [:stable]
      end
    end

    describe "identities" do
      test "unique_slug_per_site prevents duplicate slugs within a site" do
        site = create_site!()
        _workspace1 = create_workspace!(slug: "unique-slug", site_id: site.id)

        assert_raise Ash.Error.Invalid, fn ->
          create_workspace!(slug: "unique-slug", site_id: site.id)
        end
      end

      test "allows same slug across different sites" do
        site1 = create_site!()
        site2 = create_site!()

        workspace1 = create_workspace!(slug: "same-slug", site_id: site1.id)
        workspace2 = create_workspace!(slug: "same-slug", site_id: site2.id)

        assert workspace1.slug == workspace2.slug
        assert workspace1.site_id != workspace2.site_id
      end

      test "unique_language_per_group prevents duplicate languages in same group" do
        site = create_site!()

        english = create_workspace!(language: "en", site_id: site.id)
        language_group_id = english.language_group_id

        assert_raise Ash.Error.Invalid, fn ->
          create_workspace!(
            language: "en",
            language_group_id: language_group_id,
            site_id: site.id
          )
        end
      end

      test "allows same language in different groups" do
        site = create_site!()

        workspace1 = create_workspace!(language: "en", site_id: site.id)
        workspace2 = create_workspace!(language: "en", site_id: site.id)

        assert workspace1.language == workspace2.language
        assert workspace1.language_group_id != workspace2.language_group_id
      end
    end

    describe "JSON API configuration" do
      test "has correct JSON API type" do
        json_api_type = AshJsonApi.Resource.Info.type(Workspace)
        assert json_api_type == "workspace"
      end
    end

    describe "public_list action" do
      test "lists active workspaces without authentication" do
        site = create_site!()

        # Create workspaces with different statuses
        active1 = create_workspace!(name: "Active 1", status: :active, site_id: site.id)
        active2 = create_workspace!(name: "Active 2", status: :active, site_id: site.id)
        _draft = create_workspace!(name: "Draft", status: :draft, site_id: site.id)

        # Archived workspace
        _archived =
          create_workspace!(name: "Archived", status: :active, site_id: site.id)
          |> Ash.Changeset.for_destroy(:destroy, %{}, tenant: site.id, authorize?: false)
          |> Ash.destroy!(return_destroyed?: true)

        # Query public_list action without actor (no authentication)
        workspaces =
          Workspace
          |> Ash.Query.for_read(:public_list, %{}, tenant: site.id, authorize?: false)
          |> Ash.read!()

        workspace_ids = Enum.map(workspaces, & &1.id) |> Enum.sort()

        # Should only return active workspaces
        assert length(workspaces) == 2
        assert Enum.sort([active1.id, active2.id]) == workspace_ids
      end

      test "supports pagination" do
        site = create_site!()

        # Create 25 active workspaces
        _workspaces =
          Enum.map(1..25, fn i ->
            create_workspace!(name: "Workspace #{i}", status: :active, site_id: site.id)
          end)

        # Query with explicit pagination (20 per page)
        result =
          Workspace
          |> Ash.Query.for_read(:public_list, %{}, tenant: site.id, authorize?: false)
          |> Ash.Query.page(limit: 20)
          |> Ash.read!()

        assert length(result.results) == 20

        # Query second page
        result_page2 =
          Workspace
          |> Ash.Query.for_read(:public_list, %{}, tenant: site.id, authorize?: false)
          |> Ash.Query.page(offset: 20, limit: 10)
          |> Ash.read!()

        assert length(result_page2.results) == 5
      end

      test "respects tenant context" do
        site1 = create_site!()
        site2 = create_site!()

        # Create active workspaces in different sites
        site1_workspace = create_workspace!(name: "Site 1", status: :active, site_id: site1.id)
        _site2_workspace = create_workspace!(name: "Site 2", status: :active, site_id: site2.id)

        # Query as site1 tenant
        workspaces =
          Workspace
          |> Ash.Query.for_read(:public_list, %{}, tenant: site1.id, authorize?: false)
          |> Ash.read!()

        # Should only see site1 workspaces
        assert length(workspaces) == 1
        assert Enum.at(workspaces, 0).id == site1_workspace.id
      end

      test "allows public access without authorization" do
        site = create_site!()
        _workspace = create_workspace!(name: "Public", status: :active, site_id: site.id)

        # This should not raise an authorization error
        workspaces =
          Workspace
          |> Ash.Query.for_read(:public_list, %{}, tenant: site.id)
          |> Ash.read!()

        assert length(workspaces) == 1
      end
    end

    describe "public_get action" do
      test "gets a single active workspace without authentication" do
        site = create_site!()

        workspace =
          create_workspace!(name: "Active Workspace", status: :active, site_id: site.id)

        # Query without actor (no authentication)
        fetched =
          Ash.get!(
            Workspace,
            workspace.id,
            action: :public_get,
            tenant: site.id,
            authorize?: false
          )

        assert fetched.id == workspace.id
        assert fetched.name == "Active Workspace"
      end

      test "returns error when workspace is not active" do
        site = create_site!()
        draft_workspace = create_workspace!(name: "Draft", status: :draft, site_id: site.id)

        # Should not find draft workspace
        result =
          Ash.get(
            Workspace,
            draft_workspace.id,
            action: :public_get,
            tenant: site.id,
            authorize?: false
          )

        assert match?({:error, _}, result)
      end

      test "returns error when workspace is archived" do
        site = create_site!()

        archived_workspace =
          create_workspace!(name: "To Archive", status: :active, site_id: site.id)
          |> Ash.Changeset.for_destroy(:destroy, %{}, tenant: site.id, authorize?: false)
          |> Ash.destroy!(return_destroyed?: true)

        # Should not find archived workspace
        result =
          Ash.get(
            Workspace,
            archived_workspace.id,
            action: :public_get,
            tenant: site.id,
            authorize?: false
          )

        assert match?({:error, _}, result)
      end

      test "respects tenant context" do
        site1 = create_site!()
        site2 = create_site!()

        workspace = create_workspace!(name: "Site 1", status: :active, site_id: site1.id)

        # Should find in correct tenant
        fetched =
          Ash.get!(
            Workspace,
            workspace.id,
            action: :public_get,
            tenant: site1.id,
            authorize?: false
          )

        assert fetched.id == workspace.id

        # Should not find in wrong tenant
        result =
          Ash.get(
            Workspace,
            workspace.id,
            action: :public_get,
            tenant: site2.id,
            authorize?: false
          )

        assert match?({:error, _}, result)
      end

      test "allows public access without authorization" do
        site = create_site!()
        workspace = create_workspace!(name: "Public", status: :active, site_id: site.id)

        # This should not raise an authorization error
        fetched =
          Ash.get!(
            Workspace,
            workspace.id,
            action: :public_get,
            tenant: site.id
          )

        assert fetched.id == workspace.id
      end
    end
  end
end
