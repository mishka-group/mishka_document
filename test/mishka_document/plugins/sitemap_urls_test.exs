# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_document/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaDocument.Plugins.SitemapUrlsTest do
  @moduledoc """
  What the documentation adds to a site's `/sitemap.xml`: each active document's front page and the
  approved pages of the version a reader is shown, at the addresses the site's own document pages
  answer, in the document's language. What is listed is what the head of its page lets a search
  engine index: the last describe holds each kind to the robots meta `MishkaDocument.Plugins.PageSeo`
  and core's head write for it.

  The pages are the ones `MishkaDocument.Provision.ensure!/1` writes, handed over the way
  `MishkaCmsCore.Runtime.Compilers.SitemapCompiler` hands them — the site's indexable pages holding a
  capture besides the language — with the addresses so far as a stream. The plugin is called
  directly, and registered by hand where the event is fired: this suite's data case registers no
  plugins. What it returns is a stream too, read here as the build reads it.

  EVERY STATUS IS PINNED. The generators pick a document's and a version's status at random and
  start every page in review, and any one of them left to the generator decides whether an address
  is listed.
  """
  use MishkaDocument.DataCase,
    async: false,
    parameterize: for(mode <- ~w(prefix_others prefix_all), do: %{mode: mode})

  alias MishkaCmsCore.Helpers
  alias MishkaCmsCore.Runtime.Compilers.SitemapCompiler
  alias MishkaCmsCore.Runtime.{Languages, PageEditions, Seo}
  alias MishkaCmsCore.Runtime.States.{AssetsState, SettingsState, SiteState}
  alias MishkaCmsCore.Settings
  alias MishkaDocument.Plugins.{PageSeo, SitemapUrls}
  alias MishkaDocument.Provision
  alias MishkaDocument.Workspace
  alias MishkaInstaller.Event.EventHandler
  alias MishkaInstaller.Event.Hook

  @moduletag :integration

  @january ~U[2026-01-01 00:00:00Z]
  @february ~U[2026-02-01 00:00:00Z]
  @march ~U[2026-03-01 00:00:00Z]
  @april ~U[2026-04-01 00:00:00Z]

  setup %{mode: mode} do
    name = "sitemapdocs#{System.unique_integer([:positive])}"
    site = create_site!(name: name, host: "#{name}.test", active: true)

    on_exit(fn ->
      SettingsState.delete(site.id, "site.languages")
      SettingsState.delete(site.id, "site.language_urls")
    end)

    {:ok, _} = Settings.put("site.languages", ["en", "fa"], site_id: site.id)
    {:ok, _} = Settings.put("site.language_urls", mode, site_id: site.id)

    Provision.ensure!(site)

    {:ok, site: site}
  end

  # Where English, the site's first language, puts `path` in `mode`: under no prefix while the first
  # language goes without one, under its own once every language carries one.
  defp english("prefix_others", path), do: path
  defp english("prefix_all", path), do: "/en" <> path

  # What `MishkaCmsCore.Runtime.Compilers.SitemapCompiler` hands the plugins.
  defp handed(site) do
    {pages, _hidden} = PageEditions.indexable(site.id)

    Enum.reject(
      pages,
      &(Languages.url(&1.path, %{}, site.id) || PageEditions.language_only?(&1.path))
    )
  end

  defp listed(site, pages \\ nil, urls \\ []) do
    assert {:reply, %{urls: listed}} =
             SitemapUrls.call(%{site: site, pages: pages || handed(site), urls: stream(urls)})

    Enum.to_list(listed)
  end

  # Addresses as core hands them: a stream nothing is read from until the build reads it.
  defp stream(urls), do: Stream.map(urls, & &1)

  defp paths(urls), do: urls |> Enum.map(& &1.path) |> Enum.sort()

  defp page_reads(reads), do: Enum.count(reads, &(&1 =~ ~s("mishka_document_sections")))

  # What `fun` returns, and the SQL of every query the repo ran meanwhile.
  defp reads_while(fun) do
    handler = "sitemap-reads-#{System.unique_integer([:positive])}"
    test = self()

    :ok =
      :telemetry.attach(
        handler,
        [:mishka_document, :repo, :query],
        fn _event, _measurements, meta, _config -> send(test, {handler, meta.query}) end,
        nil
      )

    on_exit(fn -> :telemetry.detach(handler) end)
    result = fun.()
    :telemetry.detach(handler)
    {result, drain(handler, [])}
  end

  defp drain(handler, reads) do
    receive do
      {^handler, query} -> drain(handler, [query | reads])
    after
      0 -> Enum.reverse(reads)
    end
  end

  defp document!(site, attrs) do
    [site_id: site.id, skip_version: true, status: :active, language: "en"]
    |> Keyword.merge(attrs)
    |> create_workspace!()
  end

  defp version!(site, document, attrs) do
    [
      site_id: site.id,
      workspace_id: document.id,
      status: :stable,
      is_latest_for_version: false,
      published_at: @january
    ]
    |> Keyword.merge(attrs)
    |> create_workspace_version!()
  end

  defp page!(site, version, slug, attrs \\ []) do
    [
      site_id: site.id,
      workspace_version_id: version.id,
      slug: slug,
      language: "en",
      content_review_status: :approved,
      technical_review_status: :approved
    ]
    |> Keyword.merge(attrs)
    |> create_section!()
  end

  defp robots_meta(content), do: %{tag: "meta", attrs: %{"name" => "robots"}, content: content}

  # One active English document with one published version and one approved page.
  defp published!(site, slug, attrs \\ []) do
    document = document!(site, [slug: slug] ++ attrs)
    version = version!(site, document, [])
    page!(site, version, "#{slug}-intro")
    document
  end

  # A DOCUMENT WITH AN ADDRESS OF ITS OWN is listed there, its pages under it — never under /docs,
  # which would list one page at two addresses. Its front page is a page of the site at a fixed path,
  # which the sitemap lists as one, so only its pages are added here.
  describe "a document with an address of its own" do
    test "lists its pages under the address, each under the pages it is filed under",
         %{site: site} do
      document = document!(site, slug: "product", path: "/product/docs")
      version = version!(site, document, is_latest_for_version: true)
      install = page!(site, version, "install")
      page!(site, version, "steps", parent_section_id: install.id)

      assert paths(listed(site)) == ["/product/docs/install", "/product/docs/install/steps"]
    end

    # ITS FRONT PAGE IS THE ADDRESS ITSELF, which the sitemap already lists as a page of the site.
    test "lists no front page of its own, and the pages under it directly under the address",
         %{site: site} do
      document = document!(site, slug: "product", path: "/product/docs")
      version = version!(site, document, is_latest_for_version: true)
      front = page!(site, version, "get-started", front_page: true)
      page!(site, version, "install", parent_section_id: front.id)
      page!(site, version, "upgrading")

      assert paths(listed(site)) == ["/product/docs/install", "/product/docs/upgrading"]
    end

    # A GROUP IS ONLY A HEADING, with no address to list, and its pages are listed as if it were not
    # there.
    test "lists no group, and the pages under one directly under the address", %{site: site} do
      document = document!(site, slug: "product", path: "/product/docs")
      version = version!(site, document, is_latest_for_version: true)
      group = page!(site, version, "navigation", group_heading: true)
      page!(site, version, "breadcrumb", parent_section_id: group.id)

      assert paths(listed(site)) == ["/product/docs/breadcrumb"]
    end

    test "lists a group with a page of its own at its slug, and its pages as before", %{
      site: site
    } do
      document = document!(site, slug: "product", path: "/product/docs")
      version = version!(site, document, is_latest_for_version: true)
      group = page!(site, version, "navigation", group_heading: true, group_page: true)
      page!(site, version, "breadcrumb", parent_section_id: group.id)

      assert Enum.sort(paths(listed(site))) ==
               ["/product/docs/breadcrumb", "/product/docs/navigation"]
    end

    test "lists nothing for it once the page at its address is gone", %{site: site} do
      document = document!(site, slug: "product", path: "/product/docs")
      version = version!(site, document, is_latest_for_version: true)
      page!(site, version, "install")

      pages = Enum.reject(handed(site), &(&1.path == "/product/docs/*section"))

      assert paths(listed(site, pages)) == []
    end

    # ITS FRONT PAGE IS ONE CORE LISTS, as a page of the site at a fixed path: a document whose
    # robots meta keeps it out of an index takes that address out of what core lists.
    test "takes its front page out of core's addresses while it may not be listed", %{site: site} do
      for {slug, attrs} <- [
            {"product", [seo_tags: [robots_meta("noindex, follow")]]},
            {"tool", []},
            {"members", [permissions: ["members:read"]]},
            {"shelved", [status: :draft]}
          ] do
        document = document!(site, [slug: slug, path: "/#{slug}/docs"] ++ attrs)
        version = version!(site, document, is_latest_for_version: true)
        page!(site, version, "#{slug}-start", front_page: true)
      end

      core =
        for path <- ~w(/about /product/docs /tool/docs /members/docs /shelved/docs),
            do: %{path: path, lastmod: nil}

      assert paths(listed(site, nil, core)) == ["/about", "/tool/docs"]
    end

    test "takes it out while no document stands at the address", %{site: site} do
      document = document!(site, slug: "tool", path: "/tool/docs")
      version!(site, document, is_latest_for_version: true)
      create_page!(site_id: site.id, path: "/nobody/docs/*section", active: true, permissions: [])

      core = for path <- ~w(/about /tool/docs /nobody/docs), do: %{path: path, lastmod: nil}

      assert paths(listed(site, nil, core)) == ["/about", "/tool/docs"]
    end
  end

  describe "a published document" do
    test "is listed at its front page and each approved page of the version marked latest",
         %{site: site, mode: mode} do
      document = document!(site, slug: "guide")
      older = version!(site, document, published_at: @january)
      current = version!(site, document, published_at: @february, is_latest_for_version: true)

      page!(site, older, "older-install")
      install = page!(site, current, "install")
      page!(site, current, "in-review", technical_review_status: :pending)
      page!(site, current, "unread", content_review_status: :pending)
      page!(site, current, "sent-back", content_review_status: :rejected)

      core = %{path: "/about", lastmod: nil}
      [first | urls] = listed(site, nil, [core])

      assert first == core
      assert paths(urls) == [english(mode, "/docs/guide"), english(mode, "/docs/guide/install")]

      stored = Ash.get!(Workspace, document.id, tenant: site.id, authorize?: false)
      front = Enum.find(urls, &(&1.path == english(mode, "/docs/guide")))
      assert front.lastmod == Enum.max([stored.updated_at, install.updated_at], DateTime)

      assert Enum.find(urls, &(&1.path == english(mode, "/docs/guide/install"))).lastmod ==
               install.updated_at
    end

    # A FRONT PAGE IS DRAWN AT ITS DOCUMENT'S ADDRESS, so it is listed as that address and dates
    # it, and never under its own slug, which is a missing page.
    test "lists a front page at its document's address alone, which it dates", %{
      site: site,
      mode: mode
    } do
      document = document!(site, slug: "guide")
      version = version!(site, document, is_latest_for_version: true)
      front = page!(site, version, "get-started", front_page: true)
      page!(site, version, "install", parent_section_id: front.id)

      urls = listed(site)

      assert paths(urls) == [english(mode, "/docs/guide"), english(mode, "/docs/guide/install")]

      dated = Enum.find(urls, &(&1.path == english(mode, "/docs/guide"))).lastmod
      assert DateTime.compare(dated, front.updated_at) != :lt
    end

    test "shows the version an editor marked latest over a newer published one", %{
      site: site,
      mode: mode
    } do
      document = document!(site, slug: "guide")
      marked = version!(site, document, published_at: @january, is_latest_for_version: true)
      newer = version!(site, document, published_at: @february)

      page!(site, marked, "marked-page")
      page!(site, newer, "newer-page")

      assert paths(listed(site)) == [
               english(mode, "/docs/guide"),
               english(mode, "/docs/guide/marked-page")
             ]
    end

    test "falls back to the newest published version when the one marked latest is a draft",
         %{site: site, mode: mode} do
      document = document!(site, slug: "guide")
      beta = version!(site, document, status: :beta, published_at: @january)
      stable = version!(site, document, status: :stable, published_at: @february)
      retired = version!(site, document, status: :archived, published_at: @march)

      draft =
        version!(site, document, status: :draft, published_at: nil, is_latest_for_version: true)

      for {version, slug} <- [{beta, "beta"}, {stable, "stable"}, {retired, "retired"}],
          do: page!(site, version, "#{slug}-page")

      page!(site, draft, "draft-page")

      assert paths(listed(site)) == [
               english(mode, "/docs/guide"),
               english(mode, "/docs/guide/stable-page")
             ]
    end
  end

  # A DOCUMENT WITH NO PUBLISHED VERSION STILL DRAWS ITS FRONT PAGE, and the head of that page lets
  # a search engine index it, so it is listed, dated by the document, with no page of it: the pages
  # of a draft version are nobody's to read.
  describe "a document with no published version" do
    test "lists its front page alone, dated by the document", %{site: site, mode: mode} do
      unpublished = document!(site, slug: "unpublished")

      draft =
        version!(site, unpublished,
          status: :draft,
          published_at: nil,
          is_latest_for_version: true
        )

      page!(site, draft, "unpublished-intro")
      bare = document!(site, slug: "bare")

      assert site |> listed() |> Map.new(&{&1.path, &1.lastmod}) == %{
               english(mode, "/docs/unpublished") => stored_at(site, unpublished),
               english(mode, "/docs/bare") => stored_at(site, bare)
             }
    end

    test "is not listed while it is locked, noindex or in a language its page does not answer",
         %{site: site} do
      document!(site, slug: "members", permissions: ["members:read"])
      document!(site, slug: "hidden", seo_tags: [robots_meta("noindex")])
      document!(site, slug: "anleitung", language: "de")

      assert listed(site) == []
    end

    defp stored_at(site, document),
      do: Ash.get!(Workspace, document.id, tenant: site.id, authorize?: false).updated_at
  end

  # A PAGE IS DATED BY WHEN IT LAST CHANGED: its own time, its approved notes' and the time one of
  # them was archived. Nothing is written to the page when a note changes, and a document's front
  # page takes the newest of its pages'.
  describe "a page's date" do
    setup %{site: site, mode: mode} do
      document = document!(site, slug: "guide")
      Ash.Seed.update!(document, %{updated_at: @january})
      version = version!(site, document, is_latest_for_version: true)
      page = Ash.Seed.update!(page!(site, version, "install"), %{updated_at: @february})

      {:ok,
       page: page,
       version: version,
       front: english(mode, "/docs/guide"),
       address: english(mode, "/docs/guide/install")}
    end

    defp lastmods(site),
      do: site |> listed() |> Map.new(&{&1.path, DateTime.truncate(&1.lastmod, :second)})

    test "is its own while it has no notes", ctx do
      assert lastmods(ctx.site) == %{ctx.front => @february, ctx.address => @february}
    end

    test "moves to a note edited after it, and its document's front page with it", ctx do
      create_shown_note!(ctx.page, @january)
      create_shown_note!(ctx.page, @march)

      assert lastmods(ctx.site) == %{ctx.front => @march, ctx.address => @march}

      stored =
        Ash.get!(MishkaDocument.Section, ctx.page.id, tenant: ctx.site.id, authorize?: false)

      assert DateTime.truncate(stored.updated_at, :second) == @february
    end

    test "moves to the time one of its notes was archived", ctx do
      ctx.page |> create_shown_note!(@january) |> archive_note_at!(@april)

      assert lastmods(ctx.site) == %{ctx.front => @april, ctx.address => @april}
    end

    test "stays its own while it is newer than its notes", ctx do
      create_shown_note!(ctx.page, @january)

      assert lastmods(ctx.site) == %{ctx.front => @february, ctx.address => @february}
    end

    test "does not move for a note its page does not show", ctx do
      create_shown_note!(ctx.page, @march, content_review_status: :pending)
      create_shown_note!(ctx.page, @april, technical_review_status: :rejected)

      assert lastmods(ctx.site) == %{ctx.front => @february, ctx.address => @february}
    end

    test "moves only the page whose note changed", ctx do
      other = Ash.Seed.update!(page!(ctx.site, ctx.version, "steps"), %{updated_at: @february})
      create_shown_note!(other, @march)

      assert lastmods(ctx.site) == %{
               ctx.front => @march,
               ctx.address => @february,
               String.replace(ctx.address, "install", "steps") => @march
             }
    end

    test "is read with the pages, never with a read of its own", ctx do
      {bare, bare_reads} = reads_while(fn -> listed(ctx.site) end)

      for slug <- ["beta", "gamma"] do
        version = version!(ctx.site, document!(ctx.site, slug: slug), [])
        create_shown_note!(page!(ctx.site, version, "#{slug}-intro"), @march)
      end

      create_shown_note!(ctx.page, @march)
      {noted, noted_reads} = reads_while(fn -> listed(ctx.site) end)

      assert length(bare) == 2
      assert length(noted) == 6
      assert page_reads(noted_reads) == page_reads(bare_reads)

      assert Enum.all?(noted_reads, fn query ->
               not (query =~ ~s("mishka_document_notes")) or
                 query =~ ~s("mishka_document_sections")
             end)
    end
  end

  describe "what is never listed" do
    test "a document that is not active", %{site: site} do
      published!(site, "drafted", status: :draft)
      published!(site, "shelved", status: :archived)

      assert listed(site) == []
    end

    test "a document in a language the site does not publish", %{site: site} do
      published!(site, "rahnama", language: "fa")
      published!(site, "anleitung", language: "de")

      assert paths(listed(site)) == ["/fa/docs/rahnama", "/fa/docs/rahnama/rahnama-intro"]
    end

    test "a document in a language its page does not answer", %{site: site, mode: mode} do
      published!(site, "guide")
      published!(site, "rahnama", language: "fa")
      %{section: inner} = Provision.item_paths()

      # The page of a document now answers English alone; the front page still answers both.
      pages = Enum.map(handed(site), &if(&1.path == inner, do: %{&1 | extra: %{}}, else: &1))

      assert paths(listed(site, pages)) == [
               english(mode, "/docs/guide"),
               english(mode, "/docs/guide/guide-intro"),
               "/fa/docs/rahnama"
             ]
    end

    test "an address whose page the site does not serve", %{site: site, mode: mode} do
      published!(site, "guide")
      %{workspace: front, section: inner} = Provision.item_paths()

      assert listed(site, []) == []

      assert paths(listed(site, Enum.reject(handed(site), &(&1.path == inner)))) == [
               english(mode, "/docs/guide")
             ]

      assert paths(listed(site, Enum.reject(handed(site), &(&1.path == front)))) == [
               english(mode, "/docs/guide/guide-intro")
             ]
    end
  end

  # READ AS A VISITOR WHO IS NOT SIGNED IN: a locked document or page is left out of the read itself,
  # whoever holds the lock.
  describe "a record kept out of an index" do
    test "a document that names a permission lists nothing, and its pages are never read",
         %{site: site, mode: mode} do
      published!(site, "members", permissions: ["members:read"])

      {urls, reads} = reads_while(fn -> listed(site) end)

      assert urls == []
      refute Enum.any?(reads, &(&1 =~ ~s("mishka_document_sections")))

      published!(site, "guide")

      assert paths(listed(site)) == [
               english(mode, "/docs/guide"),
               english(mode, "/docs/guide/guide-intro")
             ]
    end

    test "a noindex document lists no page of it but one whose own robots meta allows it",
         %{site: site, mode: mode} do
      for directive <- ["noindex", "none"] do
        document = document!(site, slug: directive, seo_tags: [robots_meta(directive)])
        version = version!(site, document, [])

        page!(site, version, "#{directive}-inherits")
        page!(site, version, "#{directive}-own", seo_tags: [robots_meta("index, follow")])
      end

      assert paths(listed(site)) == [
               english(mode, "/docs/noindex/noindex-own"),
               english(mode, "/docs/none/none-own")
             ]
    end

    test "a page that names a permission, or whose own robots meta says noindex, is left out alone",
         %{site: site, mode: mode} do
      document = document!(site, slug: "guide")
      version = version!(site, document, [])

      page!(site, version, "open")
      page!(site, version, "locked", permissions: ["members:read"])
      page!(site, version, "hidden", seo_tags: [robots_meta("noindex, follow")])

      assert paths(listed(site)) == [
               english(mode, "/docs/guide"),
               english(mode, "/docs/guide/open")
             ]
    end

    test "a page under a locked page, however deep, is left out with it", %{
      site: site,
      mode: mode
    } do
      version = version!(site, document!(site, slug: "guide"), [])

      open = page!(site, version, "open")
      page!(site, version, "open-child", parent_section_id: open.id)
      locked = page!(site, version, "locked", permissions: ["members:read"])
      child = page!(site, version, "locked-child", parent_section_id: locked.id)
      page!(site, version, "locked-grandchild", parent_section_id: child.id)

      assert paths(listed(site)) ==
               [
                 english(mode, "/docs/guide"),
                 english(mode, "/docs/guide/open"),
                 english(mode, "/docs/guide/open/open-child")
               ]
    end
  end

  describe "read as the build reads it" do
    test "reads nothing until what it returns is read", %{site: site, mode: mode} do
      assert {:reply, %{urls: urls}} =
               SitemapUrls.call(%{site: site, pages: handed(site), urls: stream([])})

      published!(site, "guide")

      assert paths(urls) == [
               english(mode, "/docs/guide"),
               english(mode, "/docs/guide/guide-intro")
             ]
    end

    test "lists every document, past the most one read returns", %{site: site, mode: mode} do
      slugs = for n <- 1..101, do: "guide-#{String.pad_leading("#{n}", 3, "0")}"

      for slug <- slugs, do: version!(site, document!(site, slug: slug), [])

      assert paths(listed(site)) == Enum.map(slugs, &english(mode, "/docs/#{&1}"))
    end

    # ONE READ OF THE PAGES FOR A BATCH OF DOCUMENTS, never one for each document — and the reads
    # the public action makes to keep a locked page out are made once for the batch too.
    test "reads the pages of a batch of documents together", %{site: site} do
      published!(site, "alpha")
      {one, one_read} = reads_while(fn -> listed(site) end)

      for slug <- ["beta", "gamma"], do: published!(site, slug)
      {three, three_read} = reads_while(fn -> listed(site) end)

      assert length(one) == 2
      assert length(three) == 6
      assert page_reads(three_read) == page_reads(one_read)
    end

    test "lists every page of a document, past the most one read returns", %{
      site: site,
      mode: mode
    } do
      document = document!(site, slug: "guide")
      version = version!(site, document, [])

      pages =
        for n <- 1..101, do: page!(site, version, "page-#{String.pad_leading("#{n}", 3, "0")}")

      urls = listed(site)

      assert paths(urls) ==
               Enum.sort([
                 english(mode, "/docs/guide")
                 | Enum.map(pages, &english(mode, "/docs/guide/#{&1.slug}"))
               ])

      stored = Ash.get!(Workspace, document.id, tenant: site.id, authorize?: false)
      changed = Enum.max([stored.updated_at | Enum.map(pages, & &1.updated_at)], DateTime)

      assert Enum.find(urls, &(&1.path == english(mode, "/docs/guide"))).lastmod == changed
    end
  end

  # EACH KIND'S LISTING IS HELD TO THE HEAD ITS PAGE WRITES. A document's front page and a page of it
  # are listed exactly when the robots meta `MishkaDocument.Plugins.PageSeo` and core's head give them
  # lets a search engine index them and they open with no permission — a locked page is one a crawler
  # is sent away from, whatever it says.
  describe "what is listed is what the head lets a search engine index" do
    @host "docs.example.com"

    defp base, do: Seo.base(@host)

    # The head core builds for the `kind` page that `params` name, as `MishkaCmsWeb.RuntimeLive`
    # builds it: whether its robots meta says index, and what it opens with.
    defp head_of(site, kind, params) do
      path = Provision.item_paths()[kind]

      given =
        Seo.given(
          %{
            title: "Document page",
            path: path,
            language: "en",
            seo: %{description: nil, schema: []}
          },
          site_id: site.id,
          url: base() <> Languages.url(path, params, site.id),
          params: params,
          record: Map.fetch!(%{workspace: "docs:document", section: "docs:page"}, kind)
        )

      {:reply, :halt, answered} = PageSeo.call(given)
      head = answered |> Seo.accept(given) |> Seo.head(base: base())

      directives =
        for {"meta", attrs} <- head.tags,
            {"name", "robots"} in attrs,
            {"content", content} <- attrs,
            directive <- String.split(content, [",", " "], trim: true),
            do: directive

      %{
        indexed?: directives != [] and directives -- ["noindex", "none"] == directives,
        permissions: head.permissions,
        shown?: not is_nil(head.title)
      }
    end

    # Every `{kind, params, address}` against the sitemap: listed when and only when its page is
    # shown, says index and opens with no permission; and at least one of each in the set, so that
    # neither side is vacuous.
    defp assert_listed_as_indexed(site, rows) do
      listed = MapSet.new(paths(listed(site)))

      verdicts =
        for {kind, params, address} <- rows do
          head = head_of(site, kind, params)
          says = head.shown? and head.indexed? and head.permissions == []

          assert MapSet.member?(listed, address) == says,
                 "#{address} is #{if says, do: "indexable", else: "not indexable"} but " <>
                   "#{if MapSet.member?(listed, address), do: "listed", else: "not listed"}"

          says
        end

      assert true in verdicts and false in verdicts
    end

    defp front(slug, mode),
      do: {:workspace, %{"lang" => "en", "workspace" => slug}, english(mode, "/docs/#{slug}")}

    defp inner(slug, page_path, mode) do
      {:section, %{"lang" => "en", "workspace" => slug, "section" => page_path},
       english(mode, "/docs/#{slug}/#{page_path}")}
    end

    test "a document's front page, with a published version and without", %{
      site: site,
      mode: mode
    } do
      overrides = [
        {"open", []},
        {"indexed", [seo_tags: [robots_meta("index, follow")]]},
        {"noindex", [seo_tags: [robots_meta("noindex, follow")]]},
        {"none", [seo_tags: [robots_meta("none")]]},
        {"locked", [permissions: ["members:read"]]}
      ]

      for {slug, attrs} <- overrides do
        version!(site, document!(site, [slug: slug] ++ attrs), [])
        document!(site, [slug: "bare-#{slug}"] ++ attrs)
      end

      rows =
        for {slug, _attrs} <- overrides,
            slug <- [slug, "bare-#{slug}"],
            do: front(slug, mode)

      assert_listed_as_indexed(site, rows)
    end

    test "a page of a document: its own robots meta, else its document's, and its locks", %{
      site: site,
      mode: mode
    } do
      open = version!(site, document!(site, slug: "open"), [])

      hidden =
        version!(site, document!(site, slug: "hidden", seo_tags: [robots_meta("noindex")]), [])

      locked = version!(site, document!(site, slug: "locked", permissions: ["members:read"]), [])

      page!(site, open, "plain")
      page!(site, open, "noindex", seo_tags: [robots_meta("noindex, follow")])
      page!(site, open, "none", seo_tags: [robots_meta("none")])
      page!(site, open, "indexed", seo_tags: [robots_meta("index, follow")])
      page!(site, open, "private", permissions: ["members:read"])
      parent = page!(site, open, "parent", permissions: ["members:read"])
      page!(site, open, "child", parent_section_id: parent.id)

      page!(site, hidden, "inherits")
      page!(site, hidden, "own", seo_tags: [robots_meta("index, follow")])
      page!(site, locked, "inside")

      assert_listed_as_indexed(site, [
        inner("open", "plain", mode),
        inner("open", "noindex", mode),
        inner("open", "none", mode),
        inner("open", "indexed", mode),
        inner("open", "private", mode),
        inner("open", "parent/child", mode),
        inner("hidden", "inherits", mode),
        inner("hidden", "own", mode),
        inner("locked", "inside", mode)
      ])
    end
  end

  describe "the plugin" do
    test "is one of the plugins this extension's supervisor starts" do
      assert SitemapUrls in MishkaDocument.Application.plugins()
    end

    # Registered by hand for the reason `MishkaDocument.ProvisionTest`'s `listening!/0` gives: this
    # suite's registry is not up when the extension's supervisor starts its plugins.
    test "answers `seo:sitemap:urls`, the event core fires", %{site: site, mode: mode} do
      {:ok, _registered} = SitemapUrls.register()
      :ok = EventHandler.do_compile("seo:sitemap:urls", :start, false)

      published!(site, "guide")

      assert %{urls: urls} =
               Hook.call("seo:sitemap:urls", %{site: site, pages: handed(site), urls: stream([])})

      assert paths(urls) == [
               english(mode, "/docs/guide"),
               english(mode, "/docs/guide/guide-intro")
             ]
    end

    # THE CONTRACT AS CORE READS IT: the build of the site's sitemap reads the stream this returns
    # and writes each address on the site's own address.
    test "is read by the build of the site's sitemap, on the site's own address", %{
      site: site,
      mode: mode
    } do
      {:ok, _registered} = SitemapUrls.register()
      :ok = EventHandler.do_compile("seo:sitemap:urls", :start, false)

      :ok =
        SiteState.save(%{
          id: site.id,
          name: site.name,
          host: site.host,
          priority: site.priority,
          active: true,
          master: site.master
        })

      on_exit(fn ->
        SiteState.delete(site.id)
        AssetsState.delete(site.name, "sitemap")
      end)

      published!(site, "guide")

      assert {:ok, %{files: %{"sitemap-00001.xml.gz" => gz}}} =
               SitemapCompiler.compile_and_store(site.name)

      origin = Helpers.site_url(site.host, "")
      file = :zlib.gunzip(gz)

      assert file =~ "<loc>#{origin}#{english(mode, "/docs/guide")}</loc>"
      assert file =~ "<loc>#{origin}#{english(mode, "/docs/guide/guide-intro")}</loc>"
    end

    test "fills the addresses of two of the sample pages" do
      %{workspace: front, section: inner} = Provision.item_paths()

      assert front in Provision.page_paths()
      assert inner in Provision.page_paths()
    end

    test "hands a payload with no site on untouched" do
      payload = %{site: nil, pages: [], urls: [%{path: "/about", lastmod: nil}]}

      assert SitemapUrls.call(payload) == {:reply, payload}
    end

    test "hands a payload whose addresses are not an Enumerable on untouched", %{site: site} do
      published!(site, "guide")
      payload = %{site: site, pages: handed(site), urls: nil}

      assert SitemapUrls.call(payload) == {:reply, payload}
    end
  end
end
