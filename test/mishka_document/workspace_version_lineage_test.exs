# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_document/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaDocument.Test.WorkspaceVersionLineageTest do
  @moduledoc """
  Tests for MishkaDocument.WorkspaceVersionLineage resource - tracks version cloning history.
  """
  use MishkaDocument.DataCase, async: false

  if Code.ensure_loaded?(MishkaDocument) do
    alias MishkaDocument.WorkspaceVersionLineage

    describe "resource configuration" do
      test "uses correct table name" do
        assert AshPostgres.DataLayer.Info.table(WorkspaceVersionLineage) ==
                 "mishka_document_workspace_version_lineage"
      end

      test "uses UUID primary key" do
        site = create_site!()
        lineage = create_workspace_version_lineage!(site_id: site.id)

        assert {:ok, _uuid} = Ecto.UUID.cast(lineage.id)
        assert String.length(lineage.id) == 36
      end

      test "is a multi-tenant resource with site_id" do
        assert Ash.Resource.Info.multitenancy_strategy(WorkspaceVersionLineage) == :attribute
        assert Ash.Resource.Info.multitenancy_attribute(WorkspaceVersionLineage) == :site_id
        refute Ash.Resource.Info.multitenancy_global?(WorkspaceVersionLineage)
      end
    end

    describe "create action" do
      test "creates lineage record with valid attributes" do
        site = create_site!()
        workspace = create_workspace!(site_id: site.id)
        source_version = create_workspace_version!(workspace_id: workspace.id, site_id: site.id)
        new_version = create_workspace_version!(workspace_id: workspace.id, site_id: site.id)

        lineage =
          WorkspaceVersionLineage
          |> Ash.Changeset.for_create(
            :create,
            %{
              new_version_id: new_version.id,
              source_version_id: source_version.id,
              cloned_at:
                DateTime.add(DateTime.utc_now(), -3600, :second) |> DateTime.truncate(:second)
            },
            tenant: site.id,
            authorize?: false
          )
          |> Ash.create!()

        assert lineage.new_version_id == new_version.id
        assert lineage.source_version_id == source_version.id
        assert lineage.site_id == site.id
        assert %DateTime{} = lineage.cloned_at
      end

      test "auto-assigns site_id from tenant context" do
        site = create_site!()
        workspace = create_workspace!(site_id: site.id)
        source_version = create_workspace_version!(workspace_id: workspace.id, site_id: site.id)
        new_version = create_workspace_version!(workspace_id: workspace.id, site_id: site.id)

        lineage =
          WorkspaceVersionLineage
          |> Ash.Changeset.for_create(
            :create,
            %{
              new_version_id: new_version.id,
              source_version_id: source_version.id,
              cloned_at:
                DateTime.add(DateTime.utc_now(), -3600, :second) |> DateTime.truncate(:second)
            },
            tenant: site.id,
            authorize?: false
          )
          |> Ash.create!()

        assert lineage.site_id == site.id
      end

      test "auto-sets cloned_at if not provided" do
        site = create_site!()
        workspace = create_workspace!(site_id: site.id)
        source_version = create_workspace_version!(workspace_id: workspace.id, site_id: site.id)
        new_version = create_workspace_version!(workspace_id: workspace.id, site_id: site.id)

        # Persisted, not just built. The check constraint compares against
        # `timezone('UTC', clock_timestamp())` — the real wall clock — so a just-computed
        # `utc_now()` no longer collides with a sandbox transaction's frozen `NOW()`.
        lineage =
          WorkspaceVersionLineage
          |> Ash.Changeset.for_create(
            :create,
            %{
              new_version_id: new_version.id,
              source_version_id: source_version.id
            },
            tenant: site.id,
            authorize?: false
          )
          |> Ash.create!()

        assert %DateTime{} = lineage.cloned_at

        diff = DateTime.diff(DateTime.utc_now(), lineage.cloned_at, :second)
        assert diff >= 0 and diff < 5
      end

      test "allows explicit cloned_at timestamp" do
        site = create_site!()
        workspace = create_workspace!(site_id: site.id)
        source_version = create_workspace_version!(workspace_id: workspace.id, site_id: site.id)
        new_version = create_workspace_version!(workspace_id: workspace.id, site_id: site.id)

        # Truncate to second precision since :utc_datetime doesn't store microseconds
        past_time = DateTime.add(DateTime.utc_now(), -3600, :second) |> DateTime.truncate(:second)

        lineage =
          WorkspaceVersionLineage
          |> Ash.Changeset.for_create(
            :create,
            %{
              new_version_id: new_version.id,
              source_version_id: source_version.id,
              cloned_at: past_time
            },
            tenant: site.id,
            authorize?: false
          )
          |> Ash.create!()

        # Should match exactly since both are truncated to seconds
        assert DateTime.compare(lineage.cloned_at, past_time) == :eq
      end

      test "requires new_version_id" do
        site = create_site!()
        workspace = create_workspace!(site_id: site.id)
        source_version = create_workspace_version!(workspace_id: workspace.id, site_id: site.id)

        assert_raise Ash.Error.Invalid, fn ->
          WorkspaceVersionLineage
          |> Ash.Changeset.for_create(
            :create,
            %{
              source_version_id: source_version.id,
              cloned_at:
                DateTime.add(DateTime.utc_now(), -3600, :second) |> DateTime.truncate(:second)
            },
            tenant: site.id,
            authorize?: false
          )
          |> Ash.create!()
        end
      end

      test "requires source_version_id" do
        site = create_site!()
        workspace = create_workspace!(site_id: site.id)
        new_version = create_workspace_version!(workspace_id: workspace.id, site_id: site.id)

        assert_raise Ash.Error.Invalid, fn ->
          WorkspaceVersionLineage
          |> Ash.Changeset.for_create(
            :create,
            %{
              new_version_id: new_version.id,
              cloned_at:
                DateTime.add(DateTime.utc_now(), -3600, :second) |> DateTime.truncate(:second)
            },
            tenant: site.id,
            authorize?: false
          )
          |> Ash.create!()
        end
      end

      test "prevents version from being cloned from itself" do
        site = create_site!()
        workspace = create_workspace!(site_id: site.id)
        version = create_workspace_version!(workspace_id: workspace.id, site_id: site.id)

        assert_raise Ash.Error.Invalid, ~r/cannot be cloned from itself/i, fn ->
          WorkspaceVersionLineage
          |> Ash.Changeset.for_create(
            :create,
            %{
              new_version_id: version.id,
              source_version_id: version.id,
              cloned_at:
                DateTime.add(DateTime.utc_now(), -3600, :second) |> DateTime.truncate(:second)
            },
            tenant: site.id,
            authorize?: false
          )
          |> Ash.create!()
        end
      end

      test "requires tenant context" do
        site = create_site!()
        workspace = create_workspace!(site_id: site.id)
        source_version = create_workspace_version!(workspace_id: workspace.id, site_id: site.id)
        new_version = create_workspace_version!(workspace_id: workspace.id, site_id: site.id)

        assert_raise Ash.Error.Invalid, fn ->
          WorkspaceVersionLineage
          |> Ash.Changeset.for_create(
            :create,
            %{
              new_version_id: new_version.id,
              source_version_id: source_version.id,
              cloned_at:
                DateTime.add(DateTime.utc_now(), -3600, :second) |> DateTime.truncate(:second)
            },
            authorize?: false
          )
          |> Ash.create!()
        end
      end
    end

    describe "master_create action" do
      test "creates lineage record with explicit site_id" do
        site = create_site!()
        workspace = create_workspace!(site_id: site.id)
        source_version = create_workspace_version!(workspace_id: workspace.id, site_id: site.id)
        new_version = create_workspace_version!(workspace_id: workspace.id, site_id: site.id)

        lineage =
          WorkspaceVersionLineage
          |> Ash.Changeset.for_create(
            :master_create,
            %{
              new_version_id: new_version.id,
              source_version_id: source_version.id,
              site_id: site.id,
              cloned_at:
                DateTime.add(DateTime.utc_now(), -3600, :second) |> DateTime.truncate(:second)
            },
            authorize?: false
          )
          |> Ash.create!()

        assert lineage.new_version_id == new_version.id
        assert lineage.source_version_id == source_version.id
        assert lineage.site_id == site.id
      end

      test "auto-sets cloned_at if not provided" do
        site = create_site!()
        workspace = create_workspace!(site_id: site.id)
        source_version = create_workspace_version!(workspace_id: workspace.id, site_id: site.id)
        new_version = create_workspace_version!(workspace_id: workspace.id, site_id: site.id)

        lineage =
          WorkspaceVersionLineage
          |> Ash.Changeset.for_create(
            :master_create,
            %{
              new_version_id: new_version.id,
              source_version_id: source_version.id,
              site_id: site.id,
              cloned_at:
                DateTime.add(DateTime.utc_now(), -3600, :second) |> DateTime.truncate(:second)
            },
            authorize?: false
          )
          |> Ash.create!()

        assert %DateTime{} = lineage.cloned_at
        assert is_struct(lineage.cloned_at, DateTime)
      end

      test "requires site_id to be explicitly provided" do
        site = create_site!()
        workspace = create_workspace!(site_id: site.id)
        source_version = create_workspace_version!(workspace_id: workspace.id, site_id: site.id)
        new_version = create_workspace_version!(workspace_id: workspace.id, site_id: site.id)

        assert_raise Ash.Error.Invalid, fn ->
          WorkspaceVersionLineage
          |> Ash.Changeset.for_create(
            :master_create,
            %{
              new_version_id: new_version.id,
              source_version_id: source_version.id,
              cloned_at:
                DateTime.add(DateTime.utc_now(), -3600, :second) |> DateTime.truncate(:second)
            },
            authorize?: false
          )
          |> Ash.create!()
        end
      end

      test "prevents version from being cloned from itself" do
        site = create_site!()
        workspace = create_workspace!(site_id: site.id)
        version = create_workspace_version!(workspace_id: workspace.id, site_id: site.id)

        assert_raise Ash.Error.Invalid, ~r/cannot be cloned from itself/i, fn ->
          WorkspaceVersionLineage
          |> Ash.Changeset.for_create(
            :master_create,
            %{
              new_version_id: version.id,
              source_version_id: version.id,
              site_id: site.id,
              cloned_at:
                DateTime.add(DateTime.utc_now(), -3600, :second) |> DateTime.truncate(:second)
            },
            authorize?: false
          )
          |> Ash.create!()
        end
      end
    end

    describe "update action" do
      test "updates cloned_at timestamp" do
        site = create_site!()
        lineage = create_workspace_version_lineage!(site_id: site.id)

        # Truncate to second precision since :utc_datetime doesn't store microseconds
        new_time = DateTime.add(DateTime.utc_now(), -7200, :second) |> DateTime.truncate(:second)

        updated =
          lineage
          |> Ash.Changeset.for_update(
            :update,
            %{cloned_at: new_time},
            tenant: site.id,
            authorize?: false
          )
          |> Ash.update!()

        # Should match exactly since both are truncated to seconds
        assert DateTime.compare(updated.cloned_at, new_time) == :eq
      end

      test "can update with tenant context" do
        site = create_site!()
        lineage = create_workspace_version_lineage!(site_id: site.id)

        new_time = DateTime.add(DateTime.utc_now(), -3600, :second)

        # Should succeed with tenant
        updated =
          lineage
          |> Ash.Changeset.for_update(
            :update,
            %{cloned_at: new_time},
            tenant: site.id,
            authorize?: false
          )
          |> Ash.update!()

        assert updated.id == lineage.id
      end
    end

    describe "master_update action" do
      test "updates lineage record bypassing tenant context" do
        site = create_site!()
        lineage = create_workspace_version_lineage!(site_id: site.id)

        # Truncate to second precision since :utc_datetime doesn't store microseconds
        new_time = DateTime.add(DateTime.utc_now(), -7200, :second) |> DateTime.truncate(:second)

        # Fetch the record first using master_get (bypasses tenant)
        record =
          Ash.get!(WorkspaceVersionLineage, lineage.id, action: :master_get, authorize?: false)

        updated =
          record
          |> Ash.Changeset.for_update(:master_update, %{cloned_at: new_time}, authorize?: false)
          |> Ash.update!()

        # Should match exactly since both are truncated to seconds
        assert DateTime.compare(updated.cloned_at, new_time) == :eq
        assert updated.site_id == site.id
      end

      test "returns error if record not found" do
        fake_id = Ash.UUID.generate()

        # Standard update action requires record to exist first, so test get fails
        assert {:error, %Ash.Error.Invalid{errors: [%Ash.Error.Query.NotFound{}]}} =
                 Ash.get(WorkspaceVersionLineage, fake_id, action: :master_get, authorize?: false)
      end
    end

    describe "read actions" do
      test "reads lineage records with tenant context" do
        site = create_site!()
        lineage = create_workspace_version_lineage!(site_id: site.id)

        results = Ash.read!(WorkspaceVersionLineage, tenant: site.id, authorize?: false)

        assert Enum.any?(results, fn l -> l.id == lineage.id end)
      end

      test "supports pagination" do
        site = create_site!()
        workspace = create_workspace!(site_id: site.id)

        # Create 5 lineage records
        for _ <- 1..5 do
          source = create_workspace_version!(workspace_id: workspace.id, site_id: site.id)
          new_v = create_workspace_version!(workspace_id: workspace.id, site_id: site.id)

          create_workspace_version_lineage!(
            new_version_id: new_v.id,
            source_version_id: source.id,
            site_id: site.id
          )
        end

        result =
          WorkspaceVersionLineage
          |> Ash.Query.page(limit: 3, count: true)
          |> Ash.read!(tenant: site.id, authorize?: false)

        assert length(result.results) <= 3
        assert result.count >= 5
      end
    end

    describe "master_read action" do
      test "reads all lineage records system-wide" do
        site1 = create_site!()
        site2 = create_site!()

        lineage1 = create_workspace_version_lineage!(site_id: site1.id)
        lineage2 = create_workspace_version_lineage!(site_id: site2.id)

        page = Ash.read!(WorkspaceVersionLineage, action: :master_read, authorize?: false)
        results = page.results

        assert Enum.any?(results, fn l -> l.id == lineage1.id end)
        assert Enum.any?(results, fn l -> l.id == lineage2.id end)
      end

      test "supports pagination" do
        # Create lineage records across multiple sites
        for _ <- 1..5 do
          site = create_site!()
          create_workspace_version_lineage!(site_id: site.id)
        end

        result =
          WorkspaceVersionLineage
          |> Ash.Query.for_read(:master_read, %{}, authorize?: false)
          |> Ash.Query.page(limit: 3, count: true)
          |> Ash.read!(authorize?: false)

        assert length(result.results) <= 3
        assert result.count >= 5
      end
    end

    describe "by_new_version action" do
      test "finds lineage record by new_version_id" do
        site = create_site!()
        workspace = create_workspace!(site_id: site.id)
        source = create_workspace_version!(workspace_id: workspace.id, site_id: site.id)
        new_v = create_workspace_version!(workspace_id: workspace.id, site_id: site.id)

        lineage =
          create_workspace_version_lineage!(
            new_version_id: new_v.id,
            source_version_id: source.id,
            site_id: site.id
          )

        results =
          WorkspaceVersionLineage
          |> Ash.Query.for_read(:by_new_version, %{new_version_id: new_v.id}, authorize?: false)
          |> Ash.read!(tenant: site.id, authorize?: false)

        assert length(results) == 1
        assert hd(results).id == lineage.id
      end

      test "returns empty list if no lineage exists for new_version" do
        site = create_site!()
        workspace = create_workspace!(site_id: site.id)
        version = create_workspace_version!(workspace_id: workspace.id, site_id: site.id)

        results =
          WorkspaceVersionLineage
          |> Ash.Query.for_read(:by_new_version, %{new_version_id: version.id}, authorize?: false)
          |> Ash.read!(tenant: site.id, authorize?: false)

        assert results == []
      end
    end

    describe "by_source_version action" do
      test "finds all versions cloned from a source" do
        site = create_site!()
        workspace = create_workspace!(site_id: site.id)
        source = create_workspace_version!(workspace_id: workspace.id, site_id: site.id)

        # Clone source version multiple times
        lineages =
          for _ <- 1..3 do
            new_v = create_workspace_version!(workspace_id: workspace.id, site_id: site.id)

            create_workspace_version_lineage!(
              new_version_id: new_v.id,
              source_version_id: source.id,
              site_id: site.id
            )
          end

        page =
          WorkspaceVersionLineage
          |> Ash.Query.for_read(
            :by_source_version,
            %{source_version_id: source.id},
            authorize?: false
          )
          |> Ash.read!(tenant: site.id, authorize?: false)

        results = page.results
        assert length(results) == 3

        lineage_ids = Enum.map(lineages, & &1.id) |> MapSet.new()
        result_ids = Enum.map(results, & &1.id) |> MapSet.new()
        assert MapSet.equal?(lineage_ids, result_ids)
      end

      test "supports pagination" do
        site = create_site!()
        workspace = create_workspace!(site_id: site.id)
        source = create_workspace_version!(workspace_id: workspace.id, site_id: site.id)

        # Clone source version 5 times
        for _ <- 1..5 do
          new_v = create_workspace_version!(workspace_id: workspace.id, site_id: site.id)

          create_workspace_version_lineage!(
            new_version_id: new_v.id,
            source_version_id: source.id,
            site_id: site.id
          )
        end

        result =
          WorkspaceVersionLineage
          |> Ash.Query.for_read(
            :by_source_version,
            %{source_version_id: source.id},
            authorize?: false
          )
          |> Ash.Query.page(limit: 3, count: true)
          |> Ash.read!(tenant: site.id, authorize?: false)

        assert length(result.results) == 3
        assert result.count == 5
      end
    end

    describe "by_date_range action" do
      test "finds lineage records within date range" do
        site = create_site!()
        workspace = create_workspace!(site_id: site.id)

        now = DateTime.utc_now()
        two_hours_ago = DateTime.add(now, -7200, :second)
        one_hour_ago = DateTime.add(now, -3600, :second)
        thirty_mins_ago = DateTime.add(now, -1800, :second)

        source = create_workspace_version!(workspace_id: workspace.id, site_id: site.id)

        # Create lineage at different times
        old_lineage =
          WorkspaceVersionLineage
          |> Ash.Changeset.for_create(
            :create,
            %{
              new_version_id:
                create_workspace_version!(workspace_id: workspace.id, site_id: site.id).id,
              source_version_id: source.id,
              cloned_at: two_hours_ago
            },
            tenant: site.id,
            authorize?: false
          )
          |> Ash.create!()

        recent_lineage =
          WorkspaceVersionLineage
          |> Ash.Changeset.for_create(
            :create,
            %{
              new_version_id:
                create_workspace_version!(workspace_id: workspace.id, site_id: site.id).id,
              source_version_id: source.id,
              cloned_at: thirty_mins_ago
            },
            tenant: site.id,
            authorize?: false
          )
          |> Ash.create!()

        # Query for lineage within last hour
        page =
          WorkspaceVersionLineage
          |> Ash.Query.for_read(
            :by_date_range,
            %{start_date: one_hour_ago, end_date: now},
            authorize?: false
          )
          |> Ash.read!(tenant: site.id, authorize?: false)

        results = page.results
        result_ids = Enum.map(results, & &1.id)

        assert recent_lineage.id in result_ids
        refute old_lineage.id in result_ids
      end

      test "supports pagination" do
        site = create_site!()
        workspace = create_workspace!(site_id: site.id)
        source = create_workspace_version!(workspace_id: workspace.id, site_id: site.id)

        now = DateTime.utc_now()
        one_hour_ago = DateTime.add(now, -3600, :second)

        # Create 5 lineage records within the range
        for i <- 1..5 do
          time = DateTime.add(one_hour_ago, i * 60, :second)
          new_v = create_workspace_version!(workspace_id: workspace.id, site_id: site.id)

          WorkspaceVersionLineage
          |> Ash.Changeset.for_create(
            :create,
            %{
              new_version_id: new_v.id,
              source_version_id: source.id,
              cloned_at: time
            },
            tenant: site.id,
            authorize?: false
          )
          |> Ash.create!()
        end

        result =
          WorkspaceVersionLineage
          |> Ash.Query.for_read(
            :by_date_range,
            %{start_date: one_hour_ago, end_date: now},
            authorize?: false
          )
          |> Ash.Query.page(limit: 3, count: true)
          |> Ash.read!(tenant: site.id, authorize?: false)

        assert length(result.results) == 3
        assert result.count == 5
      end
    end

    describe "recent_clones action" do
      test "returns clones sorted by date descending" do
        site = create_site!()
        workspace = create_workspace!(site_id: site.id)
        source = create_workspace_version!(workspace_id: workspace.id, site_id: site.id)

        now = DateTime.utc_now()

        # Create lineages with different timestamps
        lineage_times =
          for i <- 1..3 do
            time = DateTime.add(now, -i * 3600, :second)
            new_v = create_workspace_version!(workspace_id: workspace.id, site_id: site.id)

            lineage =
              WorkspaceVersionLineage
              |> Ash.Changeset.for_create(
                :create,
                %{
                  new_version_id: new_v.id,
                  source_version_id: source.id,
                  cloned_at: time
                },
                tenant: site.id,
                authorize?: false
              )
              |> Ash.create!()

            {lineage.id, time}
          end

        page =
          WorkspaceVersionLineage
          |> Ash.Query.for_read(:recent_clones, %{}, authorize?: false)
          |> Ash.read!(tenant: site.id, authorize?: false)

        results = page.results

        # Get our lineages from results
        our_lineages =
          results
          |> Enum.filter(fn l -> Enum.any?(lineage_times, fn {id, _} -> id == l.id end) end)
          |> Enum.sort_by(& &1.cloned_at, {:desc, DateTime})

        # Verify they're in descending order
        assert length(our_lineages) == 3

        for i <- 0..(length(our_lineages) - 2) do
          assert DateTime.compare(
                   Enum.at(our_lineages, i).cloned_at,
                   Enum.at(our_lineages, i + 1).cloned_at
                 ) in [:gt, :eq]
        end
      end

      test "supports pagination" do
        site = create_site!()
        workspace = create_workspace!(site_id: site.id)
        source = create_workspace_version!(workspace_id: workspace.id, site_id: site.id)

        # Create 5 lineages
        for _ <- 1..5 do
          new_v = create_workspace_version!(workspace_id: workspace.id, site_id: site.id)

          create_workspace_version_lineage!(
            new_version_id: new_v.id,
            source_version_id: source.id,
            site_id: site.id
          )
        end

        result =
          WorkspaceVersionLineage
          |> Ash.Query.for_read(:recent_clones, %{}, authorize?: false)
          |> Ash.Query.page(limit: 3, count: true)
          |> Ash.read!(tenant: site.id, authorize?: false)

        assert length(result.results) <= 3
        assert result.count >= 5
      end
    end

    describe "destroy action" do
      test "permanently removes lineage record" do
        site = create_site!()
        lineage = create_workspace_version_lineage!(site_id: site.id)

        lineage
        |> Ash.Changeset.for_destroy(:destroy, %{}, tenant: site.id, authorize?: false)
        |> Ash.destroy!()

        # Verify it's removed
        results = Ash.read!(WorkspaceVersionLineage, tenant: site.id, authorize?: false)

        refute Enum.any?(results, fn l -> l.id == lineage.id end)
      end

      test "can destroy with tenant context" do
        site = create_site!()
        lineage = create_workspace_version_lineage!(site_id: site.id)

        # Should succeed with tenant
        lineage
        |> Ash.Changeset.for_destroy(:destroy, %{}, tenant: site.id, authorize?: false)
        |> Ash.destroy!()

        # Verify it's removed
        results = Ash.read!(WorkspaceVersionLineage, tenant: site.id, authorize?: false)
        refute Enum.any?(results, fn l -> l.id == lineage.id end)
      end
    end

    describe "master_destroy action" do
      test "permanently removes lineage record bypassing tenant" do
        site = create_site!()
        lineage = create_workspace_version_lineage!(site_id: site.id)

        # Fetch the record first using master_get (bypasses tenant)
        record =
          Ash.get!(WorkspaceVersionLineage, lineage.id, action: :master_get, authorize?: false)

        record
        |> Ash.Changeset.for_destroy(:master_destroy, %{}, authorize?: false)
        |> Ash.destroy!()

        # Verify it's removed
        page = Ash.read!(WorkspaceVersionLineage, action: :master_read, authorize?: false)
        results = page.results

        refute Enum.any?(results, fn l -> l.id == lineage.id end)
      end

      test "returns error if record not found" do
        fake_id = Ash.UUID.generate()

        # Standard destroy action requires record to exist first, so test get fails
        assert {:error, %Ash.Error.Invalid{errors: [%Ash.Error.Query.NotFound{}]}} =
                 Ash.get(WorkspaceVersionLineage, fake_id, action: :master_get, authorize?: false)
      end
    end

    describe "identities" do
      test "unique_new_version prevents duplicate lineage for same new_version" do
        site = create_site!()
        workspace = create_workspace!(site_id: site.id)
        source1 = create_workspace_version!(workspace_id: workspace.id, site_id: site.id)
        source2 = create_workspace_version!(workspace_id: workspace.id, site_id: site.id)
        new_v = create_workspace_version!(workspace_id: workspace.id, site_id: site.id)

        # First lineage
        _lineage1 =
          create_workspace_version_lineage!(
            new_version_id: new_v.id,
            source_version_id: source1.id,
            site_id: site.id
          )

        # Second lineage with same new_version but different source should fail
        assert_raise Ash.Error.Invalid, ~r/already has a lineage record/i, fn ->
          WorkspaceVersionLineage
          |> Ash.Changeset.for_create(
            :create,
            %{
              new_version_id: new_v.id,
              source_version_id: source2.id,
              cloned_at:
                DateTime.add(DateTime.utc_now(), -3600, :second) |> DateTime.truncate(:second)
            },
            tenant: site.id,
            authorize?: false
          )
          |> Ash.create!()
        end
      end

      test "identity is scoped to site (all_tenants? true)" do
        site1 = create_site!()
        site2 = create_site!()

        workspace1 = create_workspace!(site_id: site1.id)
        workspace2 = create_workspace!(site_id: site2.id)

        source1 = create_workspace_version!(workspace_id: workspace1.id, site_id: site1.id)
        source2 = create_workspace_version!(workspace_id: workspace2.id, site_id: site2.id)

        new_v1 = create_workspace_version!(workspace_id: workspace1.id, site_id: site1.id)
        new_v2 = create_workspace_version!(workspace_id: workspace2.id, site_id: site2.id)

        # Create lineages in different sites
        lineage1 =
          create_workspace_version_lineage!(
            new_version_id: new_v1.id,
            source_version_id: source1.id,
            site_id: site1.id
          )

        lineage2 =
          create_workspace_version_lineage!(
            new_version_id: new_v2.id,
            source_version_id: source2.id,
            site_id: site2.id
          )

        # Both should succeed since they're in different sites
        assert lineage1.site_id == site1.id
        assert lineage2.site_id == site2.id
        assert lineage1.site_id != lineage2.site_id
      end
    end

    describe "relationships" do
      test "loads new_version relationship" do
        site = create_site!()
        lineage = create_workspace_version_lineage!(site_id: site.id)

        loaded = Ash.load!(lineage, [:new_version], tenant: site.id, authorize?: false)

        assert loaded.new_version.id == lineage.new_version_id
      end

      test "loads source_version relationship" do
        site = create_site!()
        lineage = create_workspace_version_lineage!(site_id: site.id)

        loaded = Ash.load!(lineage, [:source_version], tenant: site.id, authorize?: false)

        assert loaded.source_version.id == lineage.source_version_id
      end

      test "loads site relationship" do
        site = create_site!()
        lineage = create_workspace_version_lineage!(site_id: site.id)

        loaded = Ash.load!(lineage, [:site], authorize?: false)

        assert loaded.site.id == site.id
      end

      test "loads all relationships together" do
        site = create_site!()
        lineage = create_workspace_version_lineage!(site_id: site.id)

        loaded =
          Ash.load!(lineage, [:new_version, :source_version, :site],
            tenant: site.id,
            authorize?: false
          )

        assert loaded.new_version.id == lineage.new_version_id
        assert loaded.source_version.id == lineage.source_version_id
        assert loaded.site.id == site.id
      end
    end

    describe "timestamps" do
      test "sets inserted_at on creation" do
        site = create_site!()
        lineage = create_workspace_version_lineage!(site_id: site.id)

        assert %DateTime{} = lineage.inserted_at
        assert is_struct(lineage.inserted_at, DateTime)
      end

      test "sets updated_at on creation" do
        site = create_site!()
        lineage = create_workspace_version_lineage!(site_id: site.id)

        assert %DateTime{} = lineage.updated_at
        assert is_struct(lineage.updated_at, DateTime)
      end

      test "updates updated_at on update" do
        site = create_site!()

        lineage =
          create_workspace_version_lineage!(
            site_id: site.id,
            cloned_at: DateTime.add(DateTime.utc_now(), -7200, :second)
          )

        original_updated_at = lineage.updated_at

        # Wait a moment to ensure timestamp difference
        Process.sleep(10)

        # A value distinct from the create's cloned_at so the update is a real change
        # (a no-op update would not bump updated_at).
        new_time = DateTime.add(DateTime.utc_now(), -3600, :second)

        updated =
          lineage
          |> Ash.Changeset.for_update(
            :update,
            %{cloned_at: new_time},
            tenant: site.id,
            authorize?: false
          )
          |> Ash.update!()

        assert DateTime.compare(updated.updated_at, original_updated_at) == :gt
      end
    end

    describe "json_api configuration" do
      test "uses correct type" do
        json_api_config = Ash.Resource.Info.extensions(WorkspaceVersionLineage)
        assert AshJsonApi.Resource in json_api_config
      end

      test "supports includes for relationships" do
        site = create_site!()
        lineage = create_workspace_version_lineage!(site_id: site.id)

        # Can load relationships as configured in json_api includes
        loaded =
          Ash.load!(lineage, [:new_version, :source_version, :site],
            tenant: site.id,
            authorize?: false
          )

        assert loaded.new_version.id == lineage.new_version_id
        assert loaded.source_version.id == lineage.source_version_id
        assert loaded.site.id == site.id
      end
    end

    describe "database constraints" do
      test "has check constraint for future timestamps" do
        # cloned_at <= NOW() is enforced (a past_datetime derive + the DB check constraint):
        # a future cloned_at is rejected. A future value is safely past the sandbox's frozen
        # transaction-start NOW() too, so this is deterministic (unlike auto-set-to-now, which
        # floors to the second and can trip the frozen NOW() at a boundary).
        site = create_site!()
        workspace = create_workspace!(site_id: site.id)
        source = create_workspace_version!(workspace_id: workspace.id, site_id: site.id)
        new_v = create_workspace_version!(workspace_id: workspace.id, site_id: site.id)

        future = DateTime.add(DateTime.utc_now(), 3600, :second) |> DateTime.truncate(:second)

        assert_raise Ash.Error.Invalid, fn ->
          WorkspaceVersionLineage
          |> Ash.Changeset.for_create(
            :create,
            %{
              new_version_id: new_v.id,
              source_version_id: source.id,
              cloned_at: future
            },
            tenant: site.id,
            authorize?: false
          )
          |> Ash.create!()
        end
      end
    end

    describe "attributes" do
      test "cloned_at has correct type and default" do
        site = create_site!()
        lineage = create_workspace_version_lineage!(site_id: site.id)

        assert is_struct(lineage.cloned_at, DateTime)
      end

      test "all required attributes are present" do
        site = create_site!()
        lineage = create_workspace_version_lineage!(site_id: site.id)

        assert {:ok, _uuid} = Ecto.UUID.cast(lineage.id)
        assert {:ok, _uuid} = Ecto.UUID.cast(lineage.new_version_id)
        assert {:ok, _uuid} = Ecto.UUID.cast(lineage.source_version_id)
        assert {:ok, _uuid} = Ecto.UUID.cast(lineage.site_id)
        assert %DateTime{} = lineage.cloned_at
        assert %DateTime{} = lineage.inserted_at
        assert %DateTime{} = lineage.updated_at
      end
    end
  end
end
