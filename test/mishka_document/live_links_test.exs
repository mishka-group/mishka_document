# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_document/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaDocument.LiveLinksTest do
  @moduledoc """
  The links of a page's text that lead to another page of the site, made to navigate with LiveView.

  They are done by `doc-section`'s `clean/2`, which scrubs a text as `HtmlSanitizeEx.html5/1` does
  and writes those links live in the same pass. This suite compiles it, and the helpers it uses,
  out of the bundle the way the component compiler emits them (the file a site installs, not a copy
  of it) and asks what it does to a text, with no database or page around it. What a page then
  draws, with its notes, is `MishkaDocument.LiveComponentsRenderTest`.
  """
  use ExUnit.Case, async: true

  import Phoenix.Component
  import Phoenix.LiveViewTest, only: [rendered_to_string: 1]

  @helpers ~w(clean live_nodes live_attrs live_kind live_anchor? live_target live_written
              live_here? live_page? address_key)

  # THE PAGE BEING READ, AND THE HOST OF THE SITE, as `doc-section` hands them.
  @links %{current: "/chelekom/docs/button", host: "docs.example.test"}

  @live_attributes ~s( data-phx-link="redirect" data-phx-link-state="push")

  setup_all do
    {:ok, _module} = compiled_helpers()
    :ok
  end

  defp compiled_helpers do
    helpers =
      MishkaDocument.Kit.bundle_path()
      |> File.read!()
      |> Jason.decode!()
      |> Map.fetch!("components")
      |> Enum.find(&(&1["name"] == "doc-section"))
      |> Map.fetch!("helpers")
      |> Enum.filter(&(&1["name"] in @helpers))

    assert Enum.map(helpers, & &1["name"]) |> Enum.sort() == Enum.sort(@helpers)

    definitions =
      Enum.map_join(helpers, "\n", fn helper ->
        "def #{helper["name"]}(#{helper["args"]}) do\n#{helper["code"]}\nend\n"
      end)

    [{module, _binary}] =
      Code.compile_string(
        "defmodule MishkaDocument.LiveLinksTest.Helpers do\n#{definitions}\nend"
      )

    {:ok, module}
  end

  defp helpers, do: Module.concat(["MishkaDocument.LiveLinksTest.Helpers"])

  defp live(html, links \\ @links), do: helpers().clean(html, links)

  # WHAT THE SCRUB ALONE WRITES, which is all a text with no link to change may come out as.
  defp scrubbed(html), do: HtmlSanitizeEx.html5(html)

  defp unlive(html), do: String.replace(html, @live_attributes, "")

  defp stays?(html), do: live(html) == scrubbed(html)

  defp attributes(html) do
    html |> LazyHTML.from_fragment() |> LazyHTML.query("a") |> LazyHTML.attributes()
  end

  defp live?(attributes) do
    {"data-phx-link", "redirect"} in attributes and {"data-phx-link-state", "push"} in attributes
  end

  defp live_hrefs(html, links \\ @links) do
    for attributes <- attributes(live(html, links)), live?(attributes) do
      List.keyfind(attributes, "href", 0) |> elem(1)
    end
  end

  defp anchor(href, extra \\ ""), do: ~s(<p><a href="#{href}"#{extra}>Link</a></p>)

  describe "a link to a path from the site's root" do
    test "is written as <.link navigate> writes it" do
      assigns = %{}

      navigate =
        rendered_to_string(~H|<p><.link navigate="/cms" class="strong">Link</.link></p>|)

      ours = live(~s(<p><a href="/cms" class="strong">Link</a></p>))

      assert [navigated] = attributes(navigate)
      assert [attributes] = attributes(ours)
      assert Enum.sort(attributes) == Enum.sort(navigated)
      assert live?(attributes)
    end

    test "keeps its href, its other attributes in their place, and its text" do
      html =
        ~s(<p>See <a href="/chelekom/docs/badge" class="link" title="Badge" hreflang="en" ) <>
          ~s(rel="nofollow" aria-label="The badge">the <strong>badge</strong></a>.</p>)

      assert live(html) ==
               ~s(<p>See <a href="/chelekom/docs/badge" class="link" title="Badge" hreflang="en" ) <>
                 ~s(rel="nofollow" aria-label="The badge" data-phx-link="redirect" ) <>
                 ~s(data-phx-link-state="push">the <strong>badge</strong></a>.</p>)
    end

    test "is one however it is written: root, query, fragment, version, percent-encoded" do
      for href <- [
            "/cms",
            "/",
            "/chelekom/docs/button?v=2",
            "/chelekom/docs/badge#props",
            "/docs/1.2.0",
            "/docs/v1.0.0-rc.1",
            "/docs/{{doc.version}}/install",
            "/fa/docs/%D8%B1%D8%A7%D9%87%D9%86%D9%85%D8%A7",
            "/fa/docs/راهنما",
            "/apidocs",
            "/feedback",
            "/imagesets/one",
            "/blog/2026/10/post"
          ] do
        assert live_hrefs(anchor(href)) == [href], "#{href} did not become a live link"
      end
    end

    test "is every one of a text's, wherever they sit" do
      html =
        ~s(<h2><a href="/a">A</a></h2><ul><li><a href="/b">B</a> and <a href="/c">C</a></li></ul>) <>
          ~s(<blockquote><p>See <em><a href="/d">D</a></em></p></blockquote>)

      assert live_hrefs(html) == ["/a", "/b", "/c", "/d"]
    end
  end

  # THE PAGES A LINK MAY PATCH TO are named by `links.patch`, the addresses of the pages of the document
  # being read written as its contents write them; the front page is not one of them.
  describe "a link to another page of the document being read" do
    defp patching(addresses),
      do: Map.put(@links, :patch, MapSet.new(addresses, &helpers().address_key(&1)))

    defp patch_links,
      do: patching(["/chelekom/docs/badge", "/chelekom/docs/badge?v=2", "/fa/docs/راهنما"])

    defp kinds(html, links) do
      for attributes <- attributes(live(html, links)),
          {"data-phx-link", kind} <- attributes,
          do: kind
    end

    test "is written as <.link patch> writes it" do
      assigns = %{}

      patched =
        rendered_to_string(
          ~H|<p><.link patch="/chelekom/docs/badge" class="strong">Link</.link></p>|
        )

      ours =
        live(~s(<p><a href="/chelekom/docs/badge" class="strong">Link</a></p>), patch_links())

      assert [patch_attributes] = attributes(patched)
      assert [attributes] = attributes(ours)
      assert Enum.sort(attributes) == Enum.sort(patch_attributes)
    end

    test "is one however it is written: fragment, trailing slash, encoding, query order" do
      for href <- [
            "/chelekom/docs/badge",
            "/chelekom/docs/badge/",
            "/chelekom/docs/badge#props",
            "/chelekom/docs/%62adge",
            "/chelekom/docs/./badge",
            "/chelekom/docs/x/../badge",
            "/chelekom/docs/badge?v=2",
            "/fa/docs/راهنما",
            "/fa/docs/%D8%B1%D8%A7%D9%87%D9%86%D9%85%D8%A7",
            "http://docs.example.test/chelekom/docs/badge"
          ] do
        assert kinds(anchor(href), patch_links()) == ["patch"], "#{href} did not patch"
      end

      keyed = patching(["/docs/a?lang=fa&v=2"])

      for href <- ["/docs/a?v=2&lang=fa", "/docs/a?lang=fa&v=2#x"] do
        assert kinds(anchor(href), keyed) == ["patch"], "#{href} did not patch"
      end
    end

    test "navigates when it leads to another page, another version or another key" do
      for href <- [
            "/chelekom/docs",
            "/chelekom/docs/button",
            "/chelekom/docs/badge?v=1",
            "/chelekom/docs/badge?v=2&utm=feed",
            "/chelekom/docs/badge?utm=feed",
            "/cms",
            "/cms/docs/badge",
            "/blog/2026/10/post"
          ] do
        assert kinds(anchor(href), patch_links()) == ["redirect"], "#{href} did not navigate"
      end
    end

    test "navigates when no page is named, which is every link before the view has joined" do
      assert kinds(anchor("/chelekom/docs/badge"), @links) == ["redirect"]
      assert kinds(anchor("/chelekom/docs/badge"), Map.put(@links, :patch, nil)) == ["redirect"]
      assert kinds(anchor("/chelekom/docs/badge"), patching([])) == ["redirect"]
    end

    test "is still left as it is when it leads off the site or to the page being read" do
      for href <- [
            "https://example.com/chelekom/docs/badge",
            "#props",
            "/chelekom/docs/button#x",
            "mailto:a@b.c"
          ] do
        assert live(anchor(href), patch_links()) == scrubbed(anchor(href)), "#{href} was changed"
      end
    end

    test "keeps the rest of the link as it was" do
      html =
        ~s(<p><a href="/chelekom/docs/badge#props" class="link" title="Badge" rel="nofollow">Badge</a></p>)

      assert live(html, patch_links()) ==
               ~s(<p><a href="/chelekom/docs/badge#props" class="link" title="Badge" rel="nofollow" ) <>
                 ~s(data-phx-link="patch" data-phx-link-state="push">Badge</a></p>)
    end
  end

  describe "a link that stays as it is" do
    test "when it leads nowhere on the site" do
      for href <- [
            "#h-x",
            "#",
            "https://example.com",
            "https://example.com/cms",
            "http://example.com/docs",
            "//example.com/cms",
            "///example.com/cms",
            "/\\example.com",
            "docs/install",
            "../docs",
            "?page=2",
            "mailto:team@example.com",
            "tel:+10000000",
            "javascript:alert(1)",
            "data:text/html,x",
            "/a b",
            "/a\tb",
            ""
          ] do
        assert stays?(anchor(href)), "#{inspect(href)} was changed"
      end
    end

    test "when it leads to a file or a route that is not a page" do
      for href <- [
            "/uploads/a.pdf",
            "/uploads/images/photo",
            "/assets/css/site/hash",
            "/fonts/inter.woff2",
            "/images/logo.png",
            "/api/json/documents",
            "/api",
            "/admin",
            "/admin/dashboard/document",
            "/webhooks/stripe",
            "/sitemap.xml",
            "/sitemap-00001.xml.gz",
            "/robots.txt",
            "/favicon.ico",
            "/feed",
            "/feed.xml",
            "/feeds/docs",
            "/_preview/doc-example/section/1/0",
            "/oban",
            "/gql",
            "/install",
            "/docs/guide.pdf",
            "/docs/archive.tar.gz",
            "/Admin/dashboard"
          ] do
        assert stays?(anchor(href)), "#{href} was changed"
      end
    end

    test "when its address only reaches a route that is not a page after it is resolved" do
      for href <- ["/docs/../admin/x", "/docs/%2e%2e/api/x", "/%61pi/x", "/%61dmin"] do
        assert stays?(anchor(href)), "#{href} was changed"
      end
    end

    test "when it is not meant to replace the page" do
      for extra <- [
            ~s( target="_blank"),
            ~s( target="_top"),
            ~s( target="docs"),
            ~s( rel="external"),
            ~s( rel="noopener External"),
            ~s( data-phx-link="patch" data-phx-link-state="push"),
            ~s( data-phx-link="redirect" data-phx-link-state="replace")
          ] do
        html = anchor("/cms", extra)

        assert String.contains?(scrubbed(html), extra), "#{extra} did not survive the scrub"
        assert stays?(html), "#{extra} was changed"
      end
    end

    test "unless its target is the page itself, or its rel only says what it is" do
      for extra <- [~s( target="_self"), ~s( target=""), ~s( rel="nofollow"), ~s( rel="noopener")] do
        assert live_hrefs(anchor("/cms", extra)) == ["/cms"], "#{extra} was left alone"
      end
    end

    test "when it has no href" do
      assert stays?(~s(<p><a name="top">Top</a></p>))
    end

    test "when it downloads, which the scrub never lets through, but this does not rely on" do
      for download <- [{"download", "download"}, {"download", "a.pdf"}] do
        assert helpers().live_attrs([{"href", "/cms"}, download], @links) == nil
      end

      assert helpers().live_attrs([{"href", "/cms"}], @links) ==
               [{"href", "/cms"}, {"data-phx-link", "redirect"}, {"data-phx-link-state", "push"}]
    end
  end

  describe "the page being read" do
    test "is left to the browser when only a fragment of it is asked for" do
      for href <- [
            "/chelekom/docs/button#props",
            "/chelekom/docs/button/#props",
            "/chelekom/docs/button#"
          ] do
        assert stays?(anchor(href)), "#{href} was changed"
      end
    end

    test "is navigated to when the link says anything else about it" do
      for href <- [
            "/chelekom/docs/button",
            "/chelekom/docs/button?v=2#props",
            "/chelekom/docs/badge#props",
            "/chelekom/docs/button/states#props"
          ] do
        assert live_hrefs(anchor(href)) == [href], "#{href} was left alone"
      end
    end

    test "is told apart by its query too" do
      links = %{@links | current: "/docs/mishka/install?lang=fa"}

      assert live_hrefs(anchor("/docs/mishka/install?lang=fa#top"), links) == []
      assert live_hrefs(anchor("/docs/mishka/install#top"), links) == ["/docs/mishka/install#top"]
    end

    test "is not known to a block with no address of its own" do
      assert live_hrefs(anchor("/chelekom/docs/button#props"), %{@links | current: nil}) ==
               ["/chelekom/docs/button#props"]

      assert live_hrefs(anchor("/chelekom/docs/button#props"), %{@links | current: "?"}) ==
               ["/chelekom/docs/button#props"]
    end
  end

  describe "an address in full on the site's own host" do
    test "is written as the path it is, and made live" do
      assert live(anchor("https://docs.example.test/cms?x=1#top")) ==
               ~s(<p><a href="/cms?x=1#top"#{@live_attributes}>Link</a></p>)

      assert live_hrefs(anchor("http://docs.example.test/blog")) == ["/blog"]
      assert live_hrefs(anchor("https://docs.example.test")) == ["/"]
      assert live_hrefs(anchor("https://docs.example.test:443/cms")) == ["/cms"]
      assert live_hrefs(anchor("http://docs.example.test:80/cms")) == ["/cms"]
    end

    test "is judged as the path it is" do
      for href <- [
            "https://docs.example.test/uploads/a.pdf",
            "https://docs.example.test/admin",
            "https://docs.example.test/chelekom/docs/button#props"
          ] do
        assert stays?(anchor(href)), "#{href} was changed"
      end
    end

    test "stays as it is on another host, port, scheme or with a user" do
      for href <- [
            "https://example.test/cms",
            "https://docs.example.test.evil.test/cms",
            "https://evil.test/docs.example.test/cms",
            "https://docs.example.test:8443/cms",
            "https://user@docs.example.test/cms",
            "ftp://docs.example.test/cms"
          ] do
        assert stays?(anchor(href)), "#{href} was changed"
      end
    end

    test "is never written as an address on another host" do
      for href <- [
            "https://docs.example.test//evil.test/cms",
            "https://docs.example.test///evil.test",
            "https://docs.example.test/\\evil.test"
          ] do
        assert stays?(anchor(href)), "#{href} was changed"
      end
    end

    test "stays as it is when the site's host is not known" do
      assert live(anchor("https://docs.example.test/cms"), %{@links | host: nil}) ==
               scrubbed(anchor("https://docs.example.test/cms"))
    end
  end

  describe "the rest of the text" do
    @page """
    <h2 id="a">Install &amp; run</h2>
    <p>Read&nbsp;the <a href="/chelekom/docs/badge">badge</a>, then <a href="https://example.com/x?a=1&b=2">example</a>.
    [[component doc-callout tone="tip" title="Tip"]]Use <a href="/cms">the CMS</a>[[/component]]</p>
    <ul>
      <li>one</li>
      <li>two <code>mix setup</code></li>
    </ul>
    <pre class="highlight"><code class="language-elixir"><span class="nn">Mix</span><span class="o">.</span>run(&quot;x&quot;)
    </code></pre>
    <table><tbody><tr><td><a href="/uploads/a.pdf">pdf</a></td></tr></tbody></table>
    """

    test "is exactly what the scrub writes, but for the attributes of the links changed" do
      live = live(@page)

      refute live == scrubbed(@page)
      assert unlive(live) == scrubbed(@page)
      assert live_hrefs(@page) == ["/chelekom/docs/badge", "/cms"]
    end

    test "is what the scrub writes, with nothing added, when no link in it is one to change" do
      for html <- [
            "",
            "No markup at all & no link",
            "<p>No link at all.</p>",
            ~s(<p><a href="#top">Top</a> <a href="https://example.com">Out</a></p>),
            ~s(<p><a href="/uploads/a.pdf">A file</a></p>),
            ~s(<p>Text [[component doc-callout tone="tip"]]body[[/component]]</p>),
            ~s(<!-- note --><p>Comment</p>),
            ~s(<<p>>>)
          ] do
        assert stays?(html), "#{inspect(html)} was changed"
      end
    end

    test "is no text at all when it is none" do
      assert live(nil) == ""
      assert live(42) == ""
    end

    test "is made live once" do
      once = live(@page)

      assert live(once) == once
      assert once |> String.split(~s(data-phx-link="redirect")) |> length() == 3
      assert length(attributes(once)) == length(attributes(scrubbed(@page)))
    end
  end

  describe "a text that is broken or hostile" do
    @hostile [
      ~s(<a href="/cms"),
      ~s(<<a href="/cms">>),
      ~s(<p>unclosed <a href="/cms">link),
      ~s(<a href="/cms">crossed <b>tags</a></b>),
      ~s(<a href='/cms'>single quotes</a>),
      ~s(<A HREF="/cms">upper case</A>),
      ~s(<a href=/cms>bare</a>),
      ~s(<a  href="/cms" >spaces</a>),
      ~s(<a href="/cms"/>),
      ~s{<a href="/cms" onclick="alert(1)" style="x:y">events</a>},
      ~s{<a href="javascript:alert(1)">script</a><a href="/cms">fine</a>},
      ~s{<a href="jav&#x09;ascript:alert(1)">script</a>},
      ~s{<img src=x onerror=alert(1)><a href="/cms">image</a>},
      ~s{<script>alert(1)</script><a href="/cms">script</a>},
      ~s{<svg onload=alert(1)><a href="/cms">svg</a></svg>},
      ~s(<iframe src="//evil.test"></iframe><a href="/cms">frame</a>),
      ~s(<style>a{x:y}</style><a href="/cms">style</a>),
      ~s(<![CDATA[<a href="/cms">cdata</a>]]>)
    ]

    test "is what the scrub writes, but for the attributes of the links changed" do
      for html <- @hostile do
        assert unlive(live(html)) == scrubbed(html), "#{inspect(html)} was changed"
      end
    end

    test "is never given anything to run, whatever it carries" do
      for html <- @hostile do
        written = live(html)

        refute written =~ ~r/onerror|onload|onclick|javascript:|<script/i,
               "#{inspect(html)} was written as #{inspect(written)}"
      end
    end

    test "is made live when its link is one, once the scrub has repaired it" do
      assert live(~s(<p>unclosed <a href="/cms">link)) ==
               ~s(<p>unclosed <a href="/cms"#{@live_attributes}>link</a></p>)
    end
  end
end
