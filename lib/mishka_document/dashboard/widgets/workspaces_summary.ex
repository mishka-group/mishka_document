defmodule MishkaDocument.Dashboard.Widgets.WorkspacesSummary do
  @moduledoc """
  Dashboard widget (a `dashboard:widgets` plugin): the full-width dark "Documents" summary panel —
  a docstats row of totals for workspaces, versions, sections, section drafts, issues, note drafts,
  and the set of primary languages. Every total is counted through each resource's `:master_read`
  (tenancy-bypassing) action via `Ash.count!/2`, scoped by `Widget.scope/1`: a master counts every
  site's documents, a tenant admin only its own site's. Offered to holders of
  `admin:dashboard:document:workspace`, which is the only gate on what it counts.

  Unlike the white list/stat widgets this one renders its OWN dark shell (bleeding to the card edges
  with `-m-5`) instead of `Widget.card_header`/`Widget.card_footer`.
  """
  use MishkaInstaller.Event.Hook, event: "dashboard:widgets", initial: %{priority: 96}
  use Gettext, backend: MishkaCmsCore.Gettext
  import Phoenix.Component
  require Ash.Query

  alias MishkaCmsCore.Dashboard.Widget
  alias MishkaDocument.{Issue, NoteDraft, Section, SectionDraft, Workspace, WorkspaceVersion}
  alias Phoenix.LiveView.JS

  # Languages beyond this many collapse behind a "+N" chip that reveals them on click.
  @max_lang_chips 4

  @impl true
  def call(%{widgets: widgets} = data), do: {:reply, %{data | widgets: widgets ++ [widget()]}}

  @doc "This widget's descriptor."
  @spec widget() :: Widget.t()
  def widget do
    {:ok, widget} =
      Widget.builder(%{
        id: "doc-workspaces-summary",
        priority: 130,
        pubsub: [
          MishkaDocument.Workspace,
          MishkaDocument.WorkspaceVersion,
          MishkaDocument.Section,
          MishkaDocument.SectionDraft,
          MishkaDocument.Issue,
          MishkaDocument.NoteDraft
        ],
        title: gettext_noop("Workspaces"),
        component: {__MODULE__, :render},
        permission: ["admin:dashboard:document:workspace"],
        icon: "hero-folder",
        size: 6,
        variant: :panel,
        link: "/admin/dashboard/document"
      })

    widget
  end

  @doc "Loads this widget's data off the dashboard render (in a Task), scoped to the viewer."
  def load(user) do
    scope = Widget.scope(user)

    %{
      total: count(Workspace, scope),
      versions: count(WorkspaceVersion, scope),
      sections: count(Section, scope),
      section_drafts: count(SectionDraft, scope),
      issues: open_issue_count(scope),
      note_drafts: count(NoteDraft, scope),
      languages: languages(scope)
    }
  end

  def render(assigns) do
    {shown, rest} = Enum.split(assigns.data.languages, @max_lang_chips)
    assigns = assign(assigns, shown: shown, rest: rest)

    ~H"""
    <div
      data-accent-panel
      class="flex h-full flex-col rounded-[18px] bg-[linear-gradient(120deg,#1f1e22,#17161a)] px-[26px] py-[22px] shadow-[0_1px_2px_rgba(30,28,24,0.04)] [[data-theme=dark]_&]:[filter:invert(1)_hue-rotate(180deg)]"
    >
      <div class="flex flex-wrap items-center gap-[14px]">
        <div class="flex min-w-0 shrink-0 items-center gap-3">
          <span class="grid size-10 shrink-0 place-items-center rounded-[11px] bg-[rgba(109,105,230,0.22)] text-[#a6a2f5]">
            <span class="hero-folder size-[19px]" />
          </span>
          <div>
            <div class="font-['Space_Grotesk'] text-[15px] font-semibold text-white">
              {gettext("Documents")}
            </div>
            <div class="mt-px text-[11.5px] font-medium text-[#9795a0]">
              {gettext("Across all sites & workspaces")}
            </div>
          </div>
        </div>
        <div class="flex-1"></div>
        <div class="flex shrink-0 flex-wrap items-stretch">
          <div
            :for={
              {value, label, tone} <- [
                {@data.total, gettext("Workspaces"), :white},
                {@data.versions, gettext("Versions"), :white},
                {@data.sections, gettext("Sections"), :white},
                {@data.section_drafts, gettext("Section drafts"), :amber},
                {@data.issues, gettext("Issues"), :red},
                {@data.note_drafts, gettext("Note drafts"), :amber}
              ]
            }
            class="border-s border-[rgba(255,255,255,0.09)] px-5"
          >
            <div class={[
              "font-['Space_Grotesk'] text-[27px] font-semibold leading-none tracking-[-0.03em]",
              num_tone(tone)
            ]}>
              {value}
            </div>
            <div class="mt-[5px] text-[10.5px] font-medium text-[#9795a0]">{label}</div>
          </div>
          <div class="border-s border-[rgba(255,255,255,0.09)] px-5">
            <div class="flex items-baseline gap-[7px]">
              <span class="font-['Space_Grotesk'] text-[27px] font-semibold leading-none tracking-[-0.03em] text-[#8ee0b8]">
                {length(@data.languages)}
              </span>
              <span id={"#{@widget.id}-langs"} class="flex flex-wrap items-center gap-1">
                <span :for={code <- @shown} class={lang_chip()}>{code}</span>
                <span :for={code <- @rest} data-lang-rest class={[lang_chip(), "hidden"]}>
                  {code}
                </span>
                <button
                  :if={@rest != []}
                  type="button"
                  phx-click={toggle_langs(@widget.id)}
                  title={gettext("Show the other languages")}
                  class={[
                    lang_chip(),
                    "cursor-pointer transition hover:bg-[rgba(255,255,255,0.16)] hover:text-white"
                  ]}
                >
                  <span data-lang-more>+{length(@rest)}</span>
                  <span data-lang-less class="hidden">−</span>
                </button>
              </span>
            </div>
            <div class="mt-2 text-[10.5px] font-medium text-[#9795a0]">
              {gettext("Languages")}
            </div>
          </div>
        </div>
        <.link
          navigate={@widget.link || "#"}
          class="shrink-0 ps-2 text-xs font-semibold text-[#9795a0] transition hover:text-white"
        >
          {gettext("View all")} →
        </.link>
      </div>
    </div>
    """
  end

  defp lang_chip,
    do:
      "rounded-[5px] bg-[rgba(255,255,255,0.08)] px-[5px] py-0.5 text-[8.5px] font-bold tracking-[0.04em] text-[#c9c7d1]"

  # Reveals the collapsed language chips and swaps the button's "+N" for a "−", client-side.
  defp toggle_langs(id) do
    JS.toggle_class("hidden", to: "##{id}-langs [data-lang-rest]")
    |> JS.toggle_class("hidden", to: "##{id}-langs [data-lang-more]")
    |> JS.toggle_class("hidden", to: "##{id}-langs [data-lang-less]")
  end

  defp num_tone(:amber), do: "text-[#e6c477]"
  defp num_tone(:red), do: "text-[#f2a79f]"
  defp num_tone(_), do: "text-white"

  defp count(resource, scope) do
    resource
    |> Ash.Query.for_read(:master_read, %{}, authorize?: false)
    |> scope_filter(scope)
    |> Ash.count!(authorize?: false)
  end

  defp open_issue_count(scope) do
    Issue
    |> Ash.Query.for_read(:master_read, %{}, authorize?: false)
    |> scope_filter(scope)
    |> Ash.Query.filter(status in [:open, :in_progress])
    |> Ash.count!(authorize?: false)
  end

  defp languages(scope) do
    Workspace
    |> Ash.Query.for_read(:master_read, %{}, authorize?: false)
    |> scope_filter(scope)
    |> Ash.Query.select([:language])
    |> Ash.stream!(authorize?: false, stream_with: :offset)
    |> Stream.map(& &1.language)
    |> Stream.reject(&(&1 in [nil, ""]))
    |> Stream.map(&String.upcase/1)
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp scope_filter(query, nil), do: query
  defp scope_filter(query, site_id), do: Ash.Query.filter(query, site_id == ^site_id)
end
