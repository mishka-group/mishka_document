# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_document/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaDocument.Plugins.PageSeoTest do
  @moduledoc """
  What the documentation answers on `runtime:page:seo`: the head of the document and the page of it
  the address names, and nothing on any other page.

  Each test hands the plugin the map `MishkaCmsWeb.RuntimeLive` hands it — `Seo.given/2` of the
  provisioned page — and reads what it returns. Every status is pinned: the generators pick a
  document's and a version's at random and start every page in review.
  """
  use MishkaDocument.DataCase, async: false

  import Phoenix.Component, only: [sigil_H: 2]
  import Phoenix.LiveViewTest, only: [rendered_to_string: 1]

  alias MishkaCmsCore.Runtime.{Languages, Seo}
  alias MishkaCmsCore.Runtime.States.SettingsState
  alias MishkaCmsCore.Settings
  alias MishkaDocument.Plugins.PageSeo
  alias MishkaDocument.Provision
  alias MishkaDocument.Test.Plugins.PageSeoAnswer
  alias MishkaInstaller.Event.{Event, EventHandler}
  alias MishkaInstaller.Event.Hook

  @host "docs.example.com"

  @january ~U[2026-01-01 00:00:00Z]
  @march ~U[2026-03-01 00:00:00Z]
  @april ~U[2026-04-01 00:00:00Z]

  setup do
    site = create_site!(active: true)

    on_exit(fn ->
      SettingsState.delete(site.id, "site.languages")
      SettingsState.delete(site.id, "site.language_urls")
      SettingsState.delete(site.id, "site.title")
    end)

    {:ok, _} = Settings.put("site.languages", ["en", "fa"], site_id: site.id)
    {:ok, _} = Settings.put("site.title", "The Studio", site_id: site.id)

    {:ok, site: site}
  end

  # The site's address as core writes it in this environment.
  defp base, do: Seo.base(@host)

  # Where English, the site's first language, puts `path` in `mode`: under no prefix while the first
  # language goes without one, under its own once every language carries one.
  defp english("prefix_others", path), do: path
  defp english("prefix_all", path), do: "/en" <> path

  defp url_mode!(site, mode),
    do: {:ok, _} = Settings.put("site.language_urls", mode, site_id: site.id)

  # The map core hands the plugins for a request to the `kind` page, storing `schema`, with `params`.
  defp given(site, kind, params, schema \\ []) do
    path = Provision.item_paths()[kind]
    filled = Languages.url(path, params, site.id)

    Seo.given(
      %{
        title: "Document page",
        path: path,
        language: "en",
        seo: %{description: nil, schema: schema}
      },
      site_id: site.id,
      url: filled && base() <> filled,
      params: params,
      record: Map.get(%{workspace: "docs:document", section: "docs:page"}, kind)
    )
  end

  # A page of the documentation's own kinds is answered with `:halt`; any other is handed back.
  defp answer(given) do
    case PageSeo.call(given) do
      {:reply, :halt, answered} -> answered
      {:reply, answered} -> answered
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

  defp page!(site, version, slug, attrs) do
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

  defp schema_of(answered, type), do: Enum.find(answered.schema, &(&1["@type"] == type))

  defp crumbs(answered) do
    answered
    |> schema_of("BreadcrumbList")
    |> Map.fetch!("itemListElement")
    |> Enum.map(&{&1["position"], &1["name"], &1["item"]})
  end

  defp keys(var_docs), do: Enum.map(var_docs, & &1.key)

  defp robots_meta(content), do: %{tag: "meta", attrs: %{"name" => "robots"}, content: content}

  # The head core builds from the answer, with the CMS page's own layers empty.
  defp head(given), do: given |> answer() |> Seo.accept(given) |> Seo.head(base: base())

  # The head as `MishkaCmsWeb.RuntimeLive.page_head/1` writes it into the page.
  defp rendered_head(head) do
    assigns = %{seo: head}

    rendered_to_string(~H"""
    <meta :for={{"meta", attrs} <- @seo.tags} {attrs} />
    <script :for={json <- @seo.schema} type="application/ld+json">
      <%= Phoenix.HTML.raw(json) %>
    </script>
    """)
  end

  defp meta_content(html, selector),
    do:
      html
      |> LazyHTML.from_fragment()
      |> LazyHTML.query(selector)
      |> LazyHTML.attribute("content")

  defp json_ld(html, type) do
    html
    |> LazyHTML.from_fragment()
    |> LazyHTML.query(~s(script[type="application/ld+json"]))
    |> Enum.map(&(&1 |> LazyHTML.text() |> Jason.decode!()))
    |> Enum.find(&(&1["@type"] == type))
  end

  defp robots(head) do
    for {"meta", attrs} <- head.tags,
        {"name", "robots"} in attrs,
        do: attrs |> List.keyfind("content", 0) |> elem(1)
  end

  # What `fun` returns, and the SQL of every query the repo ran meanwhile.
  defp reads_while(fun) do
    handler = "page-seo-reads-#{System.unique_integer([:positive])}"
    test = self()

    :ok =
      :telemetry.attach(
        handler,
        [:mishka_document, :repo, :query],
        fn _event, _measurements, meta, _config -> send(test, {handler, meta.query}) end,
        nil
      )

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

  # The SQL of every query the repo ran while `fun` ran, each with the number of rows it returned.
  defp rows_while(fun) do
    handler = "page-seo-rows-#{System.unique_integer([:positive])}"
    test = self()

    :ok =
      :telemetry.attach(
        handler,
        [:mishka_document, :repo, :query],
        fn _event, _measurements, meta, _config ->
          rows =
            case meta.result do
              {:ok, %{num_rows: rows}} -> rows
              _unread -> nil
            end

          send(test, {handler, {meta.query, rows}})
        end,
        nil
      )

    _answered = fun.()
    :telemetry.detach(handler)
    drain(handler, [])
  end

  describe "a document's front page" do
    for mode <- ~w(prefix_others prefix_all) do
      test "is the document's own head, in #{mode}", %{site: site} do
        url_mode!(site, unquote(mode))
        document = document!(site, name: "Guide", slug: "guide", description: "How to use it.")
        url = base() <> english(unquote(mode), "/docs/guide")

        answered = answer(given(site, :workspace, %{"lang" => "en", "workspace" => "guide"}))

        assert answered.title == "Guide"
        assert answered.description == "How to use it."
        assert answered.type == "article"
        assert answered.card.eyebrow == "Documentation"

        assert %{
                 "headline" => "Guide",
                 "description" => "How to use it.",
                 "inLanguage" => "en",
                 "mainEntityOfPage" => ^url,
                 "publisher" => %{"name" => "The Studio"}
               } = schema_of(answered, "TechArticle")

        assert crumbs(answered) == [
                 {1, "Documentation", base() <> english(unquote(mode), "/docs")},
                 {2, "Guide", url}
               ]

        assert %{
                 "doc.title" => "Guide",
                 "doc.url" => ^url,
                 "workspace.name" => "Guide",
                 "workspace.description" => "How to use it.",
                 "workspace.url" => ^url
               } = answered.vars

        refute Map.has_key?(answered.vars, "doc.version")
        assert answered.vars["doc.modified_at"] == iso(document.updated_at)

        assert keys(answered.var_docs) == [
                 "doc.title",
                 "doc.description",
                 "doc.url",
                 "doc.version",
                 "doc.group",
                 "doc.published_at",
                 "doc.modified_at",
                 "workspace.name",
                 "workspace.description",
                 "workspace.url"
               ]

        assert Enum.all?(answered.var_docs, &(is_binary(&1.label) and is_binary(&1.help)))
      end
    end

    # A name is stored as typed (`MishkaCmsCore.PlainText`), so the head escapes it once: `&amp;`
    # in the page's source, `&` to whoever reads it.
    test "writes a name with an ampersand escaped once, in the tags and in the JSON-LD", %{
      site: site
    } do
      document!(site, name: "Tips & Tricks", slug: "tips", description: "Read & run.")

      html =
        site
        |> given(:workspace, %{"lang" => "en", "workspace" => "tips"})
        |> head()
        |> rendered_head()

      assert html =~ ~s(content="Tips &amp; Tricks")
      assert html =~ ~s(content="Read &amp; run.")
      refute html =~ "&amp;amp;"
      assert html =~ ~S("headline":"Tips \u0026 Tricks")
      assert meta_content(html, ~s(meta[property="og:title"])) == ["Tips & Tricks"]
      assert meta_content(html, ~s(meta[name="description"])) == ["Read & run."]
      assert %{"headline" => "Tips & Tricks"} = json_ld(html, "TechArticle")
    end

    test "its own tags and schema come with it", %{site: site} do
      document!(site,
        slug: "guide",
        seo_tags: [%{tag: "meta", attrs: %{"name" => "robots"}, content: "noindex"}],
        schema: [%{"@type" => "SoftwareApplication", "name" => "{{workspace.name}}"}]
      )

      answered = answer(given(site, :workspace, %{"lang" => "en", "workspace" => "guide"}))

      assert [%{tag: "meta", attrs: %{"name" => "robots"}, content: "noindex"}] = answered.tags

      assert [%{"@type" => "SoftwareApplication"}, %{"@type" => "BreadcrumbList"}] =
               answered.schema
    end
  end

  describe "a page of a document" do
    setup %{site: site} do
      document = document!(site, name: "Guide", slug: "guide")
      older = version!(site, document, version_number: "1.0.0", published_at: @january)

      latest =
        version!(site, document,
          version_number: "2.0.0",
          published_at: @march,
          is_latest_for_version: true
        )

      page!(site, older, "install", title: "Install (1.0)", content: "<p>The old way.</p>")

      page!(site, latest, "install",
        title: "Install",
        content: "<p>Run <code>mix setup</code> &amp; wait.</p>"
      )

      {:ok, document: document, latest: latest}
    end

    for mode <- ~w(prefix_others prefix_all) do
      test "is the page in the version marked latest, in #{mode}", %{site: site} do
        url_mode!(site, unquote(mode))
        url = base() <> english(unquote(mode), "/docs/guide/install")

        answered =
          answer(
            given(site, :section, %{
              "lang" => "en",
              "workspace" => "guide",
              "section" => "install"
            })
          )

        assert answered.title == "Install"
        assert answered.description == "Run mix setup & wait."
        assert answered.type == "article"
        assert answered.card.eyebrow == "Guide"
        assert [version] = answered.card.meta
        assert version =~ "Version"

        assert %{
                 "headline" => "Install",
                 "version" => "2.0.0",
                 "datePublished" => "2026-03-01T00:00:00Z",
                 "mainEntityOfPage" => ^url
               } = schema_of(answered, "TechArticle")

        assert crumbs(answered) == [
                 {1, "Documentation", base() <> english(unquote(mode), "/docs")},
                 {2, "Guide", base() <> english(unquote(mode), "/docs/guide")},
                 {3, "Install", url}
               ]

        assert %{
                 "doc.title" => "Install",
                 "doc.version" => "2.0.0",
                 "doc.url" => ^url,
                 "workspace.name" => "Guide"
               } = answered.vars
      end
    end

    test "escapes a page's title with an ampersand once", %{site: site, document: document} do
      version = version!(site, document, version_number: "3.0.0", is_latest_for_version: true)
      page!(site, version, "run", title: "Install & <b>run</b>", content: "<p>Go.</p>")

      html =
        site
        |> given(:section, %{"lang" => "en", "workspace" => "guide", "section" => "run"})
        |> head()
        |> rendered_head()

      assert html =~ ~s(content="Install &amp; run")
      refute html =~ "&amp;amp;"
      assert meta_content(html, ~s(meta[property="og:title"])) == ["Install & run"]
      assert %{"headline" => "Install & run"} = json_ld(html, "TechArticle")
    end

    # A PAGE IS MODIFIED WHEN IT, A NOTE ITS PAGE SHOWS OR THE ARCHIVING OF ONE LAST CHANGED, in
    # `doc.modified_at` and in the article's `dateModified` alike.
    defp dated_page!(site, version),
      do: site |> page!(version, "tabs", []) |> Ash.Seed.update!(%{updated_at: @january})

    defp modified(site) do
      answered =
        answer(
          given(site, :section, %{"lang" => "en", "workspace" => "guide", "section" => "tabs"})
        )

      assert answered.vars["doc.modified_at"] ==
               schema_of(answered, "TechArticle")["dateModified"]

      answered.vars["doc.modified_at"]
    end

    test "is modified when the page itself changed, with no notes", %{site: site, latest: latest} do
      dated_page!(site, latest)

      assert modified(site) == iso(@january)
    end

    test "is modified when a note of it was edited after the page", %{site: site, latest: latest} do
      page = dated_page!(site, latest)
      create_shown_note!(page, @march)

      assert modified(site) == iso(@march)

      stored = Ash.get!(MishkaDocument.Section, page.id, tenant: site.id, authorize?: false)
      assert DateTime.truncate(stored.updated_at, :second) == @january
    end

    test "is modified when a note of it was archived", %{site: site, latest: latest} do
      site |> dated_page!(latest) |> create_shown_note!(@march) |> archive_note_at!(@april)

      assert modified(site) == iso(@april)
    end

    test "is modified by its own change while its notes are older", %{site: site, latest: latest} do
      site |> dated_page!(latest) |> create_shown_note!(~U[2025-12-01 00:00:00Z])

      assert modified(site) == iso(@january)
    end

    test "is not modified by a note its page does not show", %{site: site, latest: latest} do
      site
      |> dated_page!(latest)
      |> create_shown_note!(@march, content_review_status: :pending)

      assert modified(site) == iso(@january)
    end

    test "reads the pages of the version it shows and no other's", %{site: site, latest: latest} do
      page!(site, latest, "upgrade", title: "Upgrade")

      for {asked, shown} <- [{nil, 2}, {"1.0.0", 1}] do
        params =
          Map.merge(
            %{"lang" => "en", "workspace" => "guide", "section" => "install"},
            (asked && %{"v" => asked}) || %{}
          )

        reads = rows_while(fn -> answer(given(site, :section, params)) end)

        tree =
          for {sql, rows} <- reads,
              String.contains?(sql, ~s(FROM "mishka_document_sections")),
              not String.contains?(sql, ~s("content")),
              do: rows

        assert tree == [shown],
               "the pages of the version shown (#{shown}) were read with another version's"
      end
    end

    test "is the page in the version `?v=` names", %{site: site} do
      params = %{"lang" => "en", "workspace" => "guide", "section" => "install", "v" => "1.0.0"}
      answered = answer(given(site, :section, params))

      assert answered.title == "Install (1.0)"
      assert answered.vars["doc.version"] == "1.0.0"
    end

    test "a long text is cut to the start of it", %{site: site, document: document} do
      version = version!(site, document, version_number: "3.0.0", is_latest_for_version: true)
      page!(site, version, "long", content: "<p>" <> String.duplicate("word ", 100) <> "</p>")

      params = %{"lang" => "en", "workspace" => "guide", "section" => "long"}
      description = answer(given(site, :section, params)).description

      assert String.length(description) <= 160
      assert String.ends_with?(description, "…")
    end

    test "its own tags win and its own schema replaces the article", %{site: site} do
      document = document!(site, slug: "api")
      version = version!(site, document, is_latest_for_version: true)

      page!(site, version, "auth",
        seo_tags: [%{tag: "meta", attrs: %{"name" => "author"}, content: "Docs team"}],
        schema: [%{"@type" => "HowTo", "name" => "{{doc.title}}"}]
      )

      params = %{"lang" => "en", "workspace" => "api", "section" => "auth"}
      answered = answer(given(site, :section, params))

      assert [%{tag: "meta", attrs: %{"name" => "author"}, content: "Docs team"}] = answered.tags
      assert [%{"@type" => "HowTo"}, %{"@type" => "BreadcrumbList"}] = answered.schema
    end

    test "is the default: what the page sets wins, and may name the page's variables", %{
      site: site
    } do
      params = %{"lang" => "en", "workspace" => "guide", "section" => "install"}
      stored = [%{"@type" => "Article", "headline" => "{{doc.title}}"}]
      given = %{given(site, :section, params, stored) | description: "{{workspace.name}} docs."}
      title = [%{tag: "title", attrs: %{}, content: "{{doc.title}} · {{workspace.name}}"}]

      head = given |> answer() |> Seo.accept(given) |> Seo.head(base: base(), layers: [[], title])

      assert head.title == "Install · Guide"
      assert head.description == "Guide docs."

      schema = Enum.map(head.schema, &Jason.decode!/1)

      assert %{"headline" => "Install"} = Enum.find(schema, &(&1["@type"] == "Article"))
      refute Enum.any?(schema, &(&1["@type"] == "TechArticle"))
    end

    test "answers the same when it is handed its own answer", %{site: site} do
      params = %{"lang" => "en", "workspace" => "guide", "section" => "install"}
      answered = answer(given(site, :section, params))

      assert answer(answered) == answered
    end

    test "a page in review, in a draft version, or of another document changes nothing else", %{
      site: site,
      document: document,
      latest: latest
    } do
      draft = version!(site, document, version_number: "9.0.0", status: :draft)
      page!(site, draft, "drafted", [])
      page!(site, latest, "in-review", content_review_status: :pending)

      for {workspace, section} <- [
            {"guide", "drafted"},
            {"guide", "in-review"},
            {"guide", "no-such-page"},
            {"no-such-document", "install"}
          ] do
        given =
          given(site, :section, %{"lang" => "en", "workspace" => workspace, "section" => section})

        assert answer(given) == %{given | var_docs: answer(given).var_docs, card: false}
      end
    end
  end

  # A DOCUMENT WITH AN ADDRESS OF ITS OWN is named by the page that serves it there — no slug in the
  # URL — and that address, with its page's under it, is the one canonical address of it, wherever
  # it was asked for (`MishkaDocument.Address`).
  describe "a document with an address of its own" do
    setup %{site: site} do
      document = document!(site, slug: "product", name: "Product", path: "/product/docs")
      version = version!(site, document, is_latest_for_version: true)
      install = page!(site, version, "install", title: "Install")
      page!(site, version, "steps", title: "Steps", parent_section_id: install.id)
      :ok
    end

    defp at_address(site, path, params, record) do
      Seo.given(
        %{
          title: "Document page",
          path: path,
          language: "en",
          seo: %{description: nil, schema: []}
        },
        site_id: site.id,
        url: base() <> "/asked/elsewhere",
        params: params,
        record: record
      )
    end

    test "is named by the page at its address, and its pages by theirs under it", %{site: site} do
      front = answer(at_address(site, "/product/docs", %{}, "docs:document"))

      assert {front.title, front.url} == {"Product", base() <> "/product/docs"}

      page =
        answer(
          at_address(site, "/product/docs/*section", %{"section" => "install/steps"}, "docs:page")
        )

      assert {page.title, page.url} == {"Steps", base() <> "/product/docs/install/steps"}

      assert crumbs(page) == [
               {1, "Documentation", base() <> "/docs"},
               {2, "Product", base() <> "/product/docs"},
               {3, "Steps", base() <> "/product/docs/install/steps"}
             ]
    end

    test "asked by its slug under /docs, names nothing: it is read at its own address alone",
         %{site: site} do
      for {kind, params} <- [
            workspace: %{"lang" => "en", "workspace" => "product"},
            section: %{"lang" => "en", "workspace" => "product", "section" => "install/steps"}
          ] do
        given = given(site, kind, params)
        assert answer(given) == %{given | var_docs: answer(given).var_docs, card: false}
      end
    end

    test "at its address, is the one named whatever slug the query carries", %{site: site} do
      document!(site, slug: "guide", name: "Guide")

      front =
        answer(at_address(site, "/product/docs", %{"workspace" => "guide"}, "docs:document"))

      assert {front.title, front.url} == {"Product", base() <> "/product/docs"}
    end

    test "a page asked by its slug alone, when it is filed under another, names nothing",
         %{site: site} do
      given = at_address(site, "/product/docs/*section", %{"section" => "steps"}, "docs:page")
      assert answer(given).title == "Document page"
    end
  end

  # A VERSION'S FRONT PAGE IS DRAWN AT ITS DOCUMENT'S OWN ADDRESS, and the head there stays the
  # document's: the address is the document's, whichever page it draws. Its slug under the address
  # names nothing, and the pages filed under it are named directly under the address.
  describe "a document whose version has a front page" do
    setup %{site: site} do
      document = document!(site, slug: "product", name: "Product", path: "/product/docs")
      version = version!(site, document, is_latest_for_version: true)
      front = page!(site, version, "get-started", title: "Get started", front_page: true)
      page!(site, version, "install", title: "Install", parent_section_id: front.id)
      :ok
    end

    defp fronted(site, path, params, record) do
      Seo.given(
        %{
          title: "Document page",
          path: path,
          language: "en",
          seo: %{description: nil, schema: []}
        },
        site_id: site.id,
        url: base() <> "/asked/elsewhere",
        params: params,
        record: record
      )
    end

    test "keeps the document's head at the document's address", %{site: site} do
      front = answer(fronted(site, "/product/docs", %{}, "docs:document"))

      assert {front.title, front.url} == {"Product", base() <> "/product/docs"}
    end

    test "names nothing at the address with the front page's slug after it", %{site: site} do
      given =
        fronted(site, "/product/docs/*section", %{"section" => "get-started"}, "docs:page")

      assert answer(given).title == "Document page"
    end

    test "names a page filed under it directly under the address", %{site: site} do
      page =
        answer(fronted(site, "/product/docs/*section", %{"section" => "install"}, "docs:page"))

      assert {page.title, page.url} == {"Install", base() <> "/product/docs/install"}

      assert crumbs(page) == [
               {1, "Documentation", base() <> "/docs"},
               {2, "Product", base() <> "/product/docs"},
               {3, "Install", base() <> "/product/docs/install"}
             ]
    end
  end

  # A GROUP IS ONLY A HEADING: nothing is named at its slug, and the pages under it are named as if it
  # were not there.
  describe "a document whose contents hold a group" do
    setup %{site: site} do
      document = document!(site, slug: "product", name: "Product", path: "/product/docs")
      version = version!(site, document, is_latest_for_version: true)
      group = page!(site, version, "navigation", title: "Navigation", group_heading: true)
      page!(site, version, "breadcrumb", title: "Breadcrumb", parent_section_id: group.id)
      :ok
    end

    defp in_group(site, params) do
      Seo.given(
        %{
          title: "Document page",
          path: "/product/docs/*section",
          language: "en",
          seo: %{description: nil, schema: []}
        },
        site_id: site.id,
        url: base() <> "/asked/elsewhere",
        params: params,
        record: "docs:page"
      )
    end

    test "names nothing at the group's slug", %{site: site} do
      for section <- ["navigation", "navigation/breadcrumb"] do
        assert answer(in_group(site, %{"section" => section})).title == "Document page"
      end
    end

    test "names a page under it directly under the address", %{site: site} do
      page = answer(in_group(site, %{"section" => "breadcrumb"}))
      assert {page.title, page.url} == {"Breadcrumb", base() <> "/product/docs/breadcrumb"}
    end

    test "names a group with a page of its own at its slug", %{site: site} do
      [version] =
        MishkaDocument.WorkspaceVersion
        |> Ash.Query.for_read(:public_list, %{}, authorize?: false)
        |> Ash.read!(tenant: site.id)

      overlays =
        page!(site, version, "overlays", title: "Overlays", group_heading: true, group_page: true)

      page!(site, version, "modal", title: "Modal", parent_section_id: overlays.id)

      page = answer(in_group(site, %{"section" => "overlays"}))
      assert {page.title, page.url} == {"Overlays", base() <> "/product/docs/overlays"}

      page = answer(in_group(site, %{"section" => "modal"}))
      assert {page.title, page.url} == {"Modal", base() <> "/product/docs/modal"}

      assert answer(in_group(site, %{"section" => "overlays/modal"})).title == "Document page"
    end
  end

  describe "who may open it" do
    setup %{site: site} do
      document = document!(site, slug: "members", permissions: ["members:read"])
      version = version!(site, document, is_latest_for_version: true)
      install = page!(site, version, "install", [])
      billing = page!(site, version, "billing", permissions: ["billing:read"])

      open = document!(site, slug: "open")
      page!(site, version!(site, open, is_latest_for_version: true), "intro", [])

      %{members: version, install: install, billing: billing}
    end

    test "a document's front page answers the document's permissions", %{site: site} do
      for {slug, permissions} <- [{"members", ["members:read"]}, {"open", []}] do
        given = given(site, :workspace, %{"lang" => "en", "workspace" => slug})
        assert answer(given).permissions == permissions
      end
    end

    test "a page of it answers its own, else its document's", %{site: site} do
      for {workspace, section, permissions} <- [
            {"members", "install", ["members:read"]},
            {"members", "billing", ["billing:read"]},
            {"open", "intro", []}
          ] do
        params = %{"lang" => "en", "workspace" => workspace, "section" => section}
        assert answer(given(site, :section, params)).permissions == permissions
      end
    end

    # open: hr (locked) → leave → parental; hr → payroll (its own); draft (in review, locked) → notes
    # members (locked): billing (its own) → invoices; install → steps
    test "a page under others answers its own, else the nearest one's above it, else its document's",
         %{site: site, members: members, install: install, billing: billing} do
      open = version!(site, document!(site, slug: "handbook"), is_latest_for_version: true)
      hr = page!(site, open, "hr", permissions: ["hr:read"])
      leave = page!(site, open, "leave", parent_section_id: hr.id)
      page!(site, open, "parental", parent_section_id: leave.id)
      page!(site, open, "payroll", parent_section_id: hr.id, permissions: ["payroll:read"])

      draft =
        page!(site, open, "draft", content_review_status: :pending, permissions: ["hr:read"])

      page!(site, open, "notes", parent_section_id: draft.id)

      page!(site, members, "invoices", parent_section_id: billing.id)
      page!(site, members, "steps", parent_section_id: install.id)

      # Each page at its address: under the pages it is filed under, and at the top when its parent
      # is not published — `notes`, whose parent `draft` is still waiting on a review.
      for {workspace, section, permissions} <- [
            {"handbook", "hr/leave", ["hr:read"]},
            {"handbook", "hr/leave/parental", ["hr:read"]},
            {"handbook", "hr/payroll", ["payroll:read"]},
            {"handbook", "notes", ["hr:read"]},
            {"members", "billing/invoices", ["billing:read"]},
            {"members", "install/steps", ["members:read"]}
          ] do
        params = %{"lang" => "en", "workspace" => workspace, "section" => section}

        assert {section, answer(given(site, :section, params)).permissions} ==
                 {section, permissions}
      end
    end

    test "the head hands them on and keeps a locked one out of an index", %{site: site} do
      locked = head(given(site, :workspace, %{"lang" => "en", "workspace" => "members"}))

      assert locked.permissions == ["members:read"]
      assert robots(locked) == ["noindex, nofollow"]

      params = %{"lang" => "en", "workspace" => "open", "section" => "intro"}
      open = head(given(site, :section, params))

      assert open.permissions == []
      assert robots(open) == ["index, follow, max-image-preview:large"]
    end
  end

  # A LOCKED RECORD'S HEAD IS ITS OWN, AND ITS LOCK COMES WITH IT. `MishkaCmsWeb.RuntimeLive` opens
  # the address only for a reader holding the lock, so the head built here reaches that reader and no
  # other — which is why it is read as the system and not as the visitor.
  describe "a document or a page locked to permissions" do
    setup %{site: site} do
      document =
        document!(site,
          name: "Members",
          slug: "members",
          description: "For members.",
          permissions: ["members:read"]
        )

      page!(site, version!(site, document, is_latest_for_version: true), "install",
        title: "Install"
      )

      open = version!(site, document!(site, slug: "open"), is_latest_for_version: true)
      page!(site, open, "billing", title: "Billing", permissions: ["billing:read"])

      :ok
    end

    test "is described by its own head, with the lock the page admits its reader by", %{
      site: site
    } do
      front = answer(given(site, :workspace, %{"lang" => "en", "workspace" => "members"}))

      assert front.title == "Members"
      assert front.description == "For members."
      assert front.permissions == ["members:read"]
      assert %{"workspace.name" => "Members"} = front.vars
      assert %{"headline" => "Members"} = schema_of(front, "TechArticle")

      for {workspace, section, title, permissions} <- [
            {"members", "install", "Install", ["members:read"]},
            {"open", "billing", "Billing", ["billing:read"]}
          ] do
        params = %{"lang" => "en", "workspace" => workspace, "section" => section}
        answered = answer(given(site, :section, params))

        assert {section, answered.title, answered.permissions} == {section, title, permissions}
        assert %{"doc.title" => ^title} = answered.vars
      end
    end
  end

  describe "a page's robots meta" do
    setup %{site: site} do
      document = document!(site, slug: "hidden", seo_tags: [robots_meta("noindex")])
      version = version!(site, document, is_latest_for_version: true)
      author = %{tag: "meta", attrs: %{"name" => "author"}, content: "Docs team"}

      page!(site, version, "inherits", seo_tags: [author])
      page!(site, version, "own", seo_tags: [robots_meta("index, follow")])

      {:ok, author: author}
    end

    test "is its document's when it holds none of its own", %{site: site, author: author} do
      params = %{"lang" => "en", "workspace" => "hidden", "section" => "inherits"}
      given = given(site, :section, params)

      assert [^author, %{tag: "meta", attrs: %{"name" => "robots"}, content: "noindex"}] =
               answer(given).tags

      assert robots(head(given)) == ["noindex"]
    end

    test "is its own when it holds one", %{site: site} do
      params = %{"lang" => "en", "workspace" => "hidden", "section" => "own"}
      given = given(site, :section, params)

      assert [%{content: "index, follow"}] = answer(given).tags
      assert robots(head(given)) == ["index, follow"]
    end

    # A PAGE THAT IS NOT READY YET stores `noindex, follow`: its head says so, it has no article to
    # describe, and its trail stays.
    test "that says noindex leaves the article out, its own or its document's", %{site: site} do
      open = document!(site, slug: "open")
      version = version!(site, open, is_latest_for_version: true)
      page!(site, version, "soon", seo_tags: [robots_meta("noindex, follow")])

      for {workspace, section} <- [{"open", "soon"}, {"hidden", "inherits"}] do
        params = %{"lang" => "en", "workspace" => workspace, "section" => section}
        answered = answer(given(site, :section, params))

        assert [%{"@type" => "BreadcrumbList"}] = answered.schema, section
      end

      html =
        site
        |> given(:section, %{"lang" => "en", "workspace" => "open", "section" => "soon"})
        |> head()
        |> rendered_head()

      assert meta_content(html, ~s(meta[name="robots"])) == ["noindex, follow"]
      assert json_ld(html, "TechArticle") == nil
      assert %{"@type" => "BreadcrumbList"} = json_ld(html, "BreadcrumbList")

      front = answer(given(site, :workspace, %{"lang" => "en", "workspace" => "hidden"}))
      assert [%{"@type" => "BreadcrumbList"}] = front.schema

      params = %{"lang" => "en", "workspace" => "hidden", "section" => "own"}
      assert schema_of(answer(given(site, :section, params)), "TechArticle")
    end
  end

  describe "the TechArticle" do
    setup %{site: site} do
      on_exit(fn -> SettingsState.delete(site.id, "site.logo") end)

      document =
        document!(site,
          name: "Guide",
          slug: "guide",
          description: "How to use it.",
          seo_tags: [
            %{tag: "meta", attrs: %{"name" => "description"}, content: "The guide, in short."},
            %{tag: "meta", attrs: %{"name" => "author"}, content: "Docs team"}
          ]
        )

      version = version!(site, document, is_latest_for_version: true)

      page!(site, version, "words",
        content: "<p>Its text.</p>",
        seo_tags: [
          %{tag: "meta", attrs: %{"name" => "description"}, content: "Its own words."},
          %{tag: "meta", attrs: %{"name" => "author"}, content: "Ada"}
        ]
      )

      page!(site, version, "plain", content: "<p>Only its text.</p>")
      page!(site, version, "empty", content: nil)

      :ok
    end

    defp article(site, kind, params),
      do: schema_of(answer(given(site, kind, params)), "TechArticle")

    defp page_params(section), do: %{"lang" => "en", "workspace" => "guide", "section" => section}

    test "says the description the record stores, else the start of its text", %{site: site} do
      front = article(site, :workspace, %{"lang" => "en", "workspace" => "guide"})

      assert front["description"] == "The guide, in short."
      assert article(site, :section, page_params("words"))["description"] == "Its own words."
      assert article(site, :section, page_params("plain"))["description"] == "Only its text."
      refute Map.has_key?(article(site, :section, page_params("empty")), "description")
    end

    test "names the page's author, else its document's", %{site: site} do
      assert %{"author" => %{"@type" => "Person", "name" => "Ada"}} =
               article(site, :section, page_params("words"))

      assert %{"author" => %{"@type" => "Person", "name" => "Docs team"}} =
               article(site, :section, page_params("plain"))

      bare = document!(site, slug: "bare")
      page!(site, version!(site, bare, is_latest_for_version: true), "page", [])

      params = %{"lang" => "en", "workspace" => "bare", "section" => "page"}
      refute Map.has_key?(article(site, :section, params), "author")
    end

    test "is published by the site's organization, with its logo", %{site: site} do
      refute Map.has_key?(article(site, :section, page_params("plain"))["publisher"], "logo")

      {:ok, _} = Settings.put("site.logo", "/uploads/logo.png", site_id: site.id)

      assert %{
               "@type" => "Organization",
               "@id" => id,
               "name" => "The Studio",
               "url" => url,
               "logo" => logo
             } = article(site, :section, page_params("plain"))["publisher"]

      assert {id, url, logo} ==
               {base() <> "/#organization", base(), base() <> "/uploads/logo.png"}
    end

    test "shows the head's image, and none when the head has none", %{site: site} do
      given = given(site, :section, page_params("plain"))
      image = [%{tag: "meta", attrs: %{"property" => "og:image"}, content: "/a.png"}]

      pictured =
        given |> answer() |> Seo.accept(given) |> Seo.head(base: base(), layers: [[], image])

      assert %{"image" => picture} =
               pictured.schema
               |> Enum.map(&Jason.decode!/1)
               |> Enum.find(&(&1["@type"] == "TechArticle"))

      assert picture == base() <> "/a.png"

      bare = head(given).schema |> Enum.map(&Jason.decode!/1)
      refute Map.has_key?(Enum.find(bare, &(&1["@type"] == "TechArticle")), "image")
    end
  end

  describe "a document it may not show" do
    test "changes nothing else: a draft one, or one in another language", %{site: site} do
      document!(site, slug: "drafted", status: :draft)
      document!(site, slug: "persian", language: "fa")

      for slug <- ["drafted", "persian", "missing"] do
        given = given(site, :workspace, %{"lang" => "en", "workspace" => slug})
        assert answer(given) == %{given | var_docs: answer(given).var_docs, card: false}
      end
    end
  end

  describe "with no params" do
    test "returns its variables and reads nothing", %{site: site} do
      document!(site, slug: "guide")

      for kind <- [:workspace, :section] do
        given = given(site, kind, %{})
        assert {answered, []} = reads_while(fn -> answer(given) end)
        assert answered == %{given | var_docs: answered.var_docs, card: false}
        assert "workspace.name" in keys(answered.var_docs)
      end
    end
  end

  describe "a page of another kind" do
    test "is handed back as it came, with nothing read, whatever its path", %{site: site} do
      document!(site, slug: "guide")

      for record <- [nil, "blog:post", "docs:unknown"] do
        given = %{
          given(site, :workspace, %{"lang" => "en", "workspace" => "guide"})
          | record: record
        }

        assert reads_while(fn -> answer(given) end) == {given, []}
      end
    end

    test "is told apart by its kind, not its path", %{site: site} do
      document!(site, slug: "guide", name: "Guide")

      given = %{
        given(site, :workspace, %{"lang" => "en", "workspace" => "guide"})
        | page: %{title: "Manual", path: "/:lang/manual/:workspace", language: "en", seo: %{}}
      }

      assert {:reply, :halt, %{title: "Guide"}} = PageSeo.call(given)
    end
  end

  describe "the kinds it names" do
    test "are a workspace and a section of one, named as the Documents admin names them, each with the site's own to preview with",
         %{site: site} do
      document!(site, slug: "guide", name: "Guide")

      assert [
               %{
                 id: "docs:document",
                 group: "Documents",
                 label: "Workspace",
                 captures: ["workspace"],
                 samples: documents
               },
               %{
                 id: "docs:page",
                 group: "Documents",
                 label: "Section",
                 captures: ["workspace", "section"]
               }
             ] = MishkaDocument.Plugins.PageRecords.types(site.id)

      assert Enum.any?(documents, &(&1.params["workspace"] == "guide"))
    end

    test "preview a page at the address it is read at, and no front page as a page of its own",
         %{site: site} do
      document = document!(site, slug: "guide", name: "Guide")
      version = version!(site, document, is_latest_for_version: true)
      front = page!(site, version, "get-started", title: "Get started", front_page: true)
      page!(site, version, "install", title: "Install", parent_section_id: front.id)

      [_documents, %{id: "docs:page", samples: samples}] =
        MishkaDocument.Plugins.PageRecords.types(site.id)

      assert Enum.map(samples, & &1.params["section"]) == ["install"]
    end

    test "preview no group, and a page under one directly under the document", %{site: site} do
      document = document!(site, slug: "guide", name: "Guide")
      version = version!(site, document, is_latest_for_version: true)
      group = page!(site, version, "navigation", title: "Navigation", group_heading: true)
      page!(site, version, "breadcrumb", title: "Breadcrumb", parent_section_id: group.id)

      [_documents, %{id: "docs:page", samples: samples}] =
        MishkaDocument.Plugins.PageRecords.types(site.id)

      assert Enum.map(samples, & &1.params["section"]) == ["breadcrumb"]
    end
  end

  describe "what it hands `document:page:seo`" do
    setup %{site: site} do
      Process.register(self(), :__page_seo_probe__)

      {:ok, _} =
        Event.write(%{
          name: PageSeoAnswer,
          event: PageSeo.event(),
          extension: :mishka_installer,
          status: :started
        })

      :ok = EventHandler.do_compile(PageSeo.event(), :start, false)

      on_exit(fn ->
        PageSeoAnswer.forget!()
        Event.unregister(:name, PageSeoAnswer, false)
        EventHandler.do_compile(PageSeo.event(), :start, false)
      end)

      document =
        document!(site,
          slug: "product",
          name: "Product",
          path: "/product/docs",
          description: "All of it."
        )

      version = version!(site, document, version_number: "3.1.0", is_latest_for_version: true)
      page!(site, version, "start", title: "Start", front_page: true, order_position: 0)

      group =
        page!(site, version, "navigation",
          title: "Navigation",
          group_heading: true,
          order_position: 1
        )

      for {title, at} <-
            Enum.with_index(~w(Alpha Bravo Charlie Delta Echo Foxtrot Golf Hotel India)) do
        page!(site, version, String.downcase(title),
          title: title,
          parent_section_id: group.id,
          order_position: at,
          content: "<p>#{title} text.</p>"
        )
      end

      :ok
    end

    defp at_product(site, record, params) do
      Seo.given(
        %{
          title: "Document page",
          path: if(record == "docs:page", do: "/product/docs/*section", else: "/product/docs"),
          language: "en",
          seo: %{description: nil, schema: []}
        },
        site_id: site.id,
        url: base() <> "/product/docs",
        params: params,
        record: record
      )
    end

    defp asked do
      assert_received {:page_seo_asked, _seo, meta}
      meta
    end

    test "a page: its document, version, place, and the contents round it", %{site: site} do
      answered = answer(at_product(site, "docs:page", %{"section" => "hotel"}))

      assert answered.card.eyebrow == "Product · Navigation"
      assert answered.vars["doc.group"] == "Navigation"

      assert %{
               site_id: site_id,
               document: %{
                 name: "Product",
                 slug: "product",
                 path: "/product/docs",
                 language: "en",
                 description: "All of it."
               },
               version: "3.1.0",
               page: %{
                 slug: "hotel",
                 title: "Hotel",
                 description: "Hotel text.",
                 path: "hotel",
                 parents: [%{slug: "navigation", title: "Navigation", group: true}]
               },
               url: url,
               contents: contents
             } = asked()

      assert site_id == site.id
      assert url == base() <> "/product/docs/hotel"

      assert Enum.map(contents, &{&1.title, &1.current}) == [
               {"Charlie", false},
               {"Delta", false},
               {"Echo", false},
               {"Foxtrot", false},
               {"Golf", false},
               {"Hotel", true},
               {"India", false}
             ]
    end

    test "a front page: its document, the version a reader lands on, and its top level", %{
      site: site
    } do
      answered = answer(at_product(site, "docs:document", %{}))

      assert answered.card == %{eyebrow: "Documentation", meta: ["Version 3.1.0"]}
      assert answered.vars["doc.version"] == "3.1.0"

      assert %{document: %{name: "Product", url: url}, version: "3.1.0", page: nil} =
               meta = asked()

      assert url == base() <> "/product/docs"

      assert Enum.map(meta.contents, &{&1.title, &1.group, &1.current}) == [
               {"Start", false, true},
               {"Navigation", true, false}
             ]
    end

    test "its reply is the answer", %{site: site} do
      PageSeoAnswer.answer!(fn seo, %{page: %{title: title}} ->
        %{seo | image: "/cards/#{title}.jpg", card: false}
      end)

      answered = answer(at_product(site, "docs:page", %{"section" => "alpha"}))

      assert {answered.image, answered.card} == {"/cards/Alpha.jpg", false}

      assert %{image: "/cards/Alpha.jpg"} =
               Seo.accept(answered, at_product(site, "docs:page", %{}))
    end

    test "hands on the description a page stores, which its head shows", %{site: site} do
      [version] =
        MishkaDocument.WorkspaceVersion
        |> Ash.Query.for_read(:public_list, %{}, authorize?: false)
        |> Ash.read!(tenant: site.id)

      page!(site, version, "juliet",
        title: "Juliet",
        content: "<p>Its text.</p>",
        seo_tags: [%{tag: "meta", attrs: %{"name" => "description"}, content: "Its own words."}]
      )

      answer(at_product(site, "docs:page", %{"section" => "juliet"}))
      assert %{page: %{description: "Its own words."}} = asked()
    end

    test "is not asked for a page it names nothing at", %{site: site} do
      answer(at_product(site, "docs:page", %{"section" => "nowhere"}))
      refute_received {:page_seo_asked, _seo, _meta}
    end
  end

  describe "the plugin" do
    test "is one of the plugins this extension's supervisor starts" do
      assert PageSeo in MishkaDocument.Application.plugins()
    end

    # Registered by hand: this suite's registry is not up when the extension's supervisor starts its
    # plugins.
    test "answers `runtime:page:seo`, the event core fires", %{site: site} do
      {:ok, _registered} = PageSeo.register()
      :ok = EventHandler.do_compile(Seo.event(), :start, false)

      document!(site, name: "Through the hook", slug: "hooked")
      given = given(site, :workspace, %{"lang" => "en", "workspace" => "hooked"})

      assert %{title: "Through the hook", type: "article"} =
               Seo.accept(Hook.call(Seo.event(), given), given)
    end
  end

  defp iso(at), do: at |> DateTime.truncate(:second) |> DateTime.to_iso8601()
end
