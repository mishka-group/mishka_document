# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_document/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaDocumentWeb.Test.ExamplePreviewTest do
  @moduledoc """
  `/_preview/doc-example/:kind/:id/:index` (`MishkaDocumentWeb.ExamplePreviewController`,
  `MishkaDocumentWeb.Live.ExamplePreview`): one example of a page's text drawn alone and live, as
  the visitor may read the page, never indexed, under a policy of its own.

  `async: false` — the kit's compiled components and `SiteState` are the node's.
  """
  use MishkaDocument.ConnCase, async: false

  @moduletag :capture_log

  import Phoenix.LiveViewTest
  import MishkaDocument.Test.Factory

  alias MishkaCmsCore.ErrorsExceptions.NotFoundError
  alias MishkaCmsCore.Runtime.States.SiteState
  alias MishkaDocumentWeb.Live.ExamplePreview

  @components ~w(doc-example doc-callout doc-section)

  setup %{conn: conn} do
    SiteState.clear()
    name = "exampleville#{System.unique_integer([:positive])}"
    site = create_site!(name: name, host: "#{name}.test", active: true)

    SiteState.save(%{
      id: site.id,
      name: site.name,
      host: site.host,
      priority: site.priority,
      active: site.active,
      master: site.master
    })

    {:ok, _installed} = MishkaDocument.Kit.install!(site.id)

    for component <- @components, do: :ok = SiteState.put_component(site.id, component)

    on_exit(fn -> SiteState.clear() end)

    conn =
      conn
      |> Map.put(:host, site.host)
      |> Map.update!(:req_headers, &[{"host", site.host} | List.keydelete(&1, "host", 0)])

    {:ok, conn: conn, site: site}
  end

  defp version!(site, opts \\ []) do
    document =
      create_workspace!(
        Keyword.merge(
          [site_id: site.id, status: :active, language: "en", skip_version: true, slug: "guide"],
          opts
        )
      )

    create_workspace_version!(
      site_id: site.id,
      workspace_id: document.id,
      status: Keyword.get(opts, :version_status, :stable),
      is_latest_for_version: true,
      version_number: "1.0.0",
      published_at: ~U[2026-01-01 00:00:00Z]
    )
  end

  defp page!(site, version, content, opts \\ []) do
    create_section!(
      Keyword.merge(
        [
          site_id: site.id,
          workspace_version_id: version.id,
          content_review_status: :approved,
          technical_review_status: :approved,
          language: "en",
          title: "Examples",
          slug: "examples",
          content: content
        ],
        opts
      )
    )
  end

  defp example(text, attrs \\ ""),
    do:
      "[[component doc-example#{attrs}]][[component doc-callout tone=\"tip\"]]#{text}" <>
        "[[/component]][[/component]]"

  @content "<p>Before.</p>" <>
             ~s(<pre><code>[[component doc-example]]Code[[/component]]</code></pre>) <>
             "[[component doc-example title=\"First\"]][[component doc-callout tone=\"tip\"]]One" <>
             "[[/component]][[/component]]" <>
             "<p>Between.</p>" <>
             "[[component doc-example title=\"Second\"]][[component doc-callout tone=\"info\"]]Two" <>
             "[[/component]][[/component]]"

  defp drawn(html, selector),
    do: html |> LazyHTML.from_document() |> LazyHTML.query(selector)

  defp texts(html, selector),
    do: html |> drawn(selector) |> Enum.map(&(&1 |> LazyHTML.text() |> String.trim()))

  defp log_in(conn, user) do
    conn
    |> Plug.Test.init_test_session(%{})
    |> Plug.Conn.put_session(:master_mode, false)
    |> AshAuthentication.Plug.Helpers.store_in_session(user)
  end

  describe "an example of a page" do
    test "is drawn alone, the one its place names, and nothing else of the page", %{
      conn: conn,
      site: site
    } do
      page = page!(site, version!(site), @content)

      html = conn |> get("/_preview/doc-example/section/#{page.id}/1") |> html_response(200)

      assert [_live] =
               Enum.to_list(drawn(html, ~s(#doc-example-live[data-role="doc-example-live"])))

      assert texts(html, ~s([data-role="doc-example-live"] [data-role="doc-callout"])) == ["Two"]

      assert html |> drawn(~s([data-role="doc-callout"][data-tone="info"])) |> Enum.count() == 1
      assert html |> drawn(~s([data-role="doc-example"])) |> Enum.count() == 0
      refute html =~ "Before."
      refute html =~ "Between."
      refute html =~ ">One<"

      first = conn |> get("/_preview/doc-example/section/#{page.id}/0") |> html_response(200)
      assert texts(first, ~s([data-role="doc-example-live"] [data-role="doc-callout"])) == ["One"]
    end

    test "is live: it connects, and an event nothing answers leaves it drawn", %{
      conn: conn,
      site: site
    } do
      page = page!(site, version!(site), @content)

      {:ok, view, _html} = live(conn, "/_preview/doc-example/section/#{page.id}/0")

      assert has_element?(view, ~s(#doc-example-live [data-role="doc-callout"][data-tone="tip"]))
      assert render_hook(view, "nobody-answers", %{}) =~ "doc-example-live"
      assert has_element?(view, "#doc-example-live")
    end

    test "is never indexed, and is served a strict policy of its own", %{conn: conn, site: site} do
      page = page!(site, version!(site), @content)

      conn = get(conn, "/_preview/doc-example/section/#{page.id}/0")
      assert conn.status == 200

      assert get_resp_header(conn, "x-robots-tag") == ["noindex, nofollow"]
      assert get_resp_header(conn, "x-frame-options") == ["SAMEORIGIN"]
      assert get_resp_header(conn, "content-security-policy-report-only") == []

      assert [policy] = get_resp_header(conn, "content-security-policy")
      nonce = conn.assigns.csp_nonce
      assert is_binary(nonce)

      directives =
        policy
        |> String.split(";")
        |> Map.new(fn directive ->
          [name, value] = directive |> String.trim() |> String.split(" ", parts: 2)
          {name, value}
        end)

      assert directives["default-src"] == "'self'"
      assert directives["base-uri"] == "'none'"
      assert directives["object-src"] == "'none'"
      assert directives["frame-ancestors"] == "'self'"
      assert directives["form-action"] == "'self'"
      assert directives["script-src"] == "'self' 'nonce-#{nonce}'"

      assert directives["connect-src"] ==
               "'self' ws://#{site.host} wss://#{site.host}"

      assert directives["style-src-elem"] =~ "'nonce-#{nonce}'"
      refute policy =~ "unsafe-eval"
      refute directives["script-src"] =~ "unsafe-inline"
      refute directives["script-src"] =~ "http"
    end

    test "names the socket of the host and port the browser asked, and of nothing else", %{
      conn: conn,
      site: site
    } do
      page = page!(site, version!(site), @content)
      path = "/_preview/doc-example/section/#{page.id}/0"
      host = site.host

      connect_src = fn header ->
        conn =
          Map.update!(conn, :req_headers, &[{"host", header} | List.keydelete(&1, "host", 0)])

        assert [policy] = conn |> get(path) |> get_resp_header("content-security-policy")

        policy |> String.split("; ") |> Enum.find(&String.starts_with?(&1, "connect-src"))
      end

      assert connect_src.(host) == "connect-src 'self' ws://#{host} wss://#{host}"

      assert connect_src.("#{host}:4000") ==
               "connect-src 'self' ws://#{host}:4000 wss://#{host}:4000"

      # WHAT FOLLOWS THE PORT IS NEVER WRITTEN OUT: the sources are built from the host and the port
      # the header parses to, not copied from it.
      for trailing <- [" script-src *", ";x", ",https://other.example", "/path"] do
        assert connect_src.("#{host}:4000#{trailing}") ==
                 "connect-src 'self' ws://#{host}:4000 wss://#{host}:4000"
      end

      for port <- ["0", "99999", "65536"] do
        assert connect_src.("#{host}:#{port}") == "connect-src 'self'"
      end
    end

    test "is a missing page for an address that names no example", %{conn: conn, site: site} do
      page = page!(site, version!(site), @content)

      for path <- [
            "/_preview/doc-example/section/#{page.id}/2",
            "/_preview/doc-example/section/#{page.id}/-1",
            "/_preview/doc-example/section/#{page.id}/x",
            "/_preview/doc-example/post/#{page.id}/0",
            "/_preview/doc-example/section/not-an-id/0",
            "/_preview/doc-example/section/#{Ecto.UUID.generate()}/0",
            "/_preview/doc-example/note/#{page.id}/0"
          ] do
        assert_raise NotFoundError, fn -> get(conn, path) end
      end
    end
  end

  describe "a page the visitor may not read" do
    test "keeps its examples: locked to a permission the visitor does not hold", %{
      conn: conn,
      site: site
    } do
      page = page!(site, version!(site), @content, permissions: ["members:read"])
      path = "/_preview/doc-example/section/#{page.id}/0"

      assert_raise NotFoundError, fn -> get(conn, path) end

      outsider = create_user_with_permissions!(["others:read"], site_id: site.id)
      assert_raise NotFoundError, fn -> conn |> log_in(outsider) |> get(path) end

      member = create_user_with_permissions!(["members:read"], site_id: site.id)
      html = conn |> log_in(member) |> get(path) |> html_response(200)
      assert texts(html, ~s([data-role="doc-example-live"] [data-role="doc-callout"])) == ["One"]
    end

    test "keeps them while it waits for review, in a draft version, or in an archived document",
         %{conn: conn, site: site} do
      pending =
        page!(site, version!(site), @content, content_review_status: :pending)

      draft =
        page!(site, version!(site, slug: "draft", version_status: :draft), @content,
          slug: "draft"
        )

      archived =
        page!(site, version!(site, slug: "old", status: :archived), @content, slug: "old")

      for page <- [pending, draft, archived] do
        assert_raise NotFoundError, fn ->
          get(conn, "/_preview/doc-example/section/#{page.id}/0")
        end
      end
    end

    test "keeps them on another site's address", %{conn: conn, site: site} do
      page = page!(site, version!(site), @content)

      other = "elsewhere#{System.unique_integer([:positive])}"
      elsewhere = create_site!(name: other, host: "#{other}.test", active: true)

      SiteState.save(%{
        id: elsewhere.id,
        name: elsewhere.name,
        host: elsewhere.host,
        priority: elsewhere.priority,
        active: elsewhere.active,
        master: elsewhere.master
      })

      conn =
        conn
        |> Map.put(:host, elsewhere.host)
        |> Map.update!(:req_headers, &[{"host", elsewhere.host} | List.keydelete(&1, "host", 0)])

      assert_raise NotFoundError, fn ->
        get(conn, "/_preview/doc-example/section/#{page.id}/0")
      end
    end
  end

  describe "an example of a note" do
    test "is drawn alone, as its page lets the visitor read it", %{conn: conn, site: site} do
      page = page!(site, version!(site), "<p>Body</p>")

      note =
        create_note!(
          site_id: site.id,
          section_id: page.id,
          content_review_status: :approved,
          technical_review_status: :approved,
          title: "A note",
          content: "<p>Note.</p>" <> example("In the note")
        )

      html = conn |> get("/_preview/doc-example/note/#{note.id}/0") |> html_response(200)

      assert texts(html, ~s([data-role="doc-example-live"] [data-role="doc-callout"])) == [
               "In the note"
             ]

      assert_raise NotFoundError, fn ->
        get(conn, "/_preview/doc-example/section/#{note.id}/0")
      end
    end
  end

  describe "sources/2 and example/2" do
    test "count every example of the text in order, those inside others too, none in code" do
      source = "section/#{Ecto.UUID.generate()}"

      html =
        ~s(<code>[[component doc-example]]x[[/component]]</code>) <>
          example("A", ~s( title="A")) <>
          "[[component doc-callout]]" <>
          example("B") <>
          "[[/component]]" <>
          "<p>[[component&nbsp;doc-example]]C[[/component]]</p>" <>
          "[[component doc-examples]][[/component]]"

      tagged = ExamplePreview.sources(html, source)

      assert tagged =~ ~s([[component doc-example source="#{source}/0" title="A"]])
      assert tagged =~ ~s([[component doc-example source="#{source}/1"]])
      assert tagged =~ ~s([[component&nbsp;doc-example source="#{source}/2"]])
      assert tagged =~ ~s(<code>[[component doc-example]]x[[/component]]</code>)
      assert tagged =~ "[[component doc-examples]]"
      refute tagged =~ "#{source}/3"

      assert ExamplePreview.example(html, source <> "/0").inner =~ "A[[/component]]"
      assert ExamplePreview.example(html, source <> "/1").inner =~ "B[[/component]]"
      assert ExamplePreview.example(html, source <> "/2").inner == "C"
      assert ExamplePreview.example(html, source <> "/3") == nil
      assert ExamplePreview.sources("<p>No examples.</p>", source) == "<p>No examples.</p>"
    end
  end

  describe "with_version/2" do
    test "fills every {{doc.version}}, escaped, and leaves an escaped one as it is written" do
      html =
        ~s(<h2>Install {{doc.version}}</h2><p>{{ doc.version }}</p>) <>
          ~s(<a href="https://example.com/blob/v{{doc.version}}/x">x</a>) <>
          ~S(<p>\{{doc.version}} and {{doc.title}}</p>) <>
          ~s(<pre><code>{:lib, "~&gt; {{doc.version}}"}</code></pre>)

      assert ExamplePreview.with_version(html, "1.2.0") ==
               ~s(<h2>Install 1.2.0</h2><p>1.2.0</p>) <>
                 ~s(<a href="https://example.com/blob/v1.2.0/x">x</a>) <>
                 ~s(<p>{{doc.version}} and {{doc.title}}</p>) <>
                 ~s(<pre><code>{:lib, "~&gt; 1.2.0"}</code></pre>)

      assert ExamplePreview.with_version(~s(<a href="{{doc.version}}">), ~s(1"<b>)) ==
               ~s(<a href="1&quot;&lt;b&gt;">)

      assert ExamplePreview.with_version("<p>{{doc.version}}</p>", nil) ==
               "<p>{{doc.version}}</p>"

      assert ExamplePreview.with_version("<p>None.</p>", "1.2.0") == "<p>None.</p>"
    end

    test "an example's preview draws the number of its page's version", %{conn: conn, site: site} do
      page = page!(site, version!(site), example("Release {{doc.version}}"))

      html = conn |> get("/_preview/doc-example/section/#{page.id}/0") |> html_response(200)

      assert texts(html, ~s([data-role="doc-example-live"] [data-role="doc-callout"])) == [
               "Release 1.0.0"
             ]
    end
  end
end
