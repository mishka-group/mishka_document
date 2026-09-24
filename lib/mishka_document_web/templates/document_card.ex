defmodule MishkaDocumentWeb.Templates.DocumentCard do
  @moduledoc """
  The workspaces grid: a hero banner leading a card grid.

  Declared only by `MishkaDocument.Workspace`, and it reads that record directly rather than by column
  position — the design's cards are specific shapes (accent bar, completion track, stat tiles, tags,
  language editions) that a generic position mapping cannot describe.

  The page's first featured workspace wears the banner (`flagship_id/1`); every other one stays a card
  with its badge. A card's chrome is banded by how far along it is and its badges keep their language's
  colour (`MishkaDocument.WorkspaceAccent`), and it reaches its translations through the editions row —
  the list itself shows one row per document (`MishkaDocument.WorkspaceScope`).

  ## Features
  - `:filter` - the control row: archive switch, search, and a drawer holding the grouped filters
  - `:select` - card selection for bulk operations
  - `:bulk_actions` - bulk actions on selected cards
  - `:paginate` - numbered pagination under the grid

  ## Options
  - `:columns` - the *minimum card width* the grid's tracks are built from (2, 3, or 4)

  ## Performance
  Uses `@static.*` for columns, ui_adapter, etc. (no re-render on user interaction)
  Uses `@state.*` for page, filter_values, etc. (re-renders when changed)

  Pairs with `MishkaCmsCoreWeb.UIAdapters.Admin`, which draws the archive switch and the buttons.
  """

  use MishkaGervaz.Table.Behaviours.Template
  use MishkaGervaz.Messages, backend: MishkaCmsCore.Gettext

  import MishkaGervaz.Helpers, only: [dynamic_component: 1, accessible?: 2]

  alias MishkaCmsCore.LanguageEditions
  alias MishkaCmsCoreWeb.Templates.CardChrome, as: Shared
  alias MishkaCmsCore.Accounts.Checks.AccessPermissions
  alias MishkaDocument.WorkspaceAccent
  alias MishkaGervaz.Table.Templates.Shared, as: Gervaz

  @impl true
  def name, do: :document_card

  @impl true
  def label, do: dgettext("mishka_gervaz", "Document Cards")

  @impl true
  def icon, do: "hero-squares-2x2"

  @impl true
  def description, do: dgettext("mishka_gervaz", "Responsive card grid layout")

  @impl true
  def features do
    [:filter, :select, :bulk_actions, :paginate]
  end

  @impl true
  def default_options do
    [columns: 3]
  end

  @impl true
  def render(assigns) do
    static = assigns.static
    state = assigns.state
    features = static.features

    show_checkboxes =
      :select in features and
        static.bulk_actions != [] and
        Gervaz.has_visible_bulk_actions?(static.bulk_actions, state.archive_status)

    show_filters = static.filters != [] and :filter in features

    show_pagination =
      :paginate in features and is_integer(state.total_count) and state.total_count > 0

    show_bulk_actions = :bulk_actions in features and show_checkboxes

    assigns =
      assigns
      |> assign_new(:before_table, fn -> nil end)
      |> assign(:show_checkboxes, show_checkboxes)
      |> assign(:show_filters, show_filters)
      |> assign(:show_pagination, show_pagination)
      |> assign(:show_bulk_actions, show_bulk_actions)
      |> assign(:features, features)
      |> assign(:flagship_id, flagship_id(state))

    ~H"""
    <div class="mishka-gervaz-document-card">
      <div :if={@state.has_initial_data? or @state.loading == :loaded}>
        <.render_filters
          :if={@show_filters}
          static={@static}
          state={@state}
          before_table={@before_table}
          myself={@myself}
        />

        <.render_selection_toolbar
          :if={@show_checkboxes}
          static={@static}
          state={@state}
          myself={@myself}
        />

        <.render_bulk_actions
          :if={@show_bulk_actions}
          static={@static}
          state={@state}
          myself={@myself}
        />

        <div class="relative" style="isolation: isolate;">
          <Shared.loading_overlay
            :if={
              @state.has_initial_data? and @state.loading == :loading and
                @state.loading_type == :reset
            }
            text={@static.pagination_ui.loading_text}
          />

          <div
            id={"#{@static.stream_name}"}
            data-role="wsgrid"
            phx-update="stream"
            class={grid_classes(@static)}
          >
            <div
              id={"#{@static.stream_name}-empty-state"}
              class="hidden only:flex col-span-full flex-col items-center justify-center gap-3 py-11 text-center"
            >
              <span class="grid size-[52px] place-items-center rounded-[14px] bg-[#f2f1ec] text-[#a8a5a0]">
                <.dynamic_component
                  module={@static.ui_adapter}
                  function={:icon}
                  name={get_in(@static.config, [:empty_state, :icon]) || "hero-squares-2x2"}
                  class="size-6"
                />
              </span>
              <div class="font-['Space_Grotesk'] text-[14px] font-bold text-[#17161a]">
                {empty_message(@static.config)}
              </div>
            </div>
            <.render_item
              :for={{id, record} <- @stream}
              id={id}
              record={record}
              static={@static}
              state={@state}
              flagship_id={@flagship_id}
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

  @spec empty_message(map()) :: String.t()
  defp empty_message(config) do
    case get_in(config, [:empty_state, :message]) do
      message when is_binary(message) ->
        Gettext.dgettext(MishkaCmsCore.Gettext, "mishka_gervaz", message)

      _none ->
        dgettext("mishka_gervaz", "No records found")
    end
  end

  defp render_selection_toolbar(assigns) do
    checkbox_assigns =
      %{__changed__: %{}}
      |> assign(:id, "document-card-select-all")
      |> assign(:name, "select_all_document_card")
      |> assign(:value, "all")
      |> assign(:checked, assigns.state.select_all?)
      |> assign(:class, "gervaz-select-all-checkbox")
      |> assign(:label, dgettext("mishka_gervaz", "Select all"))

    toolbar_class =
      (assigns.static.theme && assigns.static.theme[:selection_toolbar_class]) ||
        "flex items-center gap-4 mb-4 py-2 px-3 bg-gray-50 rounded"

    assigns =
      assigns
      |> assign(:checkbox_assigns, checkbox_assigns)
      |> assign(:toolbar_class, toolbar_class)

    ~H"""
    <div class={@toolbar_class}>
      <.dynamic_component
        module={@static.ui_adapter}
        function={:checkbox}
        phx-click={Shared.toggle_all_js(@state.select_all?)}
        phx-target={@myself}
        {@checkbox_assigns}
      />
    </div>
    """
  end

  @doc """
  One workspace card, wearing two accents: its chrome is banded by how far along it is, its language
  badge and edition chips keep their language's colour, and archiving turns both grey
  (`MishkaDocument.WorkspaceAccent`).

  The page's *one* flagship gets the design's banner instead: full grid width, a gradient head and a
  progress ring rather than a bar. Every other featured workspace stays a card and keeps its badge —
  the design leads the grid with a single hero, and a wall of banners is not that grid.

  Unlike the generic card templates this one reads the record directly rather than by column position:
  it is declared only by `MishkaDocument.Workspace`, and the design's cards are specific shapes (accent
  bar, completion track, stat tiles, editions) that positions cannot describe.
  """
  @impl true
  def render_item(%{record: %{id: id}, flagship_id: id} = assigns) do
    assigns = card_assigns(assigns)

    ~H"""
    <div
      id={@id}
      data-role="wscard-flagship"
      class="relative col-span-full flex flex-col overflow-hidden rounded-[18px] border border-[#e1def6] bg-white shadow-[0_2px_5px_rgba(30,28,24,0.05)]"
    >
      <div class="relative overflow-hidden bg-[linear-gradient(135deg,#6d69e6,#4f46c9)] px-[22px] py-[18px]">
        <div class="absolute inset-0 opacity-[0.16] bg-[repeating-linear-gradient(45deg,#fff_0_1.5px,transparent_1.5px_13px)]">
        </div>
        <div class="relative flex items-center gap-[13px]">
          <div :if={@show_checkboxes} class="flex-none">
            <.dynamic_component
              module={@static.ui_adapter}
              function={:checkbox}
              phx-click="toggle_select"
              phx-value-id={@record.id}
              phx-target={@myself}
              {@checkbox_assigns}
            />
          </div>

          <span class="grid size-11 flex-none place-items-center rounded-xl border border-white/30 bg-white/15 text-white">
            <.dynamic_component
              module={@static.ui_adapter}
              function={:icon}
              name="hero-document-text"
              class="size-[21px]"
            />
          </span>

          <div class="min-w-0 flex-1">
            <div class="flex items-center gap-2">
              <span class="truncate font-['Space_Grotesk'] text-[20px] font-bold tracking-[-0.01em] text-white">
                {@record.name}
              </span>
              <span class="flex-none rounded-[20px] bg-white px-[7px] py-[3px] text-[8px] font-extrabold tracking-[0.1em] text-[#4f46c9]">
                {dgettext("mishka_gervaz", "FEATURED")}
              </span>
            </div>
            <div
              dir="ltr"
              class="mt-0.5 truncate font-['Space_Grotesk'] text-[11.5px] font-semibold text-white/80 rtl:text-right"
            >
              /{@record.slug}
            </div>
          </div>

          <span class="inline-flex flex-none items-center gap-[5px] rounded-[20px] border border-white/30 bg-white/20 px-2.5 py-[5px] text-[9px] font-bold uppercase tracking-[0.06em] text-white">
            <span class="size-1.5 rounded-full bg-[#8ef0bf]"></span>
            {status_label(@record)}
          </span>
        </div>
      </div>

      <div class="flex flex-wrap items-center gap-6 px-[22px] py-[18px]">
        <div class="min-w-[220px] flex-1">
          <div class="text-[12.5px] font-medium leading-[1.55] text-[#6d6a63]">
            {@record.description}
          </div>
          <div class="mt-[15px] flex items-center gap-4">
            <.flagship_stat value={@sections} label={dgettext("mishka_gervaz", "Sections")} />
            <span class="h-[26px] w-px bg-[#ecebe6]"></span>
            <.flagship_stat value={@versions} label={dgettext("mishka_gervaz", "Versions")} />
            <span class="h-[26px] w-px bg-[#ecebe6]"></span>
            <.flagship_stat
              value={@contributors}
              label={dgettext("mishka_gervaz", "Contributors")}
            />
          </div>
        </div>

        <div class="relative size-24 flex-none">
          <svg viewBox="0 0 96 96" class="size-24">
            <circle cx="48" cy="48" r="41" fill="none" stroke="#eeedfb" stroke-width="9" />
            <circle
              cx="48"
              cy="48"
              r="41"
              fill="none"
              stroke={@progress.stroke}
              stroke-width="9"
              stroke-linecap="round"
              stroke-dasharray="257.6"
              stroke-dashoffset={ring_offset(@completion)}
              transform="rotate(-90 48 48)"
            />
          </svg>
          <div class="absolute inset-0 flex flex-col items-center justify-center">
            <span class="font-['Space_Grotesk'] text-[20px] font-bold text-[#17161a]">
              {@completion}%
            </span>
            <span class="text-[8px] font-semibold uppercase tracking-[0.05em] text-[#a8a5a0]">
              {dgettext("mishka_gervaz", "Done")}
            </span>
          </div>
        </div>
      </div>

      <div :if={@editions != []} class="px-[22px] pt-0.5">
        <div class="flex items-center gap-[9px]">
          <span class="flex-none text-[9.5px] font-bold uppercase tracking-[0.06em] text-[#a8a5a0]">
            {dgettext("mishka_gervaz", "Language editions")}
          </span>
          <span class={[
            "inline-flex flex-none items-center gap-[5px] rounded-[20px] border px-2.5 py-1 text-[10px] font-bold",
            @accent.chip
          ]}>
            <span class={["size-[5px] rounded-full", @accent.fill]}></span>
            {String.upcase(@record.language || "")}
          </span>
          <.link
            :for={edition <- @editions_shown}
            navigate={edition_path(edition, @edition_view)}
            title={Shared.edition_title(edition)}
            class={[
              "inline-flex flex-none items-center gap-[5px] rounded-[20px] border px-2.5 py-1 text-[10px] font-bold transition-opacity hover:opacity-70",
              edition.accent.chip
            ]}
          >
            <span class={["size-[5px] rounded-full", edition.accent.fill]}></span>
            {String.upcase(edition.language)} · {edition.completion}%
          </.link>

          <button
            :if={@editions_rest != []}
            type="button"
            id={"#{@id}-editions-more"}
            phx-click={Shared.expand_editions(@id)}
            title={dgettext("mishka_gervaz", "Show every language")}
            class="inline-flex flex-none items-center rounded-[20px] border border-[#e0ddd6] bg-[#f4f3ef] px-2.5 py-1 text-[10px] font-bold text-[#6d6a63] transition-colors hover:bg-[#eceae4]"
          >
            +{length(@editions_rest)}
          </button>

          <button
            :if={@editions_rest != []}
            type="button"
            id={"#{@id}-editions-less"}
            phx-click={Shared.collapse_editions(@id)}
            title={dgettext("mishka_gervaz", "Show fewer languages")}
            class="hidden flex-none items-center rounded-[20px] border border-[#e0ddd6] bg-[#f4f3ef] px-3 py-1 text-[10px] font-bold leading-none text-[#6d6a63] transition-colors hover:bg-[#eceae4]"
          >
            −
          </button>
        </div>

        <div
          :if={@editions_rest != []}
          id={"#{@id}-editions-rest"}
          class="mt-2 hidden flex-wrap gap-[9px]"
        >
          <.link
            :for={edition <- @editions_rest}
            navigate={edition_path(edition, @edition_view)}
            title={Shared.edition_title(edition)}
            class={[
              "inline-flex items-center gap-[5px] rounded-[20px] border px-2.5 py-1 text-[10px] font-bold transition-opacity hover:opacity-70",
              edition.accent.chip
            ]}
          >
            <span class={["size-[5px] rounded-full", edition.accent.fill]}></span>
            {String.upcase(edition.language)} · {edition.completion}%
          </.link>
        </div>
      </div>

      <%!-- The banner has room, so every action here is spelled out: labels come back, the squares
            relax into white bordered buttons, and the primary sits at its own width. The actions and
            their classes are the resource's — the banner only overrides what its width buys. --%>
      <div
        :if={@visible_row_actions != []}
        class={[
          "px-[22px] pb-[18px] pt-3.5 [&>div]:flex [&>div]:flex-wrap [&>div]:gap-2",
          "[&>div>*]:flex-none [&_.lbl]:inline! [&>div>*]:gap-1.5 [&>div>*:first-child]:px-4",
          "[&>div>*:not(:first-child)]:size-auto [&>div>*:not(:first-child)]:h-9 [&>div>*:not(:first-child)]:px-3.5",
          "[&>div>*:not(:first-child)]:border-[#ecebe6] [&>div>*:not(:first-child)]:bg-white",
          "[&>div>*:not(:first-child)]:text-[12.5px] [&>div>*:not(:first-child)]:font-semibold",
          "[&>div>*:not(:first-child)]:text-[#5c5a54] [&>div>*:not(:first-child)]:hover:bg-[#f7f6f3]"
        ]}
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
    """
  end

  def render_item(assigns) do
    assigns = card_assigns(assigns)

    ~H"""
    <div
      id={@id}
      data-role="wscard"
      class={[
        "relative flex flex-col overflow-hidden rounded-2xl border p-[17px] shadow-[0_1px_2px_rgba(30,28,24,0.05)]",
        (@archived? && "border-[#e6e4df] bg-[#f8f7f4]") || "border-[#edece7] bg-white",
        @is_checked && "ring-2 ring-[#5b57d6]"
      ]}
    >
      <div class={["absolute inset-x-0 top-0 h-[3px]", @progress.bar]}></div>

      <div class="mb-[10px] flex flex-wrap items-center justify-end gap-[5px]">
        <span
          :if={@record.featured}
          class={[
            "rounded-[5px] px-1.5 py-[3px] text-[8px] font-extrabold tracking-[0.08em]",
            @progress.tile
          ]}
        >
          {dgettext("mishka_gervaz", "FEATURED")}
        </span>
        <span class={[
          "rounded-[5px] px-1.5 py-[3px] text-[8px] font-extrabold tracking-[0.08em]",
          @accent.tile
        ]}>
          {String.upcase(@record.language || "")}
        </span>
        <span class={[
          "inline-flex items-center gap-[5px] rounded-[20px] px-[9px] py-1 text-[8.5px] font-bold uppercase tracking-[0.05em]",
          @progress.tile
        ]}>
          <span class={["size-[5px] rounded-full", @progress.fill]}></span>
          {status_label(@record)}
        </span>
      </div>

      <div class="flex items-start gap-[11px]">
        <div :if={@show_checkboxes} class="flex-none pt-1">
          <.dynamic_component
            module={@static.ui_adapter}
            function={:checkbox}
            phx-click="toggle_select"
            phx-value-id={@record.id}
            phx-target={@myself}
            {@checkbox_assigns}
          />
        </div>

        <span class={["grid size-10 flex-none place-items-center rounded-[11px]", @progress.tile]}>
          <.dynamic_component
            module={@static.ui_adapter}
            function={:icon}
            name="hero-document-text"
            class="size-[19px]"
          />
        </span>

        <div class="min-w-0 flex-1">
          <div class={[
            "truncate text-[14.5px] font-bold",
            (@archived? && "text-[#6d6a63]") || "text-[#17161a]"
          ]}>
            {@record.name}
          </div>
          <div
            dir="ltr"
            class={[
              "mt-0.5 truncate font-['Space_Grotesk'] text-[11px] font-semibold rtl:text-right",
              @progress.solid
            ]}
          >
            /{@record.slug}
          </div>
        </div>
      </div>

      <div class={[
        "mt-3 min-h-[36px] text-[12px] font-medium leading-[1.55]",
        (@archived? && "text-[#9a978f]") || "text-[#6d6a63]"
      ]}>
        {@record.description}
      </div>

      <div class="mb-1.5 mt-[13px] flex items-center justify-between">
        <span class="text-[9.5px] font-semibold uppercase tracking-[0.05em] text-[#a8a5a0]">
          {dgettext("mishka_gervaz", "Completion")}
        </span>
        <span class={["font-['Space_Grotesk'] text-[12px] font-bold", @progress.solid]}>
          {@completion}%
        </span>
      </div>
      <div class={["h-1.5 overflow-hidden rounded", @progress.track]}>
        <div class={["h-full rounded", @progress.fill]} style={"width:#{@completion}%"}></div>
      </div>

      <div class="mt-3 flex items-center gap-2">
        <.stat_tile
          accent={@progress}
          archived?={@archived?}
          static={@static}
          icon="hero-bars-3-bottom-left"
          value={@sections}
          label={dgettext("mishka_gervaz", "sections")}
        />
        <.stat_tile
          accent={@progress}
          archived?={@archived?}
          static={@static}
          icon="hero-share"
          value={@versions}
          label={dgettext("mishka_gervaz", "versions")}
        />
      </div>

      <div :if={@tags != []} class="mt-[13px] flex min-h-[25px] flex-wrap gap-1.5">
        <span
          :for={tag <- @tags}
          class={["rounded-[7px] px-[9px] py-1 text-[10.5px] font-semibold", @progress.tile]}
        >
          {tag}
        </span>
      </div>

      <%!-- The label and the first chips share one line that never reflows: the rest open underneath
            rather than pushing the row they came from. --%>
      <div
        :if={@editions != []}
        class={[
          "mt-[13px] border-t pt-[13px]",
          (@archived? && "border-[#e7e5df]") || "border-[#f0efea]"
        ]}
      >
        <div class="flex items-center gap-2">
          <span class="flex-none text-[9px] font-bold uppercase tracking-[0.05em] text-[#a8a5a0]">
            {dgettext("mishka_gervaz", "Language editions")}
          </span>

          <%!-- The card names its own language first, as the banner does: a row reading only "FA" says
                which edition exists but not which one you are looking at. --%>
          <span class={[
            "inline-flex flex-none items-center gap-1 rounded-[20px] border px-2 py-[3px] text-[9.5px] font-bold",
            @accent.chip
          ]}>
            <span class={["size-1 rounded-full", @accent.fill]}></span>
            {String.upcase(@record.language || "")}
          </span>

          <.link
            :for={edition <- @editions_shown}
            navigate={edition_path(edition, @edition_view)}
            title={Shared.edition_title(edition)}
            class={[
              "inline-flex flex-none items-center gap-1 rounded-[20px] border px-2 py-[3px] text-[9.5px] font-bold transition-opacity hover:opacity-70",
              edition.accent.chip
            ]}
          >
            <span class={["size-1 rounded-full", edition.accent.fill]}></span>
            {String.upcase(edition.language)} · {edition.completion}%
          </.link>

          <button
            :if={@editions_rest != []}
            type="button"
            id={"#{@id}-editions-more"}
            phx-click={Shared.expand_editions(@id)}
            title={dgettext("mishka_gervaz", "Show every language")}
            class="inline-flex flex-none items-center rounded-[20px] border border-[#e0ddd6] bg-[#f4f3ef] px-2 py-[3px] text-[9.5px] font-bold text-[#6d6a63] transition-colors hover:bg-[#eceae4]"
          >
            +{length(@editions_rest)}
          </button>

          <button
            :if={@editions_rest != []}
            type="button"
            id={"#{@id}-editions-less"}
            phx-click={Shared.collapse_editions(@id)}
            title={dgettext("mishka_gervaz", "Show fewer languages")}
            class="hidden flex-none items-center rounded-[20px] border border-[#e0ddd6] bg-[#f4f3ef] px-2.5 py-[3px] text-[9.5px] font-bold leading-none text-[#6d6a63] transition-colors hover:bg-[#eceae4]"
          >
            −
          </button>
        </div>

        <div
          :if={@editions_rest != []}
          id={"#{@id}-editions-rest"}
          class="mt-[7px] hidden flex-wrap gap-[5px]"
        >
          <.link
            :for={edition <- @editions_rest}
            navigate={edition_path(edition, @edition_view)}
            title={Shared.edition_title(edition)}
            class={[
              "inline-flex items-center gap-1 rounded-[20px] border px-2 py-[3px] text-[9.5px] font-bold transition-opacity hover:opacity-70",
              edition.accent.chip
            ]}
          >
            <span class={["size-1 rounded-full", edition.accent.fill]}></span>
            {String.upcase(edition.language)} · {edition.completion}%
          </.link>
        </div>
      </div>

      <%!-- `min-w-0` on the row: the icon squares are `flex-none`, so the labelled primary is the only
            thing that can give width back, and a flex row will not let it below its own text unless
            the row itself may shrink. Without it the last icon is pushed off the card. --%>
      <div
        :if={@visible_row_actions != []}
        class="mt-[13px] [&>div]:flex [&>div]:min-w-0 [&>div]:gap-1.5"
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
    """
  end

  @doc """
  Which workspace on this page wears the banner: the first featured one, or nothing if none is.

  A stream never tells a row its position, but it does not have to — the page's own records are on
  `state.records_result`, which is where the stream's contents came from. Reading them here keeps the
  decision with the page rather than pushing a "first?" flag onto every record.

  Archived workspaces are skipped: the banner is a hero for live work, and a grey gradient reads as
  broken rather than as archived.
  """
  def flagship_id(%{records_result: %{result: %{data: %{results: records}}}})
      when is_list(records) do
    records
    |> Enum.find(&(Map.get(&1, :featured) == true and !archived?(&1)))
    |> then(&(&1 && &1.id))
  end

  def flagship_id(_state), do: nil

  # The editions row is one line that must not reflow. The card names its own language plus this many
  # siblings — two chips — and anything past that waits behind a "+N" the reader can open. A workspace
  # can be translated into as many languages as someone cares to add.
  @editions_shown 1

  # Everything both cards read off the record. Both shapes show the same workspace — only the drawing
  # differs — so neither reaches for the record directly.
  defp card_assigns(assigns) do
    %{record: record, state: state} = assigns

    checked? = Gervaz.record_checked?(state, record.id)

    checkbox_assigns =
      %{__changed__: %{}}
      |> assign(:name, "select_card")
      |> assign(:value, record.id)
      |> assign(:checked, checked?)
      |> assign(:class, "gervaz-media-checkbox size-4 cursor-pointer rounded")

    editions = editions(record)

    assigns
    |> assign(:accent, WorkspaceAccent.of(record))
    |> assign(:progress, WorkspaceAccent.for_progress(record))
    |> assign(:editions_shown, Enum.take(editions, @editions_shown))
    |> assign(:editions_rest, Enum.drop(editions, @editions_shown))
    |> assign(:archived?, archived?(record))
    |> assign(:is_checked, checked?)
    |> assign(:checkbox_assigns, checkbox_assigns)
    |> assign(:completion, completion(record))
    |> assign(:sections, metric(record, :sections_count))
    |> assign(:versions, versions_count(record))
    |> assign(:contributors, contributors(record))
    |> assign(:editions, editions(record))
    |> assign(:edition_view, edition_view(state))
    |> assign(:tags, tags(record))
    |> assign(
      :visible_row_actions,
      Enum.filter(assigns.static.row_actions, &Gervaz.action_visible?(&1, record, state))
    )
  end

  attr :value, :any, required: true
  attr :label, :string, required: true

  defp flagship_stat(assigns) do
    ~H"""
    <div>
      <div class="font-['Space_Grotesk'] text-[18px] font-bold text-[#17161a]">{@value}</div>
      <div class="text-[9.5px] font-semibold uppercase tracking-[0.05em] text-[#a8a5a0]">
        {@label}
      </div>
    </div>
    """
  end

  @doc """
  How much of the flagship's progress ring to leave undrawn.

  The ring is a 41px-radius circle, so its circumference is 2π×41 ≈ 257.6 — the dash length the design
  hard-codes. Offsetting by the *un*done share leaves the done share drawn.
  """
  def ring_offset(completion), do: Float.round(257.6 * (100 - completion) / 100, 1)

  attr :accent, :map, required: true
  attr :archived?, :boolean, required: true
  attr :static, :map, required: true
  attr :icon, :string, required: true
  attr :value, :any, required: true
  attr :label, :string, required: true

  defp stat_tile(assigns) do
    ~H"""
    <span class={[
      "flex flex-1 items-center gap-[7px] rounded-[9px] border px-2.5 py-[7px]",
      (@archived? && "border-[#e7e5df] bg-[#f2f1ec]") || "border-[#f0efea] bg-[#faf9f6]"
    ]}>
      <.dynamic_component
        module={@static.ui_adapter}
        function={:icon}
        name={@icon}
        class={["size-3.5", @accent.solid]}
      />
      <span class={[
        "font-['Space_Grotesk'] text-[13px] font-bold",
        (@archived? && "text-[#6d6a63]") || "text-[#17161a]"
      ]}>
        {@value}
      </span>
      <span class="text-[10.5px] font-semibold text-[#a8a5a0]">{@label}</span>
    </span>
    """
  end

  @doc "The words a workspace's status pill reads, in the viewer's language."
  @spec status_label(map()) :: String.t()
  def status_label(%{status: :active}), do: dgettext("mishka_gervaz", "Active")
  def status_label(%{status: :draft}), do: dgettext("mishka_gervaz", "Draft")
  def status_label(%{status: :archived}), do: dgettext("mishka_gervaz", "Archived")
  def status_label(%{status: status}), do: to_string(status)

  @doc "Whether a workspace reads as archived — by its status or by having been archived."
  def archived?(%{status: :archived}), do: true
  def archived?(%{archived_at: at}) when not is_nil(at), do: true
  def archived?(_record), do: false

  @doc """
  How far along the workspace is, 0–100.

  `health_metrics` is field-policy gated, so it arrives as `%Ash.NotLoaded{}` for a viewer who cannot
  see it — every read here has to survive that rather than take the page down with it.
  """
  def completion(record), do: metric(record, :completion)

  @doc "One `health_metrics` figure, or 0 when the viewer cannot see the calculation."
  def metric(%{health_metrics: metrics}, key) when is_map(metrics), do: Map.get(metrics, key, 0)
  def metric(_record, _key), do: 0

  @doc "How many versions the workspace has, from the `versions_count` aggregate."
  def versions_count(%{versions_count: count}) when is_integer(count), do: count
  def versions_count(_record), do: 0

  @doc """
  How many people have touched the workspace. `maintainers_info` reads the event log and is gated the
  same way `health_metrics` is, and it keys its count by string.
  """
  def contributors(%{maintainers_info: info}) when is_map(info), do: Map.get(info, "count", 0)
  def contributors(_record), do: 0

  @doc """
  The tag chips the card carries, from the `tag_names` aggregate.

  A workspace has no tags of its own — its sections do — so this is a list of names gathered three
  relationships away, and it can arrive unloaded like any other aggregate. Sorted so a card's chips
  keep their order between renders, and capped: the design gives the row one line, and a workspace
  with forty tags would push everything below it off the card.
  """
  @tag_limit 3

  def tags(%{tag_names: names}) when is_list(names) do
    names |> Enum.reject(&is_nil/1) |> Enum.uniq() |> Enum.sort() |> Enum.take(@tag_limit)
  end

  def tags(_record), do: []

  @doc """
  The workspace's sibling editions — the same document in other languages.

  The collapsing rule and the self-join are `MishkaCmsCore.LanguageEditions`', shared with every other
  translatable admin list. What is workspace-specific is only what a chip shows beyond its language:
  its own accent, and how far along that edition is, so the chip can read `FA · 76%`.
  """
  @spec editions(map()) :: [map()]
  def editions(record) do
    LanguageEditions.editions(
      record,
      &%{completion: completion(&1), accent: WorkspaceAccent.of(&1)}
    )
  end

  @doc """
  Which page an edition chip opens for the table's viewer: the edition's sections for a section
  admin, its versions for a workspace admin — the page its card's own actions open for them.
  """
  @spec edition_view(map()) :: :sections | :versions
  def edition_view(%{current_user: user}) do
    if AccessPermissions.match?(user, %{}, permissions: ["admin:dashboard:document:section"]),
      do: :sections,
      else: :versions
  end

  def edition_view(_state), do: :versions

  @doc """
  Where an edition chip goes: that language's own workspace, on the page `edition_view/1` names. The
  list only shows masters, so this is the only way to reach a translation without searching for it.
  """
  @spec edition_path(map(), :sections | :versions) :: String.t()
  def edition_path(%{id: id}, :sections), do: "/admin/dashboard/document/sections/workspace/#{id}"
  def edition_path(%{id: id}, :versions), do: "/admin/dashboard/document/workspace-version/#{id}"

  # Opening the row is a client-side class flip, not a round trip: the chips are already rendered, and
  # a stream row's expanded state must not depend on the server remembering it. Every id is scoped by
  # the row's own DOM id so one card's toggle cannot reach another's.
  # `hidden` alone cannot hide a button that also carries `inline-flex` — both set `display`, and which
  # one wins is down to their order in the stylesheet, not the order they were added. So each toggle
  # takes the display class off as well as putting `hidden` on.
  @impl true
  def render_loading(assigns) do
    loading_text =
      (assigns[:static] && assigns.static.pagination_ui.loading_text) ||
        dgettext("mishka_gervaz", "Loading...")

    assigns = assign(assigns, :loading_text, loading_text)

    ~H"""
    <div class="flex items-center justify-center gap-2.5 py-12 text-[12.5px] font-semibold text-[#6d6a63]">
      <span class="size-4 animate-spin rounded-full border-2 border-[#e0ddd6] border-t-[#5b57d6]" />
      {@loading_text}
    </div>
    """
  end

  @doc """
  The panel's control row: the archive switch, the search box, and a drawer holding every filter the
  resource grouped. Nothing here names a filter — a `:text` filter becomes the search box and the rest
  follow their group, so the resource stays the single source of truth.

  The `phx-change="filter"` form, the input names and `clear_filters` are Gervaz's contract; only the
  look is ours. The archive switch comes from the ui_adapter (`MishkaCmsCoreWeb.UIAdapters.Admin`).
  """
  @impl true
  def render_filters(assigns) do
    # `accessible?/2` is what keeps a `restricted` filter (the site picker) away from a tenant, and
    # `merge_relation_filter_state/2` is what gives a relation filter its searched-for options. Laying
    # the filters out ourselves does not mean re-deciding either.
    all_filters =
      Gervaz.merge_relation_filter_state(
        assigns.static.filters,
        assigns.state.relation_filter_state || %{}
      )

    {search, drawer} =
      all_filters
      |> Enum.filter(&accessible?(&1, assigns.state))
      |> Enum.split_with(&(&1.type == :text))

    assigns =
      assigns
      |> assign(:all_filters, all_filters)
      |> assign(:search, List.first(search))
      |> assign(:drawer, drawer)
      |> assign(:active_filters?, map_size(assigns.state.filter_values || %{}) > 0)

    ~H"""
    <div class="mb-[18px] flex flex-wrap items-start justify-between gap-4">
      <%!-- The panel's title, handed in by the page. It rides in the control row because the design
            puts them on one line, and only this template knows where that line is. --%>
      <div :if={@before_table}>{render_slot(@before_table)}</div>

      <div class="flex flex-wrap items-center justify-end gap-2.5 max-[560px]:justify-start!">
        <.dynamic_component
          :if={@state.supports_archive}
          module={@static.ui_adapter}
          function={:archive_toggle}
          table_id={@static.id}
          archive_status={@state.archive_status}
          myself={@myself}
        />

        <form
          :if={@search || @drawer != []}
          id={"#{@static.stream_name}-filter"}
          phx-change="filter"
          phx-target={@myself}
          class="relative flex flex-wrap items-center justify-end gap-2.5 max-[560px]:justify-start!"
        >
          <div :if={@search} class="relative">
            <.dynamic_component
              module={@static.ui_adapter}
              function={:icon}
              name="hero-magnifying-glass"
              class="pointer-events-none absolute start-[11px] top-1/2 size-[15px] -translate-y-1/2 text-[#a8a5a0]"
            />
            <input
              type="text"
              name={@search.name}
              value={Map.get(@state.filter_values, @search.name) || ""}
              dir="auto"
              placeholder={search_placeholder(@search)}
              phx-debounce="300"
              class="h-[38px] w-[200px] max-w-full rounded-[10px] border border-[#ecebe6] bg-[#f7f6f3] ps-[34px] pe-3 text-[12.5px] font-medium text-[#1b1a18] outline-none focus:border-[#c3c1f0]"
            />
          </div>

          <%!-- The drawer is the user's to open, as the design has it: binding `open` to whether any
              filter is set would snap it shut the moment they cleared the last one. --%>
          <details :if={@drawer != []} class="group relative max-[560px]:static!">
            <summary class="flex h-[38px] cursor-pointer list-none items-center gap-[7px] rounded-[10px] border border-[#ecebe6] bg-white px-3.5 text-[12.5px] font-semibold text-[#3a382f] transition-colors hover:bg-[#f7f6f3] [&::-webkit-details-marker]:hidden">
              <.dynamic_component
                module={@static.ui_adapter}
                function={:icon}
                name="hero-funnel"
                class="size-3.5 text-[#8a877f]"
              />
              {dgettext("mishka_gervaz", "Filter")}
              <.dynamic_component
                module={@static.ui_adapter}
                function={:icon}
                name="hero-chevron-down"
                class="size-[13px] text-[#a8a5a0] transition-transform group-open:rotate-180"
              />
            </summary>

            <div class="absolute end-0 z-30 mt-2 w-[min(92vw,520px)] rounded-[14px] border border-[#ecebe6] bg-[#faf9f6] p-[18px] shadow-[0_8px_24px_rgba(30,28,24,0.10)] max-[560px]:start-0! max-[560px]:end-0! max-[560px]:w-auto!">
              <div class="grid grid-cols-2 gap-[18px] max-[560px]:grid-cols-1!">
                <div :for={filter <- @drawer}>
                  <div class="mb-[9px] text-[10px] font-bold uppercase tracking-[0.07em] text-[#a8a5a0]">
                    {filter_label(filter)}
                  </div>
                  <Gervaz.render_filter
                    filter={filter}
                    all_filters={@all_filters}
                    state={@state}
                    static={@static}
                    myself={@myself}
                  />
                </div>
              </div>

              <button
                :if={@active_filters?}
                type="button"
                phx-click="clear_filters"
                phx-target={@myself}
                class="mt-4 inline-flex h-[30px] cursor-pointer items-center gap-1.5 rounded-lg border border-[#ecebe6] bg-white px-[11px] text-[11.5px] font-semibold text-[#5c5a54] transition-colors hover:bg-[#f7f6f3]"
              >
                <.dynamic_component
                  module={@static.ui_adapter}
                  function={:icon}
                  name="hero-x-mark"
                  class="size-[13px] text-[#a8a5a0]"
                />
                {dgettext("mishka_gervaz", "Clear filters")}
              </button>
            </div>
          </details>
        </form>
      </div>
    </div>
    """
  end

  defp search_placeholder(filter) do
    MishkaGervaz.Helpers.resolve_label(filter.ui && filter.ui.placeholder) ||
      dgettext("mishka_gervaz", "Search…")
  end

  defp filter_label(filter) do
    MishkaGervaz.Helpers.resolve_label(filter.ui && filter.ui.label) ||
      MishkaGervaz.Messages.translate_text(Phoenix.Naming.humanize(filter.name))
  end

  @doc """
  The count on the left, the page buttons on the right, under the grid.

  `prev_page` / `next_page` / `go_to_page` and every figure here are Gervaz's — only the look is ours.
  A resource that asked for `:load_more` or `:infinite` instead keeps the shared pagination, which is
  the only thing that knows how to draw those.
  """
  @impl true
  def render_pagination(assigns) do
    pagination_type = Gervaz.pagination_type(assigns.static)
    assigns = assign(assigns, :pagination_type, pagination_type)

    if pagination_type == :numbered and is_integer(assigns.state.total_pages) do
      render_numbered_pagination(assigns)
    else
      Gervaz.render_pagination(assigns)
    end
  end

  defp render_numbered_pagination(assigns) do
    %{page: page, total_pages: total_pages} = assigns.state
    page_size = assigns.state.current_page_size || assigns.static.page_size

    assigns =
      assigns
      |> assign(:page, page)
      |> assign(:total_pages, total_pages)
      |> assign(:pages, Shared.page_window(page, total_pages))
      |> assign(:shown, shown_count(assigns.state.total_count, page, page_size))

    ~H"""
    <div class="mt-[18px] flex flex-wrap items-center justify-between gap-3">
      <span class="text-[12px] font-medium text-[#a8a5a0]">
        {dgettext("mishka_gervaz", "Showing %{count}", count: @shown)} · {dgettext(
          "mishka_gervaz",
          "Page %{page} of %{total}",
          page: @page,
          total: @total_pages
        )}
      </span>

      <div :if={@total_pages > 1} class="flex items-center gap-1.5">
        <button
          type="button"
          phx-click="prev_page"
          phx-target={@myself}
          disabled={@page <= 1}
          class="h-[34px] rounded-[9px] border border-[#ecebe6] bg-white px-[13px] text-[12px] font-semibold text-[#5c5a54] transition-colors hover:bg-[#f7f6f3] disabled:cursor-default disabled:text-[#a8a5a0] disabled:hover:bg-white"
        >
          {@static.pagination_ui.prev_label || dgettext("mishka_gervaz", "Previous")}
        </button>

        <%= for entry <- @pages do %>
          <%= case entry do %>
            <% :gap -> %>
              <span class="px-1 text-[12px] font-semibold text-[#a8a5a0]">…</span>
            <% number -> %>
              <button
                type="button"
                phx-click="go_to_page"
                phx-value-page={number}
                phx-target={@myself}
                aria-current={number == @page && "page"}
                class={[
                  "size-[34px] rounded-[9px] font-['Space_Grotesk'] text-[12px] font-bold transition-colors",
                  (number == @page &&
                     "bg-[linear-gradient(140deg,#6d69e6,#4f4bcc)] text-white") ||
                    "border border-[#ecebe6] bg-white text-[#5c5a54] hover:bg-[#f7f6f3]"
                ]}
              >
                {number}
              </button>
          <% end %>
        <% end %>

        <button
          type="button"
          phx-click="next_page"
          phx-target={@myself}
          disabled={@page >= @total_pages}
          class="h-[34px] rounded-[9px] border border-[#ecebe6] bg-white px-[13px] text-[12px] font-semibold text-[#5c5a54] transition-colors hover:bg-[#f7f6f3] disabled:cursor-default disabled:text-[#a8a5a0] disabled:hover:bg-white"
        >
          {@static.pagination_ui.next_label || dgettext("mishka_gervaz", "Next")}
        </button>
      </div>
    </div>
    """
  end

  # How many cards are under your eyes right now — the last page holds the remainder, not a full page.
  # The design counts what it shows, not what the table holds; the total has its own place.
  defp shown_count(total, page, page_size)
       when is_integer(total) and is_integer(page) and is_integer(page_size) do
    total |> Kernel.-((page - 1) * page_size) |> max(0) |> min(page_size)
  end

  defp shown_count(_total, _page, page_size), do: page_size

  # Private helpers

  # The design's grid is intrinsic, not a fixed column count: cards are at least 290px wide and as many
  # fit as will, so `:columns` reads as the *minimum card width* the track is built from.
  defp grid_classes(static) do
    options = static.template_options || default_options()
    custom_class = Keyword.get(options, :class)

    ["grid items-start gap-3.5", track_class(Keyword.get(options, :columns, 3)), custom_class]
    |> Enum.filter(& &1)
  end

  # WHOLE CLASS NAMES, one clause per column count, because Tailwind's scanner reads SOURCE TEXT.
  # This was `"grid-cols-[…minmax(min(100%,#{min_width})…]"` with the width interpolated in, which
  # hands the scanner a string with a hole in it: no rule was generated for any of the three widths,
  # `grid-template-columns` never applied, and every card stretched to the full row instead of
  # tiling three across.
  #
  # It looked correct until recently only because the admin was styled by the in-browser Tailwind
  # JIT, which reads classes off the rendered DOM and so never cared how they were assembled. The
  # admin is served a compiled `admin.css` now (`mix admin_css`), and a class that exists only after
  # interpolation has nothing to find. Any class built from a variable has to be written out like
  # this — or, where the value set is genuinely open, declared with `@source inline(...)` in that task.
  defp track_class(2), do: "grid-cols-[repeat(auto-fill,minmax(min(100%,380px),1fr))]"
  defp track_class(4), do: "grid-cols-[repeat(auto-fill,minmax(min(100%,230px),1fr))]"
  defp track_class(_columns), do: "grid-cols-[repeat(auto-fill,minmax(min(100%,290px),1fr))]"
end
