# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_document/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaDocument.PageSource do
  @moduledoc """
  The rows a documentation page is made of: the document its address names, its published
  versions, the version a reader is shown and that version's approved pages, the page the address
  names with its text, and that page's notes.

  ## Read once, for everything that draws them

  A document's front page and each of its pages are drawn by the head
  (`MishkaDocument.Plugins.PageSeo`), the frame (`MishkaDocument.Plugins.PageFrame`) and the page's
  own blocks, `doc-sidebar`, `doc-section`, `doc-toc` and the bar's `doc-switcher`. Each of them
  read the same document, the same versions and the same pages on its own. `read/1` reads them once,
  in `handle_params/3`, through the `runtime:page:source` event (`MishkaDocument.Plugins.PageSource`,
  `MishkaCmsCore.Runtime.PageSource`), and every one of them is handed what it read: the two plugins
  as `source`, the blocks as `page_source`.

  Three reads, each bringing what is joined to it: the document, with its versions and its other
  editions and theirs (relationships loaded in the same read); the pages of all of those versions
  the page's readers look in, in one read; and the page the address names, with its text and its
  notes.

  A request is the map core hands any of the three plugins: the `site_id`, the page and its `path`,
  the `params` (the path's captures and the query), the `language` of the response, the
  `current_user` and, on the event, `held`.

  ## As the visitor

  Every row is read as the visitor, `current_user`, through the actions and policies the blocks read
  with (`MishkaDocument.Resources.Preparations.OpenToActor`): `:public_list` of the document, of its
  versions, of the pages of the versions shown, and of the page and its notes. What the visitor may
  not open is not among them: a locked document, a locked page or one under a locked page, a page
  whose own page on the site is closed to them, a draft, a version that is not published.

  THE SYSTEM READS ONE ROW, AND ONLY WHEN THE VISITOR'S READ FOUND NO DOCUMENT: the document and its
  versions, as the blocks have always read them (`open?` says which read found it). Two things need
  it, and neither shows the visitor anything their own lock does not let them see:

    * the lock. A document the visitor may not open is no row at all when read as them, and the head
      would hand `MishkaCmsWeb.RuntimeLive` no permissions to refuse them with. The head takes the
      lock alone from it, and the address answers 404;
    * a page whose own lock opens for the visitor inside a document whose lock does not. Its pages
      are still read as the visitor, so only a page they may open is found, and the document is drawn
      around that page as the blocks draw it.

  ## Keyed to its visitor, and to what it was read for

  A source names the site, the visitor (`MishkaCmsCore.Runtime.PageSource.visitor_id/1`), the
  language and the document it was read for. A block takes nothing from one read for another site or
  another visitor, and takes a row only for exactly the read it would make itself: the same document
  named the same way, the versions of that document, the pages of that version, that page's text and
  notes. Anything else it reads for itself, so a block an admin pinned to another document, or placed
  on a page of their own, reads as it always did.

  ## What a block reads of it

  A block's code calls nothing of this extension's (`MishkaDocument.KitTest`), so it reads a source
  by its shape, which is therefore part of what the kit relies on:

    * `rows_of` — `"mishka_document"`, which a block asks before anything else;
    * `site_id`, `visitor`, `language` — whom and for what it was read;
    * `tried` — the documents the address named, `{:path, address}` or `{:slug, slug}`, in the order
      they were looked for, and `found_by` the one that answered, or `nil`;
    * `workspace` — that document; `versions` — its published versions, newest first;
    * `version` — the one shown; `pages` — its approved pages, in their order;
      `pages_by_version` — the approved pages of every version of the document, and on a page of
      it of the version each other edition is on, by the version's id, each in their order;
    * `body` — the page the address names, every field, with `rendered_content`; `notes` — its
      approved notes, in their order, with their `content`.

  ## Another page of the same document

  A live patch to another page, or to another version, reads only what changed: the event hands back
  the source the address before read for the same visitor (`held`), and the document, its versions
  and, in the same version, its pages are taken from it.
  """

  require Ash.Query

  alias MishkaCmsCore.Runtime.Languages
  alias MishkaCmsCore.Runtime.PageSource, as: CorePageSource
  alias MishkaDocument.{Address, Note, Section, Workspace, WorkspaceVersion}

  @enforce_keys [:site_id, :visitor, :language]
  defstruct [
    :site_id,
    :visitor,
    :language,
    :found_by,
    :workspace,
    :version,
    :page,
    :body,
    rows_of: "mishka_document",
    tried: [],
    open?: false,
    versions: [],
    editions: [],
    pages_by_version: %{},
    pages: [],
    lock: [],
    notes: []
  ]

  @type named :: {:path, String.t()} | {:slug, String.t()}

  @type t :: %__MODULE__{
          rows_of: String.t(),
          site_id: String.t(),
          visitor: term(),
          language: String.t() | nil,
          tried: [named()],
          found_by: named() | nil,
          workspace: struct() | nil,
          open?: boolean(),
          versions: [struct()],
          editions: [struct()],
          version: struct() | nil,
          pages_by_version: %{optional(String.t()) => [struct()]},
          pages: [struct()],
          page: struct() | nil,
          lock: [String.t()],
          body: struct() | nil,
          notes: [struct()]
        }

  # EVERYTHING ANY OF THE READERS DRAWS OF THE DOCUMENT, so each is handed one row: the blocks' links
  # and landing, the head's tags and lock, the frame's editions.
  @document_fields [
    :id,
    :name,
    :slug,
    :path,
    :description,
    :language,
    :language_group_id,
    :seo_tags,
    :schema,
    :permissions,
    :inserted_at,
    :updated_at
  ]

  @version_fields [
    :id,
    :workspace_id,
    :status,
    :version_number,
    :is_latest_for_version,
    :published_at,
    :inserted_at
  ]

  # What a tree of pages is asked for: where each one sits, what it is called, how it is locked,
  # which group of translations and which lineage it belongs to. Never its text.
  @page_fields [
    :id,
    :workspace_version_id,
    :title,
    :slug,
    :order_position,
    :parent_section_id,
    :front_page,
    :group_heading,
    :group_page,
    :permissions,
    :language_group_id,
    :section_lineage_id
  ]

  @note_fields [:id, :title, :order_position, :content]

  # What the frame offers of another edition of the document: where it is and what it is called.
  @edition_fields [:id, :name, :slug, :path, :language, :language_group_id]

  @doc """
  The rows of the documentation page `request` asks for, read as its `current_user`; `nil` for a
  request that names no document, on no site. A document that is not there, or not shown, is a
  source with no `workspace`: every reader handed it answers as its own read of it would.
  """
  @spec read(map()) :: t() | nil
  def read(%{site_id: site_id} = request) when is_binary(site_id) do
    case own_address(request) ++ by_slug(request) do
      [] -> nil
      names -> request |> blank(names) |> document(request, names) |> version(request)
    end
  end

  def read(_request), do: nil

  @doc """
  The source the page read for `request`, when it was handed one for this site and visitor; else
  the rows read here, once (`read/1`). For the plugins on the frame and the head, which are handed
  core's `source`.
  """
  @spec of(map()) :: t() | nil
  def of(%{source: %__MODULE__{} = source} = request) do
    case for_request?(source, request) do
      true -> source
      false -> read(request)
    end
  end

  def of(request), do: read(request)

  defp for_request?(source, request) do
    source.site_id == Map.get(request, :site_id) and
      source.visitor == CorePageSource.visitor_id(Map.get(request, :current_user)) and
      source.language == Map.get(request, :language)
  end

  defp blank(request, names) do
    %__MODULE__{
      site_id: request.site_id,
      visitor: CorePageSource.visitor_id(Map.get(request, :current_user)),
      language: Map.get(request, :language),
      tried: names
    }
  end

  defp own_address(%{page: %{path: path}}) do
    case Address.of_page(path) do
      nil -> []
      address -> [{:path, address}]
    end
  end

  defp own_address(_request), do: []

  defp by_slug(%{params: %{"workspace" => slug}}) when is_binary(slug) and slug != "",
    do: [{:slug, slug}]

  defp by_slug(_request), do: []

  # THE DOCUMENT AND ITS VERSIONS: taken from what the address before read when it is the same
  # document for the same visitor in the same language; else read as the visitor, else, for the
  # lock and for a page whose own lock opens, as the system (see the moduledoc).
  defp document(source, request, names) do
    case held(request, source) do
      %__MODULE__{found_by: found_by} = held when found_by != nil ->
        %{
          source
          | found_by: found_by,
            workspace: held.workspace,
            open?: held.open?,
            versions: held.versions,
            editions: held.editions
        }

      _not_held ->
        visitor = Map.get(request, :current_user)

        case first(names, request, [actor: visitor], editions?(request)) do
          {named, workspace} ->
            with_rows(%{source | found_by: named, workspace: workspace, open?: true})

          nil ->
            as_the_system(source, request, names)
        end
    end
  end

  defp as_the_system(source, request, names) do
    case first(names, request, [authorize?: false], false) do
      {named, workspace} ->
        %{source | found_by: named, workspace: workspace}
        |> with_rows()
        |> Map.put(:editions, editions(workspace, request))

      nil ->
        source
    end
  end

  # The document's versions, newest first, and its other editions, each with its own versions, as
  # they came with it.
  defp with_rows(%{workspace: workspace} = source) do
    %{
      source
      | versions: newest_first(loaded(workspace, :versions)),
        editions:
          for(
            edition <- loaded(workspace, :editions),
            do: %{edition | versions: newest_first(loaded(edition, :versions))}
          )
    }
  end

  defp loaded(record, key) do
    case Map.get(record, key) do
      rows when is_list(rows) -> rows
      _not_loaded -> []
    end
  end

  # THE OTHER EDITIONS COME WITH THE DOCUMENT, in the read that finds it and as the same visitor, on a
  # site that publishes in more than one language: one that publishes in one has nothing to switch
  # to.
  defp editions?(%{site_id: site_id}) do
    match?([_, _ | _], Languages.site(site_id))
  end

  # A DOCUMENT FOUND ONLY BY THE SYSTEM brings no editions with it, for its read would bring the
  # system's: they are read as the visitor, for the page whose own lock opens for them.
  defp editions(%{language_group_id: group, id: id}, request) when is_binary(group) do
    case editions?(request) do
      false ->
        []

      true ->
        as = [actor: Map.get(request, :current_user), tenant: request.site_id]

        Workspace
        |> Ash.Query.for_read(:public_list, %{}, as)
        |> Ash.Query.filter(language_group_id == ^group and id != ^id)
        |> Ash.Query.select(@edition_fields)
        |> Ash.Query.load(versions: versions())
        |> Ash.read(as ++ [page: false])
        |> rows()
        |> Enum.map(&%{&1 | versions: newest_first(loaded(&1, :versions))})
    end
  end

  defp editions(_no_group, _request), do: []

  # The source the address before read, when it is for this site, this visitor, this language and
  # the document this address names.
  defp held(%{held: %__MODULE__{} = held}, source) do
    same? =
      held.site_id == source.site_id and held.visitor == source.visitor and
        held.language == source.language and held.tried == source.tried

    if same?, do: held
  end

  defp held(_request, _source), do: nil

  defp first(names, request, as, editions?) do
    Enum.find_value(names, fn named ->
      case document_row(named, request, as, editions?) do
        nil -> nil
        workspace -> {named, workspace}
      end
    end)
  end

  # ONE READ OF THE DOCUMENT brings its versions and, for the frame, its other editions with theirs:
  # relationships through the public reads (`MishkaDocument.Workspace`'s `versions` and `editions`),
  # loaded as whoever the document is read as, so what that reader may not open is left out of them
  # as it is of the document.
  defp document_row(named, %{site_id: site_id} = request, as, editions?) do
    opts = [tenant: site_id] ++ as

    Workspace
    |> Ash.Query.for_read(:public_list, %{}, opts)
    |> named_by(named)
    |> in_language(Map.get(request, :language))
    |> Ash.Query.select(@document_fields)
    |> Ash.Query.load(versions: versions())
    |> with_editions(editions?)
    |> Ash.read(opts ++ [page: [limit: 1]])
    |> case do
      {:ok, %{results: [workspace | _rest]}} -> workspace
      _none -> nil
    end
  end

  defp with_editions(query, false), do: query

  defp with_editions(query, true) do
    Ash.Query.load(query,
      editions:
        Workspace
        |> Ash.Query.select(@edition_fields)
        |> Ash.Query.sort(language: :asc)
        |> Ash.Query.load(versions: versions())
    )
  end

  # THE VERSION SHOWN, ITS PAGES, THE PAGE THE ADDRESS NAMES, ITS TEXT AND ITS NOTES. The pages of the
  # same document are the ones the address before read; the page's own text and notes are read again
  # only for another page.
  defp version(%{workspace: nil} = source, _request), do: source

  defp version(source, request) do
    params = Map.get(request, :params) || %{}
    version = Address.version_shown(source.versions, params["v"])
    held = held(request, source)
    by_version = pages_by_version(source, request, held)
    pages = Map.get(by_version, version && version.id, [])
    page = page_at(pages, request)
    lock = lock_of(page, pages)
    {body, notes} = text_of(page, lock, held, source.site_id, request)

    %{
      source
      | version: version,
        pages_by_version: by_version,
        pages: pages,
        page: page,
        lock: opens_with(lock, body, source.workspace),
        body: body,
        notes: notes
    }
  end

  # EVERY PAGE THE PAGE'S READERS FIND ANOTHER PAGE AMONG, IN ONE READ, by the version it is in: the
  # pages of every version of the document — the version shown is the tree the blocks draw and the
  # head and the frame find the page in, the others the version menu's other addresses of it — and,
  # on a page of a document, the pages of the version each other edition is on, which the frame finds
  # the same page in. Which version an edition is on is decided from its versions once they are read
  # (the one marked latest, else the newest published), so they are read here and not with the
  # document. The address before read the same ones for the same document and visitor.
  defp pages_by_version(source, request, held) do
    wanted =
      Enum.map(source.versions, & &1.id) ++
        for edition <- editions_read_for(request, source),
            %{id: id} <- [Address.version_shown(List.wrap(edition.versions), nil)],
            do: id

    case held do
      %{pages_by_version: by_version} when is_map(by_version) ->
        if Enum.all?(wanted, &Map.has_key?(by_version, &1)),
          do: by_version,
          else: pages_of(wanted, source.site_id, request)

      _not_held ->
        pages_of(wanted, source.site_id, request)
    end
  end

  defp editions_read_for(%{record: "docs:page"}, source), do: source.editions
  defp editions_read_for(_front_page, _source), do: []

  defp pages_of([], _site_id, _request), do: %{}

  defp pages_of(version_ids, site_id, request) do
    as = [actor: Map.get(request, :current_user), tenant: site_id]
    found = Map.new(version_ids, &{&1, []})

    Section
    |> Ash.Query.for_read(:public_list, %{}, as)
    |> Ash.Query.filter(workspace_version_id in ^version_ids)
    |> Ash.Query.select(@page_fields)
    |> Ash.read(as ++ [page: false])
    |> rows()
    |> Enum.sort_by(&{&1.order_position || 0, &1.title, &1.id})
    |> Enum.group_by(& &1.workspace_version_id)
    |> then(&Map.merge(found, &1))
  end

  # The page the `section` capture names, else, on a document's own address, its version's front
  # page.
  defp page_at(pages, %{params: %{"section" => wanted}}) when is_binary(wanted) and wanted != "",
    do: Address.page_at(pages, wanted)

  defp page_at(pages, _front_page), do: Address.page_at(pages, [])

  defp text_of(nil, _lock, _held, _site_id, _request), do: {nil, []}

  defp text_of(%{id: id}, _lock, %{body: %{id: id} = body, notes: notes}, _site_id, _request),
    do: {body, notes}

  defp text_of(page, lock, _held, site_id, request) do
    case body_of(page, lock, actor: Map.get(request, :current_user), tenant: site_id) do
      nil -> {nil, []}
      body -> {body, body |> loaded(:notes) |> Enum.sort_by(&{&1.order_position || 0, &1.id})}
    end
  end

  # THE PAGE'S OWN ROW, every field of it, with its text as the site draws it and its notes — read
  # once for the three that draw it: `doc-section` its text and its notes, `doc-toc` its headings and
  # the notes' titles, the head its summary and its tags. When it last changed is read for a page
  # that says it; what it opens with only where the pages read with the version cannot say
  # (`lock_of/2`).
  defp body_of(page, lock, as) do
    loads =
      [:rendered_content, notes: Ash.Query.select(Note, @note_fields)] ++
        if(page.front_page == true, do: [], else: [:last_modified_at]) ++
        if lock == :unknown, do: [:effective_permissions], else: []

    Section
    |> Ash.Query.for_read(:public_list, %{}, as)
    |> Ash.Query.filter(id == ^page.id)
    |> Ash.Query.load(loads)
    |> Ash.read(as ++ [page: [limit: 1]])
    |> case do
      {:ok, %{results: [body | _rest]}} -> body
      _none -> nil
    end
  end

  # WHAT THE PAGE OPENS WITH, by the rule `MishkaDocument.Resources.Calculations.EffectivePermissions`
  # gives: its own lock, else the nearest page above it that names one, else its document's. The
  # pages read with the version hold the answer where the page and every page above it are among
  # them; where one is not — a page in review, or archived — `:unknown`, and the calculation is asked
  # with the page's own row.
  @doc false
  @spec lock_of(map() | nil, [map()]) :: {:ok, [String.t()]} | :unknown
  def lock_of(nil, _pages), do: {:ok, []}

  def lock_of(page, pages),
    do: lock_above(page.permissions, page.parent_section_id, Map.new(pages, &{&1.id, &1}), [])

  defp lock_above([_ | _] = own, _parent_id, _by_id, _seen), do: {:ok, own}
  defp lock_above(_none, nil, _by_id, _seen), do: {:ok, []}

  defp lock_above(_none, parent_id, by_id, seen) do
    cond do
      parent_id in seen ->
        {:ok, []}

      parent = Map.get(by_id, parent_id) ->
        lock_above(parent.permissions, parent.parent_section_id, by_id, [parent_id | seen])

      true ->
        :unknown
    end
  end

  @doc false
  @spec opens_with({:ok, [String.t()]} | :unknown, map() | nil, map() | nil) :: [String.t()]
  def opens_with({:ok, []}, _body, workspace), do: List.wrap(workspace && workspace.permissions)
  def opens_with({:ok, lock}, _body, _workspace), do: lock
  def opens_with(:unknown, %{effective_permissions: lock}, _workspace), do: List.wrap(lock)
  def opens_with(:unknown, _no_body, workspace), do: List.wrap(workspace && workspace.permissions)

  defp rows({:ok, %{results: found}}) when is_list(found), do: found
  defp rows({:ok, found}) when is_list(found), do: found
  defp rows(_unreadable), do: []

  defp newest_first(versions),
    do: Enum.sort_by(versions, &{moment(&1.published_at), moment(&1.inserted_at), &1.id}, :desc)

  defp moment(%DateTime{} = at), do: DateTime.to_unix(at, :microsecond)
  defp moment(_never), do: 0

  # ---------------------------------------------------------------------------
  # A read of its own, for a caller handed no source
  # ---------------------------------------------------------------------------

  @doc """
  The document whose own address the page is at, else the one with no address of its own the
  `workspace` capture names, in the page's language, on the page's site; `nil` when the request
  names none or none is shown. Only `fields` of it are read, and `loads` loaded.

  READ AS THE SYSTEM, for the head of a caller that is no visitor: an editor's preview and a share
  card (`MishkaDocument.Plugins.PageSeo`). A page a visitor reads is answered from `read/1`.

  A slug names only a document with no address of its own: one that has an address is read there
  and nowhere else, so `/docs/<its slug>` names nothing.
  """
  @spec workspace(map(), [atom()], term()) :: struct() | nil
  def workspace(%{site_id: site_id} = request, fields, loads) when is_binary(site_id),
    do:
      Enum.find_value(
        own_address(request) ++ by_slug(request),
        &system(&1, request, fields, loads)
      )

  def workspace(_request, _fields, _loads), do: nil

  defp system(named, %{site_id: site_id} = request, fields, loads) do
    Workspace
    |> Ash.Query.for_read(:public_list, %{}, tenant: site_id, authorize?: false)
    |> named_by(named)
    |> in_language(Map.get(request, :language))
    |> Ash.Query.select(fields)
    |> Ash.Query.load(loads)
    |> Ash.read(tenant: site_id, authorize?: false, page: [limit: 1])
    |> case do
      {:ok, %{results: [workspace | _rest]}} -> workspace
      _none -> nil
    end
  end

  defp named_by(query, {:slug, slug}),
    do: Ash.Query.filter(query, slug == ^slug and is_nil(path))

  defp named_by(query, {:path, address}), do: Ash.Query.filter(query, path == ^address)

  defp in_language(query, language) when is_binary(language) and language != "",
    do: Ash.Query.filter(query, language == ^language)

  defp in_language(query, _no_language), do: query

  @doc "A document's published versions, without their pages, for `workspace/3` to load."
  @spec versions() :: Ash.Query.t()
  def versions, do: Ash.Query.select(WorkspaceVersion, @version_fields)

  @doc """
  The version a reader is shown among a document's published `versions`
  (`MishkaDocument.Address.version_shown/2`) and its approved pages as a tree — what a page's
  address is followed through (`MishkaDocument.Address.page_at/2`), read for that version alone,
  as the system, as `workspace/3` reads; `nil` when there is none.
  """
  @spec shown([struct()], String.t() | nil, String.t()) :: {struct(), [struct()]} | nil
  def shown(versions, asked, site_id) do
    with %WorkspaceVersion{} = version <- Address.version_shown(versions, asked),
         {:ok, %WorkspaceVersion{sections: pages} = shown} when is_list(pages) <-
           Ash.load(version, [sections: pages()], tenant: site_id, authorize?: false) do
      {shown, pages}
    else
      _none -> nil
    end
  end

  @doc "A version's pages, without their text, for `Ash.load/3` or a read of the pages of several."
  @spec pages() :: Ash.Query.t()
  def pages, do: Ash.Query.select(Section, @page_fields)
end
