# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_document/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaDocument.Plugins.PageFrame do
  @moduledoc """
  Tells the site's layout what only a documentation page knows — the languages the document or the
  page it shows is written in, and the bar under the header — through the `runtime:page:frame`
  mishka_installer hook `MishkaCmsWeb.RuntimeLive` fires in `handle_params/3`
  (`MishkaCmsCore.Runtime.SiteLayout` is the contract: the map it is handed and what it reads
  back).

  A page is matched by the kind of record it says it shows (`record`, its `extra`'s `"record"`):
  `"docs:document"`, a document's front page, or `"docs:page"`, one page of a document — the kinds
  `MishkaDocument.Plugins.PageRecords` names, the ones `MishkaDocument.Plugins.PageSeo` answers
  for. The library, which shows no record, is matched by its section, `"document"`. Every other page
  is handed back untouched, before anything is read.

  ## The languages

  The header's language switcher is the only one the documentation has. On a document's pages it
  lists the languages THAT record is written in, each at the address of its own edition, which is
  what `language_group_id` says: the editions of a document are the documents sharing it, and the
  edition of a page is the page of the other document's latest version that shares its own group
  (`doc-switcher` did the same with the slug as the fallback for a translation nobody linked, and so
  does this). The core's default would offer this same path in every language, and an edition's
  slugs are its own: the Persian edition of `/docs/handbook/install` is `/fa/docs/rahnama/nasb`.

    * a document's front page: each edition of the document, titled with its name;
    * a page: each edition that has the page, titled with the page's title there. An edition that
      has no such page is not offered, as a language a record has no edition in never is;
    * an edition is at the address its document has, `/chelekom/docs`, else under the
      documentation's base by its slug (`MishkaDocument.Provision.item_paths/0`), and the page under
      it as `MishkaDocument.Address` writes it, in the address the site's URL mode gives that
      language (`MishkaCmsCore.Runtime.Languages.url/3`). No version number crosses to another
      edition, which numbers its versions on its own: it is read at its latest.

  The edition being read is read as the system, as `MishkaDocument.Plugins.PageSeo` reads it, since
  the visitor was admitted to it. The others are read as a visitor who is not signed in: the
  frame hands the plugin no visitor, so an edition locked to permissions is not offered rather than
  named to someone who may not open it. The library keeps the core's default.

  ## The bar

  Every page of the documentation has the bar, titled `Docs` and linking to the library. A
  document's pages add the trail under it, the document and then the page, and the version in a
  menu on its trailing side: the kit's `doc-switcher`, which reads the document's versions and the
  same page in each of them. It is a component with state of its own, so the bar gives it an `id`
  and the page's `params`, and `MishkaDocument.Plugins.ContentComponents` names it for the site's
  stylesheet, since only the bar draws it.

  Registered in `MishkaDocument.Application`.
  """

  use Gettext, backend: MishkaCmsCore.Gettext
  use MishkaInstaller.Event.Hook, event: "runtime:page:frame", initial: %{priority: 50}

  require Ash.Query

  alias MishkaCmsCore.Runtime.Languages
  alias MishkaDocument.{Address, PageSource, Provision, Workspace}

  @records ["docs:document", "docs:page"]

  # The block the bar draws its version menu with, and the id its state is kept under.
  @switcher "doc-switcher"
  @switcher_id "doc-version"

  @workspace_fields [:id, :name, :slug, :path, :language, :language_group_id]

  @doc """
  The components the bar draws on a document's pages, by name. No page or layout names them, so
  `MishkaDocument.Plugins.ContentComponents` hands them to the site's stylesheet.
  """
  @spec bar_components() :: [String.t()]
  def bar_components, do: [@switcher]

  @impl true
  def call(%{record: record} = frame) when record in @records,
    do: {:reply, :halt, document(frame)}

  def call(%{section: "document"} = frame),
    do: {:reply, :halt, %{frame | section_bar: library_bar(frame)}}

  def call(frame), do: {:reply, frame}

  # THE DOCUMENT THE ADDRESS NAMES, and the page of it for a `docs:page`. An address that names none
  # is a page that answers "not published", which offers no language and no trail.
  defp document(frame) do
    case PageSource.workspace(frame, @workspace_fields, loads(frame)) do
      %Workspace{} = workspace ->
        shown = shown(frame, workspace)

        %{
          frame
          | translations: translations(frame, workspace, shown),
            section_bar: bar(frame, workspace, shown)
        }

      nil ->
        %{frame | translations: [], section_bar: library_bar(frame)}
    end
  end

  # Only a page needs the document's versions: its title is read off the version being read.
  defp loads(%{record: "docs:page"}), do: [versions: PageSource.versions()]
  defp loads(_front_page), do: []

  # What is shown of the document: its name on its front page; on a page, its title and where it is
  # among the pages of the version `?v=` names. `nil` for a page the address does not name.
  defp shown(%{record: "docs:page", params: params, site_id: site_id}, workspace) do
    with wanted when is_binary(wanted) and wanted != "" <- params["section"],
         {_version, tree} <- PageSource.shown(workspace.versions, params["v"], site_id),
         %{} = page <- Address.page_at(tree, wanted) do
      %{title: page.title, page: page, segments: Map.get(Address.paths(tree), page.id, [])}
    else
      _names_no_page -> nil
    end
  end

  defp shown(_front_page, workspace), do: %{title: workspace.name, page: nil, segments: []}

  # ---------------------------------------------------------------------------
  # The languages
  # ---------------------------------------------------------------------------

  defp translations(_frame, _workspace, nil), do: []

  defp translations(%{site_id: site_id}, workspace, shown) do
    case other_editions(workspace, site_id) do
      [] ->
        []

      others ->
        for {edition, found} <- editions_of(others, workspace, shown, site_id),
            path = address(edition, found.segments, site_id),
            is_binary(path),
            do: %{language: edition.language, path: path, title: found.title}
    end
  end

  # The other documents of the group the document is in, as a visitor who is not signed in reads
  # them. None while the site publishes one language, which has nothing to switch to.
  defp other_editions(%{language_group_id: nil}, _site_id), do: []

  defp other_editions(%{language_group_id: group, id: id}, site_id) do
    case Languages.site(site_id) do
      [_only] ->
        []

      _several ->
        Workspace
        |> Ash.Query.for_read(:public_list, %{}, actor: nil, tenant: site_id)
        |> Ash.Query.filter(language_group_id == ^group and id != ^id)
        |> Ash.Query.select(@workspace_fields)
        |> Ash.read(actor: nil, tenant: site_id, page: false)
        |> rows()
    end
  end

  # Each edition with what it shows of the record: the edition being read as it was read, the others
  # as they have it. A front page is every document's own name.
  defp editions_of(others, workspace, %{page: nil} = shown, _site_id),
    do: [{workspace, shown} | for(edition <- others, do: {edition, front(edition)})]

  defp editions_of(others, workspace, %{page: page} = shown, site_id),
    do: [{workspace, shown} | translated(others, page, site_id)]

  defp front(edition), do: %{title: edition.name, page: nil, segments: []}

  # The page in each edition that has it, in the version that edition is on: the page that shares
  # its group of translations, else the one called the same.
  defp translated(editions, page, site_id) do
    trees = latest_trees(editions, site_id)

    for edition <- editions,
        tree = Map.get(trees, edition.id, []),
        %{} = found <- [same_page(tree, page)],
        do: {edition, %{title: found.title, segments: Map.get(Address.paths(tree), found.id, [])}}
  end

  defp same_page(tree, %{slug: slug, language_group_id: group}) do
    named = Enum.filter(tree, &Address.addressed?/1)

    (group && Enum.find(named, &(&1.language_group_id == group))) ||
      Enum.find(named, &(&1.slug == slug))
  end

  # The approved pages of the version each edition is on — the one marked latest, else the newest
  # published (`MishkaDocument.Address.version_shown/2`) — as `%{document_id => pages}`, in two reads
  # for all of them.
  defp latest_trees(editions, site_id) do
    ids = Enum.map(editions, & &1.id)

    latest =
      PageSource.versions()
      |> Ash.Query.for_read(:public_list, %{}, actor: nil, tenant: site_id)
      |> Ash.Query.filter(workspace_id in ^ids)
      |> Ash.read(actor: nil, tenant: site_id, page: false)
      |> rows()
      |> Enum.group_by(& &1.workspace_id)
      |> Map.new(fn {id, versions} -> {id, Address.version_shown(versions, nil)} end)

    pages =
      latest
      |> Map.values()
      |> Enum.map(& &1.id)
      |> pages_of(site_id)
      |> Enum.group_by(& &1.workspace_version_id)

    Map.new(latest, fn {id, version} -> {id, Map.get(pages, version.id, [])} end)
  end

  defp pages_of([], _site_id), do: []

  defp pages_of(version_ids, site_id) do
    PageSource.pages()
    |> Ash.Query.for_read(:public_list, %{}, actor: nil, tenant: site_id)
    |> Ash.Query.filter(workspace_version_id in ^version_ids)
    |> Ash.read(actor: nil, tenant: site_id, page: false)
    |> rows()
  end

  defp rows({:ok, found}) when is_list(found), do: found
  defp rows(_unreadable), do: []

  # AN EDITION'S ADDRESS: where its document has one of its own, else under the documentation's
  # base by its slug; its page under that, in the language of the edition.
  defp address(%{path: own} = edition, segments, site_id) when is_binary(own) and own != "" do
    case segments do
      [] ->
        Languages.url(own, language(edition), site_id)

      _page ->
        Languages.url(
          Address.page_paths(own).page,
          Map.put(language(edition), "section", Enum.join(segments, "/")),
          site_id
        )
    end
  end

  defp address(edition, [], site_id) do
    Languages.url(
      Provision.item_paths().workspace,
      Map.put(language(edition), "workspace", edition.slug),
      site_id
    )
  end

  defp address(edition, segments, site_id) do
    Languages.url(
      Provision.item_paths().section,
      Map.merge(language(edition), %{
        "workspace" => edition.slug,
        "section" => Enum.join(segments, "/")
      }),
      site_id
    )
  end

  defp language(edition), do: %{Languages.capture() => edition.language}

  # ---------------------------------------------------------------------------
  # The bar
  # ---------------------------------------------------------------------------

  defp library_bar(%{language: language, site_id: site_id}),
    do: %{title: gettext("Docs"), title_path: library(language, site_id)}

  # DOCS IS THE BAR'S TITLE, so the trail starts at the document: the library, the document and the
  # page are one line, and listing the library again would draw it twice. The version menu is the
  # kit's `doc-switcher`, with the page's own URL keys (the document, the page, `?v=`) and the base
  # it builds the address of every version from — a document at an address of its own is read there.
  defp bar(%{site_id: site_id} = frame, workspace, shown) do
    %{
      title: gettext("Docs"),
      title_path: library(workspace.language, site_id),
      crumbs: crumbs(workspace, shown, site_id),
      component: @switcher,
      assigns: Map.merge(switcher(frame), own_address(frame))
    }
  end

  defp crumbs(workspace, %{page: %{}} = shown, site_id) do
    [
      %{label: workspace.name, path: address(workspace, [], site_id)},
      %{label: shown.title}
    ]
  end

  defp crumbs(workspace, _front_page_or_none, site_id),
    do: [%{label: workspace.name, path: address(workspace, [], site_id)}]

  defp switcher(%{params: params, language: language}) do
    %{
      id: @switcher_id,
      lang: language,
      doc_base: Provision.docs_base(),
      params: Map.delete(params, Languages.capture()),
      version_text: ""
    }
  end

  # A PAGE AT A DOCUMENT'S OWN ADDRESS NAMES IT, so the block reads that document rather than one a
  # slug in the URL names, and writes no `?lang=`: the address is one edition's, and says which.
  defp own_address(%{page: %{path: path}}) do
    case Address.of_page(path) do
      nil -> %{}
      address -> %{path: address, lang_param: ""}
    end
  end

  defp own_address(_frame), do: %{}

  defp library(language, site_id),
    do: Languages.url(Provision.docs_base(), %{Languages.capture() => language}, site_id)
end
