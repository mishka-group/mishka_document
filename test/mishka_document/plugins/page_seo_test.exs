defmodule MishkaDocument.Plugins.PageSeoTest do
  @moduledoc """
  What the documentation answers on `runtime:page:seo`: the head of the document and the page of it
  the address names, and nothing on any other page.

  Each test hands the plugin the map `MishkaCmsWeb.RuntimeLive` hands it — `Seo.given/2` of the
  provisioned page — and reads what it returns. Every status is pinned: the generators pick a
  document's and a version's at random and start every page in review.
  """
  use MishkaDocument.DataCase, async: false

  alias MishkaCmsCore.Runtime.{PageEditions, Seo}
  alias MishkaCmsCore.Runtime.States.SettingsState
  alias MishkaCmsCore.Settings
  alias MishkaDocument.Plugins.PageSeo
  alias MishkaDocument.Provision
  alias MishkaInstaller.Event.EventHandler
  alias MishkaInstaller.Event.Hook

  @host "docs.example.com"

  @january ~U[2026-01-01 00:00:00Z]
  @march ~U[2026-03-01 00:00:00Z]

  setup do
    site = create_site!(active: true)

    on_exit(fn ->
      SettingsState.delete(site.id, "site.languages")
      SettingsState.delete(site.id, "site.title")
    end)

    {:ok, _} = Settings.put("site.languages", ["en", "fa"], site_id: site.id)
    {:ok, _} = Settings.put("site.title", "The Studio", site_id: site.id)

    {:ok, site: site}
  end

  # The site's address as core writes it in this environment.
  defp base, do: Seo.base(@host)

  # The map core hands the plugins for a request to the `kind` page, storing `schema`, with `params`.
  defp given(site, kind, params, schema \\ []) do
    path = Provision.item_paths()[kind]
    filled = PageEditions.path(path, params)

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

  describe "a document's front page" do
    test "is the document's own head", %{site: site} do
      document = document!(site, name: "Guide", slug: "guide", description: "How to use it.")
      url = base() <> "/en/docs/guide"

      answered = answer(given(site, :workspace, %{"lang" => "en", "workspace" => "guide"}))

      assert answered.title == "Guide"
      assert answered.description == "How to use it."
      assert answered.type == "article"

      assert %{
               "headline" => "Guide",
               "description" => "How to use it.",
               "inLanguage" => "en",
               "mainEntityOfPage" => ^url,
               "publisher" => %{"name" => "The Studio"}
             } = schema_of(answered, "TechArticle")

      assert crumbs(answered) == [
               {1, "Documentation", base() <> "/en/docs"},
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
               "doc.published_at",
               "doc.modified_at",
               "workspace.name",
               "workspace.description",
               "workspace.url"
             ]

      assert Enum.all?(answered.var_docs, &(is_binary(&1.label) and is_binary(&1.help)))
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

    test "is the page in the version marked latest", %{site: site} do
      url = base() <> "/en/docs/guide/install"

      answered =
        answer(
          given(site, :section, %{"lang" => "en", "workspace" => "guide", "section" => "install"})
        )

      assert answered.title == "Install"
      assert answered.description == "Run mix setup & wait."
      assert answered.type == "article"

      assert %{
               "headline" => "Install",
               "version" => "2.0.0",
               "datePublished" => "2026-03-01T00:00:00Z",
               "mainEntityOfPage" => ^url
             } = schema_of(answered, "TechArticle")

      assert crumbs(answered) == [
               {1, "Documentation", base() <> "/en/docs"},
               {2, "Guide", base() <> "/en/docs/guide"},
               {3, "Install", url}
             ]

      assert %{
               "doc.title" => "Install",
               "doc.version" => "2.0.0",
               "doc.url" => ^url,
               "workspace.name" => "Guide"
             } = answered.vars
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

      assert [%{"@type" => "Article", "headline" => "Install"}] =
               Enum.map(head.schema, &Jason.decode!/1)
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

        assert answer(given) == %{given | var_docs: answer(given).var_docs}
      end
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

      for {workspace, section, permissions} <- [
            {"handbook", "leave", ["hr:read"]},
            {"handbook", "parental", ["hr:read"]},
            {"handbook", "payroll", ["payroll:read"]},
            {"handbook", "notes", ["hr:read"]},
            {"members", "invoices", ["billing:read"]},
            {"members", "steps", ["members:read"]}
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
  end

  describe "a document it may not show" do
    test "changes nothing else: a draft one, or one in another language", %{site: site} do
      document!(site, slug: "drafted", status: :draft)
      document!(site, slug: "persian", language: "fa")

      for slug <- ["drafted", "persian", "missing"] do
        given = given(site, :workspace, %{"lang" => "en", "workspace" => slug})
        assert answer(given) == %{given | var_docs: answer(given).var_docs}
      end
    end
  end

  describe "with no params" do
    test "returns its variables and reads nothing", %{site: site} do
      document!(site, slug: "guide")

      for kind <- [:workspace, :section] do
        given = given(site, kind, %{})
        assert {answered, []} = reads_while(fn -> answer(given) end)
        assert answered == %{given | var_docs: answered.var_docs}
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
