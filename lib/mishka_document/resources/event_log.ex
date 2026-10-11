defmodule MishkaDocument.EventLog do
  @moduledoc """
  Minimal event log for tracking activities in MishkaDocument.

  Stores only essential information:
  - What happened (resource, action)
  - When it happened (timestamp)
  - Who did it (actor)
  - Which record (record_id)
  - Minimal context (site_id, title/name for display)

  Does NOT store full input data or changed attributes to keep storage minimal.

  The gervaz table over it is the document event log at `/admin/dashboard/document/event-logs`, drawn
  by the shared `MishkaCmsCoreWeb.Templates.ActivityTimeline` — the same timeline the unified log at
  `/admin/dashboard/runtime/activity` uses, over the very same rows. Everything the timeline reads
  off a record comes from here: `:severity`, the content-change `:tone` it tints a create/update/
  destroy row by, the day marks (`MishkaDocument.Resources.Helpers.DayMarks`) and `:occurred_at`.

  Tenant scoping is `MishkaDocument.Resources.Helpers.TenantSiteFilter`'s, on the `:table_read` list
  and `:table_get` single-row reads both roles use — `site_id` lives in JSONB, so Ash multitenancy
  cannot apply.

  Every read needs one of the two document areas, `admin:<dashboard|api>:document:workspace` or
  `admin:<dashboard|api>:document:section`, and returns only the events of the records that area
  holds: a workspace admin reads workspace and version events, a section admin the rest
  (`logged/1`). A master (a user whose `site_id` is nil) reads every site;
  a site admin only rows carrying its own site, whatever read or `site_id` argument it asks with.
  Writes belong to the system and to masters. Calls made with `authorize?: false` are not checked.

  Only `:table_read` carries the page-level day marks (`MishkaDocument.Resources.Helpers.DayMarks`);
  `:table_get` deliberately omits them, since one isolated realtime row has no page to mark.
  """
  use Ash.Resource,
    otp_app: :mishka_document,
    domain: MishkaDocument,
    data_layer: AshPostgres.DataLayer,
    notifiers: [Ash.Notifier.PubSub],
    extensions: [AshEvents.EventLog, MishkaGervaz.Resource],
    authorizers: [Ash.Policy.Authorizer]

  use MishkaGervaz.Messages, backend: MishkaCmsCore.Gettext
  import Phoenix.Component, only: [sigil_H: 2]
  import MishkaCmsCore.CoreComponents, only: [icon: 1]
  require Ash.Query

  alias MishkaCmsCore.Activity.Helpers
  alias MishkaCmsCore.Activity.Sources.EventLog, as: EventLogSource
  alias MishkaCmsCore.Localized
  alias MishkaCmsCoreWeb.Templates.ActivityTimeline

  # The same endpoint the `pub_sub` block below publishes through — the re-broadcast is a second
  # message on that block's own topic, so it has to go to the host's endpoint, not a hardcoded one.
  @endpoint_module Application.compile_env!(:mishka_cms_core, :endpoint)

  @workspace_logged [MishkaDocument.Workspace, MishkaDocument.WorkspaceVersion]

  @section_logged [
    MishkaDocument.Section,
    MishkaDocument.SectionDraft,
    MishkaDocument.Note,
    MishkaDocument.NoteDraft,
    MishkaDocument.Tag,
    MishkaDocument.Issue,
    MishkaDocument.IssueComment
  ]

  postgres do
    table "mishka_document_event_logs"
    repo Application.compile_env!(:mishka_cms_core, :repo)

    references do
      reference :actor, on_delete: :nilify
    end

    custom_indexes do
      index [:occurred_at]
    end
  end

  event_log do
    clear_records_for_replay MishkaDocument.Resources.Helpers.ClearRecordsForReplay
    advisory_lock_key_generator MishkaDocument.Resources.Helpers.AdvisoryLockKeyGenerator
    primary_key_type Ash.Type.UUIDv7
    record_id_type :uuid
    public_fields :all

    persist_actor_primary_key :actor_id, MishkaCmsCore.Accounts.User do
      allow_nil? true
      attribute_type :uuid
    end
  end

  mishka_gervaz do
    table do
      identity do
        name :event_logs
        route "/admin/dashboard/document/event-logs"
        stream_name :event_logs
      end

      source do
        actions do
          read {:table_read, :table_read}
          get {:table_get, :table_get}
        end

        preload do
          always [:actor, :severity, :tone]
        end
      end

      columns do
        column :event_info do
          static true

          requires [
            :id,
            :record_id,
            :occurred_at,
            :actor_id,
            :resource,
            :action_type,
            :metadata,
            :data
          ]

          label fn -> dgettext("mishka_gervaz", "Event") end
          position :first

          # The timeline node is the template's (it owns the rail); this is the message + its badge.
          # The wording is the unified log's, so the same row reads the same on both pages.
          render fn record ->
            entry = EventLogSource.entry_from_record(record)
            assigns = %{message: entry.message, resource_label: entry.resource_label}

            ~H"""
            <div class="flex flex-wrap items-center gap-2">
              <span class="text-[13px] font-semibold text-[#1b1a18]">{@message}</span>
              <span class="rounded-md bg-[#eeedfb] px-[7px] py-0.5 text-[8.5px] font-bold tracking-[0.05em] text-[#5b57d6]">
                {@resource_label}
              </span>
            </div>
            """
          end
        end

        column :event_actor do
          static true
          requires [:id, :actor, :actor_id, :severity, :tone]
          label fn -> dgettext("mishka_gervaz", "Actor") end

          # The avatar echoes the row's tone-or-severity, like the timeline node beside it — not the
          # actor, which the name already says.
          render fn record ->
            name = actor_label(record)

            assigns = %{
              id: record.id,
              initials: Helpers.initials(name),
              name: name,
              tone: ActivityTimeline.avatar_tone_class(record.tone || record.severity)
            }

            ~H"""
            <span id={"event-actor-#{@id}"} class="inline-flex items-center gap-[5px]">
              <span class={[
                "grid size-4 place-items-center rounded-[5px] font-['Space_Grotesk'] text-[8px] font-bold",
                @tone
              ]}>
                {@initials}
              </span>
              <span class="text-[11.5px] font-medium text-[#8a877f]">{@name}</span>
            </span>
            """
          end
        end

        column :event_date do
          static true
          requires [:occurred_at]
          label fn -> dgettext("mishka_gervaz", "Date") end

          # The day heading above the row already carries the year; the row only needs the day.
          render fn record ->
            assigns = %{
              time: Localized.time(record.occurred_at, :Hm),
              day: Localized.date(record.occurred_at, :MMMd)
            }

            ~H"""
            <div class="font-['Space_Grotesk'] text-[12px] font-semibold text-[#5c5a54]">
              {@time}
            </div>
            <div class="mt-0.5 text-[10.5px] font-medium text-[#bcb9b2]">{@day}</div>
            """
          end
        end

        column :event_site do
          static true

          # `:__metadata__` carries the batch-resolved name; a `static` column's render fn is handed a
          # map of exactly its `requires`, so the name only reaches it if it is required.
          requires [:metadata, :data, :__metadata__]
          label fn -> dgettext("mishka_gervaz", "Site") end
          visible fn state -> state.master_user? end

          # The name is resolved for the whole page in one query by
          # `MishkaDocument.Resources.Helpers.SiteNames` and carried here as metadata, so this reads
          # it rather than firing a Site query per row.
          render fn record ->
            assigns = %{site_name: Map.get(Map.get(record, :__metadata__) || %{}, :site_name)}

            ~H"""
            <span
              :if={@site_name}
              class="inline-flex items-center gap-[5px] rounded-[20px] bg-[#f4f3ef] px-[9px] py-[3px] text-[10.5px] font-semibold text-[#6d6a63]"
            >
              <.icon name="hero-globe-alt" class="size-[11px] text-[#a8a5a0]" />{@site_name}
            </span>
            """
          end
        end
      end

      filters do
        filter :action_type, :select do
          source :action_type

          options fn ->
            [
              {dgettext("mishka_gervaz", "Create"), "create"},
              {dgettext("mishka_gervaz", "Update"), "update"},
              {dgettext("mishka_gervaz", "Destroy"), "destroy"}
            ]
          end

          ui do
            prompt dgettext_noop("mishka_gervaz", "All Actions")
            label fn -> dgettext("mishka_gervaz", "Action Type") end
          end
        end

        filter :resource, :select do
          source :resource

          options fn ->
            [
              {dgettext("mishka_gervaz", "Workspace"), "Elixir.MishkaDocument.Workspace"},
              {dgettext("mishka_gervaz", "Workspace Version"),
               "Elixir.MishkaDocument.WorkspaceVersion"},
              {dgettext("mishka_gervaz", "Section"), "Elixir.MishkaDocument.Section"},
              {dgettext("mishka_gervaz", "Note"), "Elixir.MishkaDocument.Note"},
              {dgettext("mishka_gervaz", "Section Draft"), "Elixir.MishkaDocument.SectionDraft"},
              {dgettext("mishka_gervaz", "Note Draft"), "Elixir.MishkaDocument.NoteDraft"},
              {dgettext("mishka_gervaz", "Tag"), "Elixir.MishkaDocument.Tag"},
              {dgettext("mishka_gervaz", "Issue"), "Elixir.MishkaDocument.Issue"},
              {dgettext("mishka_gervaz", "Issue Comment"), "Elixir.MishkaDocument.IssueComment"}
            ]
          end

          ui do
            prompt dgettext_noop("mishka_gervaz", "All Resources")
            label fn -> dgettext("mishka_gervaz", "Resource") end
          end
        end

        filter :created_at, :date_range do
          source :occurred_at

          ui do
            label fn -> dgettext("mishka_gervaz", "Date Range") end
          end
        end
      end

      row do
        selectable false
      end

      pagination do
        type :load_more
        page_size 20

        ui do
          show_total true
          load_more_label dgettext_noop("mishka_gervaz", "Load more events")
        end
      end

      realtime do
        enabled true
        prefix "event_log"

        visible fn record, user ->
          case user do
            %{id: _, site_id: nil} ->
              true

            %{site_id: site_id} when is_binary(site_id) ->
              event_site =
                cond do
                  is_map(record.metadata) && Map.has_key?(record.metadata, "site_id") ->
                    record.metadata["site_id"]

                  is_map(record.data) && Map.has_key?(record.data, "site_id") ->
                    record.data["site_id"]

                  true ->
                    nil
                end

              event_site == site_id

            _ ->
              false
          end
        end
      end

      url_sync do
        mode :bidirectional
        params [:filters, :page]
        prefix "event_logs"
        max_filter_length 500
      end

      presentation do
        template MishkaCmsCoreWeb.Templates.ActivityTimeline
        # No cap: unlike the unified log's capped UNION, every count here is an exact one.
        template_options timestamp: :occurred_at

        features [:filter, :paginate]
      end

      empty_state message: dgettext_noop("mishka_gervaz", "No event logs found"),
                  icon: "hero-clipboard-document-list"
    end
  end

  actions do
    defaults [:read]

    read :master_read do
      description "Read all event logs - master users only"
      prepare build(sort: [occurred_at: :desc])
      pagination offset?: true, default_limit: 10, countable: true

      validate {MishkaCmsCore.Runtime.Resources.Validations.TenantContext, require_master: true}
    end

    read :tenant_read do
      description "Read event logs for a specific tenant"

      argument :site_id, :uuid do
        allow_nil? false
      end

      prepare build(sort: [occurred_at: :desc])
      pagination offset?: true, default_limit: 10, countable: true

      filter expr(
               fragment("(?->>'site_id') = ?::text", metadata, ^arg(:site_id)) or
                 fragment("(?->>'site_id') = ?::text", data, ^arg(:site_id))
             )
    end

    read :table_read do
      description "Read event logs for MishkaGervaz table - auto-filters by actor site_id"
      prepare build(sort: [occurred_at: :desc])
      prepare {MishkaDocument.Resources.Helpers.TenantSiteFilter, []}
      prepare {MishkaDocument.Resources.Helpers.DayMarks, []}
      prepare {MishkaDocument.Resources.Helpers.SiteNames, []}
      pagination offset?: true, default_limit: 20, countable: true
    end

    read :table_get do
      description "Single-row read for the table's realtime path - the table read without the page-level day marks, which mean nothing for one isolated record and would draw a stray heading if stamped on it."
      prepare {MishkaDocument.Resources.Helpers.TenantSiteFilter, []}
      prepare {MishkaDocument.Resources.Helpers.SiteNames, []}
    end
  end

  policies do
    policy always() do
      access_type :strict

      authorize_if {MishkaCmsCore.Accounts.Checks.AccessPermissions,
                    permissions: [
                      "admin:dashboard:document:workspace",
                      "admin:api:document:workspace",
                      "admin:dashboard:document:section",
                      "admin:api:document:section"
                    ]}
    end

    policy action_type(:read) do
      authorize_if actor_attribute_equals(:site_id, nil)

      authorize_if expr(
                     fragment("(?->>'site_id') = ?::text", metadata, ^actor(:site_id)) or
                       fragment("(?->>'site_id') = ?::text", data, ^actor(:site_id))
                   )
    end

    # An event is read by the area of the record it is about (`logged/1`).
    # An event of a resource neither area lists needs both.
    policy action_type(:read) do
      authorize_if expr(resource in ^@section_logged)

      authorize_if {MishkaCmsCore.Accounts.Checks.AccessPermissions,
                    permissions: [
                      "admin:dashboard:document:workspace",
                      "admin:api:document:workspace"
                    ]}
    end

    policy action_type(:read) do
      authorize_if expr(resource in ^@workspace_logged)

      authorize_if {MishkaCmsCore.Accounts.Checks.AccessPermissions,
                    permissions: [
                      "admin:dashboard:document:section",
                      "admin:api:document:section"
                    ]}
    end

    policy action_type([:create, :update, :destroy, :action]) do
      authorize_if actor_attribute_equals(:site_id, nil)
    end
  end

  pub_sub do
    module Application.compile_env!(:mishka_cms_core, :endpoint)
    prefix "event_log"

    publish :create, ["created"]
  end

  changes do
    change after_action(fn _changeset, record, _context ->
             record_with_actor = Ash.load!(record, [:actor], authorize?: false)

             notification = %Ash.Notifier.Notification{
               resource: MishkaDocument.EventLog,
               data: record_with_actor,
               action: %{name: :create, type: :create}
             }

             Task.start(fn ->
               Process.sleep(200)
               @endpoint_module.broadcast("event_log:created", "create", notification)
             end)

             {:ok, record}
           end),
           on: [:create]
  end

  relationships do
    belongs_to :actor, MishkaCmsCore.Accounts.User do
      # How any resource reaches an account — see `MishkaCmsCore.Accounts.User`'s `:related`.
      read_action :related
      sortable? false
      attribute_writable? false
    end
  end

  calculations do
    calculate :actor_master?,
              :boolean,
              {MishkaCmsCore.Accounts.Calculations.ByMaster, field: :actor_id} do
      description "Whether the actor is a master, for a reader who cannot load a master's account"
    end

    calculate :severity,
              :atom,
              {MishkaCmsCore.Activity.Calculations.Severity, field: :action} do
      description "How loudly the timeline draws this event: a destroy of any kind warns, the rest inform."
    end

    calculate :tone,
              :atom,
              {MishkaCmsCore.Activity.Calculations.Tone, field: :action} do
      description "Which action colour the timeline tints this event by: a create reads green, an update blue, a destroy red; any other action carries no tone and is drawn by its severity."
    end
  end

  @doc """
  The resources whose events an area reads: `:workspace` for `document:workspace`, `:section` for
  `document:section`. Every resource writing to the log is listed under exactly one area.

      MishkaDocument.EventLog.logged(:workspace)
      #=> [MishkaDocument.Workspace, MishkaDocument.WorkspaceVersion]
  """
  @spec logged(:workspace | :section) :: [module()]
  def logged(:workspace), do: @workspace_logged
  def logged(:section), do: @section_logged

  @doc """
  How many events the viewer can see, as `%{total: n, info: n, warn: n}` — the log's KPI row.

  Counted through `:table_read`, the very action the table reads, so a figure can never disagree with
  the list beside it: a master counts every site, a tenant only its own. There is no `:error` figure
  — an event log records what a resource DID, never a failure, so
  `MishkaCmsCore.Activity.Helpers.severity_for/1` only ever reads one of these as `:info` or `:warn`.
  """
  @spec counts(map() | nil) :: %{
          total: non_neg_integer(),
          info: non_neg_integer(),
          warn: non_neg_integer()
        }
  def counts(actor) do
    query = Ash.Query.for_read(__MODULE__, :table_read, %{}, actor: actor)
    total = count(query)
    warn = query |> Ash.Query.filter(action in ^Helpers.warn_actions()) |> count()

    %{total: total, info: total - warn, warn: warn}
  end

  defp count(query) do
    case Ash.count(query) do
      {:ok, count} -> count
      {:error, _reason} -> 0
    end
  end

  @doc """
  Who did `event`, for the reader whose read loaded its `:actor` and `:actor_master?`.

  The email the reader may see, "Master" for a master, "System" for an event no user did (a replay, a
  seed, a job) and "Unknown" for an actor the reader's read did not return.
  """
  @spec actor_label(map()) :: String.t()
  def actor_label(event) do
    MishkaCmsCore.Accounts.Helper.who(
      Map.get(event, :actor),
      Map.get(event, :actor_master?) == true,
      (Map.get(event, :actor_id) && :unknown) || :system
    )
  end
end
