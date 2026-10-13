defmodule MishkaDocument.ShareCards do
  @moduledoc """
  Which share card (`MishkaCmsCore.Runtime.ShareCard`) a documentation record shows: the kind of
  record its page shows (`MishkaDocument.Plugins.PageRecords`) and the captures that name it — what
  a page of that kind answers for (`MishkaDocument.Plugins.PageSeo`).

    * a document (`MishkaDocument.Workspace`), while it is active — its front page, `"docs:document"`
    * a page (`MishkaDocument.Section`), while both its reviews approve it, its version is published
      and its document is active — `"docs:page"`, under its document's slug, at its own part of the
      address: the slugs of the pages it is drawn under among its version's approved pages, then its
      own (`MishkaDocument.Address`). A version's front page shows none of its own: it is drawn at
      its document's address, whose card is the document's. A group shows none: it is only a
      heading in the contents, with no page of its own — unless it has one (`group_page`), which
      shows its own at its own address.

  A page of a version other than the one a reader is shown with no `?v=` is named with its `"v"`
  (`MishkaDocument.Address.version_query/2`): its card shows its own version.

  The after-save plugins (`MishkaDocument.Plugins.WorkspaceShareCard`,
  `MishkaDocument.Plugins.SectionShareCard`) hand `target/1` to `ShareCard.refresh/3`, and each
  record's edit modal to its Share image field. A record a reader cannot open shows none: `nil`.
  `targets/1` names every card of a site, for `MishkaDocument.Plugins.ShareCardTargets`.
  """

  require Ash.Query

  alias MishkaCmsCore.Runtime.Compilers.SitemapCompiler
  alias MishkaCmsCore.Runtime.Languages
  alias MishkaDocument.{Address, Section, Workspace, WorkspaceVersion}

  # The most documents whose versions are read together.
  @documents 50

  # The most versions whose pages are read together.
  @versions 20

  @version_fields [
    :id,
    :workspace_id,
    :version_number,
    :is_latest_for_version,
    :published_at,
    :inserted_at
  ]

  @tree_fields [
    :id,
    :slug,
    :parent_section_id,
    :front_page,
    :group_heading,
    :group_page,
    :workspace_version_id
  ]

  @spec target(struct()) :: MishkaCmsCore.Runtime.ShareCard.target() | nil
  def target(%Workspace{status: :active, slug: slug, language: language}) when is_binary(slug),
    do: {:record, "docs:document", captures(%{"workspace" => slug}, language)}

  def target(%Section{front_page: true}), do: nil
  def target(%Section{group_heading: true, group_page: page?}) when page? != true, do: nil

  def target(
        %Section{
          content_review_status: :approved,
          technical_review_status: :approved,
          slug: slug
        } = section
      )
      when is_binary(slug) do
    case shown_in(section) do
      nil ->
        nil

      {document, query} ->
        {:record, "docs:page",
         %{"workspace" => document, "section" => address_of(section)}
         |> captures(section.language)
         |> Map.merge(query)}
    end
  end

  def target(_not_shown), do: nil

  @doc """
  Every share card of the site `site_id` a visitor who is not signed in can reach, as `target/1`
  names them: each active document's front page in its own language, once for each of its
  published versions, and each approved page of each of those versions at its own address. Only
  documents in a language the site lists (`MishkaCmsCore.Runtime.Languages.site/1`); a document
  that names a permission, and a page that opens with one, are left out
  (`MishkaDocument.Resources.Preparations.OpenToActor`).

  A lazy stream of `{:record, kind, captures}`: the documents are read #{@documents} at a time in
  `id` order, their versions in one read a batch, and the ids, slugs and parents of the pages of
  #{@versions} versions at a time. `[]` for no site.
  """
  @spec targets(String.t() | nil) :: Enumerable.t()
  def targets(site_id) when is_binary(site_id) do
    languages = Languages.site(site_id)

    Workspace
    |> Ash.Query.for_read(:public_list, %{}, actor: nil, tenant: site_id)
    |> Ash.Query.filter(language in ^languages and not is_nil(slug))
    |> Ash.Query.select([:id, :slug, :language])
    |> SitemapCompiler.stream_rows(actor: nil, tenant: site_id)
    |> Stream.chunk_every(@documents)
    |> Stream.flat_map(&batch_targets(site_id, &1))
  end

  def targets(_no_site), do: []

  # A batch of documents: each front page once for each version a reader reaches, then the pages of
  # those versions.
  defp batch_targets(site_id, documents) do
    versions = site_id |> published_versions(documents) |> Enum.group_by(& &1.workspace_id)

    editions =
      for document <- documents,
          {version, query} <- editions(Map.get(versions, document.id, [])),
          do: {document, version, query}

    fronts =
      for {document, _version, query} <- editions,
          do:
            {:record, "docs:document",
             %{"workspace" => document.slug}
             |> captures(document.language)
             |> Map.merge(query)}

    pages =
      editions
      |> Enum.filter(fn {_document, version, _query} -> version end)
      |> Stream.chunk_every(@versions)
      |> Stream.flat_map(&page_targets(site_id, &1))

    Stream.concat(fronts, pages)
  end

  # Each published version with the query a reader reaches it at; a document with none is read at
  # its front page alone, with none.
  defp editions([]), do: [{nil, %{}}]

  defp editions(versions) do
    for version <- versions,
        query = Address.version_query(version, versions),
        is_map(query),
        do: {version, query}
  end

  defp published_versions(site_id, documents) do
    ids = Enum.map(documents, & &1.id)

    WorkspaceVersion
    |> Ash.Query.for_read(:public_list, %{}, actor: nil, tenant: site_id)
    |> Ash.Query.filter(workspace_id in ^ids)
    |> Ash.Query.select(@version_fields)
    |> Ash.read!(actor: nil, tenant: site_id, page: false)
  end

  # The pages of these versions, each at its own part of its version's address; a version's front
  # page is its document's, named with it.
  defp page_targets(site_id, editions) do
    ids = Enum.map(editions, fn {_document, version, _query} -> version.id end)

    trees =
      Section
      |> Ash.Query.for_read(:public_list, %{}, actor: nil, tenant: site_id)
      |> Ash.Query.filter(workspace_version_id in ^ids)
      |> Ash.Query.select(@tree_fields)
      |> Ash.read!(actor: nil, tenant: site_id, page: false)
      |> Enum.group_by(& &1.workspace_version_id)

    for {document, version, query} <- editions,
        {_id, [_ | _] = segments} <- Address.paths(Map.get(trees, version.id, [])),
        do:
          {:record, "docs:page",
           %{"workspace" => document.slug, "section" => Enum.join(segments, "/")}
           |> captures(document.language)
           |> Map.merge(query)}
  end

  # The slug of the active document a page belongs to and the query its version is reached at, read
  # as the system, as `PageSeo` reads them; `nil` when no reader reaches it.
  defp shown_in(%{workspace_version_id: id, site_id: site_id})
       when is_binary(id) and is_binary(site_id) do
    WorkspaceVersion
    |> Ash.Query.filter(id == ^id)
    |> Ash.Query.select([:id, :workspace_id, :version_number])
    |> Ash.Query.load(
      workspace:
        Workspace
        |> Ash.Query.select([:slug, :status])
        |> Ash.Query.load(versions: Ash.Query.select(WorkspaceVersion, @version_fields))
    )
    |> Ash.read_one(tenant: site_id, authorize?: false)
    |> case do
      {:ok, %{workspace: %{status: :active, slug: slug, versions: versions}} = version}
      when is_binary(slug) ->
        case Address.version_query(version, versions) do
          nil -> nil
          query -> {slug, query}
        end

      _not_shown ->
        nil
    end
  end

  defp shown_in(_section), do: nil

  # The slugs of the pages a page is drawn under, then its own, as a `*section` capture holds them:
  # its place among its version's approved pages, read as the system, as `PageSeo` reads them.
  defp address_of(%{id: id, workspace_version_id: version_id, site_id: site_id} = section) do
    pages =
      Section
      |> Ash.Query.for_read(:public_list, %{}, tenant: site_id, authorize?: false)
      |> Ash.Query.filter(workspace_version_id == ^version_id and id != ^id)
      |> Ash.Query.select([
        :id,
        :slug,
        :parent_section_id,
        :front_page,
        :group_heading,
        :group_page
      ])
      |> Ash.read(tenant: site_id, authorize?: false, page: false)
      |> case do
        {:ok, found} -> found
        _unreadable -> []
      end

    [section | pages]
    |> Address.paths()
    |> Map.fetch!(id)
    |> Enum.join("/")
  end

  defp captures(captures, language) when is_binary(language),
    do: Map.put(captures, Languages.capture(), language)

  defp captures(captures, _no_language), do: captures
end
