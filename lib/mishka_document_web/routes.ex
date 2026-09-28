defmodule MishkaDocumentWeb.Routes do
  @moduledoc """
  Extension routes for MishkaDocument.
  """

  @behaviour MishkaCmsCore.ExtensionRouter

  @impl true
  def routes(:admin) do
    [
      {:live, "/document", MishkaDocumentWeb.Live.Admin.Dashboard.Home.Index, :index},
      {:live, "/document/workspace-version/:id",
       MishkaDocumentWeb.Live.Admin.Dashboard.WorkspaceVersion.Index, :index},
      {:live, "/document/sections/workspace/:workspace_id",
       MishkaDocumentWeb.Live.Admin.Dashboard.Section.Index, :workspace_redirect},
      {:live, "/document/sections/:workspace_version_id",
       MishkaDocumentWeb.Live.Admin.Dashboard.Section.Index, :index},
      {:live, "/document/tags", MishkaDocumentWeb.Live.Admin.Dashboard.Tag.Index, :index}
    ]
  end

  def routes(:public), do: []
  def routes(:api), do: []
  def routes(_), do: []
end
