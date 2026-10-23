# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_document/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaDocument.EarlierPages do
  @moduledoc """
  The sample pages as the release in production wrote them, held in code so that
  `MishkaDocument.Provision` can tell a page nobody edited from one somebody did.

  An older site has the library and the document pages that `MishkaDocument.Provision` wrote
  before the site's layout drew the header, the bar and the footer: a 1280 pixel wrapper of their
  own, their own header with the Docs link and the language pills, and `doc-switcher` as the bar.
  Hung on `site-main` (`MishkaCmsCore.Runtime.SiteLayout.adopt_pages/3`) they would draw a second
  bar inside the layout's column, so the provision writes the pages of the new design over them
  where it is certain nobody has touched them. This is how it is certain: the stored template is
  EXACTLY one of the texts below, character for character, as
  `MishkaCmsCore.Install.StarterContent.upgrade/1` compares the starter's earlier texts. A page
  stores its template trimmed (the attribute's `trim?`), so the texts are compared as the page
  would have stored them.

  The texts are the templates of the `master` branch at `3a06455`, copied unchanged. A template
  names the site it was written for (`site="..."`) and, on a document at an address of its own, that
  address, so each is a function of them, and `recognise/2` reads the address back out of the stored
  template and rebuilds the text from it. The one older text is the library before it streamed its
  cards (`live_visit`); a page written before the sites chose their URL mode, in September, is not
  held and is left as it is.

  Nothing here is written to a site, and nothing here is the design the pages have now.
  """

  @docs "/:lang/docs"

  @doc """
  What `template`, a page's stored template, is of the sample pages as `master` wrote them for the
  site called `site`: `:library`, `{:document, nil}` for the two pages that read a document by its
  slug, `{:document, address}` for the two at a document's own address, and `nil` for anything else,
  an edit of any of them by a single character included.
  """
  @spec recognise(term(), String.t()) :: :library | {:document, String.t() | nil} | nil
  def recognise(template, site) when is_binary(template) and is_binary(site) do
    cond do
      template in [stored(index(site)), stored(without_live_visit(site))] -> :library
      template == stored(document(site)) -> {:document, nil}
      true -> addressed(template, site)
    end
  end

  def recognise(_template, _site), do: nil

  # The address a document's page was written for, taken from the one line that names it, and the
  # text rebuilt from it: a template that is not the text for that address is not recognised.
  defp addressed(template, site) do
    with [_line, address] <- Regex.run(~r/^\s+path="([^"]+)" lang_param=""$/m, template),
         true <- template == stored(document(site, address)) do
      {:document, address}
    else
      _not_an_address_page -> nil
    end
  end

  # As the page row holds it: the template attribute trims what it is given.
  defp stored(text), do: String.trim(text)

  # THE LIBRARY BEFORE IT STREAMED ITS CARDS: `5702fc8` added the one line, and nothing else.
  defp without_live_visit(site),
    do:
      String.replace(index(site), "      live_visit={assigns[:live_visit] == true}\n", "",
        global: false
      )

  @doc "The library page as `3a06455` wrote it for the site called `site`."
  @spec index(String.t()) :: String.t()
  def index(site) do
    """
    <div class="min-h-screen bg-[#f6f5f2] text-[#1b1a18]">
    #{indent(header(site, :languages), 2)}

      <main class="mx-auto max-w-6xl px-6 py-8">
        <.component
          component_name="doc-workspace-list"
          site="#{site}"
          id="doc-index"
          current_user={assigns[:current_user]}
          live_visit={assigns[:live_visit] == true}
          heading="Documentation"
          lang={@page.language}
          per_page={12}
          sort="order"
          show_description={true}
          show_languages={true}
          doc_base="#{@docs}"
          base={#{live_url(@docs)}}
          params={Map.drop(@query_params, ["lang"])}
          empty_text="Nothing is published here yet."
        />
      </main>
    </div>
    """
  end

  @doc """
  A document's front page and the page of it as `3a06455` wrote them for the site called `site`, one
  text for both: the pages of a document read by its slug, or, with `address`, of one at an address
  of its own.
  """
  @spec document(String.t(), String.t() | nil) :: String.t()
  def document(site, address \\ nil) do
    """
    <div class="min-h-screen bg-[#f6f5f2] text-[#1b1a18]">
    #{indent(header(site, {:switcher, address}), 2)}

      <main class="mx-auto grid max-w-7xl grid-cols-1 gap-6 px-6 py-8 lg:grid-cols-[240px_minmax(0,1fr)_200px]">
        <.component
          component_name="doc-sidebar"
          site="#{site}"
          id="doc-contents"
          current_user={assigns[:current_user]}#{serves(address, 10)}
          heading="Contents"
          lang={@page.language}
          doc_base="#{@docs}"
          params={Map.drop(@query_params, ["lang"])}
          show_filter={true}
        />

        <.component
          component_name="doc-section"
          site="#{site}"
          id="doc-page"
          current_user={assigns[:current_user]}#{serves(address, 10)}
          lang={@page.language}
          doc_base="#{@docs}"
          params={Map.drop(@query_params, ["lang"])}
        />

        <.component
          component_name="doc-toc"
          site="#{site}"
          id="doc-on-this-page"
          current_user={assigns[:current_user]}#{serves(address, 10)}
          heading="On this page"
          lang={@page.language}
          doc_base="#{@docs}"
          params={Map.drop(@query_params, ["lang"])}
        />
      </main>
    </div>
    """
  end

  # The library listed the languages of `@page_languages` as pills, and the document pages took
  # `doc-switcher` in their place.
  defp header(site, offers) do
    """
    <header class="border-b border-[#ecebe6] bg-white">
      <div class="mx-auto flex max-w-7xl flex-wrap items-center justify-between gap-3 px-6 py-5">
        <.link
          navigate={#{live_url(@docs)}}
          class="font-['Space_Grotesk'] text-[20px] font-bold tracking-[-0.01em]"
        >
          Documentation
        </.link>
    #{indent(offered(site, offers), 4)}
      </div>
    </header>
    """
  end

  defp offered(_site, :languages) do
    """
    <nav class="flex flex-wrap items-center gap-2 text-[12.5px] font-semibold">
      <a
        :for={edition <- @page_languages}
        href={edition.path}
        hreflang={edition.language}
        class={[
          "rounded-full border px-3 py-1.5 uppercase",
          (edition.language == @page.language &&
             "border-[#5b57d6] bg-[#f2f1fc] text-[#4f4bcc]") ||
            "border-[#ecebe6] text-[#6d6a63] hover:bg-[#f6f5f2]"
        ]}
      >
        {edition.language}
      </a>
    </nav>
    """
  end

  defp offered(site, {:switcher, address}) do
    """
    <.component
      component_name="doc-switcher"
      site="#{site}"
      id="doc-switcher"
      current_user={assigns[:current_user]}#{serves(address, 6)}
      show="both"
      lang={@page.language}
      doc_base="#{@docs}"
      params={Map.drop(@query_params, ["lang"])}
      show_banner={true}
    />
    """
  end

  # A page at a document's own address names it, and writes no `?lang=`.
  defp serves(address, indent) when is_binary(address),
    do: "\n" <> String.duplicate(" ", indent) <> ~s|path="#{address}" lang_param=""|

  defp serves(_no_address, _indent), do: ""

  defp live_url(address), do: ~s|site_path("#{address}", @page.language)|

  defp indent(markup, spaces) do
    pad = String.duplicate(" ", spaces)

    markup
    |> String.trim_trailing("\n")
    |> String.split("\n")
    |> Enum.map_join("\n", fn
      "" -> ""
      line -> pad <> line
    end)
  end
end
