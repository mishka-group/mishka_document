# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_document/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaDocumentWeb.Templates.IssueCard do
  @moduledoc """
  The issues list: full-width cards, each one able to open a comments panel underneath itself.

  Declared only by `MishkaDocument.Issue`, and it reads that record directly rather than by column
  position — a card is a specific shape (title over a type and a status badge, a description, a meta
  line, and an actions cluster) that a generic position mapping cannot describe. The resource's columns
  stay the field-selection contract and the sort menu's vocabulary; nothing here renders through them.

  A card wears two badges — what kind of issue it is (`type_badge/1`) and where it stands
  (`status_badge/1`) — and their colours are the ones the Documents dashboard's issue panel already
  uses, so an issue reads the same on both pages.

  ## The expanded panel

  `:expand` is what separates this from the other card templates. The Comment button pushes
  `expand_row`, Gervaz answers by putting `AsyncResult.loading()` on `state.expanded_data` and asking
  the page for the viewer, and the page hands back a `current_user`/`master_user?` pair the panel
  mounts `MishkaDocumentWeb.Live.Admin.Dashboard.Issue.IssueCommentsLive` from. One row is open at a
  time — that is Gervaz's rule, not ours.

  The panel also carries the status machine. Which transitions an issue offers is decided by
  `transitions/1` here, not by the resource: the actions themselves accept any status, so this is the
  only thing standing between `:closed` and a "Mark In Progress" button.

  ## Features
  - `:filter` - the toolbar: search, the archive switch, and an Advanced panel holding the rest
  - `:select` - per-card selection for bulk operations, with a Select all row over the list
  - `:bulk_actions` - bulk actions on the selected cards
  - `:paginate` - the page-size picker and numbered pages under the list
  - `:expand` - the comments and actions panel

  Pairs with `MishkaCmsCoreWeb.UIAdapters.Admin`, which draws the archive switch and the row
  actions. The furniture around the cards — the toolbar, the count row, the loading veils, the
  pagination — comes from `MishkaCmsCoreWeb.Templates.CardChrome`. See
  `MishkaDocumentWeb.Templates.DocumentCard`, the same idea for workspaces.
  """

  use MishkaGervaz.Table.Behaviours.Template
  use MishkaGervaz.Messages, backend: MishkaCmsCore.Gettext

  import MishkaGervaz.Helpers, only: [dynamic_component: 1]

  alias MishkaCmsCore.Localized
  alias MishkaCmsCoreWeb.Templates.CardChrome, as: Shared
  alias MishkaGervaz.Table.Templates.Shared, as: Gervaz
  alias Phoenix.LiveView.AsyncResult

  @types %{
    suggestion: %{
      label: dgettext_noop("mishka_gervaz", "Suggestion"),
      chip: "bg-[#eeedfb] text-[#4f4bcc]",
      dot: "bg-[#6d69e6]"
    },
    typo: %{
      label: dgettext_noop("mishka_gervaz", "Typo"),
      chip: "bg-[#f4ecfb] text-[#8a4bcc]",
      dot: "bg-[#a566e0]"
    },
    broken_link: %{
      label: dgettext_noop("mishka_gervaz", "Broken link"),
      chip: "bg-[#fbe9e7] text-[#b3433a]",
      dot: "bg-[#e5484d]"
    },
    incorrect_content: %{
      label: dgettext_noop("mishka_gervaz", "Incorrect content"),
      chip: "bg-[#fbe9f2] text-[#b03a76]",
      dot: "bg-[#d4569b]"
    },
    review_feedback: %{
      label: dgettext_noop("mishka_gervaz", "Review feedback"),
      chip: "bg-[#e4f4f7] text-[#0f7b8a]",
      dot: "bg-[#35a4b5]"
    },
    other: %{
      label: dgettext_noop("mishka_gervaz", "Other"),
      chip: "bg-[#f2f1ec] text-[#6d6a63]",
      dot: "bg-[#a8a5a0]"
    }
  }

  @statuses %{
    open: %{label: dgettext_noop("mishka_gervaz", "Open"), chip: "bg-[#fbf1df] text-[#a5691a]"},
    in_progress: %{
      label: dgettext_noop("mishka_gervaz", "In progress"),
      chip: "bg-[#eef1fc] text-[#3a5bc4]"
    },
    resolved: %{
      label: dgettext_noop("mishka_gervaz", "Resolved"),
      chip: "bg-[#e6f6ee] text-[#177a53]"
    },
    closed: %{
      label: dgettext_noop("mishka_gervaz", "Closed"),
      chip: "bg-[#f2f1ec] text-[#6d6a63]"
    }
  }

  @impl true
  def name, do: :issue_card

  @impl true
  def label, do: dgettext("mishka_gervaz", "Issue Cards")

  @impl true
  def icon, do: "hero-exclamation-triangle"

  @impl true
  def description,
    do: dgettext("mishka_gervaz", "Full-width list with an expandable comments panel")

  @impl true
  def features do
    [:filter, :select, :bulk_actions, :paginate, :expand]
  end

  @impl true
  def default_options, do: []

  @impl true
  def render(assigns) do
    static = assigns.static
    state = assigns.state
    features = static.features

    show_checkboxes =
      :select in features and
        static.bulk_actions != [] and
        Gervaz.has_visible_bulk_actions?(static.bulk_actions, state.archive_status)

    assigns =
      assigns
      |> assign(:show_checkboxes, show_checkboxes)
      |> assign(:show_filters, static.filters != [] and :filter in features)
      |> assign(
        :show_pagination,
        :paginate in features and is_integer(state.total_count) and state.total_count > 0
      )
      |> assign(:show_bulk_actions, :bulk_actions in features and show_checkboxes)

    ~H"""
    <div class="mishka-gervaz-issue-card">
      <div :if={@state.has_initial_data? or @state.loading == :loaded}>
        <Shared.filter_bar
          :if={@show_filters}
          static={@static}
          state={@state}
          myself={@myself}
          search_placeholder={dgettext("mishka_gervaz", "Search issues…")}
        />

        <Shared.select_row
          static={@static}
          state={@state}
          myself={@myself}
          show_checkboxes={@show_checkboxes}
          empty_label={dgettext("mishka_gervaz", "0 issues")}
        />

        <.render_bulk_actions
          :if={@show_bulk_actions}
          static={@static}
          state={@state}
          myself={@myself}
        />

        <div class="relative isolate">
          <Shared.loading_overlay
            :if={
              @state.has_initial_data? and @state.loading == :loading and
                @state.loading_type == :reset
            }
            text={loading_text(@static)}
          />

          <div id={"#{@static.stream_name}"} phx-update="stream" class="flex flex-col gap-3">
            <Shared.empty_state
              id={"#{@static.stream_name}-empty-state"}
              static={@static}
              icon="hero-exclamation-triangle"
            />

            <.render_item
              :for={{id, record} <- @stream}
              id={id}
              record={record}
              static={@static}
              state={@state}
              show_checkboxes={@show_checkboxes}
              myself={@myself}
            />
          </div>
        </div>

        <.render_pagination :if={@show_pagination} static={@static} state={@state} myself={@myself} />
      </div>
    </div>
    """
  end

  @doc """
  One issue card, and the comments panel underneath it while it is the open one.

  Reads the record directly rather than by column position — the resource declares this template, and
  a card's shape (badges beside a title, a meta line, an actions cluster) is not a column order.
  """
  @impl true
  def render_item(assigns) do
    %{record: record, state: state} = assigns

    checked? = Gervaz.record_checked?(state, record.id)

    assigns =
      assigns
      |> assign(:type, type_badge(record))
      |> assign(:status, status_badge(record))
      |> assign(:checked?, checked?)
      |> assign(:expanded?, to_string(state.expanded_id) == to_string(record.id))
      |> assign(:reporter, reporter(record))
      |> assign(:comments, comments_count(record))
      |> assign(:site, site_name(record))
      |> assign(:date, inserted_on(record))
      |> assign(
        :visible_row_actions,
        Enum.filter(assigns.static.row_actions, &Gervaz.action_visible?(&1, record, state))
      )

    ~H"""
    <div
      id={@id}
      data-role="isscard"
      class={[
        "overflow-hidden rounded-2xl border bg-white shadow-[0_1px_2px_rgba(30,28,24,0.04)]",
        (@expanded? && "border-[#dcdbf5]") || "border-[#ecebe6]",
        @checked? && "ring-2 ring-[#5b57d6]"
      ]}
    >
      <div class="flex gap-3.5 px-5 py-[18px]">
        <div :if={@show_checkboxes} class="flex-none pt-[3px]">
          <.dynamic_component
            module={@static.ui_adapter}
            function={:checkbox}
            phx-click="toggle_select"
            phx-value-id={@record.id}
            phx-target={@myself}
            name="select_card"
            value={@record.id}
            checked={@checked?}
            class="gervaz-media-checkbox size-4 cursor-pointer rounded accent-[#5b57d6]"
          />
        </div>

        <div class="min-w-0 flex-1">
          <div data-role="iss-head" class="flex items-start gap-3 max-[560px]:flex-col!">
            <div class="min-w-0 flex-1">
              <div class="font-['Space_Grotesk'] text-[15.5px] font-semibold tracking-[-0.01em] text-[#17161a]">
                {@record.title}
              </div>
              <div class="mt-[9px] flex flex-wrap items-center gap-[7px]">
                <span class={[
                  "inline-flex items-center gap-1.5 rounded-md px-[9px] py-[3px] text-[10px] font-bold tracking-[0.03em]",
                  @type.chip
                ]}>
                  <span class={["size-[5px] rounded-full", @type.dot]}></span>
                  {badge_label(@type)}
                </span>
                <span class={[
                  "rounded-md px-[9px] py-[3px] text-[10px] font-bold uppercase tracking-[0.03em]",
                  @status.chip
                ]}>
                  {badge_label(@status)}
                </span>
              </div>
            </div>

            <%!-- `min-w-0` on the row: the icon squares are `flex-none`, so the Comment button is the
                  only thing that can give width back, and a flex row will not let it below its own
                  text unless the row itself may shrink. --%>
            <div
              data-role="iss-actions"
              class="flex min-w-0 flex-none items-center gap-2 max-[560px]:w-full! max-[560px]:flex-wrap! max-[560px]:justify-end!"
            >
              <button
                type="button"
                phx-click="expand_row"
                phx-value-id={@record.id}
                phx-target={@myself}
                aria-expanded={to_string(@expanded?)}
                class={[
                  "inline-flex h-8 min-w-0 items-center gap-1.5 rounded-[9px] border px-3 text-[11.5px] font-semibold transition-colors",
                  (@expanded? && "border-[#dcdbf5] bg-[#f2f1fc] text-[#4f4bcc]") ||
                    "border-[#ecebe6] bg-white text-[#5c5a54] hover:bg-[#f7f6f3]"
                ]}
              >
                <.dynamic_component
                  module={@static.ui_adapter}
                  function={:icon}
                  name="hero-chat-bubble-left-right"
                  class="size-3.5 flex-none"
                />
                <span class="truncate">{dgettext("mishka_gervaz", "Comment")}</span>
              </button>

              <div
                :if={@visible_row_actions != []}
                class="[&>div]:flex [&>div]:min-w-0 [&>div]:gap-2"
              >
                <Gervaz.render_row_actions
                  row_actions={@visible_row_actions}
                  record={@record}
                  static={@static}
                  state={@state}
                  myself={@myself}
                />
              </div>
            </div>
          </div>

          <p class="mt-[11px] text-[13px] font-medium leading-[1.5] text-[#6d6a63] [text-wrap:pretty]">
            {@record.description}
          </p>

          <div
            data-role="iss-meta"
            class="mt-3 flex flex-wrap items-center gap-x-[18px] gap-y-2.5"
          >
            <span class="inline-flex items-center gap-1.5 text-[11px] font-semibold text-[#8a877f]">
              <.dynamic_component
                module={@static.ui_adapter}
                function={:icon}
                name="hero-user"
                class="size-[13px] flex-none"
              />
              <span id={"issue-reporter-#{@record.id}"} dir="auto" class="truncate">{@reporter}</span>
            </span>

            <span class="inline-flex items-center gap-1.5 text-[11px] font-semibold text-[#8a877f]">
              <.dynamic_component
                module={@static.ui_adapter}
                function={:icon}
                name="hero-chat-bubble-left-right"
                class="size-[13px] flex-none"
              />
              {@comments}
            </span>

            <span class="text-[11px] font-semibold text-[#a8a5a0]">{@date}</span>

            <span
              :if={@site}
              class="rounded-md border border-[#e4e2f7] bg-[#f2f1fc] px-[9px] py-[3px] text-[10.5px] font-semibold text-[#4f4bcc]"
            >
              {@site}
            </span>
          </div>
        </div>
      </div>

      <.render_expanded
        :if={@expanded? and :expand in @static.features}
        record={@record}
        static={@static}
        state={@state}
        myself={@myself}
      />
    </div>
    """
  end

  defp render_expanded(assigns) do
    assigns = assign(assigns, :transitions, transitions(assigns.record))

    ~H"""
    <div class="border-t border-[#f0efea] bg-[#fbfbfa] p-5">
      <div class="mb-4 flex items-center justify-between gap-3">
        <div class="flex items-center gap-2">
          <.dynamic_component
            module={@static.ui_adapter}
            function={:icon}
            name="hero-chat-bubble-left-right"
            class="size-4 text-[#5b57d6]"
          />
          <span class="text-[13px] font-bold text-[#1b1a18]">
            {dgettext("mishka_gervaz", "Comments & Actions")}
          </span>
        </div>
        <button
          type="button"
          phx-click="expand_row"
          phx-value-id={@record.id}
          phx-target={@myself}
          title={dgettext("mishka_gervaz", "Close")}
          class="grid size-7 flex-none place-items-center rounded-lg text-[#a8a5a0] transition-colors hover:bg-[#f0efea] hover:text-[#5c5a54]"
        >
          <.dynamic_component
            module={@static.ui_adapter}
            function={:icon}
            name="hero-x-mark"
            class="size-[15px]"
          />
        </button>
      </div>

      <div :if={@transitions != []} class="mb-[18px] flex flex-wrap items-center gap-2.5">
        <span class="text-[11px] font-bold text-[#8a877f]">
          {dgettext("mishka_gervaz", "Actions")}
        </span>
        <button
          :for={{event, label, tone} <- @transitions}
          type="button"
          phx-click={event}
          phx-value-issue-id={@record.id}
          class={[
            "inline-flex h-[34px] items-center rounded-[9px] border px-3.5 text-[12px] font-semibold transition-colors",
            tone
          ]}
        >
          {label}
        </button>
      </div>

      <%= case @state.expanded_data do %>
        <% %AsyncResult{ok?: true, result: %{current_user: current_user, master_user?: master?}} -> %>
          <.live_component
            module={MishkaDocumentWeb.Live.Admin.Dashboard.Issue.IssueCommentsLive}
            id={"issue-comments-" <> to_string(@record.id)}
            issue_id={@record.id}
            issue_status={@record.status}
            current_user={current_user}
            master_user?={master?}
          />
        <% _ -> %>
          <div class="flex items-center justify-center gap-2.5 py-6">
            <span class="size-4 animate-spin rounded-full border-2 border-[#e0ddd6] border-t-[#5b57d6]" />
            <span class="text-[12px] font-medium text-[#8a877f]">
              {dgettext("mishka_gervaz", "Loading comments…")}
            </span>
          </div>
      <% end %>
    </div>
    """
  end

  @doc """
  Which status changes an issue offers, in the order the panel shows them.

  The resource's transition actions accept any status — they only set one — so this is the whole state
  machine. An issue never offers the state it is already in, and `:closed` is a terminal state you
  leave only by reopening.
  """
  @spec transitions(map()) :: [{String.t(), String.t(), String.t()}]
  def transitions(%{status: :open}), do: [in_progress(), resolved(), closed()]
  def transitions(%{status: :in_progress}), do: [resolved(), closed()]
  def transitions(%{status: :resolved}), do: [reopen(), closed()]
  def transitions(%{status: :closed}), do: [reopen()]
  def transitions(_record), do: []

  defp in_progress do
    {"mark_in_progress", dgettext("mishka_gervaz", "Mark In Progress"),
     "border-[#cfd8f5] bg-[#eef1fc] text-[#3a5bc4] hover:bg-[#e4e9fb]"}
  end

  defp resolved do
    {"mark_resolved", dgettext("mishka_gervaz", "Mark Resolved"),
     "border-[#c9e6d5] bg-[#eaf7ef] text-[#177a53] hover:bg-[#ddf1e5]"}
  end

  defp closed do
    {"mark_closed", dgettext("mishka_gervaz", "Close"),
     "border-[#ecebe6] bg-white text-[#5c5a54] hover:bg-[#f6f5f2]"}
  end

  defp reopen do
    {"reopen", dgettext("mishka_gervaz", "Reopen"),
     "border-[#f0e2c4] bg-[#fbf1df] text-[#a5691a] hover:bg-[#f6ecd6]"}
  end

  @doc """
  The page-size picker on the left, the numbered pages on the right, under the list.

  `change_page_size`, `prev_page` / `next_page` / `go_to_page` and every figure here are Gervaz's —
  only the look is ours. A resource that asked for `:load_more` or `:infinite` instead keeps the
  shared pagination, which is the only thing that knows how to draw those.
  """
  @impl true
  def render_pagination(assigns) do
    ~H"""
    <Shared.pagination static={@static} state={@state} myself={@myself} />
    """
  end

  @doc """
  How an issue's type badge reads and what colour it wears.

  One entry per `Issue.issue_type`, and the design names five of the six — `:review_feedback` is ours
  and takes the one hue the others leave free, so no two types read as each other. `issue_type` has a
  default on the resource, but a record read with a narrowed field set can still arrive without it: an
  issue whose type nobody chose reads as `:other` rather than taking the card down.
  """
  @spec type_badge(map()) :: %{label: String.t(), chip: String.t(), dot: String.t()}
  def type_badge(%{issue_type: type}) when is_map_key(@types, type), do: @types[type]
  def type_badge(_record), do: @types.other

  @doc """
  How an issue's status badge reads and what colour it wears — flat and uppercase, no dot.

  These are the four the Documents dashboard's issue rows already use, so an issue keeps its colour
  between the two pages. Falls back to `:open`, which is the attribute's own default.
  """
  @spec status_badge(map()) :: %{label: String.t(), chip: String.t()}
  def status_badge(%{status: status}) when is_map_key(@statuses, status), do: @statuses[status]
  def status_badge(_record), do: @statuses.open

  @doc "The words an issue's type badge reads, in the viewer's language."
  @spec type_label(map()) :: String.t()
  def type_label(record), do: record |> type_badge() |> badge_label()

  @doc "The words an issue's status badge reads, in the viewer's language."
  @spec status_label(map()) :: String.t()
  def status_label(record), do: record |> status_badge() |> badge_label()

  @doc """
  Who reported `issue`, for the reader whose read loaded its `:reporter` and `:reporter_master?`.

  The email the reader may see, "Master" for a master, else "Unknown".
  """
  @spec reporter(map()) :: String.t()
  def reporter(issue) do
    MishkaCmsCore.Accounts.Helper.who(
      Map.get(issue, :reporter),
      Map.get(issue, :reporter_master?) == true,
      :unknown
    )
  end

  defp badge_label(%{label: label}),
    do: Gettext.dgettext(MishkaCmsCore.Gettext, "mishka_gervaz", label)

  defp site_name(%{site: %{name: name}}) when is_binary(name), do: name
  defp site_name(_record), do: nil

  defp comments_count(%{comments_count: count}) when is_integer(count), do: count
  defp comments_count(_record), do: 0

  defp inserted_on(%{inserted_at: at})
       when is_struct(at, DateTime) or is_struct(at, NaiveDateTime),
       do: Localized.date(at, :yMMMd)

  defp inserted_on(_record), do: "—"

  @impl true
  def render_loading(assigns) do
    assigns = assign(assigns, :text, loading_text(assigns[:static]))

    ~H"""
    <Shared.loading text={@text} />
    """
  end

  defp loading_text(nil), do: dgettext("mishka_gervaz", "Loading...")

  defp loading_text(static),
    do: static.pagination_ui.loading_text || dgettext("mishka_gervaz", "Loading...")
end
