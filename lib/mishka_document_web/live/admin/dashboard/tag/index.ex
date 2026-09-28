defmodule MishkaDocumentWeb.Live.Admin.Dashboard.Tag.Index do
  use MishkaCmsCore.ExtensionLiveView

  alias MishkaCmsCore.Accounts.User
  alias MishkaGervaz.Table.Web.UrlSync

  @impl true
  def mount(_params, _session, socket) do
    current_user = socket.assigns.current_user

    socket =
      socket
      |> assign(:page_title, gettext("Document Tags"))
      |> assign(:url_state, nil)
      |> subscribe_to_pubsub(current_user)

    {:ok, socket}
  end

  @impl true
  def handle_params(params, uri, socket) do
    url_state = UrlSync.decode(params, uri, MishkaDocument.Tag)
    {:noreply, assign(socket, :url_state, url_state)}
  end

  defp subscribe_to_pubsub(socket, %User{site_id: nil}) do
    Phoenix.PubSub.subscribe(MishkaCmsCore.PubSub, "tag:created")
    Phoenix.PubSub.subscribe(MishkaCmsCore.PubSub, "tag:updated")
    Phoenix.PubSub.subscribe(MishkaCmsCore.PubSub, "tag:destroyed")
    socket
  end

  defp subscribe_to_pubsub(socket, %User{site_id: site_id}) when is_binary(site_id) do
    Phoenix.PubSub.subscribe(MishkaCmsCore.PubSub, "tag:#{site_id}:created")
    Phoenix.PubSub.subscribe(MishkaCmsCore.PubSub, "tag:#{site_id}:updated")
    Phoenix.PubSub.subscribe(MishkaCmsCore.PubSub, "tag:#{site_id}:destroyed")
    socket
  end

  defp subscribe_to_pubsub(socket, _), do: socket

  defp close_form_modal(socket) do
    js = MishkaCmsCore.CoreComponents.hide_modal("document-tag-form-modal")

    push_event(socket, "gervaz:exec-js", %{
      target: "document-tag-form-modal",
      js: Jason.encode!(js.ops)
    })
  end

  @impl true
  def handle_info({:form_saved, :create, _result}, socket) do
    {:noreply,
     socket
     |> close_form_modal()
     |> put_flash(:info, gettext("Tag created successfully"))}
  end

  @impl true
  def handle_info({:form_saved, :update, _result}, socket) do
    {:noreply,
     socket
     |> close_form_modal()
     |> put_flash(:info, gettext("Tag updated successfully"))}
  end

  @impl true
  def handle_info({:form_cancelled, _resource}, socket) do
    {:noreply, close_form_modal(socket)}
  end

  @impl true
  def handle_info({:row_action, _event, _payload}, socket), do: {:noreply, socket}

  @impl true
  def handle_info({:show_modal, _record}, socket), do: {:noreply, socket}

  @impl true
  def handle_info(
        %Phoenix.Socket.Broadcast{
          topic: "tag" <> _,
          payload: %Ash.Notifier.Notification{} = notification
        },
        socket
      ) do
    send_update(MishkaGervaz.Table.Web.Live,
      id: "tags-table",
      pubsub_notification: notification
    )

    {:noreply, socket}
  end

  @impl true
  def handle_info({:put_flash, kind, message}, socket) do
    {:noreply, put_flash(socket, kind, message)}
  end

  @impl true
  def handle_info(_msg, socket), do: {:noreply, socket}
end
