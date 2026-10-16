# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_document/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaDocument.Test.WorkspaceVersionTest do
  @moduledoc """
  Tests for MishkaDocument.WorkspaceVersion resource.
  """
  use MishkaDocument.DataCase, async: false

  if Code.ensure_loaded?(MishkaDocument) do
    alias MishkaDocument.WorkspaceVersion

    describe "resource configuration" do
      test "uses correct table name" do
        assert AshPostgres.DataLayer.Info.table(WorkspaceVersion) ==
                 "mishka_document_workspace_versions"
      end

      test "uses UUID v7 for primary keys" do
        version = create_workspace_version!()
        assert is_binary(version.id)
        assert String.length(version.id) == 36
      end

      test "is always site-specific (not global)" do
        multitenancy_config = Ash.Resource.Info.multitenancy_strategy(WorkspaceVersion)
        assert multitenancy_config == :attribute
        assert Ash.Resource.Info.multitenancy_global?(WorkspaceVersion) == false
      end
    end

    describe "create action" do
      test "creates version with valid attributes" do
        site = create_site!()
        workspace = create_workspace!(site_id: site.id)

        version =
          create_workspace_version!(
            workspace_id: workspace.id,
            version_number: "1.0.0",
            version_name: "Initial Release",
            status: :draft,
            site_id: site.id
          )

        assert version.workspace_id == workspace.id
        assert version.version_number == "1.0.0"
        assert version.version_name == "Initial Release"
        assert version.status == :draft
        assert version.site_id == site.id
      end

      test "requires workspace_id, version_number, and status" do
        site = create_site!()

        assert_raise Ash.Error.Invalid, fn ->
          WorkspaceVersion
          |> Ash.Changeset.for_create(:create, %{}, tenant: site.id, authorize?: false)
          |> Ash.create!()
        end
      end

      test "auto-assigns site_id from tenant context" do
        site = create_site!()
        workspace = create_workspace!(site_id: site.id)

        version =
          WorkspaceVersion
          |> Ash.Changeset.for_create(
            :create,
            %{
              workspace_id: workspace.id,
              version_number: "1.0.0",
              status: :draft
            },
            tenant: site.id,
            authorize?: false
          )
          |> Ash.create!()

        assert version.site_id == site.id
      end

      test "defaults status to draft" do
        site = create_site!()
        workspace = create_workspace!(site_id: site.id)

        version =
          WorkspaceVersion
          |> Ash.Changeset.for_create(
            :create,
            %{workspace_id: workspace.id, version_number: "1.0.0"},
            tenant: site.id,
            authorize?: false
          )
          |> Ash.create!()

        assert version.status == :draft
      end

      test "defaults is_latest_for_version to false" do
        site = create_site!()
        workspace = create_workspace!(site_id: site.id)

        version = create_workspace_version!(workspace_id: workspace.id, site_id: site.id)

        assert version.is_latest_for_version == false
      end

      test "requires published_at for stable versions" do
        site = create_site!()
        workspace = create_workspace!(site_id: site.id)

        assert_raise Ash.Error.Invalid, fn ->
          WorkspaceVersion
          |> Ash.Changeset.for_create(
            :create,
            %{
              workspace_id: workspace.id,
              version_number: "1.0.0",
              status: :stable
            },
            tenant: site.id,
            authorize?: false
          )
          |> Ash.create!()
        end
      end

      test "allows stable status with published_at" do
        site = create_site!()
        workspace = create_workspace!(site_id: site.id)

        version =
          create_workspace_version!(
            workspace_id: workspace.id,
            status: :stable,
            published_at: DateTime.utc_now(),
            site_id: site.id
          )

        assert version.status == :stable
        assert version.published_at != nil
      end

      test "accepts optional source_version_id argument" do
        site = create_site!()
        workspace = create_workspace!(site_id: site.id)

        source_version = create_workspace_version!(workspace_id: workspace.id, site_id: site.id)

        new_version =
          WorkspaceVersion
          |> Ash.Changeset.for_create(
            :create,
            %{
              workspace_id: workspace.id,
              version_number: "1.0.1",
              status: :draft,
              source_version_id: source_version.id
            },
            tenant: site.id,
            authorize?: false
          )
          |> Ash.create!()

        assert new_version.source_version_id == source_version.id
      end

      test "accepts optional description" do
        site = create_site!()
        workspace = create_workspace!(site_id: site.id)

        version =
          create_workspace_version!(
            workspace_id: workspace.id,
            description: "This is a test version",
            site_id: site.id
          )

        assert version.description == "This is a test version"
      end
    end

    describe "master_create action" do
      test "creates version with explicit site_id" do
        site = create_site!()
        workspace = create_workspace!(site_id: site.id)

        version =
          WorkspaceVersion
          |> Ash.Changeset.for_create(
            :master_create,
            %{
              workspace_id: workspace.id,
              version_number: "1.0.0",
              status: :draft,
              site_id: site.id
            },
            authorize?: false
          )
          |> Ash.create!()

        assert version.workspace_id == workspace.id
        assert version.site_id == site.id
      end

      test "requires explicit site_id" do
        site = create_site!()
        workspace = create_workspace!(site_id: site.id)

        assert_raise Ash.Error.Invalid, fn ->
          WorkspaceVersion
          |> Ash.Changeset.for_create(
            :master_create,
            %{
              workspace_id: workspace.id,
              version_number: "1.0.0",
              status: :draft
            },
            authorize?: false
          )
          |> Ash.create!()
        end
      end
    end

    describe "update action" do
      test "updates version attributes" do
        site = create_site!()
        workspace = create_workspace!(site_id: site.id)
        version = create_workspace_version!(workspace_id: workspace.id, site_id: site.id)

        updated =
          version
          |> Ash.Changeset.for_update(
            :update,
            %{version_name: "Updated Name", description: "New description"},
            tenant: site.id,
            authorize?: false
          )
          |> Ash.update!()

        assert updated.version_name == "Updated Name"
        assert updated.description == "New description"
      end

      test "validates stable versions must have published_at" do
        site = create_site!()
        workspace = create_workspace!(site_id: site.id)
        version = create_workspace_version!(workspace_id: workspace.id, site_id: site.id)

        assert_raise Ash.Error.Invalid, fn ->
          version
          |> Ash.Changeset.for_update(
            :update,
            %{status: :stable},
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
        version = create_workspace_version!(workspace_id: workspace.id, site_id: site1.id)

        # site_id is not in the accepted fields for update
        updated =
          version
          |> Ash.Changeset.for_update(
            :update,
            %{version_name: "Updated"},
            tenant: site1.id,
            authorize?: false
          )
          |> Ash.update!()

        # site_id should remain unchanged
        assert updated.site_id == site1.id
        assert updated.site_id != site2.id
      end
    end

    describe "master_update action" do
      test "updates version for master users" do
        site = create_site!()
        workspace = create_workspace!(site_id: site.id)
        version = create_workspace_version!(workspace_id: workspace.id, site_id: site.id)

        updated =
          version
          |> Ash.Changeset.for_update(:master_update, %{version_name: "Master Updated"},
            authorize?: false
          )
          |> Ash.update!()

        assert updated.version_name == "Master Updated"
      end
    end

    describe "read actions with multitenancy" do
      test "tenant read only shows versions for that tenant" do
        site1 = create_site!()
        site2 = create_site!()

        workspace1 = create_workspace!(site_id: site1.id, skip_version: true)
        workspace2 = create_workspace!(site_id: site2.id, skip_version: true)

        version1 = create_workspace_version!(workspace_id: workspace1.id, site_id: site1.id)
        _version2 = create_workspace_version!(workspace_id: workspace2.id, site_id: site2.id)

        # Query as site1 tenant
        versions =
          WorkspaceVersion
          |> Ash.Query.set_tenant(site1.id)
          |> Ash.read!(authorize?: false)

        assert length(versions) == 1
        assert Enum.at(versions, 0).id == version1.id
      end

      test "master_read shows all versions system-wide" do
        site1 = create_site!()
        site2 = create_site!()

        workspace1 = create_workspace!(site_id: site1.id)
        workspace2 = create_workspace!(site_id: site2.id)

        _version1 = create_workspace_version!(workspace_id: workspace1.id, site_id: site1.id)
        _version2 = create_workspace_version!(workspace_id: workspace2.id, site_id: site2.id)

        result =
          WorkspaceVersion
          |> Ash.Query.for_read(:master_read, %{}, authorize?: false)
          |> Ash.read!()

        versions = result.results
        assert length(versions) >= 2
      end

      test "master_get retrieves version by ID bypassing tenant" do
        site = create_site!()
        workspace = create_workspace!(site_id: site.id)
        version = create_workspace_version!(workspace_id: workspace.id, site_id: site.id)

        fetched =
          Ash.get!(WorkspaceVersion, version.id, action: :master_get, authorize?: false)

        assert fetched.id == version.id
      end
    end

    describe "by_workspace action" do
      test "retrieves all versions for a specific workspace" do
        site = create_site!()
        workspace1 = create_workspace!(site_id: site.id, skip_version: true)
        workspace2 = create_workspace!(site_id: site.id, skip_version: true)

        version1 =
          create_workspace_version!(
            workspace_id: workspace1.id,
            version_number: "1.0.0",
            site_id: site.id
          )

        version2 =
          create_workspace_version!(
            workspace_id: workspace1.id,
            version_number: "1.0.1",
            site_id: site.id
          )

        _version3 =
          create_workspace_version!(workspace_id: workspace2.id, site_id: site.id)

        result =
          WorkspaceVersion
          |> Ash.Query.for_read(
            :by_workspace,
            %{workspace_id: workspace1.id},
            tenant: site.id,
            authorize?: false
          )
          |> Ash.read!()

        versions = result.results
        version_ids = Enum.map(versions, & &1.id) |> Enum.sort()

        assert length(versions) == 2
        assert Enum.sort([version1.id, version2.id]) == version_ids
      end

      test "supports pagination" do
        site = create_site!()
        workspace = create_workspace!(site_id: site.id)

        # Create 25 versions
        _versions =
          Enum.map(1..25, fn i ->
            create_workspace_version!(
              workspace_id: workspace.id,
              version_number: "0.0.#{i}",
              site_id: site.id
            )
          end)

        result =
          WorkspaceVersion
          |> Ash.Query.for_read(
            :by_workspace,
            %{workspace_id: workspace.id},
            tenant: site.id,
            authorize?: false
          )
          |> Ash.Query.page(limit: 20)
          |> Ash.read!()

        assert length(result.results) == 20
      end
    end

    describe "latest_versions action" do
      test "retrieves only versions marked as latest" do
        site = create_site!()
        workspace = create_workspace!(site_id: site.id)

        _version1 =
          create_workspace_version!(
            workspace_id: workspace.id,
            version_number: "1.0.0",
            is_latest_for_version: false,
            site_id: site.id
          )

        version2 =
          create_workspace_version!(
            workspace_id: workspace.id,
            version_number: "1.0.1",
            is_latest_for_version: true,
            site_id: site.id
          )

        result =
          WorkspaceVersion
          |> Ash.Query.for_read(:latest_versions, %{}, tenant: site.id, authorize?: false)
          |> Ash.read!()

        versions = result.results
        version_ids = Enum.map(versions, & &1.id)

        assert length(versions) == 1
        assert version2.id in version_ids
      end
    end

    describe "by_status action" do
      test "retrieves versions by status" do
        site = create_site!()
        workspace = create_workspace!(site_id: site.id, skip_version: true)

        draft_version =
          create_workspace_version!(
            workspace_id: workspace.id,
            status: :draft,
            site_id: site.id
          )

        _alpha_version =
          create_workspace_version!(
            workspace_id: workspace.id,
            status: :alpha,
            site_id: site.id
          )

        result =
          WorkspaceVersion
          |> Ash.Query.for_read(
            :by_status,
            %{status: :draft},
            tenant: site.id,
            authorize?: false
          )
          |> Ash.read!()

        versions = result.results
        version_ids = Enum.map(versions, & &1.id)

        assert length(versions) == 1
        assert draft_version.id in version_ids
      end
    end

    describe "publish action" do
      test "publishes a version by setting published_at and status to stable" do
        site = create_site!()
        workspace = create_workspace!(site_id: site.id)
        version = create_workspace_version!(workspace_id: workspace.id, site_id: site.id)

        published =
          version
          |> Ash.Changeset.for_update(:publish, %{}, tenant: site.id, authorize?: false)
          |> Ash.update!()

        assert published.published_at != nil
        assert published.status == :stable
      end

      test "prevents publishing already published version" do
        site = create_site!()
        workspace = create_workspace!(site_id: site.id)

        version =
          create_workspace_version!(
            workspace_id: workspace.id,
            status: :stable,
            published_at: DateTime.utc_now(),
            site_id: site.id
          )

        assert_raise Ash.Error.Invalid, fn ->
          version
          |> Ash.Changeset.for_update(:publish, %{}, tenant: site.id, authorize?: false)
          |> Ash.update!()
        end
      end
    end

    describe "mark_as_latest action" do
      test "marks version as latest and unmarks others" do
        site = create_site!()
        workspace = create_workspace!(site_id: site.id)

        version1 =
          create_workspace_version!(
            workspace_id: workspace.id,
            version_number: "1.0.0",
            is_latest_for_version: true,
            site_id: site.id
          )

        version2 =
          create_workspace_version!(
            workspace_id: workspace.id,
            version_number: "1.0.1",
            is_latest_for_version: false,
            site_id: site.id
          )

        # Mark version2 as latest
        updated_version2 =
          version2
          |> Ash.Changeset.for_update(:mark_as_latest, %{}, tenant: site.id, authorize?: false)
          |> Ash.update!()

        assert updated_version2.is_latest_for_version == true

        # Reload version1 to check it was unmarked
        reloaded_version1 =
          Ash.get!(WorkspaceVersion, version1.id,
            action: :master_get,
            authorize?: false
          )

        assert reloaded_version1.is_latest_for_version == false
      end
    end

    describe "destroy action" do
      test "permanently deletes version" do
        site = create_site!()
        workspace = create_workspace!(site_id: site.id)
        version = create_workspace_version!(workspace_id: workspace.id, site_id: site.id)
        version_id = version.id

        version
        |> Ash.Changeset.for_destroy(:destroy, %{}, tenant: site.id, authorize?: false)
        |> Ash.destroy!()

        # Should not exist in any query
        result =
          Ash.get(
            WorkspaceVersion,
            version_id,
            action: :master_get,
            authorize?: false
          )

        assert match?({:error, _}, result)
      end

      test "prevents deleting latest version" do
        site = create_site!()
        workspace = create_workspace!(site_id: site.id)

        version =
          create_workspace_version!(
            workspace_id: workspace.id,
            is_latest_for_version: true,
            site_id: site.id
          )

        assert_raise Ash.Error.Invalid, fn ->
          version
          |> Ash.Changeset.for_destroy(:destroy, %{}, tenant: site.id, authorize?: false)
          |> Ash.destroy!()
        end
      end
    end

    describe "master_destroy action" do
      test "permanently deletes version for master users" do
        site = create_site!()
        workspace = create_workspace!(site_id: site.id)
        version = create_workspace_version!(workspace_id: workspace.id, site_id: site.id)
        version_id = version.id

        version
        |> Ash.Changeset.for_destroy(:master_destroy, %{}, authorize?: false)
        |> Ash.destroy!()

        result =
          Ash.get(
            WorkspaceVersion,
            version_id,
            action: :master_get,
            authorize?: false
          )

        assert match?({:error, _}, result)
      end

      test "prevents deleting latest version for master users" do
        site = create_site!()
        workspace = create_workspace!(site_id: site.id)

        version =
          create_workspace_version!(
            workspace_id: workspace.id,
            is_latest_for_version: true,
            site_id: site.id
          )

        assert_raise Ash.Error.Invalid, fn ->
          version
          |> Ash.Changeset.for_destroy(:master_destroy, %{}, authorize?: false)
          |> Ash.destroy!()
        end
      end
    end

    describe "database constraints" do
      test "enforces version_number length constraints" do
        site = create_site!()
        workspace = create_workspace!(site_id: site.id)

        # Empty version_number should fail
        assert_raise Ash.Error.Invalid, fn ->
          create_workspace_version!(
            workspace_id: workspace.id,
            version_number: "",
            site_id: site.id
          )
        end

        # Version number too long (> 50) should fail
        long_version = String.duplicate("1", 51)

        assert_raise Ash.Error.Invalid, fn ->
          create_workspace_version!(
            workspace_id: workspace.id,
            version_number: long_version,
            site_id: site.id
          )
        end
      end

      test "enforces stable versions must have published_at constraint" do
        site = create_site!()
        workspace = create_workspace!(site_id: site.id)

        # This should fail validation before hitting DB constraint
        assert_raise Ash.Error.Invalid, fn ->
          create_workspace_version!(
            workspace_id: workspace.id,
            status: :stable,
            published_at: nil,
            site_id: site.id
          )
        end
      end
    end

    describe "relationships" do
      test "belongs_to site" do
        site = create_site!()
        workspace = create_workspace!(site_id: site.id)
        version = create_workspace_version!(workspace_id: workspace.id, site_id: site.id)

        version_with_site = Ash.load!(version, :site, tenant: version.site_id, authorize?: false)

        assert version_with_site.site.id == site.id
        assert version_with_site.site.host == site.host
      end

      test "belongs_to workspace" do
        site = create_site!()
        workspace = create_workspace!(site_id: site.id)
        version = create_workspace_version!(workspace_id: workspace.id, site_id: site.id)

        version_with_workspace =
          Ash.load!(version, :workspace, tenant: version.site_id, authorize?: false)

        assert version_with_workspace.workspace.id == workspace.id
        assert version_with_workspace.workspace.name == workspace.name
      end

      test "source_version relationship" do
        site = create_site!()
        workspace = create_workspace!(site_id: site.id)

        source_version =
          create_workspace_version!(workspace_id: workspace.id, site_id: site.id)

        new_version =
          WorkspaceVersion
          |> Ash.Changeset.for_create(
            :create,
            %{
              workspace_id: workspace.id,
              version_number: "1.0.1",
              status: :draft,
              source_version_id: source_version.id
            },
            tenant: site.id,
            authorize?: false
          )
          |> Ash.create!()

        version_with_source =
          Ash.load!(new_version, :source_version, tenant: new_version.site_id, authorize?: false)

        assert version_with_source.source_version.id == source_version.id
      end

      test "cloned_versions relationship" do
        site = create_site!()
        workspace = create_workspace!(site_id: site.id)

        source_version =
          create_workspace_version!(workspace_id: workspace.id, site_id: site.id)

        cloned1 =
          WorkspaceVersion
          |> Ash.Changeset.for_create(
            :create,
            %{
              workspace_id: workspace.id,
              version_number: "1.0.1",
              status: :draft,
              source_version_id: source_version.id
            },
            tenant: site.id,
            authorize?: false
          )
          |> Ash.create!()

        cloned2 =
          WorkspaceVersion
          |> Ash.Changeset.for_create(
            :create,
            %{
              workspace_id: workspace.id,
              version_number: "1.0.2",
              status: :draft,
              source_version_id: source_version.id
            },
            tenant: site.id,
            authorize?: false
          )
          |> Ash.create!()

        cloned_query =
          WorkspaceVersion
          |> Ash.Query.set_tenant(site.id)
          |> Ash.Query.page(limit: 10)

        source_with_cloned =
          Ash.load!(source_version, [cloned_versions: cloned_query], authorize?: false)

        cloned_ids =
          Enum.map(source_with_cloned.cloned_versions.results, & &1.id) |> Enum.sort()

        assert length(source_with_cloned.cloned_versions.results) == 2
        assert Enum.sort([cloned1.id, cloned2.id]) == cloned_ids
      end
    end

    describe "identities" do
      test "unique_version_per_workspace prevents duplicate version numbers within workspace" do
        site = create_site!()
        workspace = create_workspace!(site_id: site.id)

        _version1 =
          create_workspace_version!(
            workspace_id: workspace.id,
            version_number: "1.0.0",
            site_id: site.id
          )

        assert_raise Ash.Error.Invalid, fn ->
          create_workspace_version!(
            workspace_id: workspace.id,
            version_number: "1.0.0",
            site_id: site.id
          )
        end
      end

      test "allows same version number across different workspaces" do
        site = create_site!()
        workspace1 = create_workspace!(site_id: site.id)
        workspace2 = create_workspace!(site_id: site.id)

        version1 =
          create_workspace_version!(
            workspace_id: workspace1.id,
            version_number: "1.0.0",
            site_id: site.id
          )

        version2 =
          create_workspace_version!(
            workspace_id: workspace2.id,
            version_number: "1.0.0",
            site_id: site.id
          )

        assert version1.version_number == version2.version_number
        assert version1.workspace_id != version2.workspace_id
      end
    end

    describe "JSON API configuration" do
      test "has correct JSON API type" do
        json_api_type = AshJsonApi.Resource.Info.type(WorkspaceVersion)
        assert json_api_type == "workspace_version"
      end
    end

    describe "public_list action" do
      test "lists stable versions without authentication" do
        site = create_site!()
        workspace = create_workspace!(site_id: site.id, skip_version: true)

        # Create versions with different statuses
        stable1 =
          create_workspace_version!(
            workspace_id: workspace.id,
            status: :stable,
            published_at: DateTime.utc_now(),
            site_id: site.id
          )

        stable2 =
          create_workspace_version!(
            workspace_id: workspace.id,
            version_number: "1.0.1",
            status: :stable,
            published_at: DateTime.utc_now(),
            site_id: site.id
          )

        _draft =
          create_workspace_version!(
            workspace_id: workspace.id,
            version_number: "1.0.2",
            status: :draft,
            site_id: site.id
          )

        # Query public_list action without actor (no authentication)
        versions =
          WorkspaceVersion
          |> Ash.Query.for_read(:public_list, %{}, tenant: site.id, authorize?: false)
          |> Ash.read!()

        version_ids = Enum.map(versions, & &1.id) |> Enum.sort()

        # Should only return stable versions
        assert length(versions) == 2
        assert Enum.sort([stable1.id, stable2.id]) == version_ids
      end

      test "respects tenant context" do
        site1 = create_site!()
        site2 = create_site!()

        workspace1 = create_workspace!(site_id: site1.id, skip_version: true)
        workspace2 = create_workspace!(site_id: site2.id, skip_version: true)

        # Create stable versions in different sites
        site1_version =
          create_workspace_version!(
            workspace_id: workspace1.id,
            status: :stable,
            published_at: DateTime.utc_now(),
            site_id: site1.id
          )

        _site2_version =
          create_workspace_version!(
            workspace_id: workspace2.id,
            status: :stable,
            published_at: DateTime.utc_now(),
            site_id: site2.id
          )

        # Query as site1 tenant
        versions =
          WorkspaceVersion
          |> Ash.Query.for_read(:public_list, %{}, tenant: site1.id, authorize?: false)
          |> Ash.read!()

        # Should only see site1 versions
        assert length(versions) == 1
        assert Enum.at(versions, 0).id == site1_version.id
      end
    end

    describe "public_get action" do
      test "gets a single stable version without authentication" do
        site = create_site!()
        workspace = create_workspace!(site_id: site.id)

        version =
          create_workspace_version!(
            workspace_id: workspace.id,
            status: :stable,
            published_at: DateTime.utc_now(),
            site_id: site.id
          )

        # Query without actor (no authentication)
        fetched =
          Ash.get!(
            WorkspaceVersion,
            version.id,
            action: :public_get,
            tenant: site.id,
            authorize?: false
          )

        assert fetched.id == version.id
      end

      test "returns error when version is not stable" do
        site = create_site!()
        workspace = create_workspace!(site_id: site.id)

        draft_version =
          create_workspace_version!(
            workspace_id: workspace.id,
            status: :draft,
            site_id: site.id
          )

        # Should not find draft version
        result =
          Ash.get(
            WorkspaceVersion,
            draft_version.id,
            action: :public_get,
            tenant: site.id,
            authorize?: false
          )

        assert match?({:error, _}, result)
      end
    end

    describe "complex scenarios" do
      test "version cloning and lineage tracking" do
        site = create_site!()
        workspace = create_workspace!(site_id: site.id)

        # Create original version
        v1 =
          create_workspace_version!(
            workspace_id: workspace.id,
            version_number: "1.0.0",
            site_id: site.id
          )

        # Clone to create v2
        v2 =
          WorkspaceVersion
          |> Ash.Changeset.for_create(
            :create,
            %{
              workspace_id: workspace.id,
              version_number: "1.0.1",
              status: :draft,
              source_version_id: v1.id
            },
            tenant: site.id,
            authorize?: false
          )
          |> Ash.create!()

        # Clone v2 to create v3
        v3 =
          WorkspaceVersion
          |> Ash.Changeset.for_create(
            :create,
            %{
              workspace_id: workspace.id,
              version_number: "1.0.2",
              status: :draft,
              source_version_id: v2.id
            },
            tenant: site.id,
            authorize?: false
          )
          |> Ash.create!()

        # Load cloned versions for v1
        cloned_query =
          WorkspaceVersion
          |> Ash.Query.set_tenant(site.id)
          |> Ash.Query.page(limit: 10)

        v1_with_cloned = Ash.load!(v1, [cloned_versions: cloned_query], authorize?: false)

        # v1 should have v2 as a cloned version
        assert length(v1_with_cloned.cloned_versions.results) == 1
        assert Enum.at(v1_with_cloned.cloned_versions.results, 0).id == v2.id

        # Load source version for v3
        v3_with_source = Ash.load!(v3, :source_version, tenant: v3.site_id, authorize?: false)
        assert v3_with_source.source_version.id == v2.id
      end

      test "workspace with multiple versions" do
        site = create_site!()
        workspace = create_workspace!(site_id: site.id, skip_version: true)

        # Create multiple versions
        _v1 =
          create_workspace_version!(
            workspace_id: workspace.id,
            version_number: "0.0.1",
            status: :draft,
            site_id: site.id
          )

        _v2 =
          create_workspace_version!(
            workspace_id: workspace.id,
            version_number: "0.0.2",
            status: :alpha,
            site_id: site.id
          )

        v3 =
          create_workspace_version!(
            workspace_id: workspace.id,
            version_number: "1.0.0",
            status: :stable,
            published_at: DateTime.utc_now(),
            is_latest_for_version: true,
            site_id: site.id
          )

        # Query versions by workspace
        result =
          WorkspaceVersion
          |> Ash.Query.for_read(
            :by_workspace,
            %{workspace_id: workspace.id},
            tenant: site.id,
            authorize?: false
          )
          |> Ash.read!()

        versions = result.results
        assert length(versions) == 3

        # Query only latest versions
        latest_result =
          WorkspaceVersion
          |> Ash.Query.for_read(:latest_versions, %{}, tenant: site.id, authorize?: false)
          |> Ash.read!()

        latest_versions = latest_result.results
        assert length(latest_versions) == 1
        assert Enum.at(latest_versions, 0).id == v3.id
      end
    end
  end
end
