defmodule MishkaDocument.Test.EventLogTimelineTest do
  @moduledoc """
  Tests what the shared `MishkaCmsCoreWeb.Templates.ActivityTimeline` reads off a
  `MishkaDocument.EventLog` record on `/admin/dashboard/document/event-logs`:

  - the `:severity` calculation the timeline node and actor avatar are tinted from
  - the day marks `MishkaDocument.Resources.Helpers.DayMarks` stamps on each record's metadata
  - `MishkaDocument.EventLog.counts/1`, the KPI row, and its tenant scope
  """
  use MishkaDocument.DataCase, async: false

  if Code.ensure_loaded?(MishkaDocument) do
    alias MishkaCmsCore.Activity.Helpers
    alias MishkaCmsCoreWeb.Templates.ActivityTimeline
    alias MishkaDocument.EventLog

    defp read_table(actor, opts \\ []) do
      page = Keyword.get(opts, :page, offset: 0, limit: 1000)

      EventLog
      |> Ash.Query.for_read(:table_read, %{}, actor: actor, authorize?: false)
      |> Ash.Query.load([:severity, :tone])
      |> Ash.read!(page: page)
      |> Map.get(:results)
    end

    defp create_event!(opts) do
      site_id = Keyword.get(opts, :site_id)
      title = Keyword.get(opts, :title, "Test Record")

      attrs = %{
        record_id: Ash.UUIDv7.generate(),
        resource: MishkaDocument.Workspace,
        action: Keyword.get(opts, :action, :create),
        action_type: Keyword.get(opts, :action_type, :create),
        metadata: %{"site_id" => site_id, "title" => title},
        data: %{},
        occurred_at: Keyword.get(opts, :occurred_at, DateTime.utc_now())
      }

      EventLog
      |> Ash.Changeset.for_create(:create, attrs, authorize?: false)
      |> Ash.create!()
    end

    defp marks(record), do: {record.__metadata__[:first_of_day?], record.__metadata__[:day_count]}

    describe "severity calculation" do
      test "a destroy of any kind warns, everything else informs" do
        master = create_user!()
        site = create_site!()

        for {action, action_type} <- [
              {:create, :create},
              {:master_create, :create},
              {:update, :update},
              {:unarchive, :update}
            ] do
          create_event!(site_id: site.id, action: action, action_type: action_type)
        end

        for {action, action_type} <- [
              {:destroy, :destroy},
              {:master_destroy, :destroy},
              {:permanent_destroy, :destroy},
              {:master_permanent_destroy, :destroy}
            ] do
          create_event!(site_id: site.id, action: action, action_type: action_type)
        end

        by_action = Map.new(read_table(master), &{&1.action, &1.severity})

        assert by_action[:create] == :info
        assert by_action[:master_create] == :info
        assert by_action[:update] == :info
        assert by_action[:unarchive] == :info
        assert by_action[:destroy] == :warn
        assert by_action[:master_destroy] == :warn
        assert by_action[:permanent_destroy] == :warn
        assert by_action[:master_permanent_destroy] == :warn
      end

      test "an action the feed has no rule for informs rather than raising" do
        master = create_user!()
        site = create_site!()

        create_event!(site_id: site.id, action: :mark_applied, action_type: :update)

        assert [%{severity: :info}] =
                 master |> read_table() |> Enum.filter(&(&1.action == :mark_applied))
      end
    end

    describe "tone calculation" do
      test "a create tones :created, an update :updated, a destroy of any kind :destroyed" do
        master = create_user!()
        site = create_site!()

        for {action, action_type} <- [
              {:create, :create},
              {:master_create, :create},
              {:update, :update},
              {:master_update, :update},
              {:destroy, :destroy},
              {:master_destroy, :destroy},
              {:permanent_destroy, :destroy},
              {:master_permanent_destroy, :destroy}
            ] do
          create_event!(site_id: site.id, action: action, action_type: action_type)
        end

        by_action = Map.new(read_table(master), &{&1.action, &1.tone})

        assert by_action[:create] == :created
        assert by_action[:master_create] == :created
        assert by_action[:update] == :updated
        assert by_action[:master_update] == :updated
        assert by_action[:destroy] == :destroyed
        assert by_action[:master_destroy] == :destroyed
        assert by_action[:permanent_destroy] == :destroyed
        assert by_action[:master_permanent_destroy] == :destroyed
      end

      test "an action that is not a create/update/destroy carries no tone" do
        master = create_user!()
        site = create_site!()

        create_event!(site_id: site.id, action: :unarchive, action_type: :update)
        create_event!(site_id: site.id, action: :mark_applied, action_type: :update)

        tones = master |> read_table() |> Map.new(&{&1.action, &1.tone})

        assert tones[:unarchive] == nil
        assert tones[:mark_applied] == nil
      end
    end

    describe "timeline palette" do
      test "tone_for maps content-change actions and nils everything else" do
        assert Helpers.tone_for(:create) == :created
        assert Helpers.tone_for(:master_create) == :created
        assert Helpers.tone_for(:update) == :updated
        assert Helpers.tone_for(:destroy) == :destroyed
        assert Helpers.tone_for(:master_permanent_destroy) == :destroyed
        assert Helpers.tone_for(:completed) == nil
        assert Helpers.tone_for(:mark_applied) == nil
      end

      test "the node dot is green for a create/info, blue for an update, red for a destroy" do
        assert ActivityTimeline.dot_class(:created) == "bg-[#1f9d6b]"
        assert ActivityTimeline.dot_class(:updated) == "bg-[#2f86c4]"
        assert ActivityTimeline.dot_class(:destroyed) == "bg-[#d5544b]"
        assert ActivityTimeline.dot_class(:info) == "bg-[#1f9d6b]"
      end

      test "the actor avatar tint matches its dot for every tone" do
        assert ActivityTimeline.avatar_tone_class(:created) == "bg-[#e6f6ee] text-[#1f9d6b]"
        assert ActivityTimeline.avatar_tone_class(:updated) == "bg-[#e6f1fa] text-[#2f86c4]"
        assert ActivityTimeline.avatar_tone_class(:destroyed) == "bg-[#fbe9e7] text-[#d5544b]"
      end
    end

    describe "day marks" do
      test "only the newest row of a day opens it, and carries that day's total" do
        master = create_user!()
        site = create_site!()
        today = DateTime.utc_now()
        yesterday = DateTime.add(today, -1, :day)

        create_event!(site_id: site.id, occurred_at: DateTime.add(today, -60, :second))
        create_event!(site_id: site.id, occurred_at: DateTime.add(today, -30, :second))
        create_event!(site_id: site.id, occurred_at: yesterday)

        [newest, second, third] = read_table(master)

        assert marks(newest) == {true, 2}
        assert marks(second) == {false, nil}
        assert marks(third) == {true, 1}
      end

      test "a day's total counts the whole day, not the loaded window" do
        master = create_user!()
        site = create_site!()
        now = DateTime.utc_now()

        for offset <- 1..5,
            do: create_event!(site_id: site.id, occurred_at: DateTime.add(now, -offset, :second))

        [newest | _rest] = read_table(master, page: [offset: 0, limit: 2])

        assert marks(newest) == {true, 5}
      end

      test "the first row of page two does not repeat the day page one ended on" do
        master = create_user!()
        site = create_site!()
        now = DateTime.utc_now()

        for offset <- 1..4,
            do: create_event!(site_id: site.id, occurred_at: DateTime.add(now, -offset, :second))

        [third, fourth] = read_table(master, page: [offset: 2, limit: 2])

        assert {false, nil} = marks(third)
        assert {false, nil} = marks(fourth)
      end

      test "a day's total only counts what the viewer can see" do
        site = create_site!()
        other_site = create_site!()
        tenant = create_user!(site_id: site.id)
        now = DateTime.utc_now()

        create_event!(site_id: site.id, occurred_at: now)
        create_event!(site_id: other_site.id, occurred_at: DateTime.add(now, -1, :second))
        create_event!(site_id: other_site.id, occurred_at: DateTime.add(now, -2, :second))

        assert [only] = read_table(tenant)
        assert marks(only) == {true, 1}
      end
    end

    describe "counts/1" do
      test "splits the log into info and warn, and they sum to the total" do
        master = create_user_with_permissions!(["admin:dashboard:*"])
        site = create_site!()

        create_event!(site_id: site.id, action: :create, action_type: :create)
        create_event!(site_id: site.id, action: :update, action_type: :update)
        create_event!(site_id: site.id, action: :destroy, action_type: :destroy)

        assert %{total: 3, info: 2, warn: 1} = EventLog.counts(master)
      end

      test "a tenant counts only its own site" do
        site = create_site!()
        other_site = create_site!()
        tenant = create_user_with_permissions!(["admin:dashboard:*"], site_id: site.id)

        create_event!(site_id: site.id, action: :create, action_type: :create)
        create_event!(site_id: other_site.id, action: :create, action_type: :create)
        create_event!(site_id: other_site.id, action: :destroy, action_type: :destroy)

        assert %{total: 1, info: 1, warn: 0} = EventLog.counts(tenant)
      end

      test "an empty log counts to zero rather than failing" do
        assert %{total: 0, info: 0, warn: 0} = EventLog.counts(create_user!())
      end
    end

    describe "site badge resolution" do
      test "the master read resolves every row's site name in the batch, not per row" do
        master = create_user!()
        site = create_site!()

        create_event!(site_id: site.id)
        create_event!(site_id: site.id)

        for record <- read_table(master) do
          assert record.__metadata__[:site_name] == site.name
        end
      end

      test "a site that no longer exists falls back to a truncated id" do
        master = create_user!()
        gone = Ash.UUIDv7.generate()

        create_event!(site_id: gone)

        assert [record] = read_table(master)
        assert record.__metadata__[:site_name] == String.slice(gone, 0, 8) <> "..."
      end
    end

    describe "realtime single-row get" do
      test "the get action gervaz's realtime path uses does not stamp day marks" do
        master = create_user!()
        site = create_site!()
        event = create_event!(site_id: site.id, occurred_at: DateTime.utc_now())

        get_action = MishkaGervaz.Resource.Info.Table.action_for(EventLog, :get, true)

        loaded =
          Ash.get!(EventLog, event.id, action: get_action, actor: master, authorize?: false)

        refute loaded.__metadata__[:first_of_day?]
        assert loaded.__metadata__[:day_count] == nil
      end

      test "the realtime get still resolves the site badge for a master" do
        master = create_user!()
        site = create_site!()
        event = create_event!(site_id: site.id, occurred_at: DateTime.utc_now())

        get_action = MishkaGervaz.Resource.Info.Table.action_for(EventLog, :get, true)

        loaded =
          Ash.get!(EventLog, event.id, action: get_action, actor: master, authorize?: false)

        assert loaded.__metadata__[:site_name] == site.name
      end
    end
  end
end
