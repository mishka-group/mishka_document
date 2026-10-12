defmodule MishkaDocument.DocumentAddressTest do
  @moduledoc """
  A document's own address (`MishkaDocument.Address`): how it is stored, what it may be, how a
  page's address under it is read, and the two pages it is read at, written when it is set
  (`MishkaDocument.Resources.Changes.EnsureAddressPages`).
  """
  use MishkaDocument.DataCase, async: false

  import MishkaDocument.Test.Factory

  require Ash.Query

  alias MishkaCmsCore.Runtime.Page
  alias MishkaDocument.{Address, Workspace}

  @workspace_admin "admin:dashboard:document:workspace"

  setup do
    {:ok, site: create_site!()}
  end

  defp create(site, attrs, opts \\ []) do
    Workspace
    |> Ash.Changeset.for_create(
      :create,
      Map.merge(%{name: "Product", status: :active, language: "en"}, attrs),
      Keyword.merge([tenant: site.id, authorize?: false], opts)
    )
    |> Ash.create()
  end

  defp write(workspace, attrs, opts) do
    workspace
    |> Ash.Changeset.for_update(:update, attrs, Keyword.merge([tenant: workspace.site_id], opts))
    |> Ash.update()
  end

  defp pages_at(site, paths) do
    Page
    |> Ash.Query.for_read(:master_read, %{}, authorize?: false)
    |> Ash.Query.filter(site_id == ^site.id and path in ^paths)
    |> Ash.read!(authorize?: false, page: [limit: 10])
    |> Map.fetch!(:results)
    |> Enum.sort_by(& &1.path)
  end

  defp message(%{errors: errors}),
    do: Enum.map_join(errors, " ", &Exception.message/1)

  describe "the address rules" do
    test "store an address one way, and refuse what the site could not answer" do
      assert Address.normalize(" /Product/Docs/ ") == "/product/docs"
      assert Address.normalize("") == nil
      assert Address.normalize(nil) == nil

      assert Address.check("/product/docs") == :ok
      assert Address.check("/:lang/product/docs") == :ok
      assert Address.check("/:lang/product/:lang") == {:error, :not_a_path}
      assert Address.check(Address.normalize("/product docs")) == {:error, :not_a_path}
      assert Address.check(Address.normalize("https://example.com/docs")) == {:error, :not_a_path}
      assert Address.check(Address.normalize("/")) == {:error, :not_a_path}
      assert Address.check("/docs") == {:error, :in_docs_base}
      assert Address.check("/docs/product") == {:error, :in_docs_base}
      assert Address.check("/:lang/docs/product") == {:error, :in_docs_base}
    end

    test "say when two addresses would answer each other's pages" do
      assert Address.overlap?("/product/docs", "/product/docs")
      assert Address.overlap?("/product/docs", "/product/docs/extra")
      assert Address.overlap?("/product", "/product/docs")
      refute Address.overlap?("/product/docs", "/product/docsx")
      refute Address.overlap?("/product/docs", "/other/docs")
    end

    test "read the address a page serves off its path" do
      assert Address.of_page("/product/docs/*section") == "/product/docs"
      assert Address.of_page("/product/docs") == "/product/docs"
      assert Address.of_page("/:lang/product/docs/*section") == "/:lang/product/docs"
      assert Address.of_page("/:lang/docs/:workspace/*section") == nil
      assert Address.of_page(nil) == nil
    end

    test "place a page under the pages it is drawn under, and at the top when its parent is not shown" do
      pages = [
        %{id: 1, slug: "headless", parent_section_id: nil},
        %{id: 2, slug: "switch", parent_section_id: 1},
        %{id: 3, slug: "orphan", parent_section_id: 99},
        %{id: 4, slug: "loop-a", parent_section_id: 5},
        %{id: 5, slug: "loop-b", parent_section_id: 4}
      ]

      assert Address.paths(pages) == %{
               1 => ["headless"],
               2 => ["headless", "switch"],
               3 => ["orphan"],
               4 => ["loop-a"],
               5 => ["loop-b"]
             }

      assert Address.page_at(pages, "headless/switch").id == 2
      assert Address.page_at(pages, ["orphan"]).id == 3
      assert Address.page_at(pages, "switch") == nil
      assert Address.page_at(pages, "") == nil
    end

    test "draw a front page at the document's own address, and the pages under it directly under that" do
      pages = [
        %{id: 1, slug: "get-started", parent_section_id: nil, front_page: true},
        %{id: 2, slug: "install", parent_section_id: 1, front_page: false},
        %{id: 3, slug: "headless", parent_section_id: nil, front_page: false},
        %{id: 4, slug: "switch", parent_section_id: 3, front_page: false}
      ]

      assert Address.paths(pages) == %{
               1 => [],
               2 => ["install"],
               3 => ["headless"],
               4 => ["headless", "switch"]
             }

      assert Address.page_at(pages, []).id == 1
      assert Address.page_at(pages, "").id == 1
      assert Address.page_at(pages, "install").id == 2
      assert Address.page_at(pages, "get-started") == nil
      assert Address.page_at(pages, "get-started/install") == nil

      by_id = Map.new(pages, &{&1.id, &1})
      parent_of = &Map.get(by_id, &1.parent_section_id)

      assert Address.section_path(by_id[1], parent_of) == []
      assert Address.section_path(by_id[2], parent_of) == ["install"]
      assert Address.front_page?(by_id[1])
      refute Address.front_page?(%{slug: "x"})
    end

    test "address the pages under a group as if it were not there, and the group nowhere" do
      pages = [
        %{id: 1, slug: "navigation", parent_section_id: nil, group_heading: true},
        %{id: 2, slug: "breadcrumb", parent_section_id: 1},
        %{id: 3, slug: "menus", parent_section_id: 1, group_heading: true},
        %{id: 4, slug: "dropdown", parent_section_id: 3},
        %{id: 5, slug: "headless", parent_section_id: nil},
        %{id: 6, slug: "tabs", parent_section_id: 5}
      ]

      assert Address.paths(pages) == %{
               2 => ["breadcrumb"],
               4 => ["dropdown"],
               5 => ["headless"],
               6 => ["headless", "tabs"]
             }

      assert Address.page_at(pages, "breadcrumb").id == 2
      assert Address.page_at(pages, "dropdown").id == 4
      assert Address.page_at(pages, "navigation") == nil
      assert Address.page_at(pages, "navigation/breadcrumb") == nil
      assert Address.page_at(pages, "") == nil
      assert Address.group?(Enum.at(pages, 0))
      refute Address.group?(Enum.at(pages, 1))
    end
  end

  describe "a document given an address" do
    test "stores it one way, and is given the two pages it is read at", %{site: site} do
      {:ok, workspace} = create(site, %{slug: "product", path: " /Product/Docs/ "})

      assert workspace.path == "/product/docs"

      assert [front, page] = pages_at(site, ["/product/docs", "/product/docs/*section"])
      assert {front.path, front.extra["record"]} == {"/product/docs", "docs:document"}
      assert {page.path, page.extra["record"]} == {"/product/docs/*section", "docs:page"}

      for written <- [front, page] do
        assert written.template =~ ~s(path="/product/docs" lang_param="")
      end
    end

    test "keeps a page the site already has at the address, its own design", %{site: site} do
      own = create_page!(site_id: site.id, name: "Own design", path: "/product/docs")

      {:ok, _workspace} = create(site, %{slug: "product", path: "/product/docs"})

      assert [front, page] = pages_at(site, ["/product/docs", "/product/docs/*section"])
      assert {front.id, front.name} == {own.id, own.name}
      assert page.extra["record"] == "docs:page"
    end

    test "refuses an address under the documentation's base", %{site: site} do
      {:error, error} = create(site, %{slug: "product", path: "/docs/product"})
      assert message(error) =~ "/docs"
    end

    test "refuses an address another document is read at, above it or under it", %{site: site} do
      {:ok, _first} = create(site, %{slug: "product", path: "/product/docs"})

      for taken <- ["/product/docs", "/product/docs/extra", "/product"] do
        {:error, error} =
          create(site, %{slug: "other-#{System.unique_integer([:positive])}", path: taken})

        assert message(error) =~ "/product/docs", "#{taken} was let through"
      end

      assert {:ok, _beside} = create(site, %{slug: "manual", path: "/product/manual"})
    end

    test "lets a translation share an address that holds the language", %{site: site} do
      {:ok, english} = create(site, %{slug: "product", path: "/:lang/product/docs"})

      assert {:ok, persian} =
               create(site, %{
                 slug: "product-fa",
                 language: "fa",
                 language_group_id: english.language_group_id,
                 path: "/:lang/product/docs"
               })

      assert persian.path == english.path

      {:error, error} =
        create(site, %{slug: "stranger", language: "ar", path: "/:lang/product/docs"})

      assert message(error) =~ "/:lang/product/docs"
    end

    test "refuses a writer who may not write its pages, and says what they lack", %{site: site} do
      {:ok, workspace} = create(site, %{slug: "product"})
      writer = create_user_with_permissions!([@workspace_admin], site_id: site.id)

      {:error, error} = write(workspace, %{path: "/product/docs"}, actor: writer)

      assert message(error) =~ "admin:dashboard:runtime:page"
      assert pages_at(site, ["/product/docs", "/product/docs/*section"]) == []
    end

    test "lets that writer set it once the site has both pages", %{site: site} do
      {:ok, workspace} = create(site, %{slug: "product"})
      writer = create_user_with_permissions!([@workspace_admin], site_id: site.id)

      for path <- ["/product/docs", "/product/docs/*section"],
          do: create_page!(site_id: site.id, path: path)

      assert {:ok, %{path: "/product/docs"}} =
               write(workspace, %{path: "/product/docs"}, actor: writer)
    end

    test "emptied, is read under /docs again and leaves its pages", %{site: site} do
      {:ok, workspace} = create(site, %{slug: "product", path: "/product/docs"})

      assert {:ok, %{path: nil}} = write(workspace, %{path: ""}, authorize?: false)
      assert length(pages_at(site, ["/product/docs", "/product/docs/*section"])) == 2
    end
  end
end
