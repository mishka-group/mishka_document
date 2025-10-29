defmodule MishkaDocument.Test.EventLogTest do
  @moduledoc """
  Tests for MishkaDocument.EventLog resource - Activity tracking for workspaces and other resources.

  Tests that events are automatically created when actions are performed on resources
  and that metadata is correctly captured for activity feeds.
  """
  use MishkaDocument.DataCase, async: false

  if Code.ensure_loaded?(MishkaDocument) do
    alias MishkaDocument.EventLog
    alias MishkaDocument.Workspace

    defp get_events_for_record(record_id) do
      EventLog
      |> Ash.Query.for_read(:read, %{}, authorize?: false)
      |> Ash.read!()
      |> Enum.filter(&(&1.record_id == record_id))
    end

    defp get_events_for_actor(actor_id) do
      EventLog
      |> Ash.Query.for_read(:read, %{}, authorize?: false)
      |> Ash.read!()
      |> Enum.filter(&(&1.actor_id == actor_id))
    end

    defp get_events_for_site(site_id) do
      EventLog
      |> Ash.Query.for_read(:read, %{}, authorize?: false)
      |> Ash.read!()
      |> Enum.filter(&(&1.metadata["site_id"] == site_id))
    end

    describe "event tracking on workspace create" do
      test "creates event when workspace is created" do
        site = create_site!()

        workspace =
          create_workspace!(
            name: "Test Workspace",
            slug: "test-workspace",
            status: :active,
            site_id: site.id
          )

        events = get_events_for_record(workspace.id)

        # Workspace may create multiple events (create + language_group_id update)
        assert length(events) >= 1

        # Find the create event
        create_event = Enum.find(events, &(&1.action == :create))
        assert create_event != nil
        assert create_event.resource == MishkaDocument.Workspace
        assert create_event.record_id == workspace.id
      end

      test "stores metadata with site_id and title" do
        site = create_site!()

        workspace =
          create_workspace!(
            name: "My Workspace",
            slug: "my-workspace",
            site_id: site.id
          )

        events = get_events_for_record(workspace.id)
        event = Enum.at(events, 0)

        assert event.metadata["site_id"] == site.id
        assert event.metadata["title"] == "My Workspace"
      end

      test "tracks actor when provided" do
        site = create_site!()
        user = create_user!(site_id: site.id)

        workspace =
          Workspace
          |> Ash.Changeset.for_create(
            :create,
            %{
              name: "Actor Workspace",
              slug: "actor-workspace",
              status: :active,
              language: "en"
            },
            tenant: site.id,
            actor: user,
            authorize?: false
          )
          |> Ash.create!()

        events = get_events_for_record(workspace.id)
        create_event = Enum.find(events, &(&1.action == :create))

        # Check actor_id was tracked
        assert create_event.actor_id == user.id
      end

      test "creates event for master_create action" do
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
          |> Ash.create!()

        event = get_events_for_record(workspace.id) |> Enum.find(&(&1.action == :master_create))

        assert event != nil
        assert event.metadata["title"] == "Master Workspace"
      end
    end

    describe "event tracking on workspace update" do
      test "creates event when workspace is updated" do
        site = create_site!()
        workspace = create_workspace!(name: "Original", site_id: site.id)

        _updated =
          workspace
          |> Ash.Changeset.for_update(
            :update,
            %{name: "Updated Name"},
            tenant: site.id,
            authorize?: false
          )
          |> Ash.update!()

        events =
          get_events_for_record(workspace.id)
          |> Enum.sort_by(& &1.occurred_at, DateTime)

        # Create + language_group_id update + manual update = 3 events
        assert length(events) >= 3

        create_event = Enum.at(events, 0)
        # Skip the language_group_id update at index 1
        update_event = Enum.at(events, 2)

        assert create_event.action == :create
        assert create_event.metadata["title"] == "Original"

        assert update_event.action == :update
        assert update_event.metadata["title"] == "Updated Name"
      end

      test "tracks multiple updates" do
        site = create_site!()
        workspace = create_workspace!(name: "First", site_id: site.id)

        workspace
        |> Ash.Changeset.for_update(:update, %{name: "Second"},
          tenant: site.id,
          authorize?: false
        )
        |> Ash.update!()

        workspace
        |> Ash.Changeset.for_update(:update, %{name: "Third"}, tenant: site.id, authorize?: false)
        |> Ash.update!()

        events =
          get_events_for_record(workspace.id)
          |> Enum.sort_by(& &1.occurred_at, DateTime)

        # Create + language_group_id update + 2 manual updates = 4 events
        assert length(events) >= 4

        assert Enum.at(events, 0).action == :create
        assert Enum.at(events, 1).action == :update
        assert Enum.at(events, 2).action == :update
        assert Enum.at(events, 3).action == :update

        assert Enum.at(events, 0).metadata["title"] == "First"
        # Event 1 is the language_group_id update, title still "First"
        assert Enum.at(events, 1).metadata["title"] == "First"
        assert Enum.at(events, 2).metadata["title"] == "Second"
        assert Enum.at(events, 3).metadata["title"] == "Third"
      end
    end

    describe "event tracking on workspace destroy (soft delete)" do
      test "creates event when workspace is archived" do
        site = create_site!()
        workspace = create_workspace!(name: "To Archive", site_id: site.id)

        workspace
        |> Ash.Changeset.for_destroy(:destroy, %{}, tenant: site.id, authorize?: false)
        |> Ash.destroy!()

        events = get_events_for_record(workspace.id)

        # Should have create + language_group_id update + destroy
        assert length(events) >= 3

        destroy_event = Enum.find(events, &(&1.action == :destroy))
        assert destroy_event != nil
        assert destroy_event.metadata["title"] == "To Archive"
        assert destroy_event.metadata["site_id"] == site.id
      end
    end

    describe "event tracking on workspace permanent_destroy" do
      test "creates event when workspace is permanently deleted" do
        site = create_site!()
        workspace = create_workspace!(name: "To Delete", site_id: site.id)

        workspace
        |> Ash.Changeset.for_destroy(:permanent_destroy, %{}, tenant: site.id, authorize?: false)
        |> Ash.destroy!()

        events = get_events_for_record(workspace.id)

        # Should have create + language_group_id update + permanent_destroy
        assert length(events) >= 3

        destroy_event = Enum.find(events, &(&1.action == :permanent_destroy))
        assert destroy_event != nil
        assert destroy_event.metadata["title"] == "To Delete"
        assert destroy_event.metadata["site_id"] == site.id
      end
    end

    describe "querying events" do
      test "can filter events by site_id" do
        site1 = create_site!()
        site2 = create_site!()

        ws1 = create_workspace!(name: "Site 1 WS", site_id: site1.id)
        ws2 = create_workspace!(name: "Site 2 WS", site_id: site2.id)

        site1_events = get_events_for_site(site1.id)
        site2_events = get_events_for_site(site2.id)

        # Each workspace creates 2 events (create + language_group_id update)
        assert length(site1_events) >= 2
        workspace1_events = Enum.filter(site1_events, &(&1.record_id == ws1.id))
        assert length(workspace1_events) == 2

        assert length(site2_events) >= 2
        workspace2_events = Enum.filter(site2_events, &(&1.record_id == ws2.id))
        assert length(workspace2_events) == 2
      end

      test "can filter events by resource type" do
        site = create_site!()
        _workspace = create_workspace!(name: "Test", site_id: site.id)

        workspace_events =
          EventLog
          |> Ash.Query.for_read(:read, %{}, authorize?: false)
          |> Ash.read!()
          |> Enum.filter(&(&1.resource == MishkaDocument.Workspace))

        assert length(workspace_events) >= 1
        assert Enum.all?(workspace_events, &(&1.resource == MishkaDocument.Workspace))
      end

      test "can filter events by action type" do
        site = create_site!()
        workspace = create_workspace!(name: "Test", site_id: site.id)

        workspace
        |> Ash.Changeset.for_update(:update, %{name: "Updated"},
          tenant: site.id,
          authorize?: false
        )
        |> Ash.update!()

        all_events = get_events_for_record(workspace.id)

        create_events = Enum.filter(all_events, &(&1.action == :create))
        update_events = Enum.filter(all_events, &(&1.action == :update))

        assert length(create_events) == 1
        # 2 updates: language_group_id + manual update
        assert length(update_events) == 2
      end

      test "can sort events by time" do
        site = create_site!()

        ws1 = create_workspace!(name: "First", site_id: site.id)
        ws2 = create_workspace!(name: "Second", site_id: site.id)
        ws3 = create_workspace!(name: "Third", site_id: site.id)

        events =
          get_events_for_site(site.id)
          |> Enum.filter(&(&1.resource == MishkaDocument.Workspace))
          |> Enum.sort_by(& &1.occurred_at, {:desc, DateTime})

        # Each workspace creates 2 events (create + language_group_id update)
        assert length(events) >= 6

        # Most recent events should be from ws3, then ws2, then ws1
        ws3_events = Enum.filter(events, &(&1.record_id == ws3.id))
        ws2_events = Enum.filter(events, &(&1.record_id == ws2.id))
        ws1_events = Enum.filter(events, &(&1.record_id == ws1.id))

        assert length(ws3_events) == 2
        assert length(ws2_events) == 2
        assert length(ws1_events) == 2

        # Verify ws3 events are more recent than ws2 events
        assert DateTime.compare(
                 Enum.at(ws3_events, 0).occurred_at,
                 Enum.at(ws2_events, 0).occurred_at
               ) in [:gt, :eq]

        # Verify ws2 events are more recent than ws1 events
        assert DateTime.compare(
                 Enum.at(ws2_events, 0).occurred_at,
                 Enum.at(ws1_events, 0).occurred_at
               ) in [:gt, :eq]
      end

      test "can get activity feed for specific user" do
        site = create_site!()
        user1 = create_user!(site_id: site.id)
        user2 = create_user!(site_id: site.id)

        ws1 =
          Workspace
          |> Ash.Changeset.for_create(
            :create,
            %{name: "User1 WS", slug: "user1-ws", status: :active, language: "en"},
            tenant: site.id,
            actor: user1,
            authorize?: false
          )
          |> Ash.create!()

        ws2 =
          Workspace
          |> Ash.Changeset.for_create(
            :create,
            %{name: "User2 WS", slug: "user2-ws", status: :active, language: "en"},
            tenant: site.id,
            actor: user2,
            authorize?: false
          )
          |> Ash.create!()

        user1_events = get_events_for_actor(user1.id)
        user2_events = get_events_for_actor(user2.id)

        assert length(user1_events) == 1
        assert Enum.at(user1_events, 0).record_id == ws1.id

        assert length(user2_events) == 1
        assert Enum.at(user2_events, 0).record_id == ws2.id
      end
    end

    describe "event log for activity feeds" do
      test "provides all necessary data for activity feed display" do
        site = create_site!()
        user = create_user!(site_id: site.id)

        workspace =
          Workspace
          |> Ash.Changeset.for_create(
            :create,
            %{name: "Activity Workspace", slug: "activity-ws", status: :active, language: "en"},
            tenant: site.id,
            actor: user,
            authorize?: false
          )
          |> Ash.create!()

        created = Enum.find(get_events_for_record(workspace.id), &(&1.action == :create))

        # Loaded the way the activity feed loads it (`MishkaDocument.EventLog`'s own timeline).
        event = Ash.load!(created, :actor, authorize?: false)

        # Loaded by nobody in particular, the account behind the event keeps its address to itself.
        anonymous = Ash.load!(created, :actor)
        assert anonymous.actor.id == user.id
        assert %Ash.ForbiddenField{} = anonymous.actor.email

        assert event.id != nil
        assert event.resource == MishkaDocument.Workspace
        assert event.action == :create
        assert event.record_id == workspace.id
        assert event.actor_id == user.id
        assert event.actor.email != nil
        assert event.metadata["site_id"] == site.id
        assert event.metadata["title"] == "Activity Workspace"
        assert event.occurred_at != nil

        activity_message = "#{event.actor.email} created workspace '#{event.metadata["title"]}'"
        assert activity_message =~ to_string(user.email)
        assert activity_message =~ "Activity Workspace"
      end

      test "tracks complete workspace lifecycle" do
        site = create_site!()
        user = create_user!(site_id: site.id)

        workspace =
          Workspace
          |> Ash.Changeset.for_create(
            :create,
            %{name: "Lifecycle WS", slug: "lifecycle-ws", status: :active, language: "en"},
            tenant: site.id,
            actor: user,
            authorize?: false
          )
          |> Ash.create!()

        workspace
        |> Ash.Changeset.for_update(
          :update,
          %{name: "Updated Lifecycle WS"},
          tenant: site.id,
          actor: user,
          authorize?: false
        )
        |> Ash.update!()

        workspace
        |> Ash.Changeset.for_destroy(:destroy, %{},
          tenant: site.id,
          actor: user,
          authorize?: false
        )
        |> Ash.destroy!()

        events =
          get_events_for_record(workspace.id)
          |> Enum.sort_by(& &1.occurred_at, DateTime)
          |> Enum.map(&Ash.load!(&1, :actor))

        # Create event + language_group_id update + manual update + destroy
        assert length(events) >= 3

        # Find specific event types
        create_event = Enum.find(events, &(&1.action == :create))

        update_event =
          Enum.find(
            events,
            &(&1.action == :update && &1.metadata["title"] == "Updated Lifecycle WS")
          )

        assert create_event.metadata["title"] == "Lifecycle WS"
        assert update_event.metadata["title"] == "Updated Lifecycle WS"

        # Verify actor tracking for user-initiated actions
        assert create_event.actor_id == user.id
        assert update_event.actor_id == user.id
        # Note: automatic language_group_id update has actor_id = nil
      end
    end

    describe "events are NOT created for read-only actions" do
      test "does not create events for read actions" do
        site = create_site!()
        workspace = create_workspace!(name: "Read Test", site_id: site.id)

        Ash.get!(Workspace, workspace.id, tenant: site.id, authorize?: false)
        Ash.get!(Workspace, workspace.id, tenant: site.id, authorize?: false)
        Ash.get!(Workspace, workspace.id, tenant: site.id, authorize?: false)

        events = get_events_for_record(workspace.id)

        # Create + language_group_id update = 2 events
        assert length(events) == 2
        # Verify only create and update actions exist (no read actions)
        assert Enum.all?(events, &(&1.action in [:create, :update]))
      end

      test "does not create events for list queries" do
        site = create_site!()
        _ws1 = create_workspace!(name: "WS1", site_id: site.id)
        _ws2 = create_workspace!(name: "WS2", site_id: site.id)

        Workspace
        |> Ash.Query.for_read(:read, %{}, tenant: site.id, authorize?: false)
        |> Ash.read!()

        Workspace
        |> Ash.Query.for_read(:read, %{}, tenant: site.id, authorize?: false)
        |> Ash.read!()

        all_events =
          EventLog
          |> Ash.Query.for_read(:read, %{}, authorize?: false)
          |> Ash.read!()

        # Should only have create and update (language_group_id) events, no read events
        assert Enum.all?(all_events, &(&1.action in [:create, :master_create, :update]))
      end
    end

    describe "event tracking on Issue create/update" do
      test "creates event when issue is created" do
        site = create_site!()
        user = create_user!(site_id: site.id)
        workspace = create_workspace!(site_id: site.id)

        workspace_version =
          create_workspace_version!(workspace_id: workspace.id, site_id: site.id)

        section =
          MishkaDocument.Section
          |> Ash.Changeset.for_create(
            :create,
            %{
              workspace_version_id: workspace_version.id,
              title: "Test Section",
              slug: "test-section",
              language: "en",
              order_position: 0
            },
            tenant: site.id,
            authorize?: false
          )
          |> Ash.create!()

        issue =
          MishkaDocument.Issue
          |> Ash.Changeset.for_create(
            :create,
            %{
              section_id: section.id,
              title: "Test Issue",
              description: "Test Description",
              issue_type: :typo,
              status: :open
            },
            tenant: site.id,
            actor: user,
            authorize?: false
          )
          |> Ash.create!()

        events = get_events_for_record(issue.id)
        assert length(events) >= 1

        create_event = Enum.find(events, &(&1.action == :create))
        assert create_event != nil
        assert create_event.metadata["title"] == "Test Issue"
        assert create_event.metadata["site_id"] == site.id
      end

      test "creates event when issue is updated" do
        site = create_site!()
        user = create_user!(site_id: site.id)
        workspace = create_workspace!(site_id: site.id)

        workspace_version =
          create_workspace_version!(workspace_id: workspace.id, site_id: site.id)

        section =
          MishkaDocument.Section
          |> Ash.Changeset.for_create(
            :create,
            %{
              workspace_version_id: workspace_version.id,
              title: "Test Section",
              slug: "test-section",
              language: "en",
              order_position: 0
            },
            tenant: site.id,
            authorize?: false
          )
          |> Ash.create!()

        issue =
          MishkaDocument.Issue
          |> Ash.Changeset.for_create(
            :create,
            %{
              section_id: section.id,
              title: "Original Issue",
              description: "Original",
              issue_type: :typo,
              status: :open
            },
            tenant: site.id,
            actor: user,
            authorize?: false
          )
          |> Ash.create!()

        issue
        |> Ash.Changeset.for_update(
          :update,
          %{title: "Updated Issue"},
          tenant: site.id,
          authorize?: false
        )
        |> Ash.update!()

        events = get_events_for_record(issue.id)
        update_event = Enum.find(events, &(&1.action == :update))

        assert update_event != nil
        assert update_event.metadata["title"] == "Updated Issue"
      end

      test "creates event for permanent_destroy" do
        site = create_site!()
        user = create_user!(site_id: site.id)
        workspace = create_workspace!(site_id: site.id)

        workspace_version =
          create_workspace_version!(workspace_id: workspace.id, site_id: site.id)

        section =
          MishkaDocument.Section
          |> Ash.Changeset.for_create(
            :create,
            %{
              workspace_version_id: workspace_version.id,
              title: "Test Section",
              slug: "test-section",
              language: "en",
              order_position: 0
            },
            tenant: site.id,
            authorize?: false
          )
          |> Ash.create!()

        issue =
          MishkaDocument.Issue
          |> Ash.Changeset.for_create(
            :create,
            %{
              section_id: section.id,
              title: "To Delete",
              description: "Test",
              issue_type: :typo,
              status: :open
            },
            tenant: site.id,
            actor: user,
            authorize?: false
          )
          |> Ash.create!()

        issue
        |> Ash.Changeset.for_destroy(:permanent_destroy, %{}, tenant: site.id, authorize?: false)
        |> Ash.destroy!()

        events = get_events_for_record(issue.id)
        destroy_event = Enum.find(events, &(&1.action == :permanent_destroy))

        assert destroy_event != nil
        assert destroy_event.metadata["title"] == "To Delete"
      end
    end

    describe "event tracking on Note create/update" do
      test "creates event when note is created" do
        site = create_site!()
        workspace = create_workspace!(site_id: site.id)

        workspace_version =
          create_workspace_version!(workspace_id: workspace.id, site_id: site.id)

        section =
          MishkaDocument.Section
          |> Ash.Changeset.for_create(
            :create,
            %{
              workspace_version_id: workspace_version.id,
              title: "Test Section",
              slug: "test-section",
              language: "en",
              order_position: 0
            },
            tenant: site.id,
            authorize?: false
          )
          |> Ash.create!()

        note =
          MishkaDocument.Note
          |> Ash.Changeset.for_create(
            :create,
            %{
              section_id: section.id,
              title: "Test Note",
              content: "Test content",
              order_position: 0
            },
            tenant: site.id,
            authorize?: false
          )
          |> Ash.create!()

        events = get_events_for_record(note.id)
        assert length(events) >= 1

        create_event = Enum.find(events, &(&1.action == :create))
        assert create_event != nil
        assert create_event.metadata["title"] == "Test Note"
        assert create_event.metadata["site_id"] == site.id
      end

      test "creates event when note is updated" do
        site = create_site!()
        workspace = create_workspace!(site_id: site.id)

        workspace_version =
          create_workspace_version!(workspace_id: workspace.id, site_id: site.id)

        section =
          MishkaDocument.Section
          |> Ash.Changeset.for_create(
            :create,
            %{
              workspace_version_id: workspace_version.id,
              title: "Test Section",
              slug: "test-section",
              language: "en",
              order_position: 0
            },
            tenant: site.id,
            authorize?: false
          )
          |> Ash.create!()

        note =
          MishkaDocument.Note
          |> Ash.Changeset.for_create(
            :create,
            %{
              section_id: section.id,
              title: "Original Note",
              content: "Original",
              order_position: 0
            },
            tenant: site.id,
            authorize?: false
          )
          |> Ash.create!()

        note
        |> Ash.Changeset.for_update(
          :update,
          %{title: "Updated Note"},
          tenant: site.id,
          authorize?: false
        )
        |> Ash.update!()

        events = get_events_for_record(note.id)
        update_event = Enum.find(events, &(&1.action == :update))

        assert update_event != nil
        assert update_event.metadata["title"] == "Updated Note"
      end

      test "creates event for permanent_destroy" do
        site = create_site!()
        workspace = create_workspace!(site_id: site.id)

        workspace_version =
          create_workspace_version!(workspace_id: workspace.id, site_id: site.id)

        section =
          MishkaDocument.Section
          |> Ash.Changeset.for_create(
            :create,
            %{
              workspace_version_id: workspace_version.id,
              title: "Test Section",
              slug: "test-section",
              language: "en",
              order_position: 0
            },
            tenant: site.id,
            authorize?: false
          )
          |> Ash.create!()

        note =
          MishkaDocument.Note
          |> Ash.Changeset.for_create(
            :create,
            %{
              section_id: section.id,
              title: "To Delete",
              content: "Test",
              order_position: 0
            },
            tenant: site.id,
            authorize?: false
          )
          |> Ash.create!()

        note
        |> Ash.Changeset.for_destroy(:permanent_destroy, %{}, tenant: site.id, authorize?: false)
        |> Ash.destroy!()

        events = get_events_for_record(note.id)
        destroy_event = Enum.find(events, &(&1.action == :permanent_destroy))

        assert destroy_event != nil
        assert destroy_event.metadata["title"] == "To Delete"
      end
    end

    describe "event tracking on Section create/update" do
      test "creates event when section is created" do
        site = create_site!()
        workspace = create_workspace!(site_id: site.id)

        workspace_version =
          create_workspace_version!(workspace_id: workspace.id, site_id: site.id)

        section =
          MishkaDocument.Section
          |> Ash.Changeset.for_create(
            :create,
            %{
              workspace_version_id: workspace_version.id,
              title: "Test Section",
              slug: "test-section",
              language: "en",
              order_position: 0
            },
            tenant: site.id,
            authorize?: false
          )
          |> Ash.create!()

        events = get_events_for_record(section.id)
        assert length(events) >= 1

        create_event = Enum.find(events, &(&1.action == :create))
        assert create_event != nil
        assert create_event.metadata["title"] == "Test Section"
        assert create_event.metadata["site_id"] == site.id
      end

      # TODO: https://discord.com/channels/711271361523351632/1019647368196534283
      # TODO: We should fix the problem with the event log when section is updated
      test "creates event when section is updated" do
        site = create_site!()
        workspace = create_workspace!(site_id: site.id)

        workspace_version =
          create_workspace_version!(workspace_id: workspace.id, site_id: site.id)

        section =
          MishkaDocument.Section
          |> Ash.Changeset.for_create(
            :create,
            %{
              workspace_version_id: workspace_version.id,
              title: "Original Section",
              slug: "original-section",
              language: "en",
              order_position: 0
            },
            tenant: site.id,
            authorize?: false
          )
          |> Ash.create!()

        section
        |> Ash.Changeset.for_update(
          :update,
          %{title: "Updated Section"},
          tenant: site.id,
          authorize?: false
        )
        |> Ash.update!()

        events = get_events_for_record(section.id)
        # Find the update event with the new title (not the language_group_id auto-update)
        update_event =
          Enum.find(events, &(&1.action == :update && &1.metadata["title"] == "Updated Section"))

        assert update_event != nil
        assert update_event.metadata["title"] == "Updated Section"
      end

      test "creates event when section is soft-deleted (archived)" do
        site = create_site!()
        workspace = create_workspace!(site_id: site.id)

        workspace_version =
          create_workspace_version!(workspace_id: workspace.id, site_id: site.id)

        section =
          MishkaDocument.Section
          |> Ash.Changeset.for_create(
            :create,
            %{
              workspace_version_id: workspace_version.id,
              title: "To Archive Section",
              slug: "to-archive-section",
              language: "en",
              order_position: 0
            },
            tenant: site.id,
            authorize?: false
          )
          |> Ash.create!()

        section
        |> Ash.Changeset.for_destroy(:destroy, %{}, tenant: site.id, authorize?: false)
        |> Ash.destroy!()

        events = get_events_for_record(section.id)
        destroy_event = Enum.find(events, &(&1.action == :destroy))

        assert destroy_event != nil
        assert destroy_event.metadata["title"] == "To Archive Section"
      end

      test "creates event for permanent_destroy" do
        site = create_site!()
        workspace = create_workspace!(site_id: site.id)

        workspace_version =
          create_workspace_version!(workspace_id: workspace.id, site_id: site.id)

        section =
          MishkaDocument.Section
          |> Ash.Changeset.for_create(
            :create,
            %{
              workspace_version_id: workspace_version.id,
              title: "To Delete",
              slug: "to-delete",
              language: "en",
              order_position: 0
            },
            tenant: site.id,
            authorize?: false
          )
          |> Ash.create!()

        section
        |> Ash.Changeset.for_destroy(:permanent_destroy, %{}, tenant: site.id, authorize?: false)
        |> Ash.destroy!()

        events = get_events_for_record(section.id)
        destroy_event = Enum.find(events, &(&1.action == :permanent_destroy))

        assert destroy_event != nil
        assert destroy_event.metadata["title"] == "To Delete"
      end
    end

    describe "event tracking on Tag create/update" do
      test "creates event when tag is created" do
        site = create_site!()

        tag =
          MishkaDocument.Tag
          |> Ash.Changeset.for_create(
            :create,
            %{
              name: "Test Tag",
              slug: "test-tag"
            },
            tenant: site.id,
            authorize?: false
          )
          |> Ash.create!()

        events = get_events_for_record(tag.id)
        assert length(events) >= 1

        create_event = Enum.find(events, &(&1.action == :create))
        assert create_event != nil
        assert create_event.metadata["title"] == "Test Tag"
        assert create_event.metadata["site_id"] == site.id
      end

      test "creates event when tag is updated" do
        site = create_site!()

        tag =
          MishkaDocument.Tag
          |> Ash.Changeset.for_create(
            :create,
            %{
              name: "Original Tag",
              slug: "original-tag"
            },
            tenant: site.id,
            authorize?: false
          )
          |> Ash.create!()

        tag
        |> Ash.Changeset.for_update(
          :update,
          %{name: "Updated Tag"},
          tenant: site.id,
          authorize?: false
        )
        |> Ash.update!()

        events = get_events_for_record(tag.id)

        update_event =
          Enum.find(events, &(&1.action == :update && &1.metadata["title"] == "Updated Tag"))

        assert update_event != nil
        assert update_event.metadata["title"] == "Updated Tag"
      end

      test "creates event for permanent_destroy" do
        site = create_site!()

        tag =
          MishkaDocument.Tag
          |> Ash.Changeset.for_create(
            :create,
            %{
              name: "To Delete",
              slug: "to-delete"
            },
            tenant: site.id,
            authorize?: false
          )
          |> Ash.create!()

        tag
        |> Ash.Changeset.for_destroy(:permanent_destroy, %{}, tenant: site.id, authorize?: false)
        |> Ash.destroy!()

        events = get_events_for_record(tag.id)
        destroy_event = Enum.find(events, &(&1.action == :permanent_destroy))

        assert destroy_event != nil
        assert destroy_event.metadata["title"] == "To Delete"
      end
    end

    describe "event tracking on WorkspaceVersion create/update" do
      test "creates event when workspace version is created" do
        site = create_site!()
        workspace = create_workspace!(site_id: site.id)

        workspace_version =
          MishkaDocument.WorkspaceVersion
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

        events = get_events_for_record(workspace_version.id)
        assert length(events) >= 1

        create_event = Enum.find(events, &(&1.action == :create))
        assert create_event != nil
        assert create_event.metadata["title"] == "1.0.0"
        assert create_event.metadata["site_id"] == site.id
      end

      test "creates event when workspace version is updated" do
        site = create_site!()
        workspace = create_workspace!(site_id: site.id)

        workspace_version =
          MishkaDocument.WorkspaceVersion
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

        workspace_version
        |> Ash.Changeset.for_update(
          :update,
          %{version_number: "2.0.0"},
          tenant: site.id,
          authorize?: false
        )
        |> Ash.update!()

        events = get_events_for_record(workspace_version.id)
        update_event = Enum.find(events, &(&1.action == :update))

        assert update_event != nil
        assert update_event.metadata["title"] == "2.0.0"
      end

      test "creates event when workspace version is published" do
        site = create_site!()
        workspace = create_workspace!(site_id: site.id)

        workspace_version =
          MishkaDocument.WorkspaceVersion
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

        workspace_version
        |> Ash.Changeset.for_update(:publish, %{}, tenant: site.id, authorize?: false)
        |> Ash.update!()

        events = get_events_for_record(workspace_version.id)
        publish_event = Enum.find(events, &(&1.action == :publish))

        assert publish_event != nil
        assert publish_event.metadata["title"] == "1.0.0"
      end

      test "creates event when workspace version is marked as latest" do
        site = create_site!()
        workspace = create_workspace!(site_id: site.id)

        workspace_version =
          MishkaDocument.WorkspaceVersion
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

        workspace_version
        |> Ash.Changeset.for_update(:mark_as_latest, %{}, tenant: site.id, authorize?: false)
        |> Ash.update!()

        events = get_events_for_record(workspace_version.id)
        mark_event = Enum.find(events, &(&1.action == :mark_as_latest))

        assert mark_event != nil
        assert mark_event.metadata["title"] == "1.0.0"
      end
    end

    describe "event tracking on NoteDraft create/update" do
      test "creates event when note draft is created" do
        site = create_site!()
        workspace = create_workspace!(site_id: site.id)

        workspace_version =
          create_workspace_version!(workspace_id: workspace.id, site_id: site.id)

        section =
          MishkaDocument.Section
          |> Ash.Changeset.for_create(
            :create,
            %{
              workspace_version_id: workspace_version.id,
              title: "Test Section",
              slug: "test-section",
              language: "en",
              order_position: 0
            },
            tenant: site.id,
            authorize?: false
          )
          |> Ash.create!()

        note_draft =
          MishkaDocument.NoteDraft
          |> Ash.Changeset.for_create(
            :create,
            %{
              workspace_version_id: workspace_version.id,
              section_id: section.id,
              title: "Test Note Draft",
              content: "Test content",
              change_version: "1.0.0",
              version_increment_type: :major
            },
            tenant: site.id,
            authorize?: false
          )
          |> Ash.create!()

        events = get_events_for_record(note_draft.id)
        assert length(events) >= 1

        create_event = Enum.find(events, &(&1.action == :create))
        assert create_event != nil
        assert create_event.metadata["title"] == "Test Note Draft"
        assert create_event.metadata["site_id"] == site.id
      end

      test "creates event when note draft is updated" do
        site = create_site!()
        workspace = create_workspace!(site_id: site.id)

        workspace_version =
          create_workspace_version!(workspace_id: workspace.id, site_id: site.id)

        section =
          MishkaDocument.Section
          |> Ash.Changeset.for_create(
            :create,
            %{
              workspace_version_id: workspace_version.id,
              title: "Test Section",
              slug: "test-section",
              language: "en",
              order_position: 0
            },
            tenant: site.id,
            authorize?: false
          )
          |> Ash.create!()

        note_draft =
          MishkaDocument.NoteDraft
          |> Ash.Changeset.for_create(
            :create,
            %{
              workspace_version_id: workspace_version.id,
              section_id: section.id,
              title: "Original Draft",
              content: "Original",
              change_version: "1.0.0",
              version_increment_type: :major
            },
            tenant: site.id,
            authorize?: false
          )
          |> Ash.create!()

        note_draft
        |> Ash.Changeset.for_update(
          :update,
          %{title: "Updated Draft"},
          tenant: site.id,
          authorize?: false
        )
        |> Ash.update!()

        events = get_events_for_record(note_draft.id)
        update_event = Enum.find(events, &(&1.action == :update))

        assert update_event != nil
        assert update_event.metadata["title"] == "Updated Draft"
      end

      test "creates event for permanent_destroy" do
        site = create_site!()
        workspace = create_workspace!(site_id: site.id)

        workspace_version =
          create_workspace_version!(workspace_id: workspace.id, site_id: site.id)

        section =
          MishkaDocument.Section
          |> Ash.Changeset.for_create(
            :create,
            %{
              workspace_version_id: workspace_version.id,
              title: "Test Section",
              slug: "test-section",
              language: "en",
              order_position: 0
            },
            tenant: site.id,
            authorize?: false
          )
          |> Ash.create!()

        note_draft =
          MishkaDocument.NoteDraft
          |> Ash.Changeset.for_create(
            :create,
            %{
              workspace_version_id: workspace_version.id,
              section_id: section.id,
              title: "To Delete",
              content: "Test",
              change_version: "1.0.0",
              version_increment_type: :major
            },
            tenant: site.id,
            authorize?: false
          )
          |> Ash.create!()

        note_draft
        |> Ash.Changeset.for_destroy(:permanent_destroy, %{}, tenant: site.id, authorize?: false)
        |> Ash.destroy!()

        events = get_events_for_record(note_draft.id)
        destroy_event = Enum.find(events, &(&1.action == :permanent_destroy))

        assert destroy_event != nil
        assert destroy_event.metadata["title"] == "To Delete"
      end
    end

    describe "event tracking on SectionDraft create/update" do
      test "creates event when section draft is created" do
        site = create_site!()
        workspace = create_workspace!(site_id: site.id)

        workspace_version =
          create_workspace_version!(workspace_id: workspace.id, site_id: site.id)

        section_draft =
          MishkaDocument.SectionDraft
          |> Ash.Changeset.for_create(
            :create,
            %{
              workspace_version_id: workspace_version.id,
              title: "Test Section Draft",
              slug: "test-section-draft",
              language: "en",
              change_version: "1.0.0",
              version_increment_type: :major,
              order_position: 0
            },
            tenant: site.id,
            authorize?: false
          )
          |> Ash.create!()

        events = get_events_for_record(section_draft.id)
        assert length(events) >= 1

        create_event = Enum.find(events, &(&1.action == :create))
        assert create_event != nil
        assert create_event.metadata["title"] == "Test Section Draft"
        assert create_event.metadata["site_id"] == site.id
      end

      test "creates event when section draft is updated" do
        site = create_site!()
        workspace = create_workspace!(site_id: site.id)

        workspace_version =
          create_workspace_version!(workspace_id: workspace.id, site_id: site.id)

        section_draft =
          MishkaDocument.SectionDraft
          |> Ash.Changeset.for_create(
            :create,
            %{
              workspace_version_id: workspace_version.id,
              title: "Original Section Draft",
              slug: "original-section-draft",
              language: "en",
              change_version: "1.0.0",
              version_increment_type: :major,
              order_position: 0
            },
            tenant: site.id,
            authorize?: false
          )
          |> Ash.create!()

        section_draft
        |> Ash.Changeset.for_update(
          :update,
          %{title: "Updated Section Draft"},
          tenant: site.id,
          authorize?: false
        )
        |> Ash.update!()

        events = get_events_for_record(section_draft.id)
        # Find the update event with the new title (not the language_group_id auto-update)
        update_event =
          Enum.find(
            events,
            &(&1.action == :update && &1.metadata["title"] == "Updated Section Draft")
          )

        assert update_event != nil
        assert update_event.metadata["title"] == "Updated Section Draft"
      end

      test "creates event for permanent_destroy" do
        site = create_site!()
        workspace = create_workspace!(site_id: site.id)

        workspace_version =
          create_workspace_version!(workspace_id: workspace.id, site_id: site.id)

        section_draft =
          MishkaDocument.SectionDraft
          |> Ash.Changeset.for_create(
            :create,
            %{
              workspace_version_id: workspace_version.id,
              title: "To Delete",
              slug: "to-delete",
              language: "en",
              change_version: "1.0.0",
              version_increment_type: :major,
              order_position: 0
            },
            tenant: site.id,
            authorize?: false
          )
          |> Ash.create!()

        section_draft
        |> Ash.Changeset.for_destroy(:permanent_destroy, %{}, tenant: site.id, authorize?: false)
        |> Ash.destroy!()

        events = get_events_for_record(section_draft.id)
        destroy_event = Enum.find(events, &(&1.action == :permanent_destroy))

        assert destroy_event != nil
        assert destroy_event.metadata["title"] == "To Delete"
      end
    end
  end
end
