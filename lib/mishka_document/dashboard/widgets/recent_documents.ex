defmodule MishkaDocument.Dashboard.Widgets.RecentDocuments do
  @moduledoc """
  Dashboard widget (a `dashboard:widgets` plugin): the most recently updated workspaces, each with its
  status badge, one-line description, maintainer, section count, latest version and language — read
  through the `Workspace` `:master_read` (tenancy-bypassing) action. A master sees every site's
  workspaces; a tenant admin only its own site's. Author, section count and latest version come from
  the resource's own `:maintainers_info`, `:health_metrics` calculations and its versions, all loaded
  on the same read: `:master_versions` for a master, `:tenant_versions` for a tenant admin. Offered
  to holders of `admin:dashboard:document:section`, who read workspaces to reach their sections;
  that area is the only gate on what it reads.

  How many workspaces the list holds is the viewer's own setting — the card's gear in customize
  mode, or Settings → Documents → Dashboard widgets, both writing the same per-user row
  (`MishkaCmsCore.Dashboard.Widget.set_config/4`).

  See `MishkaCmsCore.Dashboard.Widget` for the shared card primitives.
  """
  use MishkaInstaller.Event.Hook, event: "dashboard:widgets", initial: %{priority: 92}
  use Gettext, backend: MishkaCmsCore.Gettext
  import Phoenix.Component
  require Ash.Query

  alias MishkaCmsCore.Dashboard.Widget
  alias MishkaDocument.{Workspace, WorkspaceVersion}

  @count %{
    key: "count",
    type: :integer,
    label: gettext_noop("Documents to show"),
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
        id: "doc-recent",
        priority: 110,
        pubsub: [MishkaDocument.Workspace, MishkaDocument.WorkspaceVersion],
        title: gettext_noop("Recent documents"),
        component: {__MODULE__, :render},
        size: 3,
        permission: ["admin:dashboard:document:section"],
        icon: "hero-document",
        link: "/admin/dashboard/document",
        settings_category: "document",
        config: [@count]
      })

    widget
  end

  @doc """
  Loads this widget's data off the dashboard render (in a Task), scoped to the viewer and sized by
  their own "Documents to show" setting. Called as `load/1` (a direct call, no dashboard) it uses
  the declared default.
  """
  def load(user, config \\ %{}) do
    scope = Widget.scope(user)

    %{results: workspaces} =
      Workspace
      |> Ash.Query.for_read(:master_read, %{}, actor: user, tenant: scope, authorize?: false)
      |> scope_filter(scope)
      |> Ash.Query.sort(updated_at: :desc)
      |> Ash.Query.load([:health_metrics, :maintainers_info, versions_load(scope, user)])
      |> Ash.read!(page: [limit: Map.get(config, @count.key, @count.default)], authorize?: false)

    %{workspaces: workspaces}
  end

  defp versions_load(nil, user), do: {:master_versions, latest_version(:read_any, nil, user)}

  defp versions_load(site_id, user),
    do: {:tenant_versions, latest_version(:read, site_id, user)}

  defp latest_version(action, tenant, user) do
    WorkspaceVersion
    |> Ash.Query.for_read(action, %{}, actor: user, tenant: tenant, authorize?: false)
    |> Ash.Query.sort(inserted_at: :desc)
    |> Ash.Query.limit(1)
  end

  def render(assigns) do
    ~H"""
    <Widget.card_header
      icon="hero-document"
      tone={:gray}
      title={gettext("Recent documents")}
      subtitle={gettext("Recently updated workspaces")}
    />
    <div :for={w <- @data.workspaces} class="flex items-start gap-3 border-b border-[#f4f3ef] py-3">
      <span class="grid size-[38px] shrink-0 place-items-center rounded-[10px] bg-[#f4f3ef] text-[#9a968d]">
        <span class="hero-document-text size-[17px]" />
      </span>
      <div class="min-w-0 flex-1">
        <div class="flex items-center gap-2">
          <span :if={w.featured} class="hero-star-solid size-3 shrink-0 text-[#cf8a24]" />
          <span class="min-w-0 flex-1 truncate text-[13px] font-semibold text-[#1b1a18]">
            {w.name}
          </span>
          <Widget.badge label={status_label(w.status)} tone={status_tone(w.status)} />
          <span class="shrink-0 text-[10.5px] font-medium text-[#a8a5a0]">
            {Widget.relative_time(w.updated_at)}
          </span>
        </div>
        <div :if={w.description} class="mt-1 line-clamp-1 text-[11.5px] font-medium text-[#8a877f]">
          {w.description}
        </div>
        <div class="mt-2 flex flex-wrap items-center gap-x-2 gap-y-1.5 text-[#a8a5a0]">
          <span
            :if={author_name(w)}
            id={"recent-document-author-#{w.id}"}
            class="text-[11px] font-semibold text-[#5c5a54]"
          >
            {author_name(w)}
          </span>
          <span :if={author_name(w)} class="size-[3px] rounded-full bg-[#d5d2c9]" />
          <span class="inline-flex items-center gap-1 text-[11px] font-medium">
            <span class="hero-bars-3-bottom-left size-3" />{sections_count(w)}
          </span>
          <span :if={latest_version(w)} class="size-[3px] rounded-full bg-[#d5d2c9]" />
          <span
            :if={latest_version(w)}
            class="font-['Space_Grotesk'] text-[10.5px] font-semibold text-[#8a877f]"
          >
            {latest_version(w)}
          </span>
          <span :if={language_label(w)} class="size-[3px] rounded-full bg-[#d5d2c9]" />
          <span
            :if={language_label(w)}
            class="font-['Space_Grotesk'] text-[9px] font-bold uppercase tracking-[0.05em] text-[#a8a5a0]"
          >
            {language_label(w)}
          </span>
        </div>
      </div>
    </div>
    <Widget.empty
      :if={@data.workspaces == []}
      icon="hero-document-text"
      message={gettext("No documents yet.")}
    />
    <Widget.card_footer link={@widget.link} label={gettext("View all")} />
    """
  end

  defp scope_filter(query, nil), do: query
  defp scope_filter(query, site_id), do: Ash.Query.filter(query, site_id == ^site_id)

  defp author_name(%{maintainers_info: %{"maintainers" => [%{"name" => name} | _]}})
       when is_binary(name),
       do: name

  defp author_name(_workspace), do: nil

  defp sections_count(%{health_metrics: %{sections_count: n}}) when is_integer(n), do: n
  defp sections_count(_workspace), do: 0

  defp latest_version(%{master_versions: [%{version_number: v} | _]}) when is_binary(v),
    do: version_label(v)

  defp latest_version(%{tenant_versions: [%{version_number: v} | _]}) when is_binary(v),
    do: version_label(v)

  defp latest_version(_workspace), do: nil

  defp version_label("v" <> _rest = version), do: version
  defp version_label(version), do: "v" <> version

  defp language_label(%{language: l}) when is_binary(l) and l != "", do: String.upcase(l)
  defp language_label(_workspace), do: nil

  defp status_label(:active), do: gettext("active")
  defp status_label(:draft), do: gettext("draft")
  defp status_label(:archived), do: gettext("archived")
  defp status_label(status), do: to_string(status)

  defp status_tone(:active), do: :green
  defp status_tone(:draft), do: :gray
  defp status_tone(:archived), do: :amber
  defp status_tone(_status), do: :gray
end
