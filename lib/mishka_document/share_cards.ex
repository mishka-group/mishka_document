defmodule MishkaDocument.ShareCards do
  @moduledoc """
  Which share card (`MishkaCmsCore.Runtime.ShareCard`) a documentation record shows: the kind of
  record its page shows (`MishkaDocument.Plugins.PageRecords`) and the captures that name it — what
  a page of that kind answers for (`MishkaDocument.Plugins.PageSeo`).

    * a document (`MishkaDocument.Workspace`), while it is active — its front page, `"docs:document"`
    * a page (`MishkaDocument.Section`), while both its reviews approve it and its document is
      active — `"docs:page"`, under its document's slug

  The after-save plugins (`MishkaDocument.Plugins.WorkspaceShareCard`,
  `MishkaDocument.Plugins.SectionShareCard`) hand it to `ShareCard.refresh/3`, and each record's
  edit modal to its Share image field. A record a reader cannot open shows none: `nil`.
  """

  require Ash.Query

  alias MishkaCmsCore.Runtime.Languages
  alias MishkaDocument.{Section, Workspace, WorkspaceVersion}

  @spec target(struct()) :: MishkaCmsCore.Runtime.ShareCard.target() | nil
  def target(%Workspace{status: :active, slug: slug, language: language}) when is_binary(slug),
    do: {:record, "docs:document", captures(%{"workspace" => slug}, language)}

  def target(
        %Section{
          content_review_status: :approved,
          technical_review_status: :approved,
          slug: slug
        } = section
      )
      when is_binary(slug) do
    case active_document(section) do
      nil ->
        nil

      document ->
        {:record, "docs:page",
         captures(%{"workspace" => document, "section" => slug}, section.language)}
    end
  end

  def target(_not_shown), do: nil

  # The slug of the active document a page belongs to, read as the system, as `PageSeo` reads it.
  defp active_document(%{workspace_version_id: id, site_id: site_id})
       when is_binary(id) and is_binary(site_id) do
    WorkspaceVersion
    |> Ash.Query.filter(id == ^id)
    |> Ash.Query.load(workspace: Ash.Query.select(Workspace, [:slug, :status]))
    |> Ash.read_one(tenant: site_id, authorize?: false)
    |> case do
      {:ok, %{workspace: %{status: :active, slug: slug}}} when is_binary(slug) -> slug
      _not_shown -> nil
    end
  end

  defp active_document(_section), do: nil

  defp captures(captures, language) when is_binary(language),
    do: Map.put(captures, Languages.capture(), language)

  defp captures(captures, _no_language), do: captures
end
