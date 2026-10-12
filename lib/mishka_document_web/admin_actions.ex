defmodule MishkaDocumentWeb.AdminActions do
  @moduledoc """
  The buttons plugins add to a document's admin screen — the Sections screen of a workspace,
  `/admin/dashboard/document/sections/:workspace_version_id` — through the
  `document:workspace:admin_actions` mishka_installer event. Each button opens the plugin's own
  LiveComponent in the screen's modal, one at a time.

  ## The event

  The screen fires it through `actions/2`, which calls `MishkaCmsCore.PluginEvent.call/3`, once it
  has loaded its document and again when another version is chosen — only for a reader who may
  manage that workspace (`admin:dashboard:document:workspace`); anyone else is shown no button and
  no plugin is asked. Each plugin is handed:

      %{
        site_id: "…",
        workspace: %{id: "…", slug: "chelekom", path: "/chelekom/docs", name: "Chelekom"},
        version: %{id: "…", version_number: "0.0.9"},
        actor: %MishkaCmsCore.Accounts.User{},
        actions: []
      }

  `version` is `nil` for a workspace with no version, and `path` is `nil` for a document read at
  its default address. The plugins are asked in the screen's process, so a plugin answers from what
  it has at hand and leaves slow work to its component. A plugin appends its actions to `actions`
  and replies with the map:

      use MishkaInstaller.Event.Hook, event: "document:workspace:admin_actions"

      def call(%{workspace: %{slug: "handbook"}, actions: actions} = state),
        do: {:reply, %{state | actions: actions ++ [action()]}}

      def call(state), do: {:reply, state}

  ## An action

      %{
        id: "handbook-export",
        label: gettext("Export"),
        icon: "hero-arrow-down-tray",
        component: MyPlugin.ExportPanel,
        assigns: %{format: :pdf}
      }

    * `:id` — lower-case letters, digits, `-` and `_`, starting with a letter or a digit; the
      first action with an id is kept.
    * `:label` — the button's words, already in the reader's language.
    * `:icon` — a Heroicon class name (`hero-…`), or `nil`.
    * `:component` — a `Phoenix.LiveComponent` module.
    * `:assigns` — a map with atom keys, handed to the component.

  An action of any other shape is left out. An event that cannot run shows no button.

  ## The component

  Rendered inside the modal, which the screen opens only for a reader who may manage the workspace,
  with the action's `:assigns` and these, which it cannot override:
  `:id` (`component_id/1`), `:site_id`, `:workspace`, `:version` and `:current_user`. While its
  modal is open, each message the screen does not handle itself is handed to it as
  `update(%{info: message}, socket)`: a component that subscribes to a PubSub topic hears it
  there. Closing the modal removes it.
  """

  alias MishkaCmsCore.PluginEvent

  @event "document:workspace:admin_actions"
  @id ~r/\A[a-z0-9][a-z0-9_-]*\z/
  @reserved [
    :id,
    :module,
    :site_id,
    :workspace,
    :version,
    :current_user,
    :myself,
    :flash,
    :socket
  ]

  @typedoc "One button on the screen and the component its modal draws."
  @type action :: %{
          id: String.t(),
          label: String.t(),
          icon: String.t() | nil,
          component: module(),
          assigns: map()
        }

  @typedoc "What the screen tells a plugin, and its component, about the document on screen."
  @type context :: %{
          site_id: String.t() | nil,
          workspace: %{
            id: String.t(),
            slug: String.t() | nil,
            path: String.t() | nil,
            name: String.t() | nil
          },
          version: %{id: String.t(), version_number: String.t() | nil} | nil
        }

  @doc "The event's name."
  @spec event() :: String.t()
  def event, do: @event

  @doc """
  What the screen tells a plugin about `workspace` and its `version` (`nil` for none): its site,
  and the fields of each named in the moduledoc.
  """
  @spec context(map(), map() | nil) :: context()
  def context(workspace, version) do
    %{
      site_id: workspace.site_id,
      workspace: Map.take(workspace, [:id, :slug, :path, :name]),
      version: version && Map.take(version, [:id, :version_number])
    }
  end

  @doc """
  The actions the plugins add for `context` (`context/2`) and `actor`, in the order the plugins
  answered; `[]` when the event cannot run.
  """
  @spec actions(context(), map() | nil) :: [action()]
  def actions(context, actor) do
    @event
    |> PluginEvent.call(Map.merge(context, %{actor: actor, actions: []}))
    |> case do
      %{actions: actions} when is_list(actions) ->
        actions |> Enum.flat_map(&action/1) |> Enum.uniq_by(& &1.id)

      _other ->
        []
    end
  end

  defp action(%{id: id, label: label, component: component} = action)
       when is_binary(id) and is_binary(label) and label != "" and is_atom(component) do
    icon = Map.get(action, :icon)
    assigns = Map.get(action, :assigns, %{})

    with true <- Regex.match?(@id, id),
         true <- is_nil(icon) or (is_binary(icon) and String.starts_with?(icon, "hero-")),
         true <- is_map(assigns) and Enum.all?(Map.keys(assigns), &is_atom/1),
         true <- live_component?(component) do
      [%{id: id, label: label, icon: icon, component: component, assigns: assigns}]
    else
      false -> []
    end
  end

  defp action(_other), do: []

  defp live_component?(module) do
    Code.ensure_loaded?(module) and function_exported?(module, :__live__, 0) and
      match?(%{kind: :component}, module.__live__())
  end

  @doc "The id the screen renders `action`'s component under, and sends its updates to."
  @spec component_id(action()) :: String.t()
  def component_id(%{id: id}), do: "document-admin-action-" <> id

  @doc """
  The assigns `action`'s component is rendered with, besides its module and `component_id/1`: the
  action's own, then the screen's `context` and `current_user` over them.
  """
  @spec assigns(action(), context(), map()) :: map()
  def assigns(%{assigns: assigns}, context, current_user) do
    assigns
    |> Map.drop(@reserved)
    |> Map.merge(context)
    |> Map.put(:current_user, current_user)
  end
end
