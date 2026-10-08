defmodule MishkaDocument.Plugins.SitemapUrlsTest do
  @moduledoc """
  What the documentation adds to a site's `/sitemap.xml`: each active document's front page and the
  approved pages of the version a reader is shown, at the addresses the site's own document pages
  answer, in the document's language.

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
  alias MishkaCmsCore.Runtime.{Languages, PageEditions}
  alias MishkaCmsCore.Runtime.States.{AssetsState, SettingsState, SiteState}
  alias MishkaCmsCore.Settings
  alias MishkaDocument.Plugins.SitemapUrls
  alias MishkaDocument.Provision
  alias MishkaDocument.Workspace
  alias MishkaInstaller.Event.EventHandler
  alias MishkaInstaller.Event.Hook

  @moduletag :integration

  @january ~U[2026-01-01 00:00:00Z]
  @february ~U[2026-02-01 00:00:00Z]
  @march ~U[2026-03-01 00:00:00Z]

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

  describe "what is never listed" do
    test "a document that is not active, or has no published version", %{site: site} do
      published!(site, "drafted", status: :draft)
      published!(site, "shelved", status: :archived)

      unpublished = document!(site, slug: "unpublished")

      draft =
        version!(site, unpublished,
          status: :draft,
          published_at: nil,
          is_latest_for_version: true
        )

      page!(site, draft, "unpublished-intro")

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
                 english(mode, "/docs/guide/open-child")
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
