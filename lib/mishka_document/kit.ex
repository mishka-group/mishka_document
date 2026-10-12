defmodule MishkaDocument.Kit do
  @moduledoc """
  Where this extension's UI kit bundle is, and how to install it.

  ## What is in the bundle, and why it is a bundle

  `priv/cms_ui_kits/mishka_document.json` carries eight components of two kinds. Each is complete on
  its own: its markup, its declarations, and its own code, including the Ash reads it runs. Nothing
  about them lives in Elixir.

  ### The five blocks, which are live components

  `doc-workspace-list`, `doc-section`, `doc-sidebar`, `doc-toc` and `doc-switcher`. Each is a
  `Phoenix.LiveComponent` that resolves the document from the URL itself and runs its own reads, so
  an author can put any of them on any page and each holds what it read.

  ### The three pieces, which are function components

  `doc-workspace-card`, `doc-pager` and `doc-notice`. These hold nothing and read nothing: they draw
  what the block above hands them. The notice is drawn by all five blocks — it is every skeleton,
  every empty line and every failed read in this kit — and the card is what `doc-workspace-list`
  draws a document with unless the author names a card of their own in its `card` attribute.

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

  ## What the five are

  `doc-workspace-list` lists the documents a site publishes. `doc-section` draws one page of one of
  them — its body, its notes, the trail above it and the pages either side. `doc-sidebar` draws that
  document's whole contents as a tree, `doc-toc` draws what is on the page being read, and
  `doc-switcher` offers the document's other versions and its other languages, each leading back to
  the same page.

  A version may mark one page at its top as its front page: every block reads that page at the
  document's own address, in place of the landing, links to it there, and files the pages under it
  directly under that address (`MishkaDocument.Address`).

  A page's body and each of its notes are scrubbed with `HtmlSanitizeEx.html5/1`, the scrub a page's
  text is stored through, and drawn with `rich_content/1`, so a component the author placed in them
  with the content editor is drawn there as that component (`MishkaCmsCore.Runtime.ContentComponents`),
  and a code block keeps the classes it was highlighted with.

  ### The stylesheet

  `doc-code-highlight` colours the code blocks in a page's body. A page is stored with its code
  already highlighted — `MishkaDocument.Resources.Changes.HighlightCode` does it when the page is
  written — as `<pre class="highlight"><code class="language-x">` with a `<span>` per token, and the
  sheet colours the token classes Makeup emits, in its Monokai style. Installed with the components,
  per site, as a `:base` stylesheet, so a site's own `:custom` rows still win over it.

  Every one of them resolves a document the same way — slug to workspace, `?v=` to a version, version
  to its approved pages — and always through the public reads, never by a raw id. That is what keeps
  a draft version out of a URL somebody typed.

  ## When a block reads in step, and when in the background

  Four of the five read their FIRST answer in step with the page, on both of a visit's renders: the
  GET, so a crawler and a reader with no JavaScript are served the workspaces, the sidebar, the
  table of contents and the version switcher themselves, and the connected one, so they are drawn
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
  crawler served the skeleton is served nothing. That is also the trade the other four accept: a
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
