defmodule MishkaDocument.Dashboard.Widgets.OpenIssues do
  @moduledoc """
  Dashboard widget (a `dashboard:widgets` plugin): open documentation issues — an open-count stat
  plus the latest few, each with its issue-type badge, read through the `Issue` `:master_read`
  (tenancy-bypassing) action filtered to `status == :open`. A master sees every site's issues; a
  tenant admin only its own site's. Offered to holders of `admin:dashboard:document:section`, which
  is the only gate on what it reads.

  How many issues the list holds is the viewer's own setting — the card's gear in customize mode, or
  Settings → Documents → Dashboard widgets, both writing the same per-user row
  (`MishkaCmsCore.Dashboard.Widget.set_config/4`); the open count in the header always counts them
  all.
  """
  use MishkaInstaller.Event.Hook, event: "dashboard:widgets", initial: %{priority: 90}
  use Gettext, backend: MishkaCmsCore.Gettext
  import Phoenix.Component
  require Ash.Query

  alias MishkaCmsCore.Dashboard.Widget
  alias MishkaDocument.Issue

  @count %{
    key: "count",
    type: :integer,
    label: gettext_noop("Issues to list"),
    default: 5,
    min: 1,
    max: 12
  }

  @impl true
  def call(%{widgets: widgets} = data), do: {:reply, %{data | widgets: widgets ++ [widget()]}}

  @doc "This widget's descriptor."
  @spec widget() :: Widget.t()
  def widget do
    {:ok, widget} =
      Widget.builder(%{
        id: "doc-open-issues",
        priority: 90,
        pubsub: [MishkaDocument.Issue],
        title: gettext_noop("Open issues"),
        component: {__MODULE__, :render},
        permission: ["admin:dashboard:document:section"],
        icon: "hero-exclamation-triangle",
        size: 2,
        link: "/admin/dashboard/document/issues",
        settings_category: "document",
        config: [@count]
      })

    widget
  end

  @doc """
  Loads this widget's data off the dashboard render (in a Task), scoped to the viewer and sized by
  their own "Issues to list" setting. Called as `load/1` (a direct call, no dashboard) it uses the
  declared default.
  """
  def load(user, config \\ %{}) do
    open =
      Issue
      |> Ash.Query.for_read(:master_read, %{}, authorize?: false)
      |> scope_filter(Widget.scope(user))
      |> Ash.Query.filter(status == :open)

    %{results: latest} =
      open
      |> Ash.Query.sort(inserted_at: :desc)
      |> Ash.read!(page: [limit: Map.get(config, @count.key, @count.default)], authorize?: false)

    %{count: Ash.count!(open, authorize?: false), latest: latest}
  end

  def render(assigns) do
    ~H"""
    <Widget.card_header icon="hero-exclamation-triangle" tone={:red} title={gettext("Open issues")}>
      <:right>
        <span class="font-['Space_Grotesk'] text-[20px] font-semibold text-[#17161a]">
          {@data.count}
        </span>
      </:right>
    </Widget.card_header>
    <div
      :for={i <- @data.latest}
      class="flex items-center gap-[11px] border-t border-[#f4f3ef] py-[9px]"
    >
      <span class={["h-[26px] w-[3px] shrink-0 rounded-[2px]", issue_bar(i.issue_type)]} />
      <div class="min-w-0 flex-1">
        <div class="truncate text-[12px] font-medium text-[#3a382f]">{i.title}</div>
        <div class={[
          "mt-0.5 text-[9.5px] font-semibold uppercase tracking-[0.04em]",
          issue_text(i.issue_type)
        ]}>
          {issue_type_label(i.issue_type)}
        </div>
      </div>
      <span class="shrink-0 text-[11px] font-medium text-[#a8a5a0]">
        {Widget.relative_time(i.inserted_at)}
      </span>
    </div>
    <Widget.empty
      :if={@data.latest == []}
      icon="hero-check-circle"
      message={gettext("No open issues.")}
    />
    <Widget.card_footer link={@widget.link} label={gettext("View all")} border={false} />
    """
  end

  defp scope_filter(query, nil), do: query
  defp scope_filter(query, site_id), do: Ash.Query.filter(query, site_id == ^site_id)

  defp issue_type_label(:typo), do: gettext("Typo")
  defp issue_type_label(:broken_link), do: gettext("Broken link")
  defp issue_type_label(:incorrect_content), do: gettext("Incorrect content")
  defp issue_type_label(:suggestion), do: gettext("Suggestion")
  defp issue_type_label(:review_feedback), do: gettext("Review feedback")
  defp issue_type_label(:other), do: gettext("Other")
  defp issue_type_label(type), do: Phoenix.Naming.humanize(type)

  defp issue_bar(:broken_link), do: "bg-[#d5544b]"
  defp issue_bar(:suggestion), do: "bg-[#5b57d6]"
  defp issue_bar(:review_feedback), do: "bg-[#5b57d6]"
  defp issue_bar(:typo), do: "bg-[#3b6fd4]"
  defp issue_bar(_type), do: "bg-[#cf8a24]"

  defp issue_text(:broken_link), do: "text-[#b3433a]"
  defp issue_text(:suggestion), do: "text-[#4f4bcc]"
  defp issue_text(:review_feedback), do: "text-[#4f4bcc]"
  defp issue_text(:typo), do: "text-[#3b6fd4]"
  defp issue_text(_type), do: "text-[#a5691a]"
end
