defmodule MishkaDocument.Plugins.AddressRedirectTest do
  @moduledoc """
  A document's old address under `/docs`, asked for once it has an address of its own, answers with
  a permanent redirect to that address — its pages to theirs under it, the query string with them —
  and every other request passes untouched (`MishkaDocument.Plugins.AddressRedirect`).

  The plugin is called directly with the conn `MishkaCmsCore.Runtime.Plugs.SiteLookupPlug` hands
  it: the request's site assigned as `:current_site`.
  """
  use MishkaDocument.DataCase, async: false

  import Plug.Test, only: [conn: 2]

  alias MishkaCmsCore.Runtime.States.SettingsState
  alias MishkaCmsCore.Settings
  alias MishkaDocument.Plugins.AddressRedirect

  setup do
    site = create_site!(active: true)

    on_exit(fn ->
      SettingsState.delete(site.id, "site.languages")
      SettingsState.delete(site.id, "site.language_urls")
    end)

    {:ok, _} = Settings.put("site.languages", ["en", "fa"], site_id: site.id)

    product =
      create_workspace!(
        site_id: site.id,
        slug: "product",
        status: :active,
        language: "en",
        path: "/product/docs"
      )

    create_workspace!(
      site_id: site.id,
      slug: "product-fa",
      status: :active,
      language: "fa",
      language_group_id: product.language_group_id,
      path: "/:lang/handbook"
    )

    create_workspace!(site_id: site.id, slug: "guide", status: :active, language: "en")

    {:ok, site: site}
  end

  defp asked(site, method \\ :get, path) do
    conn = method |> conn(path) |> Plug.Conn.assign(:current_site, site)
    {:reply, answered} = AddressRedirect.call(conn, %{host: "docs.test"})
    answered
  end

  defp moved_to(conn) do
    assert {conn.status, conn.halted} == {301, true}
    conn |> Plug.Conn.get_resp_header("location") |> List.first()
  end

  test "sends a document's old address to its own, and each page of it to its own under it",
       %{site: site} do
    assert moved_to(asked(site, "/docs/product")) == "/product/docs"

    assert moved_to(asked(site, "/docs/product/install/steps?v=1.0.0")) ==
             "/product/docs/install/steps?v=1.0.0"
  end

  test "fills the language into an address that holds it", %{site: site} do
    assert moved_to(asked(site, "/fa/docs/product-fa/install")) == "/fa/handbook/install"
  end

  test "reads the language prefix every address carries in prefix_all", %{site: site} do
    {:ok, _} = Settings.put("site.language_urls", "prefix_all", site_id: site.id)

    assert moved_to(asked(site, "/en/docs/product/install")) == "/product/docs/install"
  end

  test "leaves alone a document read under /docs, a write, and every other address",
       %{site: site} do
    for {method, path} <- [
          {:get, "/docs/guide/install"},
          {:get, "/docs"},
          {:get, "/docs/no-such-document"},
          {:get, "/product/docs"},
          {:get, "/blog/product"},
          {:post, "/docs/product"}
        ] do
      answered = asked(site, method, path)
      refute answered.halted, "#{method} #{path} was answered"
      assert answered.status == nil
    end
  end

  test "leaves alone a document in a language the address does not name", %{site: site} do
    refute asked(site, "/docs/product-fa").halted
  end
end
