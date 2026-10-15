defmodule MishkaDocument.Plugins.SitemapUrls do
  @moduledoc """
  Lists a site's published documentation in its `/sitemap.xml`, through the `seo:sitemap:urls`
  mishka_installer hook `MishkaCmsCore.Runtime.Compilers.SitemapCompiler` fires when it builds the
  site's sitemap. Its `pages` are the site's indexable pages holding a capture only their owner can
  fill; this appends an address for every document and every page of one to its `urls`. A
  workspace, version or section written rebuilds its site's sitemap, because those resources list
  `MishkaCmsCore.Runtime.Resources.Notifiers.SitemapRefresh`.

  Each document is listed at its front page and each page of it at its own, at the paths
  `MishkaDocument.Provision.item_paths/0` names, filled with the document's own language and slugs
  — a page's own part of the address being the slugs of the pages it is filed under, then its own
  (`MishkaDocument.Address.paths/1`) — at the address the site's URL mode gives that language
  (`MishkaCmsCore.Runtime.Languages.url/3`). A document with an address of its own is listed there
  instead, its pages under it: its front page is a page of the site at a fixed path, which the
  sitemap already lists as one, so only its pages are added here. A version's front page is drawn
  at its document's own address (`MishkaDocument.Address`), so it is listed as that and never under
  its own slug, which is a missing page; a group is only a heading, with no address to list, unless
  it has a page of its own (`group_page`), listed at its slug. An
  address is listed only while
  the site serves its page: the page at that exact path is among `pages`, and it answers the
  document's language (`MishkaCmsCore.Runtime.PageEditions.served_languages/2`). A page moved to
  another path, taken down, closed to visitors or marked noindex lists nothing.

  READ AS A VISITOR WHO IS NOT SIGNED IN, through the public actions, because a sitemap is for
  anyone: a document that names a permission, and a page that opens with one — its own, or its
  nearest parent page's (`MishkaDocument.Resources.Calculations.EffectivePermissions`) — is left out
  of the reads themselves (`MishkaDocument.Resources.Preparations.OpenToActor`), so a locked
  document's pages are never read and nothing locked is listed.

  And only while its record may be listed (`MishkaCmsCore.Runtime.PageEditions.listed?/2`): a
  document whose robots meta says `noindex` or `none` lists neither its front page nor a page of it
  that holds no robots meta of its own; a page whose own robots meta says so is left out alone. The
  front page of such a document with an address of its own, which core lists as a page of the site,
  is taken out of `urls`.

  THE SAME ROWS THE PAGES DRAW. `doc-section` finds a document among the active ones, shows the
  version an editor marked latest among the published ones — the newest published one when none
  is — and that version's approved pages. This reads exactly those, so a draft document, a
  document with no published version, a page still in review and the pages of an older version
  (`?v=`) are never listed.

  READ WHEN THE BUILD READS IT. The addresses are appended as a stream, and nothing is read until
  the build reads it: the documents a hundred at a time, the version each of them shows in one read
  per hundred, then the pages of those hundred together, a hundred at a time, and their front pages
  after them — a front page draws its document's contents, so it last changed when the newest of
  them did. Each read starts after the last row the one before it returned
  (`MishkaCmsCore.Runtime.Compilers.SitemapCompiler.stream_rows/2`), and however many documents a
  site has, one batch of each is held at a time — with the tree of each batch's versions, their
  pages' ids, slugs and parents, which is what a page's address is read off. Each address is listed
  once: a document's slug is unique on its site, its own address in its language, and a page's slug
  among the pages under its parent.

  Registered in `MishkaDocument.Application`.
  """

  use MishkaInstaller.Event.Hook, event: "seo:sitemap:urls", initial: %{priority: 60}

  require Ash.Query

  alias MishkaCmsCore.Runtime.{Languages, PageEditions}
  alias MishkaCmsCore.Runtime.Compilers.SitemapCompiler
  alias MishkaDocument.{Address, Provision, Section, Workspace, WorkspaceVersion}

  # The most documents whose pages are read together.
  @batch 100

  @impl true
  def call(%{site: %{id: site_id}, pages: pages, urls: urls} = data)
      when is_binary(site_id) and is_list(pages) do
    # Each path this extension fills whose page the site serves, with the languages it serves it in.
    served =
      for {kind, path} <- Provision.item_paths(),
          %{} = page <- [Enum.find(pages, &(&1.path == path))],
          into: %{},
          do: {kind, {path, PageEditions.served_languages(page, site_id)}}

    # And each document's own address whose pages the site serves, by that address — the page at
    # `<address>/*section` (`MishkaDocument.Address.page_paths/1`).
    own =
      for %{path: path} = page <- pages,
          String.ends_with?(path, "/*section"),
          address = Address.of_page(path),
          is_binary(address),
          into: %{},
          do: {address, {path, PageEditions.served_languages(page, site_id)}}

    served = Map.put(served, :own, own)

    languages =
      [served[:workspace], served[:section] | Map.values(own)]
      |> Enum.flat_map(fn
        {_path, languages} -> languages
        nil -> []
      end)
      |> Enum.uniq()

    # A `urls` that is not an `Enumerable` is handed on as it came, for core to leave out.
    case Enumerable.impl_for(urls) && languages do
      [_ | _] ->
        urls =
          urls
          |> without(fn -> unlisted_fronts(site_id, Map.keys(own)) end)
          |> Stream.concat(document_urls(site_id, languages, served))

        {:reply, %{data | urls: urls}}

      _nothing_to_add ->
        {:reply, data}
    end
  end

  def call(data), do: {:reply, data}

  # `urls` without the addresses `hidden` returns, called when the build reads the stream.
  defp without(urls, hidden) do
    Stream.transform(
      urls,
      hidden,
      fn url, hidden ->
        if MapSet.member?(hidden, Map.get(url, :path)), do: {[], hidden}, else: {[url], hidden}
      end,
      fn _hidden -> :ok end
    )
  end

  # The front pages of the documents at these addresses that may not be listed, each at the address
  # the site's URL mode gives its language.
  defp unlisted_fronts(_site_id, []), do: MapSet.new()

  defp unlisted_fronts(site_id, addresses) do
    Workspace
    |> Ash.Query.for_read(:public_list, %{}, actor: nil, tenant: site_id)
    |> Ash.Query.filter(path in ^addresses)
    |> Ash.Query.select([:path, :language, :permissions, :seo_tags])
    |> Ash.read!(actor: nil, tenant: site_id, page: false)
    |> Enum.reject(&PageEditions.listed?/1)
    |> MapSet.new(&Languages.url(&1.path, %{Languages.capture() => &1.language}, site_id))
  end

  defp document_urls(site_id, languages, served) do
    site_id
    |> workspaces(languages)
    |> Stream.chunk_every(@batch)
    |> Stream.flat_map(&batch_urls(site_id, &1, served))
  end

  # A batch of documents: every page of the version each shows, then each one's front page, which
  # draws the document's contents and so changes with any of its pages. A document with no version
  # to show lists nothing.
  defp batch_urls(site_id, workspaces, served) do
    current = current_versions(site_id, workspaces)

    shown =
      for workspace <- workspaces,
          version_id <- List.wrap(current[workspace.id]),
          into: %{},
          do: {version_id, workspace}

    paths = tree_paths(site_id, Map.keys(shown))

    site_id
    |> sections(Map.keys(shown))
    |> Stream.transform(
      fn ->
        Map.new(shown, fn {version_id, workspace} -> {version_id, workspace.updated_at} end)
      end,
      fn section, changed ->
        workspace = shown[section.workspace_version_id]
        own = paths |> Map.get(section.workspace_version_id, %{}) |> Map.get(section.id)

        {own_page_address(
           site_id,
           served,
           workspace,
           section,
           own || [section.slug]
         ),
         Map.update!(
           changed,
           section.workspace_version_id,
           &Enum.max([&1, section.updated_at], DateTime)
         )}
      end,
      fn changed ->
        {for(
           {version_id, workspace} <- shown,
           not own_address?(workspace),
           url <-
             address(
               site_id,
               served,
               :workspace,
               workspace.language,
               front(workspace),
               changed[version_id],
               PageEditions.listed?(workspace)
             ),
           do: url
         ), changed}
      end,
      fn _changed -> :ok end
    )
  end

  defp front(workspace),
    do: %{Languages.capture() => workspace.language, "workspace" => workspace.slug}

  # A page's own address, but none for a front page — its address is its document's, listed with it
  # — and none for a group with no page of its own, which has none.
  defp own_page_address(_site_id, _served, _workspace, %{front_page: true}, _segments), do: []

  defp own_page_address(
         _site_id,
         _served,
         _workspace,
         %{group_heading: true, group_page: page?},
         _
       )
       when page? != true,
       do: []

  defp own_page_address(site_id, served, workspace, section, segments) do
    page_address(
      site_id,
      served,
      workspace,
      segments,
      section.updated_at,
      PageEditions.listed?(%{section | permissions: section.effective_permissions}, workspace)
    )
  end

  defp own_address?(%{path: own}), do: is_binary(own) and own != ""

  # A page's address: under its document's own address where it has one, at the page the site
  # serves there; else under the documentation's base, by the document's slug.
  defp page_address(site_id, served, %{path: own} = workspace, segments, lastmod, listed?)
       when is_binary(own) and own != "" do
    for {path, languages} <- [served.own[own]],
        listed?,
        workspace.language in languages,
        address =
          Languages.url(
            path,
            %{Languages.capture() => workspace.language, "section" => Enum.join(segments, "/")},
            site_id
          ),
        is_binary(address),
        do: %{path: address, lastmod: lastmod}
  end

  defp page_address(site_id, served, workspace, segments, lastmod, listed?) do
    page = Map.put(front(workspace), "section", Enum.join(segments, "/"))
    address(site_id, served, :section, workspace.language, page, lastmod, listed?)
  end

  # The address `kind`'s path makes with these captures in the site's URL mode, while its page
  # answers `language` and its record is `listed?`.
  defp address(site_id, served, kind, language, captures, lastmod, listed?) do
    for {path, languages} <- [served[kind]],
        listed?,
        language in languages,
        address = Languages.url(path, captures, site_id),
        is_binary(address),
        do: %{path: address, lastmod: lastmod}
  end

  # The documents a visitor who is not signed in may open, in these languages.
  defp workspaces(site_id, languages) do
    Workspace
    |> Ash.Query.for_read(:public_list, %{}, actor: nil, tenant: site_id)
    |> Ash.Query.filter(language in ^languages)
    |> Ash.Query.select([:id, :slug, :path, :language, :updated_at, :permissions, :seo_tags])
    |> SitemapCompiler.stream_rows(actor: nil, tenant: site_id)
  end

  # `doc-section`'s own rule for the version a reader is shown: the one marked latest among the
  # published ones, else the newest published. A draft marked latest is not among them. Each
  # document's first in that order, for a batch of them in one read.
  defp current_versions(site_id, workspaces) do
    workspace_ids = Enum.map(workspaces, & &1.id)

    WorkspaceVersion
    |> Ash.Query.for_read(:public_list, %{}, actor: nil, tenant: site_id)
    |> Ash.Query.filter(workspace_id in ^workspace_ids)
    |> Ash.Query.select([:id, :workspace_id])
    |> Ash.Query.sort(
      workspace_id: :asc,
      is_latest_for_version: :desc,
      published_at: :desc_nils_last,
      inserted_at: :desc,
      id: :desc
    )
    |> Ash.Query.distinct(:workspace_id)
    |> Ash.read!(actor: nil, tenant: site_id, page: false)
    |> Map.new(&{&1.workspace_id, &1.id})
  end

  # Each version's pages' own parts of their addresses, `%{version_id => %{section_id => slugs}}`,
  # read off the same pages `sections/2` streams, held for one batch.
  defp tree_paths(_site_id, []), do: %{}

  defp tree_paths(site_id, version_ids) do
    Section
    |> Ash.Query.for_read(:public_list, %{}, actor: nil, tenant: site_id)
    |> Ash.Query.filter(workspace_version_id in ^version_ids)
    |> Ash.Query.select([
      :id,
      :slug,
      :parent_section_id,
      :front_page,
      :group_heading,
      :group_page,
      :workspace_version_id
    ])
    |> Ash.read!(actor: nil, tenant: site_id, page: false)
    |> Enum.group_by(& &1.workspace_version_id)
    |> Map.new(fn {version_id, pages} -> {version_id, Address.paths(pages)} end)
  end

  # The approved pages of these versions a visitor who is not signed in may open, the ones
  # `doc-section` draws for them, in one stream.
  defp sections(_site_id, []), do: []

  defp sections(site_id, version_ids) do
    Section
    |> Ash.Query.for_read(:public_list, %{}, actor: nil, tenant: site_id)
    |> Ash.Query.filter(workspace_version_id in ^version_ids)
    |> Ash.Query.select([
      :id,
      :slug,
      :front_page,
      :group_heading,
      :group_page,
      :updated_at,
      :workspace_version_id,
      :permissions,
      :seo_tags
    ])
    |> Ash.Query.load(:effective_permissions)
    |> SitemapCompiler.stream_rows(actor: nil, tenant: site_id)
  end
end
