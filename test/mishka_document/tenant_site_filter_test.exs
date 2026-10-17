# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_document/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaDocument.Test.TenantSiteFilterTest do
  @moduledoc """
  Tests for MishkaDocument.Resources.Helpers.TenantSiteFilter preparation.

  Verifies that the table_read action correctly filters event logs:
  - Master users see all events
  - Tenant users see only events matching their site_id
  - Tenant users do not see events created by master users
  - Tenant users can see system events (no actor) for their site
  """
  use MishkaDocument.DataCase, async: false

  if Code.ensure_loaded?(MishkaDocument) do
    alias MishkaDocument.EventLog

    defp read_table(actor) do
      EventLog
      |> Ash.Query.for_read(:table_read, %{}, actor: actor, authorize?: false)
      |> Ash.read!(page: [offset: 0, limit: 1000])
      |> Map.get(:results)
    end

    defp create_event_for_site!(site_id, opts) do
      actor = Keyword.get(opts, :actor)
      action = Keyword.get(opts, :action, :create)
      action_type = Keyword.get(opts, :action_type, :create)
      title = Keyword.get(opts, :title, "Test Record")

      attrs = %{
        record_id: Ash.UUIDv7.generate(),
        resource: MishkaDocument.Workspace,
        action: action,
        action_type: action_type,
        metadata: %{"site_id" => site_id, "title" => title},
        data: %{},
        occurred_at: DateTime.utc_now()
      }

      attrs = if actor, do: Map.put(attrs, :actor_id, actor.id), else: attrs

      EventLog
      |> Ash.Changeset.for_create(:create, attrs, authorize?: false)
      |> Ash.create!()
    end

    describe "master user (site_id: nil)" do
      test "sees all events regardless of site" do
        site1 = create_site!()
        site2 = create_site!()
        master_user = create_user!()

        create_event_for_site!(site1.id, title: "Site 1 Event")
        create_event_for_site!(site2.id, title: "Site 2 Event")

        events = read_table(master_user)

        site1_events = Enum.filter(events, &(&1.metadata["site_id"] == site1.id))
        site2_events = Enum.filter(events, &(&1.metadata["site_id"] == site2.id))

        assert [_ | _] = site1_events
        assert [_ | _] = site2_events
      end

      test "sees events created by master users" do
        master_user = create_user!()
        site = create_site!()

        create_event_for_site!(site.id, actor: master_user, title: "Master Action")

        events = read_table(master_user)
        master_events = Enum.filter(events, &(&1.actor_id == master_user.id))

        assert [_ | _] = master_events
      end

      test "sees system events (no actor)" do
        master_user = create_user!()
        site = create_site!()

        create_event_for_site!(site.id, title: "System Event")

        events = read_table(master_user)
        system_events = Enum.filter(events, &is_nil(&1.actor_id))

        assert [_ | _] = system_events
      end
    end

    describe "tenant user filtering by site_id" do
      test "sees events for their own site" do
        site = create_site!()
        tenant_user = create_user!(site_id: site.id)

        create_event_for_site!(site.id, actor: tenant_user, title: "Tenant Event")

        events = read_table(tenant_user)
        site_events = Enum.filter(events, &(&1.metadata["site_id"] == site.id))

        assert [_ | _] = site_events
      end

      test "does not see events from other sites" do
        site1 = create_site!()
        site2 = create_site!()
        tenant_user = create_user!(site_id: site1.id)
        other_tenant_user = create_user!(site_id: site2.id)

        create_event_for_site!(site2.id, actor: other_tenant_user, title: "Other Site Event")

        events = read_table(tenant_user)
        other_site_events = Enum.filter(events, &(&1.metadata["site_id"] == site2.id))

        assert other_site_events == []
      end

      test "sees system events (no actor) for their site" do
        site = create_site!()
        tenant_user = create_user!(site_id: site.id)

        event = create_event_for_site!(site.id, title: "System Event For Site")

        events = read_table(tenant_user)
        found = Enum.find(events, &(&1.id == event.id))

        assert %{actor_id: nil} = found
      end
    end

    describe "tenant user filtering by actor type" do
      test "does not see events created by master users" do
        site = create_site!()
        tenant_user = create_user!(site_id: site.id)
        master_user = create_user!()

        create_event_for_site!(site.id, actor: master_user, title: "Master Action On Tenant")

        events = read_table(tenant_user)
        master_actor_events = Enum.filter(events, &(&1.actor_id == master_user.id))

        assert master_actor_events == []
      end

      test "sees events created by tenant users from their site" do
        site = create_site!()
        tenant_user1 = create_user!(site_id: site.id)
        tenant_user2 = create_user!(site_id: site.id)

        event =
          create_event_for_site!(site.id,
            actor: tenant_user2,
            title: "Other Tenant User Action"
          )

        events = read_table(tenant_user1)
        found = Enum.find(events, &(&1.id == event.id))

        assert %{actor_id: actor_id} = found
        assert actor_id == tenant_user2.id
      end

      test "does not see events created by master users even with matching site_id" do
        site = create_site!()
        tenant_user = create_user!(site_id: site.id)
        master_user = create_user!()

        master_event =
          create_event_for_site!(site.id, actor: master_user, title: "Admin Modified Resource")

        system_event = create_event_for_site!(site.id, title: "System Modified Resource")

        events = read_table(tenant_user)

        refute Enum.any?(events, &(&1.id == master_event.id))
        assert Enum.any?(events, &(&1.id == system_event.id))
      end
    end

    describe "pagination with table_read" do
      test "returns paginated results sorted by occurred_at desc" do
        site = create_site!()
        tenant_user = create_user!(site_id: site.id)

        for i <- 1..3 do
          create_event_for_site!(site.id, actor: tenant_user, title: "Event #{i}")
          Process.sleep(10)
        end

        result =
          EventLog
          |> Ash.Query.for_read(:table_read, %{}, actor: tenant_user, authorize?: false)
          |> Ash.read!(page: [offset: 0, limit: 2])

        assert length(result.results) == 2
        assert result.more?

        [first, second] = result.results
        assert DateTime.compare(first.occurred_at, second.occurred_at) in [:gt, :eq]
      end
    end

    describe "site_id in data field fallback" do
      test "tenant sees events where site_id is in data instead of metadata" do
        site = create_site!()
        tenant_user = create_user!(site_id: site.id)

        event =
          EventLog
          |> Ash.Changeset.for_create(
            :create,
            %{
              record_id: Ash.UUIDv7.generate(),
              resource: MishkaDocument.Workspace,
              action: :create,
              action_type: :create,
              metadata: %{},
              data: %{"site_id" => site.id, "name" => "From Data"},
              occurred_at: DateTime.utc_now()
            },
            authorize?: false
          )
          |> Ash.create!()

        events = read_table(tenant_user)
        found = Enum.find(events, &(&1.id == event.id))

        assert %{id: found_id} = found
        assert found_id == event.id
      end
    end
  end
end
