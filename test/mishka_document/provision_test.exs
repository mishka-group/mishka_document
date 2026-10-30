# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_document/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaDocument.ProvisionTest do
  @moduledoc """
  What a site is given when it is provisioned, and — the half that matters more — what it is never
  given twice.

  `MishkaDocument.Provision.ensure!/2` is reached from two screens that can both run at any moment: the install
  wizard, for the extensions an operator ticked, and a button an admin can press as often as they
  like — both through `installer:extension:install`. So
  every case here is written around the second run: the components and pages a site already has must
  come through it untouched, including the ones an admin edited, archived or replaced.

  The latest-documents snippet is not written here. The core keeps no snippet of its own: the run
  hands it to whichever visual editor the host installed, on `runtime:provision:snippets`, and the
  editor saves it once per site. This suite has no editor, so a run reports no snippet; where a case
  is about what the documentation hands an editor, `MishkaDocument.Test.Plugins.ProvisionSnippetSaved`
  stands in for one.

  The templates are not rendered here. `Page :master_create` compiles every one of them through
  `Validations.PageCodeCompiles` before it writes the row, so a sample page that does not compile
  fails these tests at the moment it is created; what the components then draw is
  `MishkaDocument.LiveComponentsRenderTest`, and what a reader sees at these URLs is
  `MishkaCmsWeb.DocumentProvisionPagesTest` in the application that has a router.
  """
  use MishkaDocument.DataCase, async: false

  import ExUnit.CaptureLog

  alias MishkaCmsCore.Install
  alias MishkaCmsCore.Install.{Bootstrap, Extensions}
  alias MishkaCmsCore.Runtime.Component
  alias MishkaCmsCore.Runtime.ExtensionProvision
  alias MishkaCmsCore.Runtime.Helpers
  alias MishkaCmsCore.Runtime.Languages
  alias MishkaCmsCore.Runtime.Media
  alias MishkaCmsCore.Runtime.Page
  alias MishkaCmsCore.Runtime.PageProvision
  alias MishkaCmsCore.Runtime.States.SiteState
  alias MishkaCmsCore.Runtime.Translation
  alias MishkaCmsCore.Test.Installer, as: TestInstaller
  alias MishkaDocument.Plugins.{Installer, PageFrame}
  alias MishkaDocument.Provision
  alias MishkaDocument.Test.Plugins.ProvisionSnippetSaved
  alias MishkaInstaller.Event.EventHandler

  require Ash.Query

  @moduletag :integration

  # THE EVENT THE PLUGIN ITSELF DECLARES, not one spelled out again here. Registering it under a name
  # this file chose would test the notifier and the event compiler and leave the one thing that can
  # silently drift — whether this plugin is listening where the installer fires — asserted by
  # nothing.
  @event Installer.config(:__event__)

  setup do
    name = "provisiondocs#{System.unique_integer([:positive])}"
    {:ok, site: create_site!(name: name, host: "#{name}.test", active: true)}
  end

  defp components(site), do: rows(Component, :read_any, site)
  defp archived_components(site), do: rows(Component, :master_archived, site)
  defp pages(site), do: rows(Page, :read_any, site)

  defp rows(resource, action, site) do
    resource
    |> Ash.Query.for_read(action, %{}, authorize?: false)
    |> Ash.Query.filter(site_id == ^site.id)
    |> Ash.read!(page: [limit: 100])
    |> then(& &1.results)
  end

  defp component(site, name), do: Enum.find(components(site), &(&1.name == name))
  defp page(site, path), do: Enum.find(pages(site), &(&1.path == path))

  # A VISUAL EDITOR ON THE SNIPPET'S EVENT, for the length of the test. The suite has none of its
  # own: the snippet is the editor's to save, and the core answers `snippets: []` without one.
  defp with_an_editor do
    TestInstaller.register!(ProvisionSnippetSaved, "runtime:provision:snippets")
  end

  # THE CALLS A STORED TEMPLATE MAKES, as the templates are written: `<.component …/>` with one
  # attribute per line, which is what lets a key be taken from the start of a line and never out of
  # the middle of somebody's `empty_text`. The dispatch's own keys are not the component's
  # attributes — `LiveViewHelpers.component/1` reads `component_name` and `site` and drops them, and
  # `id` is LiveView's.
  defp component_calls(source) do
    ~r|<\.component\b(.*?)/>|s
    |> Regex.scan(source)
    |> Enum.map(fn [_whole, call] ->
      [_all, name] = Regex.run(~r/component_name="([^"]+)"/, call)

      given =
        ~r/^\s*([a-z_][a-z0-9_]*)=(.*)$/m
        |> Regex.scan(call)
        |> Enum.map(fn [_whole, key, value] -> {key, written_as(value)} end)
        |> Enum.reject(fn {key, _value} -> key in ~w(component_name site id) end)

      {name, given}
    end)
  end

  defp component_keys(source),
    do:
      Enum.map(component_calls(source), fn {name, given} ->
        {name, Enum.map(given, &elem(&1, 0))}
      end)

  # How a value is written, which for a base is half of what it means: a `"literal"` is stored in the
  # page and reaches the block as it stands, while an `{expression}` is HEEx and is evaluated per
  # request against that request's assigns. Anything else is neither, and is handed back as it was so
  # the rule refusing it can say what it found.
  defp written_as(~s(") <> rest), do: {:literal, String.trim_trailing(rest, ~s("))}
  defp written_as("{" <> rest), do: {:expression, String.trim_trailing(rest, "}")}
  defp written_as(other), do: {:neither, other}

  # Every page this module writes, and the snippet, by the name to put in a failure message. The
  # snippet is the markup the run hands an editor for this site, the manifest's own function applied
  # to the site's name, since no editor here saves it.
  defp templates(site) do
    Enum.map(pages(site), &{&1.path, &1.template}) ++
      [{Provision.snippet_name(), Provision.manifest().snippet.source.(site.name)}]
  end

  # A declaration is a map that has been through JSON and through Ash's own casting, so its keys are
  # strings or atoms (`ComponentCompiler.declared_keys/1` takes both).
  defp attr_name(attr),
    do: attr |> Map.new(fn {key, value} -> {to_string(key), value} end) |> Map.fetch!("name")

  defp bundle_components do
    MishkaDocument.Kit.bundle_path()
    |> File.read!()
    |> Jason.decode!()
    |> Map.fetch!("components")
  end

  describe "the first run" do
    # THE DOCUMENT'S OWN PERMISSION NAMES ARRIVE WITH IT, as its components do, and not with
    # the core install: the first site's run creates them, and every later site finds them.
    test "creates the document's permission names, and another site's run creates none", %{
      site: site
    } do
      names = Enum.map(Provision.manifest().permissions, &elem(&1, 0))

      assert names != []
      assert stored_permissions(names) == []

      assert Provision.ensure!(site).permissions == names
      assert Enum.sort(stored_permissions(names)) == Enum.sort(names)

      assert Provision.ensure!(create_site!()).permissions == []
    end

    test "installs every component the bundle ships, scoped to this site", %{site: site} do
      report = Provision.ensure!(site)

      assert Enum.sort(report.components) == Enum.sort(Provision.component_names())

      for name <- Provision.component_names() do
        found = component(site, name)

        assert found, "#{name} was not installed"
        assert found.site_id == site.id
      end
    end

    # THE PAGE SAYS WHAT IT SHOWS, so its SEO is the record's whatever path it is later given.
    test "marks each page that shows a record with the kind it shows", %{site: site} do
      Provision.ensure!(site)
      paths = Provision.item_paths()
      by_path = Map.new(pages(site), &{&1.path, &1})

      assert by_path[paths.workspace].extra["record"] == "docs:document"
      assert by_path[paths.section].extra["record"] == "docs:page"
      refute Map.has_key?(by_path["/:lang/docs"].extra || %{}, "record")
    end

    test "creates the sample pages, every one of them in the document section", %{site: site} do
      report = Provision.ensure!(site)

      assert report.pages == Provision.page_paths()

      for path <- Provision.page_paths() do
        found = page(site, path)

        assert found, "#{path} was not created"
        assert found.section == "document"
        assert found.site_id == site.id
        assert found.active == true
      end
    end

    # THE HEADER, THE FOOTER AND THE LANGUAGE SWITCHER ARE THE LAYOUT'S. The templates draw what the
    # design shows between the two, so a page written with no layout is a page with neither — and the
    # site's `site-main` is the one its home page hangs on, which is the layout a page is given when
    # the site has it.
    test "hangs every page on the site's site-main layout, which gives it a header and a footer",
         %{site: site} do
      layout = create_layout!(site_id: site.id, name: "site-main")

      Provision.ensure!(site)

      for path <- Provision.page_paths() do
        assert page(site, path).layout_id == layout.id, "#{path} is not drawn in site-main"
      end
    end

    test "writes no layout where the site has none, and none of another site's", %{site: site} do
      elsewhere = create_site!()
      create_layout!(site_id: elsewhere.id, name: "site-main")
      create_layout!(site_id: site.id, name: "something-else")

      Provision.ensure!(site)

      for path <- Provision.page_paths() do
        assert page(site, path).layout_id == nil
      end
    end

    test "hangs a document's own address on the layout too", %{site: site} do
      layout = create_layout!(site_id: site.id, name: "site-main")

      report = Provision.ensure_address!(site, "/handbook/docs")

      assert Enum.sort(report.pages) == ["/handbook/docs", "/handbook/docs/*section"]

      for path <- report.pages do
        assert page(site, path).layout_id == layout.id
      end
    end

    test "draws no header and no footer of its own, and no hand-written colour", %{site: site} do
      Provision.ensure!(site)

      for found <- pages(site) do
        refute found.template =~ "<header", "#{found.path} draws a header the layout owns"
        refute found.template =~ "<footer", "#{found.path} draws a footer the layout owns"
        refute found.template =~ ~r/\bstyle=/, "#{found.path} writes a style attribute"

        refute found.template =~ "text-[#1b1a18]",
               "#{found.path} still writes the old page's colours"

        refute found.template =~ ~r/\[#[0-9a-fA-F]{3,6}\]/,
               "#{found.path} writes a colour the theme has a token for"
      end
    end

    # THE LIBRARY IS THE DESIGN'S: a hero over the search, the featured documents as cards and the rest
    # as rows. Its words are the design's, and the list is told to draw all of it.
    test "draws the library with its hero, its search and its two lists", %{site: site} do
      Provision.ensure!(site)
      template = page(site, "/:lang/docs").template

      assert template =~ "DOCUMENTATION"
      assert template =~ "written down"

      assert template =~
               "Guides, references and handbooks — versioned and available in several languages."

      [{"doc-workspace-list", given}] = component_calls(template)
      given = Map.new(given)

      assert given["show_search"] == {:expression, "true"}
      assert given["split_featured"] == {:expression, "true"}
      assert given["show_details"] == {:expression, "true"}
      refute Map.has_key?(given, "show_languages"), "the library asks for a row of language pills"
      assert given["read_text"] == {:literal, "Open"}
      assert given["params"] == {:expression, ~S|Map.drop(@query_params, ["lang"])|}
    end

    # THE BAR UNDER THE HEADER IS THE LAYOUT'S, filled by `MishkaDocument.Plugins.PageFrame` with
    # where the reader is and the version being read, so the page draws the contents, the page and the
    # list of its headings and nothing above them.
    test "draws a document's pages as the contents, the page and the list of its headings", %{
      site: site
    } do
      Provision.ensure!(site)

      for path <- Provision.item_paths() |> Map.values() do
        template = page(site, path).template

        assert Enum.map(component_calls(template), &elem(&1, 0)) ==
                 ["doc-sidebar", "doc-section", "doc-toc"]

        section = template |> component_calls() |> Enum.at(1) |> elem(1) |> Map.new()
        assert section["crumb_current"] == {:expression, "true"}
      end
    end

    # THE HEADER'S LANGUAGE DROPDOWN IS THE ONLY LANGUAGE SWITCH. The pages used to carry a second
    # one, `doc-switcher`'s row of language pills, in a bar of their own, and the library's cards a
    # third, a pill per edition of each document.
    test "draws no language pills and no switcher of its own", %{site: site} do
      Provision.ensure!(site)
      Provision.ensure_address!(site, "/handbook/docs")

      for {name, template} <- templates(site) do
        refute template =~ "doc-switcher", "#{name} still draws the switcher"
        refute template =~ ~r/\bshow_crumb=|\bshow="(both|language)"/, "#{name} asks for pills"
        refute template =~ ~r/\bshow_languages\b/, "#{name} asks for a pill per edition"
        refute template =~ ~r/data-role="doc-switcher/, "#{name} draws a switcher's part"
      end
    end

    # UNDER 880 PIXELS THE CONTENTS ARE A CLOSED DISCLOSURE, because a list of thirty pages above the
    # article puts the article below the first screen of a phone. The design has no phone, so this is
    # the page's own: a `<details>` that is not open, holding the contents and nothing else, before
    # the page in the markup — and the on-this-page list after it, where it cannot push it down.
    # From 880 pixels the summary is not drawn and the contents are shown whether it is open or not.
    test "draws the contents as a closed disclosure above the page, and the page outside it", %{
      site: site
    } do
      Provision.ensure!(site)
      Provision.ensure_address!(site, "/handbook/docs")

      document_pages =
        Enum.filter(pages(site), fn found ->
          found.path in Map.values(Provision.item_paths()) or
            String.starts_with?(found.path, "/handbook")
        end)

      assert length(document_pages) == 4

      for %{path: path, template: template} <- document_pages do
        assert [disclosure] = Regex.run(~r{<details\b.*?</details>}s, template),
               "#{path} has no disclosure for the contents"

        [opening] = Regex.run(~r/<details\b[^>]*>/, disclosure)
        refute opening =~ ~r/\bopen\b/, "#{path} draws the contents open"

        assert [summary] = Regex.run(~r{<summary\b.*?</summary>}s, disclosure)
        assert summary =~ ~r/>\s*Pages\s*</, "#{path}'s summary does not say what is in it"

        assert Enum.map(component_calls(disclosure), &elem(&1, 0)) == ["doc-sidebar"],
               "#{path}'s disclosure holds something other than the contents"

        {opened_at, _} = :binary.match(template, "<details")
        {page_at, _} = :binary.match(template, ~s(component_name="doc-section"))
        {headings_at, _} = :binary.match(template, ~s(component_name="doc-toc"))

        assert opened_at < page_at, "#{path} draws the page before its contents"
        assert page_at < headings_at, "#{path} draws the headings above the page"

        assert opened_at + byte_size(disclosure) < page_at,
               "#{path} draws the page in the contents"

        # From 880px: no summary, and the contents shown though the element is closed.
        assert opening =~ "min-[880px]:details-content:[content-visibility:visible]"
        assert summary =~ "min-[880px]:supports-[selector(::details-content)]:hidden"

        # A press on a page of the contents closes it again, the way the sidebar offers.
        sidebar = disclosure |> component_calls() |> hd() |> elem(1) |> Map.new()
        [_whole, id] = Regex.run(~r/<details\s+id="([^"]+)"/, disclosure)

        assert sidebar["link_click"] ==
                 {:expression, ~s|Phoenix.LiveView.JS.remove_attribute("open", to: "##{id}")|}
      end
    end

    # THE LAYOUT'S COLUMN IS THE PAGE'S WIDTH: 1160 pixels with its gutters, so a page that wraps
    # itself in a container of its own doubles the gutters and widens the page past the header and the
    # footer. What each page draws is its sections straight into the column.
    test "draws no outer container: the layout's column is the width", %{site: site} do
      Provision.ensure!(site)
      Provision.ensure_address!(site, "/handbook/docs")

      pages =
        Enum.filter(pages(site), fn found ->
          found.path in Provision.page_paths() or String.starts_with?(found.path, "/handbook")
        end)

      assert length(pages) == 5

      for found <- pages do
        refute found.template =~ "max-w-[1280px]", "#{found.path} still uses the 1280 column"
        refute found.template =~ "max-w-[1160px]", "#{found.path} draws the layout's column again"

        # The elements at the root of the template: none is a centred, side-padded or capped box.
        roots = Regex.scan(~r/^<[a-z][a-z0-9]*\b[^>]*?\bclass="([^"]*)"/m, found.template)

        assert roots != [], "#{found.path} has no element at its root"

        for [_tag, classes] <- roots, class <- String.split(classes) do
          refute class == "mx-auto", "#{found.path} centres its whole page"
          refute class =~ ~r/^(max-w-|px-|container$)/, "#{found.path} wraps its page in #{class}"
        end
      end
    end

    # A PAGE IS ONE ROW FOR EVERY LANGUAGE. `:lang` is a capture the resolver fills from the URL and
    # `MishkaCmsCore.Runtime.Languages` admits only the site's own languages into — so three rows
    # serve a site publishing in five languages, and each block is told which one it was asked for.
    test "as pattern pages, so one row answers every language the site publishes in", %{
      site: site
    } do
      Provision.ensure!(site)

      for path <- Provision.page_paths() do
        assert String.starts_with?(path, "/:lang/"),
               "#{path} pins a language, so the site's other languages have no documentation"
      end

      assert page(site, "/:lang/docs").template =~ "@page.language"
    end

    # THE ADDRESS A DOCUMENT HAS, AND THE ADDRESS ITS PAGES HAVE, are two rows rather than one
    # `*rest`: a rest capture must match at least one segment (see `WebRunTimeMetaDataState`), so a
    # single `/:lang/docs/*rest` page would leave a document's own front page with no URL at all.
    test "gives a document a front page as well as a page for each of its pages", %{site: site} do
      Provision.ensure!(site)

      assert Provision.page_paths() == [
               "/:lang/docs",
               "/:lang/docs/:workspace",
               "/:lang/docs/:workspace/*section"
             ]
    end

    # THE LANGUAGE IS THE PAGE'S OWN, wherever the page came from, so every block is told it and no
    # block is left to find it in the query keys a visitor also writes. A block handed neither takes
    # the edition the slug names, whatever language the reader asked for — which is the English
    # document inside a Persian shell. `MishkaCmsWeb.DocumentProvisionPagesTest` is where that is
    # driven; this is what makes it true of all of them rather than of the one a case happens to
    # look at.
    #
    # THE SNIPPET IS HELD TO IT TOO, though it lands on a page this module has never seen: its path
    # may capture `lang` or may capture nothing at all, and `PageEditions.language/3` answers both —
    # the captured code, else the page row's own language — so there is no page on which a block
    # would have to fall back to what a visitor appended.
    test "pins every block to the language the page is being read in", %{site: site} do
      Provision.ensure!(site)

      for {where, source} <- templates(site),
          {name, given} <- component_keys(source) do
        assert "lang" in given, "#{name} on #{where} reads a language from nowhere"

        refute "lang_param" in given,
               "#{name} on #{where} names a key nothing reads off a base that carries the language"
      end
    end

    # AND HANDS IT NO `params` TO FIND ANOTHER IN. `RuntimeLive` merges the captured `lang` over the
    # query string, so passing the map whole would be right on a pattern page by that precedence
    # rather than by anything the page says — and on the snippet's page, which captures no language
    # to merge, it would not be right at all. Every other key a block needs (`:workspace`,
    # `:section`, `?v=`) still has to reach it.
    test "and hands it the rest of the URL with the language taken out", %{site: site} do
      Provision.ensure!(site)

      for {where, source} <- templates(site) do
        assert source =~ ~S|params={Map.drop(@query_params, ["lang"])}|,
               "#{where} hands a block the language in its params after all"
      end
    end

    # A BASE WITH THE CAPTURE STILL IN IT, held to for every call rather than for the ones somebody
    # remembered. A `*_base` is a path a block appends a row's slug to and fills the `lang` segment
    # of from THAT ROW's language, which is the language the reader will be reading in when they
    # arrive — a base with the page's own language baked in would offer every translation under the
    # language the reader is leaving, and one with no language in it at all is a path this site has
    # no page at. `base` is the opposite and has to be this page's real URL, because it is what the
    # index's pager writes to the address bar — so it is the address `site_path/2` builds from the
    # page's own language, at the place the site's URL mode puts it.
    #
    # Which names those are is read off the components, so a base added to the bundle is covered here
    # the day it arrives rather than the day somebody remembers this test. The capture is looked for
    # as the literal `:lang` segment rather than through `Languages.captures?/1`, which is a question
    # about a page's PATH and admits `*lang` as well: `doc_href/5` in the bundle tells a base that
    # carries the language in its path by that one spelling.
    test "builds every link base from the language capture and every URL from the page", %{
      site: site
    } do
      Provision.ensure!(site)
      capture = ":" <> Languages.capture()

      bases =
        for component <- components(site),
            attr <- component.attrs,
            name = attr_name(attr),
            name == "base" or String.ends_with?(name, "_base"),
            into: MapSet.new(),
            do: name

      checked =
        for {where, source} <- templates(site),
            {name, given} <- component_calls(source),
            {key, value} <- given,
            MapSet.member?(bases, key) do
          case key do
            "base" ->
              assert {:expression, expression} = value,
                     "#{where} writes #{name}'s base as #{inspect(value)}, and a pager's URL is this page's own"

              assert expression =~ ~r/^site_path\(/,
                     "#{where} writes #{name} a pager URL the site's URL mode does not build: #{expression}"

              assert expression =~ "@page.language",
                     "#{where} writes #{name} a base holding no language of its own: #{expression}"

            _link_base ->
              assert {:literal, literal} = value,
                     "#{where} writes #{name}'s #{key} as #{inspect(value)}, and a link base is the same path on every request"

              assert capture in String.split(literal, "/"),
                     "#{where} hands #{name} a #{key} of #{literal}, which cannot lead to another language's edition"
          end

          key
        end

      assert checked != [],
             "no base was read out of the sample pages, so this asserts nothing of them"
    end

    # AND EVERY URL WRITTEN OUT BY HAND IS ONE OF THE PAGES THIS MODULE CREATES. A base names a row's
    # address and the rule above holds it to the capture; the index's pager and the header's link are
    # the other kind — they name a PAGE — so one that has drifted from the path it was copied from is
    # a link to the 404 with nothing in this suite to notice it. Read as the pattern `site_path/2` is
    # handed, which is the form the page definitions themselves are in.
    test "writes no URL of its own that it does not also create a page at", %{site: site} do
      Provision.ensure!(site)
      paths = Enum.map(Provision.page_paths(), &String.split(&1, "/", trim: true))

      written =
        for {where, source} <- templates(site),
            [_whole, address] <- Regex.scan(~r/site_path\("([^"]*)"/, source) do
          assert Enum.any?(paths, &List.starts_with?(&1, String.split(address, "/", trim: true))),
                 "#{where} links #{address}, which is no page this module creates"

          address
        end

      assert written != [],
             "no URL was read out of the sample pages, so this asserts nothing of them"
    end

    # AN ATTRIBUTE A COMPONENT DOES NOT DECLARE IS AN ERROR NOWHERE. `ComponentCompiler` splits what
    # a page passes by the component's own declarations and sweeps everything else into its global
    # attr, which the template renders onto its root element — so `lang={@page.language}` handed to a
    # component declaring no `lang` becomes `lang="fa"` in the public HTML, the helper reading it is
    # given nil, and the page still draws. A rename in the bundle, or a typo here, is therefore
    # silent in every other test: a page renders, and does the older thing.
    #
    # This is the one place the two halves are held together, and it can only hold the halves in this
    # checkout — a site that already has the components keeps the ones it has (see the moduledoc of
    # `MishkaDocument.Provision`).
    test "hands each component only attributes that component declares", %{site: site} do
      Provision.ensure!(site)

      declared =
        Map.new(components(site), fn component ->
          {component.name, MapSet.new(component.attrs, &attr_name/1)}
        end)

      for {where, source} <- templates(site) do
        calls = component_keys(source)

        assert calls != [],
               "no component call was read out of #{where}, so nothing is asserted of it"

        for {name, given} <- calls, key <- given do
          assert Map.has_key?(declared, name),
                 "#{where} draws #{name}, which the bundle does not ship"

          assert MapSet.member?(declared[name], key),
                 "#{where} hands #{name} an undeclared #{key}, which nothing reads"
        end
      end
    end

    # EVERY COMPONENT THE BUNDLE SHIPS IS REACHABLE FROM A PAGE. A component nobody was given
    # anywhere to put is a palette entry an author has to discover, which is the state this whole
    # step exists to end — and a function component is met through the block that draws it, which
    # is the only place it can be met: it has no query of its own and nothing to say without one.
    test "puts every component the bundle ships somewhere a reader can meet it", %{site: site} do
      Provision.ensure!(site)

      on_a_page =
        for {_where, source} <- templates(site),
            {name, _given} <- component_calls(source),
            uniq: true,
            do: name

      drawn_by_a_block =
        for component <- bundle_components(),
            piece <- component["dependencies"],
            uniq: true,
            do: piece

      # AND THE ONE THE BAR UNDER THE HEADER DRAWS, which no page names:
      # `MishkaDocument.Plugins.PageFrame` hands it to the layout.
      drawn_by_the_bar = MishkaDocument.Plugins.PageFrame.bar_components()

      assert Enum.sort(Enum.uniq(on_a_page ++ drawn_by_a_block ++ drawn_by_the_bar)) ==
               Enum.sort(Provision.component_names())
    end

    test "hands the latest-documents block to the page editor as a snippet", %{site: site} do
      with_an_editor()

      report = Provision.ensure!(site)

      assert report.snippets == [Provision.snippet_name()]

      assert_received {:snippet_offered, offered}
      assert offered.app == :mishka_document
      assert offered.snippet.name == Provision.snippet_name()
      assert offered.snippet.source =~ "doc-workspace-list"
      assert offered.site_id == site.id
      assert offered.site_name == site.name
    end

    test "reports no snippet without an editor, and gives the site the rest", %{site: site} do
      report = Provision.ensure!(site)

      assert report.snippets == []
      assert length(report.pages) == length(Provision.page_paths())
      assert length(components(site)) == length(Provision.component_names())
    end

    test "takes a site id as well as the record", %{site: site} do
      report = Provision.ensure!(site.id)

      assert length(report.pages) == length(Provision.page_paths())
      assert length(components(site)) == length(Provision.component_names())
    end

    test "says so rather than half-provisioning a site that is not there" do
      assert_raise ArgumentError, ~r/no site/, fn ->
        Provision.ensure!(Ash.UUID.generate())
      end
    end
  end

  describe "running it again" do
    setup %{site: site} do
      Provision.ensure!(site)
      :ok
    end

    test "creates nothing at all, and says every page is already there", %{site: site} do
      report = Provision.ensure!(site)

      assert %{components: [], pages: [], snippets: []} = report
      assert Enum.map(report.skipped_pages, & &1.path) == Provision.page_paths()

      assert length(components(site)) == length(Provision.component_names())
      assert length(pages(site)) == length(Provision.page_paths())
    end

    # THE REASON THE WHOLE MODULE IS WRITTEN THE WAY IT IS. `UiKitHandler.install_kit!/2` upserts, so
    # a second install of a name the site already has would overwrite the admin's work with the
    # bundle's copy and say nothing about it.
    test "keeps an edit an admin made to a component", %{site: site} do
      before = component(site, "doc-workspace-list")

      {:ok, edited} =
        Ash.update(before, %{template: ~S(<div id={@id}>mine</div>)},
          action: :master_update,
          authorize?: false,
          tenant: site.id
        )

      assert Provision.ensure!(site).components == []

      after_second = component(site, "doc-workspace-list")
      assert after_second.id == edited.id
      assert after_second.template == ~S(<div id={@id}>mine</div>)
    end

    test "keeps a page an admin rewrote", %{site: site} do
      before = page(site, "/:lang/docs")

      {:ok, edited} =
        Ash.update(before, %{template: ~S(<div>my own documentation index</div>)},
          action: :master_update,
          authorize?: false,
          tenant: site.id
        )

      assert Provision.ensure!(site).pages == []

      after_second = page(site, "/:lang/docs")
      assert after_second.id == edited.id
      assert after_second.template == ~S(<div>my own documentation index</div>)
    end

    # AND THE ONE CASE WHERE THAT EDIT CAN ACTUALLY BE LOST. Every other case here runs the
    # installer with nothing missing, where it is never called at all — so `selection:` decides
    # nothing and could be deleted without a test noticing. A site missing ONE name is where it
    # decides everything: `install_kit!/2` upserts every component of the bundle it is handed, so
    # without the selection the four rows that are already there are written over on the way to the
    # one that is not. A bundle that grows a component, or a row somebody deleted outright, is how a
    # site gets here.
    test "installs the one component that is missing and writes over none of the others", %{
      site: site
    } do
      gone = component(site, "doc-toc")
      mine = component(site, "doc-workspace-list")

      :ok =
        Ash.destroy!(gone, action: :master_permanent_destroy, authorize?: false, tenant: site.id)

      {:ok, _edited} =
        Ash.update(mine, %{template: ~S(<div id={@id}>mine</div>)},
          action: :master_update,
          authorize?: false,
          tenant: site.id
        )

      assert Provision.ensure!(site).components == ["doc-toc"]

      assert component(site, "doc-toc"), "the component that was gone was not installed"

      assert component(site, "doc-workspace-list").template == ~S(<div id={@id}>mine</div>),
             "the installer wrote the bundle's copy over an edit the admin made"
    end

    # ARCHIVING IS AN ANSWER, not an absence. The installer skips an archived row rather than
    # reviving it, so re-offering the name would report an install that did not happen — and the
    # admin who archived it would find it back in the palette.
    test "leaves a component the admin archived where they put it", %{site: site} do
      archived = component(site, "doc-toc")
      :ok = Ash.destroy!(archived, action: :master_destroy, authorize?: false, tenant: site.id)

      assert Provision.ensure!(site).components == []

      refute component(site, "doc-toc"), "an archived component came back as a new row"
      assert Enum.any?(archived_components(site), &(&1.name == "doc-toc"))
    end
  end

  # THE BAR'S WORDS ARE THE SITE'S TRANSLATIONS, as the blog's are: the bar asks for them from a plugin
  # (`MishkaDocument.Plugins.PageFrame`), not from a template that saving a page could register them
  # from, so setting a site up registers them for a translator to find.
  describe "the documentation's words" do
    setup %{site: site} do
      on_exit(fn ->
        MishkaCmsCore.Runtime.States.SettingsState.delete(site.id, "site.languages")
      end)

      {:ok, _} = MishkaCmsCore.Settings.put("site.languages", ["en", "fa"], site_id: site.id)
      :ok
    end

    defp registered(site, words) do
      Translation
      |> Ash.Query.for_read(:read_any, %{}, authorize?: false)
      |> Ash.Query.filter(key in ^words and site_id == ^site.id)
      |> Ash.read!(authorize?: false, page: false)
      |> Enum.map(&{&1.key, &1.language})
      |> Enum.sort()
    end

    test "are registered in each language of the site, and a translator's value is kept", %{
      site: site
    } do
      words = PageFrame.words()

      assert words == ["Docs"]
      assert registered(site, words) == []

      Provision.ensure!(site)

      assert registered(site, words) == [{"Docs", "en"}, {"Docs", "fa"}]

      {:ok, _} =
        Translation
        |> Ash.Query.for_read(:read_any, %{}, authorize?: false)
        |> Ash.Query.filter(key == "Docs" and language == "fa" and site_id == ^site.id)
        |> Ash.read_one!(authorize?: false)
        |> Ash.Changeset.for_update(:update, %{value: "مستندات"}, authorize?: false)
        |> Ash.update(authorize?: false)

      Provision.ensure!(site)

      assert registered(site, words) == [{"Docs", "en"}, {"Docs", "fa"}]

      assert Ash.read_one!(
               Ash.Query.filter(
                 Translation,
                 key == "Docs" and language == "fa" and site_id == ^site.id
               ),
               authorize?: false
             ).value == "مستندات"
    end

    test "are registered by a document's own address too", %{site: site} do
      Provision.ensure_address!(site, "/handbook/docs")

      assert registered(site, PageFrame.words()) == [{"Docs", "en"}, {"Docs", "fa"}]
    end
  end

  describe "a path that is not free" do
    test "is left to whoever holds it, and the rest are still created", %{site: site} do
      taken = List.last(Provision.page_paths())

      mine =
        create_page!(
          site_id: site.id,
          path: taken,
          template: ~S(<div>mine</div>)
        )

      report = Provision.ensure!(site)

      refute taken in report.pages
      assert length(report.pages) == length(Provision.page_paths()) - 1
      assert page(site, taken).id == mine.id
      assert page(site, taken).template == ~S(<div>mine</div>)

      assert [held] = report.skipped_pages
      assert held.path == taken
      assert PageProvision.note(held) =~ ~s(its path "#{taken}" is taken)
    end

    # AN ARCHIVED PAGE COUNTS AS HOLDING ITS PATH, which is stricter than the index: that one is
    # partial on `(archived_at IS NULL)` and would take the write. A site that took it would hold a
    # second page at an address it has already used, and the archived one could never come back.
    test "counts a page the admin archived as holding it", %{site: site} do
      taken = hd(Provision.page_paths())

      mine = create_page!(site_id: site.id, path: taken, template: ~S(<div>mine</div>))
      :ok = Ash.destroy!(mine, action: :master_destroy, authorize?: false, tenant: site.id)

      report = Provision.ensure!(site)

      refute taken in report.pages
      refute page(site, taken)
    end
  end

  # THE OTHER IDENTITY A PAGE ROW HAS, and the one no reading of paths can see. Left as a skip, it
  # cost the site the page a reader starts at: a site holding a page called "Documentation" at an
  # address of its own never got `/:lang/docs`, and no later run was going to write it while that
  # name was held. A held name is now answered with the next free one.
  describe "a name that is not free" do
    test "is answered with another name, at the address the docs are read at", %{site: site} do
      with_an_editor()

      mine =
        create_page!(
          site_id: site.id,
          name: "Documentation",
          path: "/handbook",
          template: ~S(<div>mine</div>)
        )

      report = Provision.ensure!(site)

      assert report.pages == Provision.page_paths(),
             "the definition whose name was taken was left out"

      assert report.snippets == [Provision.snippet_name()],
             "the run stopped before the snippet"

      assert report.skipped_pages == []

      index = page(site, hd(Provision.page_paths()))

      assert index, "the documentation's index was not created"
      assert index.name == "documentation-2"

      assert [renamed] = report.renamed_pages

      assert PageProvision.note(renamed) =~ ~s(its name "documentation" is taken),
             "the admin is not told why their page is called something else"

      assert PageProvision.note(renamed) =~ ~s(so it was created as "documentation-2")

      assert page(site, "/handbook").id == mine.id
      assert page(site, "/handbook").template == ~S(<div>mine</div>)
    end

    # THE NAME AS THE ROW CARRIES IT, which is not the name anybody typed: `master_create` slugifies
    # it, so "DOCUMENTATION" and "Document Page" are these definitions' names too and a comparison of
    # the literals would miss every one of them.
    test "counts one the site spelled its own way, and a second run still adds nothing", %{
      site: site
    } do
      create_page!(
        site_id: site.id,
        name: "DOCUMENTATION",
        path: "/handbook",
        template: ~S(<div>mine</div>)
      )

      assert Provision.ensure!(site).pages == Provision.page_paths()

      assert %{components: [], pages: [], snippets: [], renamed_pages: []} =
               Provision.ensure!(site)
    end

    # AND A RERUN IS NOT A SECOND RENAME. The page is at its own address now, so the PATH is what
    # holds it — a run reading only the name would write a third copy of the index at an address
    # that already answers.
    test "does not write it again under yet another name on the next run", %{site: site} do
      create_page!(
        site_id: site.id,
        name: "Documentation",
        path: "/handbook",
        template: ~S(<div>mine</div>)
      )

      Provision.ensure!(site)
      report = Provision.ensure!(site)

      assert report.pages == []
      assert report.renamed_pages == []
      assert Enum.map(report.skipped_pages, & &1.path) == Provision.page_paths()
      assert length(pages(site)) == length(Provision.page_paths()) + 1
    end
  end

  # REGISTERED HERE RATHER THAN RELIED ON FROM BOOT: `MishkaDocument.Application` starts its plugins
  # while this suite's Mnesia registry is not up yet — `test/test_helper.exs` starts that after the
  # applications — so nothing this extension ships is registered by the time a test runs. In
  # production the registry is up first and boot does this.
  # `register/0` IS THE PLUGIN'S OWN, and it is an upsert keyed on the plugin name — so this is safe
  # whether or not the extension's supervisor already registered it at boot. `Event.write/1` is not:
  # it would leave two rows answering to one key, which is exactly what `Extensions.install/3`
  # refuses to pretend is one install.
  defp listening! do
    {:ok, _registered} = Installer.register()
    :ok = EventHandler.do_compile(@event, :start, false)
    :ok
  end

  # A PLUGIN THE SUPERVISOR DOES NOT START NEVER REGISTERS, so the event it declares reaches it
  # nowhere and a created site is given nothing. Every case below registers it by hand, for the
  # reason `listening!/1` gives — which leaves this as the only assertion that the boot path names it
  # at all.
  describe "the plugin" do
    test "is one of the plugins this extension's supervisor starts" do
      assert Installer in MishkaDocument.Application.plugins()
    end
  end

  describe "installing on request" do
    setup do
      listening!()
      with_an_editor()
    end

    # THE EVENT IS THE ONLY DOOR. Core never names this module; it fires the event and whichever
    # plugin answers to the key does the work — which is what makes a second extension nothing more
    # than a second plugin.
    test "gives the site everything when the installer names this extension", %{site: site} do
      assert {:ok, report} = Extensions.install(site.id, "mishka_document")

      assert length(components(site)) == length(Provision.component_names())
      assert Enum.sort(Enum.map(pages(site), & &1.path)) == Enum.sort(Provision.page_paths())
      assert report.snippets == [Provision.snippet_name()]
      assert report.pages != []
    end

    # EVERY PLUGIN ON THE EVENT SEES EVERY CALL, so answering to somebody else's key would install
    # the documentation when the operator asked for the shop.
    test "does nothing at all when the installer names another extension", %{site: site} do
      assert {:error, :no_plugin_answered} = Extensions.install(site.id, "mishka_shop")

      assert components(site) == []
      assert pages(site) == []
      refute_received {:snippet_offered, _offered}
    end

    test "is offered by the installer's own registry, with the label it declared" do
      assert entry = Enum.find(Extensions.offered(), &(&1.key == "mishka_document"))

      assert entry.label == "Documentation"
      assert entry.app == :mishka_document
      assert entry.plugin == Installer
      assert entry.fields == []
    end

    # THE SCREEN GETS A FIXED MESSAGE, never the exception's own text; the log has the detail. An
    # admin of another site holds every name the install asks for, so the refusal is the
    # provision's own check of whose site it is, which raises after the plugin's permission gate.
    test "a failed install reports the fixed message and logs the exception", %{site: site} do
      elsewhere =
        create_site!(name: "elsewhere#{System.unique_integer([:positive])}", active: true)

      tenant = create_user_with_permissions!(["admin:dashboard:*"], site_id: elsewhere.id)

      log =
        capture_log(fn ->
          assert {:error, {:extension_failed, message}} =
                   Extensions.install(site.id, "mishka_document", %{}, tenant)

          assert message ==
                   "The install did not finish. Press Install again; details are in the server log."

          refute message =~ "admin:dashboard"
        end)

      assert log =~ "[MishkaDocument] install on #{site.id} failed:"
      assert log =~ "a site admin may only provision their own site"
      refute Extensions.installed?(site.id, :mishka_document)
      assert components(site) == []
    end

    # ONLY AN INSTALL IS ANSWERED. Core asks a site carrying no record of an install whether the
    # documentation is already there; the answer is no, and asking writes nothing.
    test "a site it was never installed on is not installed, and asking sets nothing up", %{
      site: site
    } do
      refute Extensions.installed?(site.id, :mishka_document)
      assert components(site) == []
      assert pages(site) == []
      assert Extensions.installed_version(site.id, :mishka_document) == nil
    end

    # A SITE IS NEVER SET UP BEHIND SOMEBODY'S BACK. Creating one used to queue this work; it does
    # not any more, and a site added to a running CMS waits to be asked.
    test "is not what creating a site does" do
      name = "untoucheddocs#{System.unique_integer([:positive])}"
      site = create_site!(name: name, host: "#{name}.test", active: true)

      assert components(site) == []
      assert pages(site) == []
      refute_received {:snippet_offered, _offered}
    end
  end

  # WHO MAY ASK. A request with nobody behind it is the install wizard's own run, made before there
  # is a user, and it is answered only until the CMS is installed. After that it is refused like an
  # actor holding nothing, and nothing is written.
  describe "who may ask for an install" do
    setup do
      :persistent_term.erase(:mishka_installed)
      on_exit(fn -> :persistent_term.erase(:mishka_installed) end)

      listening!()
      with_an_editor()
    end

    test "a request with nobody behind it installs while the CMS is not installed yet", %{
      site: site
    } do
      refute Install.installed?()

      assert {:ok, report} = Extensions.install(site.id, "mishka_document")

      assert report.pages != []
      assert length(components(site)) == length(Provision.component_names())
      assert Extensions.installed?(site.id, :mishka_document)
    end

    test "a request with nobody behind it is refused once the CMS is installed, and writes nothing",
         %{site: site} do
      Install.mark_installed!()
      names = Enum.map(Provision.manifest().permissions, &elem(&1, 0))

      assert {:error, {:extension_failed, message}} =
               Extensions.install(site.id, "mishka_document")

      for name <- ExtensionProvision.required(Provision.manifest()) do
        assert message =~ name
      end

      refute Extensions.installed?(site.id, :mishka_document)
      assert components(site) == []
      assert pages(site) == []
      refute_received {:snippet_offered, _offered}
      assert stored_permissions(names) == []
    end

    for {who, master?} <- [{"a master", true}, {"a site admin", false}] do
      @master? master?

      test "#{who} holding every name installs once the CMS is installed", %{site: site} do
        Install.mark_installed!()

        admin =
          create_user_with_permissions!(["*"], site_id: if(@master?, do: nil, else: site.id))

        assert {:ok, report} = Extensions.install(site.id, "mishka_document", %{}, admin)

        assert report.pages != []
        assert length(components(site)) == length(Provision.component_names())
        assert Extensions.installed?(site.id, :mishka_document)
      end
    end

    for installed? <- [false, true] do
      @installed? installed?

      test "an actor holding none of what it writes is refused and nothing is written, #{if installed?, do: "after", else: "before"} the CMS is installed",
           %{site: site} do
        if @installed?, do: Install.mark_installed!()
        weak = create_user_with_permissions!(["admin:dashboard:document"], site_id: site.id)

        assert {:error, {:extension_failed, message}} =
                 Extensions.install(site.id, "mishka_document", %{}, weak)

        assert message =~ "needs these permissions"
        assert message =~ "admin:dashboard:runtime:component"
        refute Extensions.installed?(site.id, :mishka_document)
        assert components(site) == []
        assert pages(site) == []
      end
    end

    test "the install wizard sets the documentation up with nobody behind the request, and the same request is refused after it",
         %{site: site} do
      assert {:ok, %{site: first}} =
               Bootstrap.run(%{
                 email: "owner-#{System.unique_integer([:positive])}@example.com",
                 password: "Password123!",
                 site_name: "Docs wizard",
                 host: "wizard-#{System.unique_integer([:positive])}.example.com",
                 extensions: ["mishka_document"]
               })

      # THE RUN COMPILES THE SITE ONTO DISK, as it does for a real one: its templates under
      # `priv/static/temp/runtime/<name>` and the media the starter content saves under
      # `uploads/<id>`. Neither goes away with the database's rollback, so each is removed here.
      on_exit(fn ->
        SiteState.delete(first.id)
        File.rm_rf(Helpers.static_temp_dir(["runtime", first.name]))
        File.rm_rf(Path.join([Media.static_dir(), "uploads", first.id]))
      end)

      assert Install.installed?()
      assert Extensions.installed?(first.id, :mishka_document)
      # The site's own header and footer are components too, written by the wizard beside them.
      assert Provision.component_names() -- Enum.map(components(first), & &1.name) == []
      assert Provision.page_paths() -- Enum.map(pages(first), & &1.path) == []

      assert {:error, {:extension_failed, _message}} =
               Extensions.install(site.id, "mishka_document")

      refute Extensions.installed?(site.id, :mishka_document)
      assert components(site) == []
    end
  end

  describe "the mark its pages carry" do
    test "says this extension gave the site the page, at the bundle's version", %{site: site} do
      MishkaDocument.Provision.ensure!(site.id)

      pages = provisioned_pages(site.id)

      assert pages != [], "the run wrote no pages to check"

      for page <- pages do
        assert MishkaCmsCore.Runtime.PageProvision.ours?(page, :mishka_document),
               "#{page.path} carries no mark saying who gave it to the site"

        assert MishkaCmsCore.Runtime.PageProvision.provisioned_version(page) ==
                 MishkaDocument.Provision.bundle_version()
      end
    end
  end

  defp provisioned_pages(site_id) do
    paths = MishkaDocument.Provision.page_paths()

    MishkaCmsCore.Runtime.Page
    |> Ash.Query.for_read(:read_any, %{}, authorize?: false)
    |> Ash.Query.filter(site_id == ^site_id)
    |> Ash.read!(authorize?: false, page: [limit: 100])
    |> Map.fetch!(:results)
    |> Enum.filter(&(&1.path in paths))
  end

  defp stored_permissions(names) do
    MishkaCmsCore.Accounts.Permission
    |> Ash.Query.filter(name in ^names)
    |> Ash.read!(authorize?: false, page: false)
    |> Enum.map(& &1.name)
  end
end
