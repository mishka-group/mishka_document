defmodule MishkaDocumentWeb.Routes do
  @moduledoc """
  Extension routes for MishkaDocument.
  """

  @behaviour MishkaCmsCore.ExtensionRouter

  @impl true
  def routes(:admin) do
    [
      {:live, "/document", MishkaDocumentWeb.Live.Admin.Dashboard.Home.Index, :index}
    ]
  end

  def routes(:public), do: []
  def routes(:api), do: []
  def routes(_), do: []
end
