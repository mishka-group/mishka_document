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
  edition of a page is the page of the other document's latest version that shares its own group,
  else the one with the same slug, for a translation nobody linked. The core's default would offer
  this same path in every language, and an edition's slugs are its own: the Persian edition of
  `/docs/handbook/install` is `/fa/docs/rahnama/nasb`.

    * a document's front page: each edition of the document, titled with its name;
    * a page: each edition that has the page, titled with the page's title there. An edition that
      has no such page is not offered, as a language a record has no edition in never is;
    * an edition is at the address its document has, `/chelekom/docs`, else under the
      documentation's base by its slug (`MishkaDocument.Provision.item_paths/0`), and the page under
      it as `MishkaDocument.Address` writes it, in the address the site's URL mode gives that
      language (`MishkaCmsCore.Runtime.Languages.url/3`). No version number crosses to another
      edition, which numbers its versions on its own: it is read at its latest.

  Every edition is read as the visitor, the frame's `current_user`, and none of it is read here: the
  page read the document, its other editions with their versions, and the pages of the version
  shown once for its head, its frame and its blocks (`source`, `MishkaDocument.PageSource`), and
  only the pages of the version each other edition is on are read here, in one read. The edition
  being read is offered only when the visitor's own read found it — the document on its front page,
  the page among the pages they read on one of its pages — and a visitor it is kept from is offered
  no language. Another edition (or, for a page, the page of it) locked to permissions is offered to
  a reader who holds one of them, and a guest, or a reader who holds none, is offered only what a
  guest can read, so an edition is never named to someone who may not open it. The library keeps
  the core's default.

  ## The bar

  Every page of the documentation has the bar, titled `Docs` and linking to the library. A
  document's pages add the trail under it, the document and then the page, and the version in a
  menu on its trailing side: the kit's `doc-switcher`, which reads the document's versions and the
  same page in each of them. It is a component with state of its own, so the bar gives it an `id`
  and the page's `params`, and `MishkaDocument.Plugins.ContentComponents` names it for the site's
  stylesheet, since only the bar draws it. It reads the versions and their pages as the visitor
  too, so the bar hands it the `current_user` the frame names, and the page's rows (`page_source`),
  which hold the document, its versions and the pages of the version shown.

  The words are the site's own translations (`MishkaCmsCore.Runtime.Translations`), in the language
  of the response, and the key itself where nobody has written one. `MishkaDocument.Provision`
  registers them (`words/0`) when it sets a site up, and `MishkaDocument.Plugins.UsedTranslationKeys`
  names them to "Remove unused".

  Registered in MishkaDocument.Application.
  """

  use MishkaInstaller.Event.Hook, event: "runtime:page:frame", initial: %{priority: 50}

  require Ash.Query

  alias MishkaCmsCore.Runtime.Languages
  alias MishkaCmsCore.Runtime.States.TranslationsState
  alias MishkaDocument.{Address, PageSource, Provision, Workspace}

  @records ["docs:document", "docs:page"]

  # What the bar calls the documentation: a key of the site's translations.
  @title "Docs"

  # The block the bar draws its version menu with, and the id its state is kept under.
  @switcher "doc-switcher"
  @switcher_id "doc-version"

  @doc """
  The words the bar asks the site's translations for, for `MishkaDocument.Provision` to register:
  the documentation's name.
  """
  @spec words() :: [String.t()]
  def words, do: [@title]

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

  # THE DOCUMENT THE ADDRESS NAMES, and the page of it for a `docs:page`, out of the rows the page
  # read once for its head, its frame and its blocks (`MishkaDocument.PageSource`). An address that
  # names none is a page that answers "not published", which offers no language and no trail.
  #
  # A DOCUMENT THE VISITOR MAY NOT READ IS NOT NAMED TO THEM, in a language or in the trail: its page
  # answers them 404, and its frame meanwhile is the library's. A page whose own lock opens for them
  # inside a document whose lock does not is drawn in its document, as the blocks draw it.
  defp document(frame) do
    case PageSource.of(frame) do
      %PageSource{workspace: %Workspace{} = workspace} = source ->
        case readable?(frame, source) do
          true ->
            shown = shown(frame, source)

            %{
              frame
              | translations: translations(frame, source, shown),
                section_bar: bar(frame, workspace, shown, source)
            }

          false ->
            %{frame | translations: [], section_bar: library_bar(frame)}
        end

      _none ->
        %{frame | translations: [], section_bar: library_bar(frame)}
    end
  end

  defp readable?(_frame, %{open?: true}), do: true
  defp readable?(%{record: "docs:page"}, %{page: %{}}), do: true
  defp readable?(_frame, _source), do: false

  # What is shown of the document: its name on its front page; on a page, its title and where it is
  # among the pages of the version `?v=` names, as the visitor reads them. `nil` for a page the
  # address does not name, or one the visitor may not open.
  defp shown(%{record: "docs:page", params: params}, source) do
    with wanted when is_binary(wanted) and wanted != "" <- params["section"],
         %{} = page <- source.page do
      %{
        title: page.title,
        page: page,
        segments: Map.get(Address.paths(source.pages), page.id, [])
      }
    else
      _names_no_page -> nil
    end
  end

  defp shown(_front_page, %{workspace: workspace}),
    do: %{title: workspace.name, page: nil, segments: []}

  # ---------------------------------------------------------------------------
  # The languages
  # ---------------------------------------------------------------------------

  # THE EDITION BEING READ IS OFFERED ONLY TO A VISITOR WHO MAY READ IT, by their own read of it
  # (`readable?/2`): the front page when the visitor's read found the document, a page when it is
  # among the pages they read. A visitor it is kept from is offered no language.
  defp translations(_frame, _source, nil), do: []

  defp translations(%{site_id: site_id} = frame, %{workspace: workspace} = source, shown) do
    case source.editions do
      [] ->
        []

      others ->
        for {edition, found} <- editions_of(others, workspace, shown, source, visitor(frame)),
            path = address(edition, found.segments, site_id),
            is_binary(path),
            do: %{language: edition.language, path: path, title: found.title}
    end
  end

  # Each edition with what it shows of the record: the edition being read as it was read, the others
  # as they have it. A front page is every document's own name.
  defp editions_of(others, workspace, %{page: nil} = shown, _source, _visitor),
    do: [{workspace, shown} | for(edition <- others, do: {edition, front(edition)})]

  defp editions_of(others, workspace, %{page: page} = shown, source, visitor),
    do: [{workspace, shown} | translated(others, page, source, visitor)]

  defp front(edition), do: %{title: edition.name, page: nil, segments: []}

  # The page in each edition that has it, in the version that edition is on: the page that shares
  # its group of translations, else the one called the same.
  defp translated(editions, page, source, visitor) do
    trees = latest_trees(editions, source, visitor)

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
  # published (`MishkaDocument.Address.version_shown/2`) — as `%{document_id => pages}`, as the
  # visitor reads them: a page locked to permissions they do not hold is not the edition's page.
  #
  # THE PAGE READ THEM ALREADY, with the pages of its own document's versions
  # (`MishkaDocument.PageSource`'s `pages_by_version`); an edition's whose pages it does not hold
  # are read here, in one read for all of them.
  defp latest_trees(editions, source, visitor) do
    latest =
      for %{versions: versions} = edition <- editions,
          is_list(versions),
          %{} = version <- [Address.version_shown(versions, nil)],
          into: %{},
          do: {edition.id, version}

    held = source.pages_by_version
    {_held, unread} = latest |> Map.values() |> Enum.split_with(&Map.has_key?(held, &1.id))

    pages =
      unread
      |> Enum.map(& &1.id)
      |> pages_of(source.site_id, visitor)
      |> Enum.group_by(& &1.workspace_version_id)
      |> Map.merge(held)

    Map.new(latest, fn {id, version} -> {id, Map.get(pages, version.id, [])} end)
  end

  defp pages_of([], _site_id, _visitor), do: []

  defp pages_of(version_ids, site_id, visitor) do
    PageSource.pages()
    |> Ash.Query.for_read(:public_list, %{}, actor: visitor, tenant: site_id)
    |> Ash.Query.filter(workspace_version_id in ^version_ids)
    |> Ash.read(actor: visitor, tenant: site_id, page: false)
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

  defp library_bar(%{language: language, site_id: site_id} = frame),
    do: %{title: word(frame), title_path: library(language, site_id)}

  defp word(%{site_id: site_id, language: language}),
    do: TranslationsState.lookup(site_id, language, @title) || @title

  # The signed-in visitor, or `nil` for a guest.
  defp visitor(frame), do: Map.get(frame, :current_user)

  # DOCS IS THE BAR'S TITLE, so the trail starts at the document: the library, the document and the
  # page are one line, and listing the library again would draw it twice. The version menu is the
  # kit's `doc-switcher`, with the page's own URL keys (the document, the page, `?v=`) and the base
  # it builds the address of every version from — a document at an address of its own is read there.
  defp bar(%{site_id: site_id} = frame, workspace, shown, source) do
    %{
      title: word(frame),
      title_path: library(workspace.language, site_id),
      crumbs: crumbs(workspace, shown, site_id),
      component: @switcher,
      assigns: frame |> switcher(source) |> Map.merge(own_address(frame))
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

  # THE MENU IS HANDED THE PAGE'S ROWS (`page_source`), so it takes the document, its versions and the
  # pages of the version shown from them, and reads only the pages of the versions it offers besides.
  defp switcher(%{params: params, language: language} = frame, source) do
    %{
      id: @switcher_id,
      lang: language,
      current_user: visitor(frame),
      page_source: source,
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
