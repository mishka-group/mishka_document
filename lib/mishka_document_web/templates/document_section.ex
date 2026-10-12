defmodule MishkaDocumentWeb.Templates.DocumentSection do
  @moduledoc """
  The sections list: full-width cards beside a rail of workspace panels.

  Declared only by `MishkaDocument.Section`, and it reads that record directly rather than by column
  position — a card is a specific shape (a breadcrumb of chips, a title over its slug, a preview of the
  content, a meta line and two review badges) that a generic position mapping cannot describe. The
  resource's columns stay the field-selection contract and the sort menu's vocabulary.

  ## The rail

  Whatever the page hands in through `:rail` — Software Info, Site Information, Maintainers, Recent
  Activity — is laid out by this template rather than beside it, which is the only way its position
  can follow the viewport. The four class strings come from
  `MishkaGervaz.Table.Templates.Shared.rail_class/2`, so switching to the plain table keeps the rail
  in the same place instead of stacking it on top of the records.

  ## The expanded panel

  `:expand` here is server-rendered: the Comment-style toggle pushes `expand_row`, the page answers by
  rendering its own Notes / Recent Activity panel and pushing it back as `expanded_html`, and this
  template only frames it. That is why `state.expanded_data` carries HTML rather than a payload — see
  `MishkaDocumentWeb.Live.Admin.Dashboard.Section.Index.render_expanded_section/2`.

  ## Features
  - `:filter` - the toolbar: Add Section, search, the archive switch, an Advanced panel, the view switch
  - `:select` - per-card selection for bulk operations, with a Select all row over the list
  - `:bulk_actions` - bulk actions on the selected cards
  - `:paginate` - the page-size picker and numbered pages under the list
  - `:expand` - the Advanced Details panel

  The furniture around the cards is `MishkaCmsCoreWeb.Templates.CardChrome`, which
  `MishkaDocumentWeb.Templates.IssueCard` draws from too. Pairs with
  `MishkaCmsCoreWeb.UIAdapters.Admin`, which draws the archive switch, the view switch and the row
  actions.
  """

  use MishkaGervaz.Table.Behaviours.Template
  use MishkaGervaz.Messages, backend: MishkaCmsCore.Gettext

  import MishkaGervaz.Helpers, only: [dynamic_component: 1]
  import MishkaCmsCore.CoreComponents, only: [show_form_modal: 2]

  alias MishkaCmsCore.Localized
  alias MishkaCmsCoreWeb.Templates.CardChrome, as: Shared
  alias MishkaGervaz.Table.Templates.Shared, as: Gervaz
  alias Phoenix.LiveView.AsyncResult

  @reviews %{
    approved: "bg-[#e6f6ee] text-[#177a53]",
    pending: "bg-[#fbf1df] text-[#a5691a]",
    rejected: "bg-[#fbe9e7] text-[#b3433a]",
    needs_revision: "bg-[#f4ecfb] text-[#8a4bcc]",
    archived: "bg-[#f2f1ec] text-[#6d6a63]"
  }

  @impl true
  def name, do: :document_section

  @impl true
  def label, do: dgettext("mishka_gervaz", "Document Sections")

  @impl true
  def icon, do: "hero-queue-list"

  @impl true
  def description, do: dgettext("mishka_gervaz", "Full-width list with expandable details")

  @impl true
  def features do
    [:filter, :select, :bulk_actions, :paginate, :expand]
  end

  @impl true
  def default_options, do: []

  @impl true
  def render(assigns) do
    assigns =
      assigns
      |> assign_new(:rail, fn -> nil end)
      |> Gervaz.assign_card_flags()

    ~H"""
    <div class="mishka-gervaz-document-section">
      <div
        :if={@state.has_initial_data? or @state.loading == :loaded}
        data-role="sec-layout"
        class={Gervaz.rail_class(@rail, :grid)}
      >
        <div class={Gervaz.rail_class(@rail, :top)}>
          <Shared.filter_bar
            :if={@show_filters}
            static={@static}
            state={@state}
            myself={@myself}
            search_placeholder={dgettext("mishka_gervaz", "Search sections…")}
          >
            <:leading>
              <button
                type="button"
                id={"#{@static.stream_name}-add"}
                phx-click={show_form_modal("section-form-modal", MishkaDocument.Section)}
                class="inline-flex h-[42px] items-center gap-2 rounded-xl bg-[linear-gradient(140deg,#6d69e6,#4f4bcc)] px-4 text-[12.5px] font-bold text-white shadow-[0_5px_14px_rgba(79,75,204,0.28)] transition-opacity hover:opacity-95"
              >
                <.dynamic_component
                  module={@static.ui_adapter}
                  function={:icon}
                  name="hero-plus"
                  class="size-4"
                />
                {dgettext("mishka_gervaz", "Add Section")}
              </button>
            </:leading>

            <:trailing :if={@show_switcher}>
              <Gervaz.render_template_switcher
                switchable_templates={@static.switchable_templates}
                current_template={@state.template}
                ui_adapter={@static.ui_adapter}
                myself={@myself}
              />
            </:trailing>
          </Shared.filter_bar>
        </div>

        <div
          :if={@rail not in [nil, []]}
          data-role="sec-rail"
          class={Gervaz.rail_class(@rail, :rail)}
        >
          {render_slot(@rail)}
        </div>

        <div class={Gervaz.rail_class(@rail, :bottom)}>
          <Shared.select_row
            static={@static}
            state={@state}
            myself={@myself}
            show_checkboxes={@show_checkboxes}
            empty_label={dgettext("mishka_gervaz", "0 sections")}
          />

          <.render_bulk_actions
            :if={@show_bulk_actions}
            static={@static}
            state={@state}
            myself={@myself}
          />

          <div class="relative isolate">
            <Shared.loading_overlay :if={
              @state.has_initial_data? and @state.loading == :loading and
                @state.loading_type == :reset
            } />

            <div id={"#{@static.stream_name}"} phx-update="stream" class="flex flex-col gap-3">
              <Shared.empty_state
                id={"#{@static.stream_name}-empty-state"}
                static={@static}
                icon="hero-document"
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

          <Shared.pagination
            :if={@show_pagination}
            static={@static}
            state={@state}
            myself={@myself}
          />
        </div>
      </div>
    </div>
    """
  end

  @doc """
  One section card.

  On a narrow screen the row rewraps rather than shrinking: the checkbox and the action squares take
  the first line on their own, the chips follow on the second, and the title, preview and meta run full
  width underneath. Squeezing all three columns onto a phone is what pushed the last action square off
  the card.
  """
  @impl true
  def render_item(assigns) do
    %{record: record, state: state} = assigns

    checked? = Gervaz.record_checked?(state, record.id)

    assigns =
      assigns
      |> assign(:checked?, checked?)
      |> assign(:expanded?, to_string(state.expanded_id) == to_string(record.id))
      |> assign(:crumbs, crumbs(record))
      |> assign(:version, version(record))
      |> assign(:versions_count, count(record, :section_versions_count))
      |> assign(:preview, preview(record))
      |> assign(:words, count(record, :content_word_count))
      |> assign(:contributors, count(record, :contributors_count))
      |> assign(:pending, pending_drafts(record))
      |> assign(:date, inserted_on(record))
      |> assign(:content_review, review(record.content_review_status))
      |> assign(:technical_review, review(record.technical_review_status))
      |> assign(
        :visible_row_actions,
        assigns.static.row_actions
        |> Gervaz.non_accordion_actions()
        |> Enum.filter(&Gervaz.action_visible?(&1, record, state))
      )

    ~H"""
    <div
      id={@id}
      data-role="seccard"
      class={[
        "overflow-hidden rounded-2xl border bg-white shadow-[0_1px_2px_rgba(30,28,24,0.04)]",
        (@expanded? && "border-[#dcdbf5]") || "border-[#ecebe6]",
        @checked? && "ring-2 ring-[#5b57d6]"
      ]}
    >
      <div class="flex gap-3.5 px-5 py-[18px] max-[560px]:flex-wrap!">
        <div :if={@show_checkboxes} class="order-1 flex-none pt-[3px]">
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

        <div
          :if={@visible_row_actions != []}
          data-role="secactions"
          class="order-3 flex flex-none items-start [&>div]:flex [&>div]:gap-[7px] max-[560px]:order-2! max-[560px]:ms-auto!"
        >
          <Gervaz.render_row_actions
            row_actions={@visible_row_actions}
            record={@record}
            static={@static}
            state={@state}
            myself={@myself}
          />
        </div>

        <div class="order-2 min-w-0 flex-1 max-[560px]:order-3! max-[560px]:basis-full!">
          <div class="flex flex-wrap items-center gap-2.5">
            <span class="rounded-md bg-[#f4f3ee] px-2 py-[3px] text-[10px] font-bold uppercase tracking-[0.05em] text-[#8a877f]">
              {dgettext("mishka_gervaz", "Documentation")}
            </span>
            <span
              :for={crumb <- @crumbs}
              class="rounded-md bg-[#f4f3ee] px-2 py-[3px] text-[10.5px] font-bold text-[#8a877f]"
            >
              {crumb}
            </span>
            <span class="rounded-md bg-[#e6f6ee] px-[9px] py-[3px] text-[10.5px] font-bold text-[#177a53]">
              {@record.title}
            </span>

            <span class="flex-1 max-[560px]:hidden!"></span>

            <span
              dir="ltr"
              class="rounded-md bg-[#f2f1fc] px-2 py-[3px] font-['Space_Grotesk'] text-[10.5px] font-bold text-[#4f4bcc]"
            >
              v{@version}
            </span>
            <span :if={@versions_count > 1} class="text-[10.5px] font-semibold text-[#a8a5a0]">
              ({dgettext("mishka_gervaz", "%{count} versions", count: @versions_count)})
            </span>
          </div>

          <div class="mt-3 flex flex-wrap items-baseline gap-3">
            <span class="font-['Space_Grotesk'] text-[17px] font-semibold tracking-[-0.01em] text-[#17161a]">
              {@record.title}
            </span>
            <span dir="ltr" class="font-['Space_Grotesk'] text-[12px] font-semibold text-[#a8a5a0]">
              /{@record.slug}
            </span>
          </div>

          <div
            :if={@preview}
            class="mt-[9px] truncate rounded-[9px] border border-[#f0efea] bg-[#faf9f6] px-3 py-[9px] font-['Space_Grotesk'] text-[12.5px] font-medium leading-[1.5] text-[#8f8c85]"
          >
            {@preview}
          </div>

          <div data-role="sec-meta" class="mt-[11px] flex flex-wrap items-center gap-x-4 gap-y-2">
            <span :if={@words > 0} class="text-[11px] font-semibold text-[#a8a5a0]">
              {dgettext("mishka_gervaz", "%{count} words", count: @words)}
            </span>
            <span class="text-[11px] font-semibold text-[#a8a5a0]">{@date}</span>
            <span class="text-[11px] font-semibold text-[#a8a5a0]">
              {dgettext("mishka_gervaz", "%{count} contributors", count: @contributors)}
            </span>
            <span
              :if={@pending > 0}
              class="inline-flex items-center gap-[5px] rounded-md bg-[#fbf1df] px-2 py-[3px] text-[10.5px] font-bold text-[#a5691a]"
            >
              <span class="size-[5px] rounded-full bg-[#cf8a24]"></span>
              {dgettext("mishka_gervaz", "%{count} pending", count: @pending)}
            </span>

            <span class="flex-1 max-[560px]:hidden!"></span>

            <span class="flex gap-1.5">
              <span
                title={dgettext("mishka_gervaz", "Content Review")}
                class={[
                  "rounded-md px-2 py-[3px] text-[9.5px] font-bold uppercase tracking-[0.03em]",
                  @content_review
                ]}
              >
                {review_label(@record.content_review_status)}
              </span>
              <span
                title={dgettext("mishka_gervaz", "Technical Review")}
                class={[
                  "rounded-md px-2 py-[3px] text-[9.5px] font-bold uppercase tracking-[0.03em]",
                  @technical_review
                ]}
              >
                {review_label(@record.technical_review_status)}
              </span>
            </span>
          </div>
        </div>
      </div>

      <button
        :if={:expand in @static.features}
        type="button"
        phx-click="expand_row"
        phx-value-id={@record.id}
        phx-target={@myself}
        aria-expanded={to_string(@expanded?)}
        class={[
          "flex w-full items-center justify-center gap-[7px] border-t border-[#f4f3ee] p-2.5 text-[11.5px] font-semibold text-[#8a877f] transition-colors hover:bg-[#faf9f6] hover:text-[#5c5a54]",
          @expanded? && "bg-[#faf9f6]"
        ]}
      >
        {(@expanded? && dgettext("mishka_gervaz", "Hide Details")) ||
          dgettext("mishka_gervaz", "Advanced Details")}
        <.dynamic_component
          module={@static.ui_adapter}
          function={:icon}
          name="hero-chevron-down"
          class={"size-3.5 transition-transform #{if @expanded?, do: "rotate-180"}"}
        />
      </button>

      <.render_expanded :if={@expanded? and :expand in @static.features} state={@state} />
    </div>
    """
  end

  defp render_expanded(assigns) do
    ~H"""
    <div class="border-t border-[#f0efea] bg-[#fbfbfa] p-5">
      <%= case @state.expanded_data do %>
        <% %AsyncResult{ok?: true, result: html} when not is_nil(html) -> %>
          {html}
        <% %AsyncResult{failed: failed} when not is_nil(failed) -> %>
          <div class="py-4 text-center text-[12px] font-medium text-[#a8a5a0]">
            {dgettext("mishka_gervaz", "Could not load details")}
          </div>
        <% _ -> %>
          <div class="flex items-center justify-center gap-2.5 py-6">
            <span class="size-4 animate-spin rounded-full border-2 border-[#e0ddd6] border-t-[#5b57d6]" />
            <span class="text-[12px] font-medium text-[#8a877f]">
              {dgettext("mishka_gervaz", "Loading details…")}
            </span>
          </div>
      <% end %>
    </div>
    """
  end

  @doc """
  The chips between "Documentation" and the section's own title — its ancestors, nearest last.

  `breadcrumb_path` is a field-policy gated calculation, so it arrives as `%Ash.NotLoaded{}` for a
  viewer who cannot see it; that reads as a section with no ancestors rather than taking the card down.
  """
  @spec crumbs(map()) :: [String.t()]
  def crumbs(%{breadcrumb_path: path}) when is_list(path) do
    Enum.flat_map(path, fn
      %{"title" => title} when is_binary(title) -> [title]
      _crumb -> []
    end)
  end

  def crumbs(_record), do: []

  @doc "The version a section was last changed in, falling back to the attribute's own default."
  @spec version(map()) :: String.t()
  def version(%{change_version: version}) when is_binary(version) and version != "", do: version
  def version(_record), do: "0.0.1"

  @doc """
  The one-line taste of the section's content the card shows.

  Kept to a single line by the design, so it is cut at a line's length and left for CSS to ellipsise.
  """
  @preview_length 160

  @spec preview(map()) :: String.t() | nil
  def preview(%{content: content}) when is_binary(content) do
    case String.trim(content) do
      "" -> nil
      trimmed -> String.slice(trimmed, 0, @preview_length)
    end
  end

  def preview(_record), do: nil

  @doc """
  How many drafts of this section are still waiting on a review — content and technical together.

  Both are aggregates behind the same field policy as the calculations, so either can arrive unloaded.
  """
  @spec pending_drafts(map()) :: non_neg_integer()
  def pending_drafts(record) do
    count(record, :pending_section_draft_content_review_count) +
      count(record, :pending_section_draft_technical_review_count)
  end

  @doc "One aggregate or calculation off the record, or 0 when the viewer cannot see it."
  @spec count(map(), atom()) :: non_neg_integer()
  def count(record, key) do
    case Map.get(record, key) do
      value when is_integer(value) and value >= 0 -> value
      _unloaded -> 0
    end
  end

  @doc "The colours a review-status badge wears, falling back to `:pending` — the attribute's default."
  @spec review(atom()) :: String.t()
  def review(status) when is_map_key(@reviews, status), do: @reviews[status]
  def review(_status), do: @reviews.pending

  @doc "The words a review-status badge reads, in the viewer's language."
  @spec review_label(atom()) :: String.t()
  def review_label(:approved), do: dgettext("mishka_gervaz", "Approved")
  def review_label(:pending), do: dgettext("mishka_gervaz", "Pending")
  def review_label(:rejected), do: dgettext("mishka_gervaz", "Rejected")
  def review_label(:needs_revision), do: dgettext("mishka_gervaz", "Needs revision")
  def review_label(:archived), do: dgettext("mishka_gervaz", "Archived")
  def review_label(status), do: to_string(status)

  defp inserted_on(%{inserted_at: at})
       when is_struct(at, DateTime) or is_struct(at, NaiveDateTime),
       do: Localized.date(at, :yMMMd)

  defp inserted_on(_record), do: "—"

  @impl true
  def render_loading(assigns), do: Shared.loading(assigns)
end
