defmodule MishkaDocumentWeb.Live.Admin.Dashboard.WorkspaceVersion.Index do
  use MishkaCmsCore.ExtensionLiveView

  alias MishkaCmsCore.Accounts.User
  alias MishkaGervaz.Table.Web.UrlSync

  @impl true
  def mount(%{"id" => workspace_id}, _session, socket) do
    current_user = socket.assigns.current_user
    workspace = load_workspace(current_user, workspace_id)

    socket =
      socket
      |> assign(:page_title, gettext("Workspace Versions"))
      |> assign(:workspace_id, workspace_id)
      |> assign(:workspace, workspace)
      |> assign(:url_state, nil)
      |> subscribe_to_pubsub(current_user)

    {:ok, socket}
  end

  @impl true
  def handle_params(params, uri, socket) do
    url_state = UrlSync.decode(params, uri, MishkaDocument.WorkspaceVersion)
    {:noreply, assign(socket, :url_state, url_state)}
  end

  defp subscribe_to_pubsub(socket, %User{site_id: nil}) do
    Phoenix.PubSub.subscribe(MishkaCmsCore.PubSub, "workspace_version:created")
    Phoenix.PubSub.subscribe(MishkaCmsCore.PubSub, "workspace_version:updated")
    Phoenix.PubSub.subscribe(MishkaCmsCore.PubSub, "workspace_version:destroyed")
    socket
  end

  defp subscribe_to_pubsub(socket, %User{site_id: site_id}) when is_binary(site_id) do
    Phoenix.PubSub.subscribe(
      MishkaCmsCore.PubSub,
      "workspace_version:#{site_id}:created"
    )

    Phoenix.PubSub.subscribe(
      MishkaCmsCore.PubSub,
      "workspace_version:#{site_id}:updated"
    )

    Phoenix.PubSub.subscribe(
      MishkaCmsCore.PubSub,
      "workspace_version:#{site_id}:destroyed"
    )

    socket
  end

  defp subscribe_to_pubsub(socket, _), do: socket

  defp close_form_modal(socket) do
    js = MishkaCmsCore.CoreComponents.hide_modal("workspace-version-form-modal")

    push_event(socket, "gervaz:exec-js", %{
      target: "workspace-version-form-modal",
      js: Jason.encode!(js.ops)
    })
  end

  @impl true
  def handle_info({:form_saved, :create, _result}, socket) do
    {:noreply,
     socket
     |> close_form_modal()
     |> put_flash(:info, gettext("Workspace version created successfully"))}
  end

  @impl true
  def handle_info({:form_saved, :update, _result}, socket) do
    {:noreply,
     socket
     |> close_form_modal()
     |> put_flash(:info, gettext("Workspace version updated successfully"))}
  end

  @impl true
  def handle_info({:form_cancelled, _resource}, socket) do
    {:noreply, close_form_modal(socket)}
  end

  @impl true
  def handle_info({:row_action, _event, _payload}, socket), do: {:noreply, socket}

  @impl true
  def handle_info({:show_modal, _id}, socket), do: {:noreply, socket}

  @impl true
  def handle_info(
        %Phoenix.Socket.Broadcast{
          topic: "workspace_version" <> _,
          payload: %Ash.Notifier.Notification{data: data} = notification
        },
        socket
      ) do
    if Map.get(data, :workspace_id) == socket.assigns.workspace_id do
      send_update(MishkaGervaz.Table.Web.Live,
        id: "workspace-versions-table",
        pubsub_notification: notification
      )
    end

    {:noreply, socket}
  end

  @impl true
  def handle_info({:put_flash, kind, message}, socket) do
    {:noreply, put_flash(socket, kind, message)}
  end

  @impl true
  def handle_info(_msg, socket), do: {:noreply, socket}

  defp load_workspace(%User{site_id: nil} = user, workspace_id) do
    case Ash.get(MishkaDocument.Workspace, workspace_id, action: :master_get, actor: user) do
      {:ok, workspace} -> workspace
      _ -> nil
    end
  end

  defp load_workspace(%User{site_id: site_id} = user, workspace_id) when is_binary(site_id) do
    case Ash.get(MishkaDocument.Workspace, workspace_id,
           action: :read,
           actor: user,
           tenant: site_id
         ) do
      {:ok, workspace} -> workspace
      _ -> nil
    end
  end

  defp load_workspace(_, _), do: nil
end
