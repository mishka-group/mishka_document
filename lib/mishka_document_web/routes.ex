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
      {:live, "/document/tags", MishkaDocumentWeb.Live.Admin.Dashboard.Tag.Index, :index},
      {:live, "/document/issues", MishkaDocumentWeb.Live.Admin.Dashboard.Issue.Index, :index},
      {:live, "/document/section-drafts",
       MishkaDocumentWeb.Live.Admin.Dashboard.SectionDraft.Index, :index},
      {:live, "/document/note-drafts", MishkaDocumentWeb.Live.Admin.Dashboard.NoteDraft.Index,
       :index},
      {:live, "/document/event-logs", MishkaDocumentWeb.Live.Admin.Dashboard.EventLog.Index,
       :index}
    ]
  end

  def routes(:public), do: []
  def routes(:api), do: []
  def routes(_), do: []
end
