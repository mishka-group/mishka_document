# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_document/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaDocumentWeb.Live.ExamplePreview do
  @moduledoc """
  One `doc-example` of a page of a document, or of one of its notes, drawn alone and live: the page
  the kit's `doc-example` opens in its Preview dialog's frame, at
  `/_preview/doc-example/<kind>/<id>/<n>` (`MishkaDocumentWeb.ExamplePreviewController`).

  `kind` is `section` or `note`, `id` the page's or the note's id and `n` the example's place among
  the `doc-example` markers of its text, counted from 0 in the order they are written — those inside
  other markers too, and none inside `<pre>` or `<code>` — the rule `sources/2` writes and the kit's
  `doc-section` writes with it (its `example_sources/2`), so the example a reader presses Preview on
  is the one drawn here.

  ## What is read

  What `doc-section` reads to draw the same text, with the same rules: the page through
  `:public_list` as the visitor, so a page locked to permissions the visitor does not hold, or one
  waiting for review, is not found; its version through `:public_list`, so a draft version's page
  is not either; and its document through `:public_list`, so an archived one's is not. A note is
  read through its own `:public_list` as the visitor, and then its page as above. All of it on the
  site the address is asked on. Anything not found, and an example no marker of the text is at, is
  the 404 every missing page is.

  ## What is drawn

  The text is scrubbed as `doc-section` scrubs it, its `{{doc.version}}` is the number of the
  page's version (`with_version/2`), and the example's own content — what its marker
  holds — is drawn with `rich_content/1`, for the site the address is asked on and the visitor, as
  the page draws it: its components, their hooks and their events are those of the page. The
  document around it is the CMS's root layout for a database page: the site's compiled stylesheet
  and scripts, a `noindex, nofollow` robots tag, and the language of the page the example is
  written in. The theme and the direction the dialog shows it in are the dialog's to set on this
  page's `<html>`, which a render here never touches.

  An event no component of the example answers is ignored.
  """
  use Phoenix.LiveView

  alias MishkaCmsCore.ErrorsExceptions.NotFoundError
  alias MishkaCmsCore.LiveUserAuth
  alias MishkaCmsCore.Runtime.{ContentComponents, Languages, LiveViewHelpers, SiteAvailability}
  alias MishkaCmsCore.Runtime.Translations
  alias MishkaDocument.{Note, Section, Workspace, WorkspaceVersion}

  require Ash.Query

  on_mount MishkaCmsCore.Runtime.CspNonce
  on_mount {LiveUserAuth, :live_user_lazy}

  @robots [{"meta", [{"name", "robots"}, {"content", "noindex, nofollow"}]}]

  @source ~r/\A(section|note)\/([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})\/(\d{1,6})\z/

  @marker ~r/\[\[component(?:\s|&nbsp;|&#160;|\x{00A0})+doc-example(?![A-Za-z0-9_-])/u
  @whole_marker ~r/\A\[\[component(?:\s|&nbsp;|&#160;|\x{00A0})+doc-example\z/u
  @code ~r/<(pre|code)(?:\s[^>]*)?>.*?<\/\1>/s
  @code_open ~r/\A<(?:pre|code)[\s>]/

  @version_placeholder ~r/(\\?)\{\{\s*doc\.version\s*\}\}/u

  @impl true
  def mount(_params, %{"source" => source, "current_site" => %{id: site_id} = site}, socket) do
    :ok = Translations.put_site(site_id)
    socket = LiveUserAuth.load_current_user(socket)
    visitor = socket.assigns[:current_user]

    with true <- SiteAvailability.allowed?(site_id, visitor),
         [_whole, kind, id, _place] <- Regex.run(@source, source),
         {:ok, html, language} <- read(kind, id, visitor, site_id),
         %{} = example <- example(html, source) do
      language = language || Languages.primary(site_id)
      Gettext.put_locale(language)

      {:ok,
       assign(socket,
         runtime_page: true,
         current_site: site,
         site_name: site.name,
         page: %{language: language},
         page_title: example.attrs |> Map.get("title") |> title(),
         page_seo: %{tags: @robots, schema: []},
         example: example.inner || ""
       ), layout: false}
    else
      _missing -> raise NotFoundError, message: "Example not found"
    end
  end

  def mount(_params, _session, _socket), do: raise(NotFoundError, message: "Example not found")

  @impl true
  def render(assigns) do
    ~H"""
    <div
      id="doc-example-live"
      data-role="doc-example-live"
      class="space-y-4 p-5 text-[#1b1a18] dark:text-[#ece6ff]"
    >
      <LiveViewHelpers.rich_content
        id="doc-example-live-body"
        html={@example}
        site={@site_name}
        current_user={@current_user}
      />
    </div>
    """
  end

  @impl true
  def handle_event(_event, _params, socket), do: {:noreply, socket}

  @impl true
  def handle_info(_message, socket), do: {:noreply, socket}

  @doc """
  `html` with every `doc-example` marker in its text handed `source="<source>/<n>"` right after its
  name, `n` counting them from 0 in the order they are written, those inside other markers too. A
  marker inside `<pre>` or `<code>` is a page showing the syntax, and is left as it was written.
  Text that names no `doc-example` is handed back as it is.

      sources(~s(<p>[[component doc-example title="A"]]x[[/component]]</p>), "section/…")
      #=> ~s(<p>[[component doc-example source="section/…/0" title="A"]]x[[/component]]</p>)
  """
  @spec sources(String.t(), String.t()) :: String.t()
  def sources(html, source) when is_binary(html) and is_binary(source) do
    case String.contains?(html, "doc-example") do
      false ->
        html

      true ->
        @code
        |> Regex.split(html, include_captures: true)
        |> Enum.map_reduce(0, fn part, at ->
          case Regex.match?(@code_open, part) do
            true -> {part, at}
            false -> tagged(part, source, at)
          end
        end)
        |> elem(0)
        |> Enum.join()
    end
  end

  @doc """
  The `doc-example` marker of `html` whose `source` is `wanted`, read from `html` with its sources
  written (`sources/2`) — `%{name: "doc-example", attrs: attrs, inner: inner, index: n}`, as
  `MishkaCmsCore.Runtime.ContentComponents.parse/1` reads a marker — or `nil`.
  """
  @spec example(String.t(), String.t()) :: map() | nil
  def example(html, wanted) when is_binary(html) and is_binary(wanted) do
    [_whole, kind, id, _place] = Regex.run(@source, wanted)

    html
    |> sources(kind <> "/" <> id)
    |> found(wanted)
  end

  # Each marker of one piece of text that is not code, handed its source, from the place `at`.
  defp tagged(part, source, at) do
    {pieces, next} =
      @marker
      |> Regex.split(part, include_captures: true)
      |> Enum.map_reduce(at, fn piece, n ->
        case Regex.match?(@whole_marker, piece) do
          true -> {piece <> ~s( source="#{source}/#{n}"), n + 1}
          false -> {piece, n}
        end
      end)

    {Enum.join(pieces), next}
  end

  @doc """
  `html` with every `{{doc.version}}` in it — `{{ doc.version }}` too, in code blocks and in a
  marker's attributes as well — replaced by `number`, HTML-escaped; `\\{{doc.version}}` is written
  as `{{doc.version}}`. The kit's `doc-section`, `doc-toc` and `doc-section-cards` draw a page's
  text by the same rule (their `with_version/2`). With no number, `html` is handed back as it is.

      with_version(~s(<code>{:lib, "~&gt; {{doc.version}}"}</code>), "1.2.0")
      #=> ~s(<code>{:lib, "~&gt; 1.2.0"}</code>)
  """
  @spec with_version(String.t(), String.t() | nil) :: String.t()
  def with_version(html, number) when is_binary(html) and is_binary(number) do
    case String.contains?(html, "{{") do
      false ->
        html

      true ->
        filled = number |> Phoenix.HTML.html_escape() |> Phoenix.HTML.safe_to_string()

        Regex.replace(@version_placeholder, html, fn whole, escape ->
          case escape do
            "" -> filled
            _escaped -> String.slice(whole, 1..-1//1)
          end
        end)
    end
  end

  def with_version(html, _no_number) when is_binary(html), do: html

  # The marker with that source among the markers of `html`, at any depth.
  defp found(html, wanted) do
    html
    |> ContentComponents.parse()
    |> Enum.find_value(fn
      {:component, %{name: "doc-example", attrs: %{"source" => ^wanted}} = marker} -> marker
      {:component, %{inner: inner}} when is_binary(inner) -> found(inner, wanted)
      _html -> nil
    end)
  end

  # The scrubbed text the example is written in, with its version's number, and its page's
  # language, when the visitor may read it.
  defp read("section", id, visitor, site_id) do
    with {%Section{} = section, number} <- section(id, visitor, site_id) do
      {:ok, with_version(clean(section.rendered_content), number), section.language}
    end
  end

  defp read("note", id, visitor, site_id) do
    with %Note{section_id: section_id, content: content} <- note(id, visitor, site_id),
         {%Section{language: language}, number} <- section(section_id, visitor, site_id) do
      {:ok, with_version(clean(content), number), language}
    end
  end

  # A page of a published version of an active document, read as `doc-section` reads its text,
  # with the number of its version.
  defp section(id, visitor, site_id) do
    with %Section{workspace_version_id: version_id} = section <-
           Section
           |> Ash.Query.for_read(:public_list, %{}, actor: visitor, tenant: site_id)
           |> Ash.Query.filter(id == ^id)
           |> Ash.Query.load([:rendered_content])
           |> first(site_id),
         %WorkspaceVersion{workspace_id: workspace_id, version_number: number} <-
           WorkspaceVersion
           |> Ash.Query.for_read(:public_list, %{}, authorize?: false)
           |> Ash.Query.filter(id == ^version_id)
           |> Ash.Query.select([:id, :workspace_id, :version_number])
           |> first(site_id),
         %Workspace{} <-
           Workspace
           |> Ash.Query.for_read(:public_list, %{}, authorize?: false)
           |> Ash.Query.filter(id == ^workspace_id)
           |> Ash.Query.select([:id])
           |> first(site_id) do
      {section, number}
    end
  end

  defp note(id, visitor, site_id) do
    Note
    |> Ash.Query.for_read(:public_list, %{}, actor: visitor, tenant: site_id)
    |> Ash.Query.filter(id == ^id)
    |> Ash.Query.select([:id, :section_id, :content])
    |> first(site_id)
  end

  defp first(query, site_id) do
    case Ash.read(query, tenant: site_id, page: [limit: 1]) do
      {:ok, %{results: [row | _rest]}} -> row
      {:ok, [row | _rest]} -> row
      _none -> nil
    end
  end

  # The scrub `doc-section` puts a page's text through on its way out.
  defp clean(content) when is_binary(content), do: HtmlSanitizeEx.html5(content)
  defp clean(_none), do: ""

  defp title(title) when is_binary(title) and title != "", do: title
  defp title(_untitled), do: "Example"
end
