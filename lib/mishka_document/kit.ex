defmodule MishkaDocument.Kit do
  @moduledoc """
  Where this extension's UI kit bundle is, and how to install it.

  ## What is in the bundle, and why it is a bundle

  `priv/cms_ui_kits/mishka_document.json` carries eleven components of two kinds. Each is complete on
  its own: its markup, its declarations, and its own code, including the Ash reads it runs. Nothing
  about them lives in Elixir.

  ### The six blocks, which are live components

  `doc-workspace-list`, `doc-section`, `doc-sidebar`, `doc-toc`, `doc-switcher` and
  `doc-section-cards`. Each is a `Phoenix.LiveComponent` that runs its own reads, so an author can
  put any of them on any page and each holds what it read. The first five resolve the document from
  the URL; `doc-section-cards` from the page it is drawn in.

  ### The five pieces, which are function components

  `doc-workspace-card`, `doc-pager`, `doc-notice`, `doc-callout` and `doc-example`. These hold
  nothing and read nothing: they draw what they are handed. The notice is drawn by all six blocks —
  it is every skeleton, every empty line and every failed read in this kit — and the card is what
  `doc-workspace-list` draws a document with unless the author names a card of their own in its
  `card` attribute. The callout and the example are placed by an author inside a page's text, with
  the content editor — `[[component doc-callout tone="tip"]]…[[/component]]` — and drawn by
  `doc-section`'s `rich_content`, which names them for the site's stylesheet.

  ### The cards

  `[[component doc-section-cards /]]` in a page's text, or in one of its notes, draws the pages
  filed under that page as cards, two a row from the `sm` breakpoint and one under it: each its
  title, the badges a plugin puts on it, its summary — the description its own SEO gives it, else the
  start of its text — and a link to its address. `doc-section` hands the marker the page it is drawn
  in (`placed_in`) and the `doc_base`, `lang_param` and `version_param` it links with, after the
  scrub and never inside `<pre>` or `<code>`. `parent` names another page of the same version — by
  its address, or by a slug only one page has, which is how a group with no page of its own is
  named. The pages are the version's approved ones the visitor may read, read through
  `public_list_at_workspace_version` as `doc-sidebar` reads them, under the parent the contents draw
  each one under and in their order; a group with no page of its own gives up its pages in its
  place. `doc-notice` draws its skeleton, its error and its empty line (`empty_text`).

  Its badges are asked on `document:page:extras`, once a card, with the page as `doc-section` tells
  it and `card: true`, and only the header's `:badges` are drawn. A plugin answering an ask with
  `card: true` answers from what it already holds and fetches nothing; `show_badges=false` asks
  nothing. Every element says what it is in its `data-role`: `doc-cards`, `doc-cards-heading`,
  `doc-cards-items`, `doc-cards-item`, `doc-cards-link`, `doc-cards-title`, `doc-cards-badges`,
  `doc-cards-badge` (`data-tone`), `doc-cards-description`, `doc-cards-empty`, `doc-cards-loading`
  and `doc-cards-error`.

  ### The example

  `[[component doc-example title="…"]]` around the markers of the components an example is made
  of, then `[[/component]]`. Its `inner_block` is drawn on the page itself, in the example's
  `doc-example-stage` and its `doc-example-body`, so the components' own hooks, events, popups and
  breakpoints work there as anywhere on the page, in the page's own colours.

  Its toolbar — `doc-example-toolbar`, named by `toolbar_label` — turns the example left to right or
  right to left, and its `doc-example-open` button, saying `preview_text`, opens a still preview:
  a `<dialog>` (`doc-example-preview`, opened as a modal) inside a `phx-update="ignore"` element
  whose id carries a digest of the example, so a LiveView patch never closes it and other content
  draws a preview of its own. The preview says `preview_note` over a frame whose page is the same
  `inner_block` turned into HTML: that page links the site's own stylesheet
  (`MishkaCmsCore.Runtime.Compilers.Shared.site_css_href/1`, for the site the page is rendered
  for), carries the theme as `<html data-theme>` and the direction as `<html dir>`, and holds no
  script. The frame is `sandbox="allow-same-origin"` — the hook reads its page from outside — named
  by `title` or `frame_label`, and carries its page in `data-document` until the preview first
  opens. The preview's own toolbar (`doc-example-preview-toolbar`) switches its colours, its width
  — a desktop's 1280 pixels, a tablet's 768 or a phone's 375, scaled down to fit a narrower
  preview — and the direction, and its `doc-example-close` button, saying `close_text`, Escape and
  a press on the backdrop close it.

  `theme` (light, dark; dark by default) and `device` (desktop, tablet, mobile; desktop) are what
  the preview is first drawn with, and `dir` (ltr, rtl; ltr) is what the example is first drawn
  with on the page and in the preview, carried on its root as `data-frame-theme`,
  `data-frame-device` and `data-frame-dir`, and `dir` on the stage. Each choice is a
  `doc-example-option` button with a `data-action` of theme, device or dir, a `data-value` and
  `aria-pressed`. Every element says what it is in its `data-role` for a site's stylesheet to
  restyle. Drawn without an id the example has no toolbar and no preview.

  An example taller than `collapse_height` pixels (320; 240, 400, 480 or 640, and 0 cuts none) is
  cut at that height under a fade until the `doc-example-expand` button in the `doc-example-foot`
  under it shows all of it, saying `expand_text` and then `collapse_text`. The root carries the
  height as `data-collapse-height`; the hook measures the example's body and writes
  `data-collapsible` onto the root — again whenever the body changes size — and the button writes
  `data-expanded`. The cut clips only the example's height, so a popup still reaches past its sides.

  A component that keeps state is drawn by LiveView on the page and is never HTML a frame could
  hold: an example holding one is drawn on the page like any other, and its preview draws
  `stateful_text` in place of its frame. A preview of a page's content, which draws every component
  cold into a string, draws the example and its frame the same way.

  They draw themselves in plain HTML and Tailwind and call no other kit. A site that installed this
  extension and skipped Chelekom renders them; the components a documentation page is made of cannot
  depend on a kit the installer only offers.

  That is the same shape Chelekom ships in, and it is the point. A component that arrives as data
  can be installed one at a time or in batches, can be edited in the admin like any other row, and
  carries no dependency on a module a third-party importer would not have. An extension that kept
  its components in compiled code would be asking the CMS to treat it specially.

  ### Who they read as

  Every read is the public action's, with the visitor the page hands down as `current_user` as its
  actor — `nil` for a guest — so a document or a page of one locked to permissions the visitor does
  not hold is left out by the same rules the record's own page keeps
  (`MishkaDocument.Resources.Preparations.OpenToActor`). The document a page sits in and its
  versions are read as the system: a page whose own lock opens for the reader is drawn inside a
  document whose lock does not.

  ## What the six are

  `doc-workspace-list` lists the documents a site publishes. `doc-section` draws one page of one of
  them — its body, its notes, the trail above it and the pages either side. `doc-sidebar` draws that
  document's whole contents as a tree, `doc-toc` draws what is on the page being read, and
  `doc-switcher` offers the document's other versions and its other languages, each leading back to
  the same page. `doc-section-cards` draws the pages filed under one page as cards.

  A version may mark one page at its top as its front page: every block reads that page at the
  document's own address, in place of the landing, links to it there, and files the pages under it
  directly under that address (`MishkaDocument.Address`). A page marked as a group is only a heading
  over the pages under it — in the contents and on the landing — with no page or address of its own:
  nothing links to it, Previous and Next step over it, and its pages are addressed as if it were not
  there. A group with a page of its own (`group_page`) is read at its own slug like any page — its
  text, its notes, its trail — and its heading in the contents, its title on the landing and its
  place in a trail link there; Previous and Next stop on it. The pages under it keep the address
  that leaves its slug out.

  A page's body and each of its notes are scrubbed with `HtmlSanitizeEx.html5/1`, the scrub a page's
  text is stored through, and drawn with `rich_content/1`, so a component the author placed in them
  with the content editor is drawn there as that component (`MishkaCmsCore.Runtime.ContentComponents`),
  and a code block keeps the classes it was highlighted with.

  After the scrub, `doc-section` draws each code block in a window: a head holding the block's
  language, read off its `language-x` class, and a `<button type="button">` that copies its code,
  over the block as it was stored. Every element of it says what it is in its `data-role` —
  `doc-code`, `doc-code-head`, `doc-code-lang`, `doc-code-copy`, `doc-code-status` — for a site's
  stylesheet to restyle, and what the button says is the block's `copy_text`, `copied_text` and
  `copy_label`. The window is drawn, never stored: a page's text keeps only its code.

  A block of more lines than `code_lines` (16; 8, 12, 20, 24 or 32, and 0 cuts none) is cut at that
  many under a fade: its window carries `data-collapsible` and `data-collapse-lines`, its `<pre>` an
  id, and a `doc-code-foot` under the code holds the `doc-code-expand` button that shows all of it,
  saying `expand_text` — `%{count}` is its number of lines — and then `collapse_text`. The copy
  button copies the whole code either way.

  ### What plugins add to a page

  Each time `doc-section` reads a page of a document it fires the `document:page:extras`
  mishka_installer event through `MishkaInstaller.Event.Hook.call/3`, with:

      %{
        site_id: "…",
        document: %{slug: "chelekom", path: "/chelekom/docs", language: "en"},
        version: "0.0.9",
        page: %{
          slug: "breadcrumb",
          title: "Breadcrumb",
          path: "breadcrumb",
          parents: [%{slug: "navigations", title: "Navigations", group: true}]
        },
        header: [],
        tabs: []
      }

  `page` is `nil` on a document's landing. Its `path` is its address under the document and
  `parents` the pages and groups it is filed under, nearest last. A plugin appends to `header` and
  `tabs` and replies with the map:

      use MishkaInstaller.Event.Hook, event: "document:page:extras"

      def call(%{document: %{slug: "handbook"}, header: header} = state),
        do: {:reply, %{state | header: header ++ [%{kind: :text, label: "Edition", value: "2"}]}}

      def call(state), do: {:reply, state}

  `header` holds facts, drawn under the title in the order given:

    * `%{kind: :badges, label: nil, items: [%{text: "v1.0", tone: :primary}]}` — a `tone` is
      `neutral` (the default), `primary`, `secondary`, `success`, `info`, `warning`, `danger`, or
      any other word a site's stylesheet keys on as `data-tone`.
    * `%{kind: :command, label: "Install", value: "mix …"}` — drawn left to right, with the button a
      code window has.
    * `%{kind: :link, label: "Source", href: "https://…", text: "View source"}` — `http`, `https`
      or a path on the site; an `http` or `https` address opens in a new tab.
    * `%{kind: :text, label: "Package", value: "…"}`.
    * `%{kind: :pending, text: "…"}` — a skeleton for the facts still being fetched, `text` for a
      screen reader.

  `tabs` holds tabs, drawn after the page's own text, `docs_tab_text`. A tab is
  `%{id: "props", label: "Props", blocks: [block]}`, or the one block it is —
  `%{id: "props", label: "Props", kind: :table, …}`. While its data is being fetched it is
  `%{id: "props", label: "Props", state: :not_ready, text: "…", failed_text: "…",
  pending: %{topic: "…"}}`, drawn as a skeleton, and one whose data could not be had is
  `%{id: "props", label: "Props", state: :failed, text: "…"}`. An `id` is lower-case letters,
  digits, `-` and `_`, and never `documentation`; the first tab with an id is kept. A block is:

    * `%{kind: :table, title: nil, description: nil, columns: [%{key: :name, label: "Name",
      code: true}], rows: [%{name: "color"}], empty_text: "…"}` — a cell is a word (in code under
      a `code: true` column), a list of words, or a badge, `%{text: "Yes", tone: :success}`;
      nothing is a dash, and a table with no rows says `empty_text`.
    * `%{kind: :list, title: nil, description: nil, items: [fact]}` — facts, one a row.

  Each tab is a link to the page with its id under `tab_param` — `?tab=props` — and the page's
  other URL keys; the text is shown when the URL names no tab a plugin added. Every panel is drawn,
  the ones not shown `hidden`, and changing tabs reads nothing again. Every element says what it is
  in its `data-role`: `doc-extras`, `doc-extra-badges`, `doc-extra-badge`, `doc-extra-command`,
  `doc-extra-link`, `doc-extra-text`, `doc-extra-label`, `doc-extra-value`, `doc-tabs`, `doc-tab`
  (`aria-current` on the one shown), `doc-tab-panel`, `doc-extra-table`, `doc-extra-list`,
  `doc-extra-row`, `doc-extra-item`, `doc-extra-blank`, `doc-extra-pending`, `doc-tab-pending` and
  `doc-tab-failed`.

  A `pending` topic — on a tab, or on the answer as `pending: %{topic: "…"}` — is a
  `Phoenix.PubSub` topic on `MishkaCmsCore.PubSub` the plugin announces the end of its fetch on.
  Once connected, `doc-section` starts one task (`MishkaGervaz.Messages.start_async/4`) that
  subscribes to it, asks the event once more, and otherwise waits for the next message on it, up
  to `pending_wait` milliseconds; then it asks again and draws the answer, and waits again while it
  still names a topic. Nothing polls. A wait that runs out turns each tab still being fetched into
  its `failed_text`, and takes the header's skeleton away.

  Every word is text the template escapes, and anything of another shape is left out. With no
  plugin, or an event that cannot run, the page is drawn as it was.

  ### The hooks

  `doc-code-copy` answers the buttons on each code window — the copy and the one that shows all of a
  cut block — and the one beside each command a plugin adds to the page. `doc-section` mounts it on
  its own root, outside the page's text, under the name the site's JavaScript registers it by
  (`MishkaCmsCore.Runtime.Compilers.JavaScriptCompiler.browser_name/2`), and one listener there
  answers every button inside, whatever render drew it. A press copies the window's code with the
  Clipboard API, or a textarea and `execCommand("copy")` where that API is missing, marks the button
  `data-copied="true"` for 1.2 seconds and puts `copied_text` in the window's `doc-code-status`
  live region. It writes no class and no style attribute, so a site's CSP has nothing to refuse.
  Installed with the components, per site.

  The `doc-example` hook answers an example's toolbar. The component of that name mounts it on its
  own root, under the name `MishkaCmsCore.Runtime.Compilers.JavaScriptCompiler.browser_name/2`
  gives it. A press writes the choice onto the root's `data-frame-*`, the buttons' `aria-pressed`
  and, for a direction, the stage's `dir`, through the hook's JS commands, which a LiveView patch
  keeps, and onto the frame's `<html>`. Opening the preview hands the frame its page and calls
  `showModal/0`. The frame is drawn at its device's width and its page's height through its `width`
  and `height` attributes — measured when the page loads, its fonts and pictures arrive, the
  preview's width changes and after every choice — and scaled down to the preview's width through
  CSSOM properties set from script, never a style attribute, so a site's CSP has nothing to refuse.
  A link pressed in the frame closes the preview and leads the page itself there. No class and no
  markup is written.

  ### The stylesheet

  `doc-code-highlight` colours the code blocks in a page's body. A page is stored with its code
  already highlighted — `MishkaDocument.Resources.Changes.HighlightCode` does it when the page is
  written — as `<pre class="highlight"><code class="language-x">` with a `<span>` per token, and the
  sheet colours the token classes Makeup emits, in its Monokai style, and draws the window around
  each block, the button's copied state included. It cuts a long block and a tall example at each
  height their attributes offer, and draws the fade, the blur and the button over the cut, keyed on
  `data-collapsible` and `data-expanded`. Installed with the components, per site, as a `:base`
  stylesheet, so a site's own `:custom` rows still win over it.

  Every one of them resolves a document the same way — slug to workspace, `?v=` to a version, version
  to its approved pages — and always through the public reads, never by a raw id. That is what keeps
  a draft version out of a URL somebody typed.

  ## When a block reads in step, and when in the background

  Five of the six read their FIRST answer in step with the page, on both of a visit's renders: the
  GET, so a crawler and a reader with no JavaScript are served the workspaces, the sidebar, the
  table of contents, the version switcher and the cards themselves, and the connected one, so they are drawn
  straight away rather than replaced by a skeleton while they are read again. Every later read runs
  in a task, and while it does the block draws a skeleton; when a read fails it draws a line and a
  button to ask again. `cold?/1` still answers for the builder's canvas and the Preview, where
  `MishkaCmsCore.Runtime.LiveViewHelpers.cold/2` renders a component with no process at all, and
  reads inline there too.

  Each task is started through `MishkaGervaz.Messages.start_async/4`, which hands it the site and
  the locale the page renders in (`MishkaCmsCore.Runtime.LiveViewHelpers.carry_into_tasks/0`), so a
  link `doc-switcher` builds there with `site_path/2` is the one its template would build.

  `doc-workspace-list` streams its rows, and says `phx-update="stream"` only where there is a socket
  to stream from — `@myself` is nil in a cold render, and a stream container is one the client never
  removes a child from, so the builder's canvas would keep the cards of the previous setting beside
  the new ones every time the Inspector changed one.

  `doc-section` is the exception, and on purpose: it is what the page IS. A skeleton where the
  document's text should be is a worse page than one that takes as long as the text does, and a
  crawler served the skeleton is served nothing. That is also the trade the other five accept: a
  reader with no JavaScript is served the skeleton of a tree, a table of contents and a version
  list, while the document's own text is in the HTTP response either way.

  `doc-sidebar`'s filter box is the other half of the same idea in reverse: it narrows the tree the
  block already holds, so a keystroke is a render and not a read.

  ## Installing

      MishkaDocument.Kit.install!(site_id)

  Per SITE rather than globally: these components read documents, and a document belongs to a tenant.
  The site is baked into the compiled module's own metadata — see `site_id/0` in the bundle's
  helpers — so a component cannot be edited into reading another site's documents.

  Re-running it upserts by name, which is what makes it safe in a seed.

  ## Updating a site that already has them

  Not with this. `install!/1` writes the bundle's copy over every row an admin ever edited, which is
  what a seed wants and what an admin does not. The "Documentation components" card on the document
  dashboard is the other way: `MishkaCmsCore.Runtime.Handlers.UiKitUpgrade` compares each installed
  row with the version and the fingerprint the installer stamped on it, reports what is behind and
  what carries an edit, and writes only what the admin chooses.

  ## What this module is not

  It installs, and that is all. There is deliberately no query helper, no render helper and nothing
  a component's stored code could call: the components are self-contained, and a function here
  would quietly become part of their contract.
  """

  alias MishkaCmsCore.Runtime.Handlers.UiKitHandler

  @doc "The bundle's absolute path inside this extension's `priv`."
  @spec bundle_path() :: String.t()
  def bundle_path,
    do: Path.join([:code.priv_dir(:mishka_document), "cms_ui_kits", "mishka_document.json"])

  @doc """
  Installs the bundle for one site, upserting by component name.

  Returns whatever `MishkaCmsCore.Runtime.Handlers.UiKitHandler.install_kit!/2` returns — `{:ok, …}`
  with the rows, or `{:error, reason}` when the file is not a bundle this CMS reads.
  """
  @spec install!(String.t()) :: {:ok, map()} | {:error, term()}
  def install!(site_id) when is_binary(site_id),
    do: UiKitHandler.install_kit!(bundle_path(), site_id: site_id)
end
