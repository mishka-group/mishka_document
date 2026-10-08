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
  at the address the site's URL mode gives that language (`MishkaCmsCore.Runtime.Languages.url/3`).
  An address is listed only while the site serves its page: the page at that exact path is among
  `pages`, and it answers the document's language
  (`MishkaCmsCore.Runtime.PageEditions.served_languages/2`). A page moved to another path, taken
  down, closed to visitors or marked noindex lists nothing.

  READ AS A VISITOR WHO IS NOT SIGNED IN, through the public actions, because a sitemap is for
  anyone: a document that names a permission, and a page that opens with one — its own, or its
  nearest parent page's (`MishkaDocument.Resources.Calculations.EffectivePermissions`) — is left out
  of the reads themselves (`MishkaDocument.Resources.Preparations.OpenToActor`), so a locked
  document's pages are never read and nothing locked is listed.

  And only while its record may be listed (`MishkaCmsCore.Runtime.PageEditions.listed?/2`): a
  document whose robots meta says `noindex` or `none` lists neither its front page nor a page of it
  that holds no robots meta of its own; a page whose own robots meta says so is left out alone.

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
  site has, one batch of each is held at a time. Each address is listed once: a document's slug is
  unique on its site, and a page's in its version.

  Registered in `MishkaDocument.Application`.
  """

  use MishkaInstaller.Event.Hook, event: "seo:sitemap:urls", initial: %{priority: 60}

  require Ash.Query

  alias MishkaCmsCore.Runtime.{Languages, PageEditions}
  alias MishkaCmsCore.Runtime.Compilers.SitemapCompiler
  alias MishkaDocument.{Provision, Section, Workspace, WorkspaceVersion}

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

    languages =
      served
      |> Enum.flat_map(fn {_kind, {_path, languages}} -> languages end)
      |> Enum.uniq()

    # A `urls` that is not an `Enumerable` is handed on as it came, for core to leave out.
    case Enumerable.impl_for(urls) && languages do
      [_ | _] ->
        {:reply, %{data | urls: Stream.concat(urls, document_urls(site_id, languages, served))}}

      _nothing_to_add ->
        {:reply, data}
    end
  end

  def call(data), do: {:reply, data}

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

    site_id
    |> sections(Map.keys(shown))
    |> Stream.transform(
      fn ->
        Map.new(shown, fn {version_id, workspace} -> {version_id, workspace.updated_at} end)
      end,
      fn section, changed ->
        workspace = shown[section.workspace_version_id]
        page = Map.put(front(workspace), "section", section.slug)

        {address(
           site_id,
           served,
           :section,
           workspace.language,
           page,
           section.updated_at,
           PageEditions.listed?(
             %{section | permissions: section.effective_permissions},
             workspace
           )
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
    |> Ash.Query.select([:id, :slug, :language, :updated_at, :permissions, :seo_tags])
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

  # The approved pages of these versions a visitor who is not signed in may open, the ones
  # `doc-section` draws for them, in one stream.
  defp sections(_site_id, []), do: []

  defp sections(site_id, version_ids) do
    Section
    |> Ash.Query.for_read(:public_list, %{}, actor: nil, tenant: site_id)
    |> Ash.Query.filter(workspace_version_id in ^version_ids)
    |> Ash.Query.select([:slug, :updated_at, :workspace_version_id, :permissions, :seo_tags])
    |> Ash.Query.load(:effective_permissions)
    |> SitemapCompiler.stream_rows(actor: nil, tenant: site_id)
  end
end
