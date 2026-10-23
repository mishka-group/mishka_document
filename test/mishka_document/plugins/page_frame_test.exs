# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_document/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaDocument.Plugins.PageFrameTest do
  @moduledoc """
  What the documentation answers on `runtime:page:frame`: the languages the document or the page of
  it the address names is written in, and the bar under the site's header — and nothing on any other
  page.

  Each test hands the plugin the map the layout hands it (`SiteLayout.given/2` of a documentation
  page) and reads what the layout reads back (`SiteLayout.accept/2`), so the languages are the ones
  the header's dropdown lists, with the site's own filter applied, and the bar is the one it draws.
  Every status is pinned: the generators pick a document's and a version's at random.
  """
  use MishkaDocument.DataCase, async: false

  alias MishkaCmsCore.Runtime.{Languages, SiteLayout}
  alias MishkaCmsCore.Runtime.States.SettingsState
  alias MishkaCmsCore.Settings
  alias MishkaDocument.Plugins.PageFrame
  alias MishkaDocument.Provision

  @january ~U[2026-01-01 00:00:00Z]

  setup do
    site = create_site!(active: true)

    on_exit(fn ->
      SettingsState.delete(site.id, "site.languages")
      SettingsState.delete(site.id, "site.language_urls")
    end)

    {:ok, _} = Settings.put("site.languages", ["en", "fa"], site_id: site.id)

    {:ok, site: site}
  end

  defp url_mode!(site, mode),
    do: {:ok, _} = Settings.put("site.language_urls", mode, site_id: site.id)

  # Where English, the site's first language, puts `path` in `mode`.
  defp english("prefix_others", path), do: path
  defp english("prefix_all", path), do: "/en" <> path

  # The map the layout hands the plugins for a request to the documentation page at `path`, which
  # shows `record`, with `params`; the page's own editions are what core would offer without it.
  defp given(site, path, record, params, language \\ "en") do
    SiteLayout.given(
      %{title: "Document", path: path, language: language, section: "document"},
      site_id: site.id,
      extra: (record && %{"record" => record}) || %{},
      params: params,
      translations: [
        %{language: "en", path: "/same/path"},
        %{language: "fa", path: "/fa/same/path"}
      ]
    )
  end

  defp document(site, kind, params, language \\ "en") do
    path = Provision.item_paths()[kind]
    record = %{workspace: "docs:document", section: "docs:page"}[kind]
    given(site, path, record, Map.put(params, "lang", language), language)
  end

  # What the plugin returns, and what the layout makes of it.
  defp answer(given) do
    case PageFrame.call(given) do
      {:reply, :halt, answered} -> answered
      {:reply, answered} -> answered
    end
  end

  defp framed(given), do: given |> answer() |> SiteLayout.accept(given)

  defp offered(frame), do: Enum.map(frame.translations, &{&1.language, &1.path, &1.title})

  defp document!(site, attrs) do
    [site_id: site.id, skip_version: true, status: :active, language: "en"]
    |> Keyword.merge(attrs)
    |> create_workspace!()
  end

  defp version!(site, document, attrs \\ []) do
    [
      site_id: site.id,
      workspace_id: document.id,
      version_number: "1.0.0",
      status: :stable,
      is_latest_for_version: true,
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
      title: String.capitalize(slug),
      language: "en",
      content_review_status: :approved,
      technical_review_status: :approved
    ]
    |> Keyword.merge(attrs)
    |> create_section!()
  end

  # THE DOCUMENT IN TWO LANGUAGES, its Persian edition filed under other slugs on purpose, so nothing
  # here can be right by having the same name: `install` in English is `nasb` in Persian, joined by
  # the group of translations; `upgrading` has no link between them and is the same slug; and
  # `english-only` has no Persian page at all.
  defp handbook!(site, english_attrs \\ [], persian_attrs \\ []) do
    english =
      document!(site, Keyword.merge([name: "Handbook", slug: "handbook"], english_attrs))

    persian =
      document!(
        site,
        Keyword.merge(
          [
            name: "راهنما",
            slug: "rahnama",
            language: "fa",
            language_group_id: english.language_group_id
          ],
          persian_attrs
        )
      )

    en = version!(site, english)
    fa = version!(site, persian, version_number: "0.3.0")

    install = page!(site, en, "install", title: "Install", order_position: 0)

    page!(site, fa, "nasb",
      title: "نصب",
      language: "fa",
      order_position: 0,
      language_group_id: install.language_group_id
    )

    page!(site, en, "upgrading", title: "Upgrading", order_position: 1)
    page!(site, fa, "upgrading", title: "ارتقا", language: "fa", order_position: 1)
    page!(site, en, "english-only", title: "English only", order_position: 2)

    %{english: english, persian: persian, en: en, fa: fa, install: install}
  end

  defp page_params(slug, extra \\ %{}),
    do: Map.merge(%{"workspace" => "handbook", "section" => slug}, extra)

  describe "a document's front page" do
    for mode <- ~w(prefix_others prefix_all) do
      test "is offered in each edition of the document, in #{mode}", %{site: site} do
        url_mode!(site, unquote(mode))
        handbook!(site)

        frame = framed(document(site, :workspace, %{"workspace" => "handbook"}))

        assert offered(frame) == [
                 {"en", english(unquote(mode), "/docs/handbook"), "Handbook"},
                 {"fa", "/fa/docs/rahnama", "راهنما"}
               ]

        assert Enum.map(frame.translations, & &1.name) == [
                 Languages.name("en"),
                 Languages.name("fa")
               ]
      end
    end

    test "is read from the edition's own slug, whichever edition is open", %{site: site} do
      handbook!(site)

      frame = framed(document(site, :workspace, %{"workspace" => "rahnama"}, "fa"))

      assert offered(frame) == [
               {"en", "/docs/handbook", "Handbook"},
               {"fa", "/fa/docs/rahnama", "راهنما"}
             ]
    end

    test "is offered in no language for a document nobody translated", %{site: site} do
      document!(site, name: "Alone", slug: "alone")

      frame = framed(document(site, :workspace, %{"workspace" => "alone"}))

      assert frame.translations == []
    end

    test "leaves out a language the site does not publish", %{site: site} do
      %{english: english} = handbook!(site)

      arabic =
        document!(site,
          name: "الدليل",
          slug: "aldalil",
          language: "ar",
          language_group_id: english.language_group_id
        )

      version!(site, arabic)

      frame = framed(document(site, :workspace, %{"workspace" => "handbook"}))

      assert Enum.map(frame.translations, & &1.language) == ["en", "fa"]
    end

    test "has nothing to switch to on a site that publishes one language", %{site: site} do
      {:ok, _} = Settings.put("site.languages", ["en"], site_id: site.id)
      handbook!(site)

      frame = framed(document(site, :workspace, %{"workspace" => "handbook"}))

      assert frame.translations == []
    end

    # THE FRAME HANDS THE PLUGIN NO VISITOR, so the other editions are read as one who is not signed
    # in: an edition locked to a permission is not named to someone who may not open it. The edition
    # being read was admitted by the page, and is among the languages.
    test "does not name an edition only some readers may open", %{site: site} do
      handbook!(site, [], permissions: ["docs:editors"])

      frame = framed(document(site, :workspace, %{"workspace" => "handbook"}))

      assert frame.translations == []
    end

    test "keeps the edition being read when it is the locked one", %{site: site} do
      handbook!(site, [], permissions: ["docs:editors"])

      frame = framed(document(site, :workspace, %{"workspace" => "rahnama"}, "fa"))

      assert offered(frame) == [
               {"en", "/docs/handbook", "Handbook"},
               {"fa", "/fa/docs/rahnama", "راهنما"}
             ]
    end

    test "is each edition at the address its document has, and the language named in it",
         %{site: site} do
      handbook!(site, [path: "/handbook/docs"], path: "/rahnama/docs")

      frame =
        framed(
          given(
            site,
            "/handbook/docs",
            "docs:document",
            %{"lang" => "en"}
          )
        )

      assert offered(frame) == [
               {"en", "/handbook/docs", "Handbook"},
               {"fa", "/rahnama/docs", "راهنما"}
             ]
    end

    test "a document with `:lang` in its address is filled with the edition's own language",
         %{site: site} do
      handbook!(site, [path: "/:lang/handbook"], path: "/:lang/rahnama")

      frame = framed(given(site, "/:lang/handbook", "docs:document", %{"lang" => "en"}))

      assert offered(frame) == [
               {"en", "/handbook", "Handbook"},
               {"fa", "/fa/rahnama", "راهنما"}
             ]
    end

    test "names nothing for an address no document answers", %{site: site} do
      handbook!(site)

      frame = framed(document(site, :workspace, %{"workspace" => "missing"}))

      assert frame.translations == []
      assert frame.section_bar.title == "Docs"
      assert frame.section_bar.crumbs == []
    end
  end

  describe "a page of a document" do
    test "is offered in each edition that has it, at the page of that edition", %{site: site} do
      handbook!(site)

      frame = framed(document(site, :section, page_params("install")))

      assert offered(frame) == [
               {"en", "/docs/handbook/install", "Install"},
               {"fa", "/fa/docs/rahnama/nasb", "نصب"}
             ]
    end

    for mode <- ~w(prefix_others prefix_all) do
      test "is at the address the site's URL mode gives, in #{mode}", %{site: site} do
        url_mode!(site, unquote(mode))
        handbook!(site)

        frame = framed(document(site, :section, page_params("install")))

        assert [{"en", path, _title}, {"fa", "/fa/docs/rahnama/nasb", _}] = offered(frame)
        assert path == english(unquote(mode), "/docs/handbook/install")
      end
    end

    # THE PERSIAN EDITION IS READ FROM ITS OWN SLUG: the page `nasb` joined to `install` is the one
    # that names it, whichever of the two is open.
    test "is found from the translation as well", %{site: site} do
      handbook!(site)

      frame =
        framed(document(site, :section, %{"workspace" => "rahnama", "section" => "nasb"}, "fa"))

      assert offered(frame) == [
               {"en", "/docs/handbook/install", "Install"},
               {"fa", "/fa/docs/rahnama/nasb", "نصب"}
             ]
    end

    # AN ADMIN CAN WRITE A TRANSLATION WITHOUT JOINING IT TO THE PAGE IT TRANSLATES, and a Persian page
    # called `upgrading` is still the Persian `upgrading`.
    test "falls back to the same slug when nobody linked the two", %{site: site} do
      handbook!(site)

      frame = framed(document(site, :section, page_params("upgrading")))

      assert offered(frame) == [
               {"en", "/docs/handbook/upgrading", "Upgrading"},
               {"fa", "/fa/docs/rahnama/upgrading", "ارتقا"}
             ]
    end

    test "leaves out a language whose edition has no such page", %{site: site} do
      handbook!(site)

      frame = framed(document(site, :section, page_params("english-only")))

      assert frame.translations == []
    end

    # EDITIONS NUMBER THEIR VERSIONS ON THEIR OWN, so a `?v=` of this edition's never crosses to
    # another, and the other edition is read at the version it is on: a page only an older version
    # of it had is not that edition's page now.
    test "reads the other edition at its latest version, and no version number crosses", %{
      site: site
    } do
      %{persian: persian} = handbook!(site)

      older =
        version!(site, persian,
          version_number: "0.1.0",
          is_latest_for_version: false,
          published_at: ~U[2025-01-01 00:00:00Z]
        )

      page!(site, older, "english-only", title: "قدیمی", language: "fa")

      assert framed(document(site, :section, page_params("english-only"))).translations == []

      frame = framed(document(site, :section, page_params("install", %{"v" => "1.0.0"})))

      assert offered(frame) == [
               {"en", "/docs/handbook/install", "Install"},
               {"fa", "/fa/docs/rahnama/nasb", "نصب"}
             ]
    end

    test "is the page of the version `?v=` names in the edition being read", %{site: site} do
      %{english: english} = handbook!(site)

      older =
        version!(site, english,
          version_number: "0.9.0",
          is_latest_for_version: false,
          published_at: ~U[2025-01-01 00:00:00Z]
        )

      page!(site, older, "install", title: "Install (0.9)")

      frame = framed(document(site, :section, page_params("install", %{"v" => "0.9.0"})))

      assert Enum.map(frame.section_bar.crumbs, & &1.label) == ["Handbook", "Install (0.9)"]
    end

    # A PAGE FILED UNDER ANOTHER IS AT ITS OWN PART OF THE ADDRESS, the slugs of the pages above it
    # and then its own, in each edition (`MishkaDocument.Address`).
    test "is at its address among the pages of each edition", %{site: site} do
      %{en: en, fa: fa} = handbook!(site)

      start = page!(site, en, "start", title: "Start", order_position: 5)
      shoroo = page!(site, fa, "shoroo", title: "شروع", language: "fa", order_position: 5)

      child =
        page!(site, en, "first-steps",
          title: "First steps",
          parent_section_id: start.id,
          order_position: 0
        )

      page!(site, fa, "gam-aval",
        title: "گام اول",
        language: "fa",
        parent_section_id: shoroo.id,
        order_position: 0,
        language_group_id: child.language_group_id
      )

      frame = framed(document(site, :section, page_params("start/first-steps")))

      assert offered(frame) == [
               {"en", "/docs/handbook/start/first-steps", "First steps"},
               {"fa", "/fa/docs/rahnama/shoroo/gam-aval", "گام اول"}
             ]
    end

    test "is each edition's page at the address its document has", %{site: site} do
      handbook!(site, [path: "/handbook/docs"], path: "/rahnama/docs")

      frame =
        framed(
          given(site, "/handbook/docs/*section", "docs:page", %{
            "lang" => "en",
            "section" => "install"
          })
        )

      assert offered(frame) == [
               {"en", "/handbook/docs/install", "Install"},
               {"fa", "/rahnama/docs/nasb", "نصب"}
             ]
    end

    test "names nothing for a page the address does not name", %{site: site} do
      handbook!(site)

      frame = framed(document(site, :section, page_params("nowhere")))

      assert frame.translations == []

      assert frame.section_bar.crumbs == [%{label: "Handbook", path: "/docs/handbook"}]
    end
  end

  describe "the bar" do
    test "of a document's front page is Docs, then the document, and its version menu",
         %{site: site} do
      handbook!(site)

      %{section_bar: bar} = framed(document(site, :workspace, %{"workspace" => "handbook"}))

      assert bar.title == "Docs"
      assert bar.title_path == "/docs"
      assert bar.links == []
      assert bar.crumbs == [%{label: "Handbook", path: "/docs/handbook"}]
      assert bar.component == "doc-switcher"
    end

    test "of a page adds the page, the last of the trail, with no address", %{site: site} do
      handbook!(site)

      %{section_bar: bar} = framed(document(site, :section, page_params("install")))

      assert bar.crumbs == [
               %{label: "Handbook", path: "/docs/handbook"},
               %{label: "Install", path: nil}
             ]
    end

    for mode <- ~w(prefix_others prefix_all) do
      test "links Docs and the document at the address the site's URL mode gives, in #{mode}",
           %{site: site} do
        url_mode!(site, unquote(mode))
        handbook!(site)

        %{section_bar: bar} = framed(document(site, :section, page_params("install")))

        assert bar.title_path == english(unquote(mode), "/docs")
        assert [%{path: path}, _page] = bar.crumbs
        assert path == english(unquote(mode), "/docs/handbook")
      end
    end

    test "links to the library in the language of the document", %{site: site} do
      handbook!(site)

      %{section_bar: bar} =
        framed(document(site, :section, %{"workspace" => "rahnama", "section" => "nasb"}, "fa"))

      assert bar.title_path == "/fa/docs"

      assert bar.crumbs == [
               %{label: "راهنما", path: "/fa/docs/rahnama"},
               %{label: "نصب", path: nil}
             ]
    end

    # THE VERSION MENU IS THE KIT'S `doc-switcher`, a block with state of its own, so the bar gives it
    # an id, and the page's own URL keys — the document, the page, the version — and the base it
    # builds every version's address from. The language is the page's, not a key of the URL.
    test "hands the version menu what it reads the document by", %{site: site} do
      handbook!(site)

      params = page_params("install", %{"v" => "1.0.0"})

      %{section_bar: %{component: "doc-switcher", assigns: given}} =
        framed(document(site, :section, params))

      assert given == %{
               id: "doc-version",
               lang: "en",
               doc_base: "/:lang/docs",
               params: params,
               version_text: ""
             }
    end

    test "tells the version menu a document at an address of its own is read there", %{site: site} do
      handbook!(site, path: "/handbook/docs")

      %{section_bar: %{assigns: handed}} =
        framed(given(site, "/handbook/docs/*section", "docs:page", %{"section" => "install"}))

      assert %{path: "/handbook/docs", lang_param: "", id: "doc-version"} = handed
    end

    test "of the library is its title alone, and the library keeps the core's languages",
         %{site: site} do
      handbook!(site)

      given = given(site, "/:lang/docs", nil, %{"lang" => "en"})
      frame = framed(given)

      assert frame.section_bar == %{
               title: "Docs",
               title_path: "/docs",
               label: nil,
               links: [],
               crumbs: [],
               component: nil,
               assigns: %{}
             }

      assert frame.translations == given.translations
    end

    test "is drawn on a page of the documentation's section whatever it shows", %{site: site} do
      frame = framed(given(site, "/:lang/docs/other", "docs:something", %{"lang" => "en"}))

      assert frame.section_bar.title == "Docs"
    end
  end

  describe "every other page" do
    test "is handed back untouched, with nothing read", %{site: site} do
      for {section, record} <- [{"blog", "blog:post"}, {nil, nil}, {"page", nil}] do
        given =
          SiteLayout.given(
            %{title: "Post", path: "/:lang/blog/:slug", language: "en", section: section},
            site_id: site.id,
            extra: (record && %{"record" => record}) || %{},
            params: %{"lang" => "en", "slug" => "post"}
          )

        assert {:reply, ^given} = PageFrame.call(given)
      end
    end
  end

  describe "as a plugin" do
    test "is supervised by this extension" do
      assert PageFrame in MishkaDocument.Application.plugins()
    end

    test "answers the layout's own event" do
      assert PageFrame.config(:__event__) == SiteLayout.event()
    end

    # THE EVENT `SiteLayout.frame/2` FIRES, which goes through the plugin the way the CMS boot
    # registers it.
    test "is asked of this extension by the layout", %{site: site} do
      handbook!(site)

      MishkaCmsCore.PluginRegistrations.reconcile(false)
      {:ok, _registered} = PageFrame.register()
      on_exit(fn -> MishkaInstaller.Event.Event.unregister(:name, PageFrame, false) end)

      :ok =
        MishkaInstaller.Event.EventHandler.do_compile(PageFrame.config(:__event__), :start, false)

      frame =
        SiteLayout.frame(
          %{
            title: "Document page",
            path: Provision.item_paths().section,
            language: "en",
            section: "document"
          },
          site_id: site.id,
          extra: %{"record" => "docs:page"},
          params: page_params("install", %{"lang" => "en"}),
          translations: []
        )

      assert offered(frame) == [
               {"en", "/docs/handbook/install", "Install"},
               {"fa", "/fa/docs/rahnama/nasb", "نصب"}
             ]

      assert frame.section_bar.title == "Docs"
      assert frame.section_bar.component == "doc-switcher"
    end
  end
end
