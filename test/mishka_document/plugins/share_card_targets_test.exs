defmodule MishkaDocument.Plugins.ShareCardTargetsTest do
  @moduledoc """
  What the documentation answers on `runtime:share_card:targets`: every card of a site a visitor
  who is not signed in reaches, under `"mishka_document"` (`MishkaDocument.ShareCards.targets/1`),
  and what a forced look at one of them hands `document:page:seo`.

  Every status is pinned: the generators pick a document's and a version's at random and start
  every page in review.
  """
  use MishkaDocument.DataCase, async: false

  alias MishkaCmsCore.Runtime.{Seo, ShareCard}
  alias MishkaCmsCore.Runtime.States.{SettingsState, SiteState}
  alias MishkaCmsCore.Settings
  alias MishkaDocument.Plugins.{PageSeo, ShareCardTargets}
  alias MishkaDocument.{Provision, ShareCards}
  alias MishkaDocument.Test.Plugins.PageSeoAnswer
  alias MishkaInstaller.Event.{Event, EventHandler}

  @january ~U[2026-01-01 00:00:00Z]
  @march ~U[2026-03-01 00:00:00Z]

  # THE APPLICATION'S PLUGIN PROCESSES ARE NOT RUNNING IN THIS SUITE: each is written to the event's
  # chain by hand, and taken off when the test exits, since Mnesia is on disk.
  defp register(plugin, event) do
    {:ok, _} =
      Event.write(%{name: plugin, event: event, extension: :mishka_installer, status: :started})

    :ok = EventHandler.do_compile(event, :start, false)

    on_exit(fn ->
      Event.unregister(:name, plugin, false)
      EventHandler.do_compile(event, :start, false)
    end)
  end

  # A NAME AND A HOST OF ITS OWN: `SiteState` refuses a site whose name or host another one it holds
  # already has, and a card is drawn only for a site it holds.
  setup do
    unique = System.unique_integer([:positive])
    host = "docs-#{unique}.example.com"
    site = create_site!(active: true, name: "share-cards-#{unique}", host: host)

    :ok =
      SiteState.save(%{
        id: site.id,
        name: site.name,
        host: host,
        priority: site.priority,
        active: true,
        master: false
      })

    on_exit(fn ->
      SettingsState.delete(site.id, "site.languages")
      SiteState.delete(site.id)
    end)

    {:ok, _} = Settings.put("site.languages", ["en", "fa"], site_id: site.id)

    {:ok, site: site}
  end

  defp document!(site, attrs) do
    [site_id: site.id, skip_version: true, status: :active, language: "en", permissions: []]
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
      permissions: [],
      content_review_status: :approved,
      technical_review_status: :approved
    ]
    |> Keyword.merge(attrs)
    |> create_section!()
  end

  defp front(slug, language, query \\ %{}),
    do: {:record, "docs:document", Map.merge(%{"workspace" => slug, "lang" => language}, query)}

  defp at(slug, section, language, query \\ %{}),
    do:
      {:record, "docs:page",
       Map.merge(%{"workspace" => slug, "section" => section, "lang" => language}, query)}

  # A document with two published versions — 2.0, marked latest, and 1.0 — and a draft one; the
  # latest holds a front page, a group, a group with a page of its own, the pages under them, a
  # page still in review and a locked page.
  defp guide!(site) do
    guide = document!(site, slug: "guide", name: "Guide")
    latest = version!(site, guide, version_number: "2.0.0", is_latest_for_version: true)
    older = version!(site, guide, version_number: "1.0.0")
    _draft = version!(site, guide, version_number: "3.0.0", status: :draft, published_at: @march)

    page!(site, latest, "welcome", front_page: true)
    install = page!(site, latest, "install", title: "Install")
    page!(site, latest, "steps", parent_section_id: install.id)
    navigation = page!(site, latest, "navigation", group_heading: true)
    page!(site, latest, "breadcrumb", parent_section_id: navigation.id)
    layout = page!(site, latest, "layout", group_heading: true, group_page: true)
    page!(site, latest, "grid", parent_section_id: layout.id)
    page!(site, latest, "pending", content_review_status: :pending)
    page!(site, latest, "secret", permissions: ["docs:secret"])

    page!(site, older, "install")

    guide
  end

  describe "the event" do
    setup %{site: site} do
      register(ShareCardTargets, ShareCard.targets_event())
      guide!(site)
      :ok
    end

    test "is answered with its own targets for a site", %{site: site} do
      document!(site, slug: "drafted", status: :draft)
      document!(site, slug: "locked", permissions: ["docs:locked"])
      document!(site, slug: "german", language: "de")
      persian = document!(site, slug: "rahnama", language: "fa", name: "راهنما")
      page!(site, version!(site, persian, version_number: "1.0.0"), "nasb", language: "fa")
      document!(site, slug: "empty")

      assert {:ok, %{"mishka_document" => targets}} = ShareCard.targets(site.id)

      assert Enum.sort(targets) ==
               Enum.sort([
                 front("guide", "en"),
                 front("guide", "en", %{"v" => "1.0.0"}),
                 at("guide", "install", "en"),
                 at("guide", "install/steps", "en"),
                 at("guide", "breadcrumb", "en"),
                 at("guide", "layout", "en"),
                 at("guide", "grid", "en"),
                 at("guide", "install", "en", %{"v" => "1.0.0"}),
                 front("rahnama", "fa"),
                 at("rahnama", "nasb", "fa"),
                 front("empty", "en")
               ])
    end

    test "names its producer alone, reading nothing, for no site and for names only" do
      assert "mishka_document" in ShareCard.producers(nil)

      asked = %{site_id: nil, force: false, producer: nil, names_only: true, targets: %{}}

      assert {:reply, %{targets: %{"mishka_document" => []}}} = ShareCardTargets.call(asked)
      assert ShareCards.targets(nil) == []
    end

    test "answers only when it or every producer is asked", %{site: site} do
      assert {:ok, targets} = ShareCard.targets(site.id, producer: "mishka_blog")
      refute Map.has_key?(targets, "mishka_document")

      assert {:ok, %{"mishka_document" => [_ | _]}} =
               ShareCard.targets(site.id, producer: "mishka_document")

      assert {:ok, %{"mishka_document" => [_ | _]}} = ShareCard.targets(site.id)
    end

    test "names its targets by ids and captures alone", %{site: site} do
      assert {:ok, %{"mishka_document" => [_ | _] = targets}} = ShareCard.targets(site.id)

      for target <- targets do
        assert {:record, kind, captures} = target
        assert kind in ["docs:document", "docs:page"]
        assert is_map(captures) and not is_struct(captures)
        assert Enum.all?(captures, fn {key, value} -> is_binary(key) and is_binary(value) end)
        assert ShareCard.decode(ShareCard.encode(target)) == target
      end
    end
  end

  describe "target/1 of a page" do
    test "names its version when it is not the one shown with none, and none unpublished", %{
      site: site
    } do
      guide = document!(site, slug: "manual")
      latest = version!(site, guide, version_number: "2.0.0", is_latest_for_version: true)
      older = version!(site, guide, version_number: "1.0.0")
      draft = version!(site, guide, version_number: "3.0.0", status: :draft)

      assert ShareCards.target(page!(site, latest, "start")) == at("manual", "start", "en")

      assert ShareCards.target(page!(site, older, "start")) ==
               at("manual", "start", "en", %{"v" => "1.0.0"})

      assert ShareCards.target(page!(site, draft, "start")) == nil
    end
  end

  # A FORCED LOOK (`ShareCard.refresh(site_id, target, force: true)`) reads every page of the
  # target's kind with `redraw: true`; the documentation's answer hands it on to `document:page:seo`,
  # where a site's plugin that draws its own card reads it.
  describe "a forced look at a document's card" do
    setup %{site: site} do
      Process.register(self(), :__page_seo_probe__)
      register(PageSeo, Seo.event())
      register(PageSeoAnswer, PageSeo.event())
      on_exit(&PageSeoAnswer.forget!/0)

      for {path, record} <- [
            {Provision.item_paths().workspace, "docs:document"},
            {Provision.item_paths().section, "docs:page"}
          ] do
        create_page!(
          site_id: site.id,
          path: path,
          title: "Document page",
          language: "en",
          active: true,
          permissions: [],
          extra: %{"record" => record, "serves_all_languages" => true}
        )
      end

      guide!(site)
      :ok
    end

    test "hands `redraw` to document:page:seo, and draws the document's card", %{site: site} do
      assert [%{title: "Guide"}] = ShareCard.specs(site.id, front("guide", "en"), redraw: true)
      assert_received {:page_seo_asked, %{redraw: true}, %{document: %{slug: "guide"}}}

      assert [%{title: "Install"}] =
               ShareCard.specs(site.id, at("guide", "install", "en"), redraw: false)

      assert_received {:page_seo_asked, %{redraw: false}, %{page: %{slug: "install"}}}
    end

    test "of a version reached by its `v`, shows that version", %{site: site} do
      assert [%{meta: ["Version 1.0.0"]}] =
               ShareCard.specs(site.id, front("guide", "en", %{"v" => "1.0.0"}))
    end

    test "draws nothing on a page of its kind where it names nothing", %{site: site} do
      assert ShareCard.specs(site.id, front("missing", "en"), redraw: true) == []
      assert ShareCard.specs(site.id, at("guide", "nowhere", "en")) == []
    end
  end

  test "is one of the plugins this extension's supervisor starts" do
    assert ShareCardTargets in MishkaDocument.Application.plugins()
  end
end
