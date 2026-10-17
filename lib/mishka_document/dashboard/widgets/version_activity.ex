# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_document/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaDocument.Dashboard.Widgets.VersionActivity do
  @moduledoc """
  Dashboard widget (a `dashboard:widgets` plugin): the most recent workspace versions — workspace
  name, version number, and status badge — read as the viewer through
  `MishkaDocument.Dashboard.Scope` with the version's workspace loaded: `:master_workspace` for a
  master, `:workspace` for a site's admin. A master sees every site's versions, a site's admin only
  their own site's, and a viewer without a document area none. Offered to holders of
  `admin:dashboard:document:workspace`.

  How far back the timeline reaches is the viewer's own setting — the card's gear in customize mode,
  or Settings → Documents → Dashboard widgets, both writing the same per-user row
  (`MishkaCmsCore.Dashboard.Widget.set_config/4`); the total is always the whole history.
  """
  use MishkaInstaller.Event.Hook, event: "dashboard:widgets", initial: %{priority: 94}
  use Gettext, backend: MishkaCmsCore.Gettext
  import Phoenix.Component

  alias MishkaCmsCore.Dashboard.Widget
  alias MishkaDocument.Dashboard.Scope
  alias MishkaDocument.WorkspaceVersion

  @count %{
    key: "count",
    type: :integer,
    label: gettext_noop("Versions to show"),
    default: 12,
    min: 3,
    max: 30
  }

  @impl true
  def call(%{widgets: widgets} = data), do: {:reply, %{data | widgets: widgets ++ [widget()]}}

  @doc "This widget's descriptor."
  @spec widget() :: Widget.t()
  def widget do
    {:ok, widget} =
      Widget.builder(%{
        id: "doc-version-activity",
        priority: 120,
        pubsub: [MishkaDocument.WorkspaceVersion],
        title: gettext_noop("Version activity"),
        component: {__MODULE__, :render},
        permission: ["admin:dashboard:document:workspace"],
        icon: "hero-clock",
        size: 3,
        link: "/admin/dashboard/document/event-logs",
        settings_category: "document",
        config: [@count]
      })

    widget
  end

  @doc """
  Loads this widget's data off the dashboard render (in a Task), read as the viewer and sized by
  their own "Versions to show" setting. Called as `load/1` (a direct call, no dashboard) it uses the
  declared default.
  """
  def load(user, config \\ %{}) do
    versions =
      WorkspaceVersion
      |> Scope.query(user)
      |> Ash.Query.sort(inserted_at: :desc)
      |> Ash.Query.load(workspace_load(Widget.scope(user)))
      |> Scope.list(Map.get(config, @count.key, @count.default))

    %{versions: versions, total: WorkspaceVersion |> Scope.query(user) |> Scope.count()}
  end

  def render(assigns) do
    ~H"""
    <Widget.card_header icon="hero-share" tone={:violet} title={gettext("Version activity")} />
    <div :if={@data.versions != []} class="relative">
      <div class="absolute start-[7px] top-2 bottom-3 w-0.5 bg-[#f0efea]"></div>
      <div :for={v <- @data.versions} class="relative flex items-center gap-3 pb-4 ps-[27px]">
        <span class={[
          "absolute start-[3px] top-0.5 size-2.5 rounded-full border-2 border-white shadow-[0_0_0_2px_#f0efea]",
          dot_tone(v.status)
        ]}></span>
        <span class="min-w-0 flex-1 truncate text-[12.5px] font-medium text-[#3a382f]">
          {workspace_name(v)}
        </span>
        <span class="shrink-0 font-['Space_Grotesk'] text-[11px] font-semibold text-[#8a877f]">
          v{v.version_number}
        </span>
        <Widget.badge label={status_label(v.status)} tone={status_tone(v.status)} />
      </div>
    </div>
    <Widget.empty
      :if={@data.versions == []}
      icon="hero-clock"
      message={gettext("No version activity yet.")}
    />
    <Widget.card_footer link={@widget.link} label={gettext("View all")} />
    """
  end

  defp workspace_load(nil), do: :master_workspace
  defp workspace_load(_site_id), do: :workspace

  defp workspace_name(%{master_workspace: %{name: name}}) when is_binary(name), do: name
  defp workspace_name(%{workspace: %{name: name}}) when is_binary(name), do: name
  defp workspace_name(_version), do: gettext("Untitled workspace")

  defp status_label(:stable), do: gettext("Stable")
  defp status_label(:rc), do: gettext("Rc")
  defp status_label(:beta), do: gettext("Beta")
  defp status_label(:alpha), do: gettext("Alpha")
  defp status_label(:draft), do: gettext("Draft")
  defp status_label(:archived), do: gettext("Archived")
  defp status_label(status), do: Phoenix.Naming.humanize(status)

  defp status_tone(:stable), do: :emerald
  defp status_tone(:rc), do: :sky
  defp status_tone(:beta), do: :indigo
  defp status_tone(:alpha), do: :violet
  defp status_tone(:draft), do: :slate
  defp status_tone(:archived), do: :amber
  defp status_tone(_status), do: :slate

  defp dot_tone(:stable), do: "bg-[#1f9d6b]"
  defp dot_tone(:archived), do: "bg-[#cf8a24]"
  defp dot_tone(:rc), do: "bg-[#3b6fd4]"
  defp dot_tone(:beta), do: "bg-[#5b57d6]"
  defp dot_tone(:alpha), do: "bg-[#5b57d6]"
  defp dot_tone(_status), do: "bg-[#8a877f]"
end
