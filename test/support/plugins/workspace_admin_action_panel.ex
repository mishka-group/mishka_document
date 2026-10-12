defmodule MishkaDocument.Test.Plugins.WorkspaceAdminActionPanel do
  @moduledoc """
  The LiveComponent `MishkaDocument.Test.Plugins.WorkspaceAdminAction`'s action opens: draws what
  the screen hands it, and each message the screen passes on to it.
  """
  use Phoenix.LiveComponent

  @impl true
  def mount(socket), do: {:ok, assign(socket, heard: [])}

  @impl true
  def update(%{info: message}, socket),
    do: {:ok, assign(socket, :heard, socket.assigns.heard ++ [inspect(message)])}

  def update(assigns, socket), do: {:ok, assign(socket, assigns)}

  @impl true
  def render(assigns) do
    ~H"""
    <div id="probe-panel">
      <span id="probe-panel-site">{@site_id}</span>
      <span id="probe-panel-workspace">{@workspace.slug}</span>
      <span id="probe-panel-version">{@version && @version.version_number}</span>
      <span id="probe-panel-greeting">{@greeting}</span>
      <span id="probe-panel-user">{@current_user.id}</span>
      <span :for={{message, index} <- Enum.with_index(@heard)} id={"probe-panel-heard-#{index}"}>
        {message}
      </span>
    </div>
    """
  end
end
