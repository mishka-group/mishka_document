# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_document/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaDocument.PageSourceTest do
  @moduledoc """
  `MishkaDocument.PageSource`: the rows a document's front page and each of its pages show, read once
  as the visitor for the head, the frame and the blocks, and what of them each visitor is handed.

  Each test hands `read/1` the map core hands the `runtime:page:source` plugins
  (`MishkaCmsCore.Runtime.PageSource.given/2`) for a guest and for a reader holding the lock, and
  reads what the source holds. What a page then asks the database for, request by request, is the
  host's `PageQueriesTest`; that the blocks draw from it, the render tests'.
  """
  use MishkaDocument.DataCase, async: false

  alias MishkaCmsCore.Runtime.PageSource, as: CorePageSource
  alias MishkaCmsCore.Runtime.States.SettingsState
  alias MishkaCmsCore.Settings
  alias MishkaDocument.{PageSource, Provision}
  alias MishkaDocument.Plugins.PageSource, as: Plugin

  @locked ["docs:editors"]

  setup do
    site = create_site!(active: true)
    on_exit(fn -> SettingsState.delete(site.id, "site.languages") end)
    {:ok, _} = Settings.put("site.languages", ["en", "fa"], site_id: site.id)

    %{site: site, editor: create_user_with_permissions!(@locked, site_id: site.id)}
  end

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
      published_at: ~U[2026-01-01 00:00:00Z]
    ]
    |> Keyword.merge(attrs)
    |> create_workspace_version!()
  end

  defp page!(site, version, slug, attrs \\ []) do
    [
      site_id: site.id,
      workspace_version_id: version.id,
      slug: slug,
      title: String.capitalize(slug),
      language: "en",
      content: "<h2>#{slug}</h2><p>Text.</p>",
      content_review_status: :approved,
      technical_review_status: :approved
    ]
    |> Keyword.merge(attrs)
    |> create_section!()
  end

  defp note!(site, page, title) do
    Ash.Seed.seed!(MishkaDocument.Note, %{
      site_id: site.id,
      section_id: page.id,
      title: title,
      content: "<p>#{title}.</p>",
      order_position: 0,
      content_review_status: :approved,
      technical_review_status: :approved
    })
  end

  # THE GUIDE IN TWO LANGUAGES, one page of it locked and a note on the open one.
  defp guide!(site, english \\ [], persian \\ []) do
    guide = document!(site, Keyword.merge([name: "Guide", slug: "guide"], english))
    version = version!(site, guide)
    install = page!(site, version, "install")
    page!(site, version, "salaries", permissions: @locked)
    note!(site, install, "Before you start")

    rahnama =
      document!(
        site,
        Keyword.merge(
          [
            name: "Rahnama",
            slug: "rahnama",
            language: "fa",
            language_group_id: guide.language_group_id
          ],
          persian
        )
      )

    version!(site, rahnama)

    %{guide: guide, version: version, install: install, rahnama: rahnama}
  end

  # The map core hands the plugins for the page of `section` (or the front page, for `nil`) of the
  # document at `slug`, for `visitor`.
  defp request(site, slug, section, visitor \\ nil, extra \\ %{}) do
    {path, record, params} =
      case section do
        nil -> {Provision.item_paths().workspace, "docs:document", %{}}
        wanted -> {Provision.item_paths().section, "docs:page", %{"section" => wanted}}
      end

    CorePageSource.given(
      %{title: "Document", path: path, language: "en", section: "document"},
      site_id: site.id,
      current_user: visitor,
      extra: %{"record" => record},
      params: Map.merge(%{"workspace" => slug, "lang" => "en"}, Map.merge(params, extra))
    )
  end

  describe "a page of an open document" do
    test "holds the document, its versions, the version's pages, the page, its text and notes", %{
      site: site
    } do
      %{guide: guide, version: version, install: install} = guide!(site)

      source = PageSource.read(request(site, "guide", "install"))

      assert %PageSource{rows_of: "mishka_document", visitor: nil, language: "en"} = source
      assert source.workspace.id == guide.id
      assert source.open?
      assert source.found_by == {:slug, "guide"}
      assert Enum.map(source.versions, & &1.id) == [version.id]
      assert source.version.id == version.id
      assert source.page.id == install.id
      assert source.body.id == install.id
      assert source.body.rendered_content =~ "install"
      assert Enum.map(source.notes, & &1.title) == ["Before you start"]
      assert source.lock == []
    end

    # EACH ROW AS THE VISITOR READS IT: a page locked to a permission is not among a guest's pages,
    # and asked for by its address it is no page at all.
    test "leaves out a page locked to a permission the visitor does not hold", %{
      site: site,
      editor: editor
    } do
      guide!(site)

      guest = PageSource.read(request(site, "guide", "salaries"))
      holder = PageSource.read(request(site, "guide", "salaries", editor))

      assert Enum.map(guest.pages, & &1.slug) == ["install"]
      assert guest.page == nil and guest.body == nil

      assert Enum.sort(Enum.map(holder.pages, & &1.slug)) == ["install", "salaries"]
      assert holder.body.slug == "salaries"
      assert holder.lock == @locked
      assert holder.visitor == editor.id
    end

    test "brings the other editions with the document, as the visitor may open them", %{
      site: site,
      editor: editor
    } do
      %{rahnama: rahnama} = guide!(site, [], permissions: @locked)

      assert PageSource.read(request(site, "guide", "install")).editions == []

      assert [%{id: id, slug: "rahnama", language: "fa", versions: [_one]}] =
               PageSource.read(request(site, "guide", "install", editor)).editions

      assert id == rahnama.id
    end

    test "never names a draft version, or a page nobody approved", %{site: site} do
      %{guide: guide, version: version} = guide!(site)

      draft =
        version!(site, guide,
          version_number: "2.0.0",
          status: :draft,
          is_latest_for_version: false
        )

      page!(site, draft, "next")
      page!(site, version, "pending", content_review_status: :pending)

      source = PageSource.read(request(site, "guide", "install", nil, %{"v" => "2.0.0"}))

      assert Enum.map(source.versions, & &1.version_number) == ["1.0.0"]
      assert source.version.id == version.id
      refute Enum.any?(source.pages, &(&1.slug in ["next", "pending"]))
      assert PageSource.read(request(site, "guide", "pending")).page == nil
    end
  end

  describe "a document locked to a permission" do
    # READ AS THE SYSTEM ONLY FOR WHAT THE VISITOR'S READ LEFT OUT: the document, for the lock the
    # page refuses them with — its pages are still read as the visitor, so a guest is handed none.
    test "is no open document to a guest, and its pages are none of theirs", %{site: site} do
      guide!(site, permissions: @locked)

      source = PageSource.read(request(site, "guide", nil))

      refute source.open?
      assert source.workspace.permissions == @locked
      assert source.pages == []
      assert source.page == nil and source.body == nil

      # ITS OTHER EDITIONS ARE READ AS THE GUEST: the Persian one, which no lock names, is theirs.
      assert Enum.map(source.editions, & &1.slug) == ["rahnama"]
    end

    test "is open to a reader holding the lock", %{site: site, editor: editor} do
      guide!(site, permissions: @locked)

      source = PageSource.read(request(site, "guide", "install", editor))

      assert source.open?
      assert source.body.slug == "install"
      assert source.lock == @locked
    end

    # A PAGE WHOSE OWN LOCK OPENS FOR THE READER INSIDE A DOCUMENT WHOSE LOCK DOES NOT is drawn in its
    # document, as the blocks draw it; the document's other pages stay out of reach.
    test "still holds a page whose own lock opens for the reader", %{site: site} do
      guide = document!(site, name: "Guide", slug: "guide", permissions: ["docs:board"])
      version = version!(site, guide)
      page!(site, version, "install")
      page!(site, version, "salaries", permissions: @locked)
      reader = create_user_with_permissions!(@locked, site_id: site.id)

      source = PageSource.read(request(site, "guide", "salaries", reader))

      refute source.open?
      assert Enum.map(source.pages, & &1.slug) == ["salaries"]
      assert source.body.slug == "salaries"
      assert source.lock == @locked
    end
  end

  describe "an address that names nothing" do
    test "is a source with no document, which every reader answers as its own read would", %{
      site: site
    } do
      guide!(site)

      assert %PageSource{workspace: nil, found_by: nil, tried: [{:slug, "missing"}]} =
               PageSource.read(request(site, "missing", nil))
    end

    test "is no source where the page names no document", %{site: site} do
      assert PageSource.read(%{request(site, "guide", nil) | params: %{}}) == nil
    end
  end

  # A LIVE PATCH TO ANOTHER PAGE OF THE SAME DOCUMENT reads the page, its text and its notes, and takes
  # the document, its versions and the version's pages from what the address before read.
  describe "another page of the document held" do
    test "is read without reading the document again", %{site: site} do
      %{version: version} = guide!(site)
      page!(site, version, "usage")

      held = PageSource.read(request(site, "guide", "install"))

      {source, statements} =
        with_queries(fn ->
          PageSource.read(%{request(site, "guide", "usage") | held: held})
        end)

      assert source.body.slug == "usage"
      assert source.workspace == held.workspace
      refute Enum.any?(statements, &(&1 =~ ~s(FROM "mishka_document_workspaces")))
      refute Enum.any?(statements, &(&1 =~ ~s(FROM "mishka_document_workspace_versions")))
    end

    test "is read again for another visitor", %{site: site, editor: editor} do
      guide!(site)
      held = PageSource.read(request(site, "guide", "install"))

      source = PageSource.read(%{request(site, "guide", "salaries", editor) | held: held})

      assert source.body.slug == "salaries"
      assert source.visitor == editor.id
    end
  end

  describe "the plugin" do
    test "answers a document's pages with their rows, and hands every other page back", %{
      site: site
    } do
      guide!(site)
      given = request(site, "guide", "install")

      assert {:reply, :halt, %{source: %PageSource{body: %{slug: "install"}}}} =
               Plugin.call(given)

      library = %{given | record: nil, extra: %{}}
      assert {:reply, ^library} = Plugin.call(library)
    end
  end
end
