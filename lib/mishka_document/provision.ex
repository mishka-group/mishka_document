# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_document/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaDocument.Provision do
  @moduledoc """
  What a site needs before anybody can read its documentation: this extension's live components,
  three sample pages built out of them, and the "latest documents" block saved as a snippet an
  author can drop on a home page.

  ## Why a production site needs this at all

  `MishkaDocument.Kit.install!/1` writes the components, and until now it had no caller at all. A
  real install goes through `MishkaCmsCore.Install.Bootstrap`, which offers Chelekom and knows
  nothing about this extension, and a site created later in the admin gets nothing until somebody asks — so the
  builder's palette on those sites had no `doc-` components in it and there was no page to put them
  on. Workspaces, versions, sections and notes existed in the admin with no address a reader could
  reach them at. `ensure!/1` is that missing step, and it runs in production two ways:
  `MishkaCmsCore.Install.Extensions` fires `installer:extension:install`, MishkaDocument.Plugins.Installer
  answers to its own key, and this is what it runs. Two screens fire it: the install wizard, for the
  extensions an operator ticked, and the "Set up documentation pages" button on this extension's dashboard,
  for a site that already exists.

  ## Idempotent, and that is the whole design

  Running this twice must be indistinguishable from running it once, because both callers can run it
  again: an admin can press the button whenever they like, and the wizard and the button can both reach a site
  again.

    * **Components.** Only the ones the site has no row for at all — active or archived — are
      installed, through `selection: %{components: missing}`.
      `MishkaCmsCore.Runtime.Handlers.UiKitHandler.install_kit!/2` UPSERTS, so handing it a name the
      site already has would overwrite whatever the admin edited into it, silently. A component the
      admin archived stays archived for the same reason: it is there, and the admin put it where it
      is.
    * **Pages.** Only where every identity the page row has is free, which
      `MishkaCmsCore.Runtime.PageProvision` reads off the resource rather than this module naming
      them. A held ADDRESS is a page left to whoever holds it while the rest of the run happens; a
      held NAME is not — a site holding a page called "Documentation" at an address of its own gets
      `/:lang/docs` under the next free name and is told which. An archived page counts as holding
      both, which is stricter than the indexes are — they are partial on `(archived_at IS NULL)` —
      because a page an admin archived is an answer, not an absence.
    * **The snippet.** Only when nothing of that name is saved for this site's page editor.

  Nothing is ever updated, so nothing an author touched can be lost. What a site that was set up
  months ago does about the sample pages having moved on since is
  `MishkaCmsCore.Runtime.PageSamples`, behind the same card as the component update: it offers each
  outdated page as a DRAFT of itself, which the admin previews in the builder and publishes when
  they want it. `sample_pages/1` is what both read the pages from.

  WHICH MEANS A SITE PROVISIONED TODAY CAN GET PAGES NEWER THAN ITS COMPONENTS. The pages below are
  written against the bundle in this checkout, and a site that already has the components keeps the
  ones it has — so an attribute added to a component since that site was seeded reaches a row that
  does not declare it, and `MishkaCmsCore.Runtime.Compilers.ComponentCompiler` sweeps every
  undeclared key into the component's global attr: it is rendered onto the element as an HTML
  attribute, read by nothing, and the behaviour the page asked for is silently the old one. Such a
  site takes the newer components from the "Documentation components" card on the document
  dashboard, which is `MishkaCmsCore.Runtime.Handlers.UiKitUpgrade`: it says which rows are behind
  the bundle and which of them carry an edit, and writes only the ones the admin chooses. What it
  does NOT do is what `MishkaDocument.Kit.install!/1` does — upsert every component the bundle ships
  over whatever is there — and neither does the button here, because an admin asking for pages has
  not asked to lose an edit. `MishkaDocument.ProvisionTest` holds the templates and the bundle
  together; no test can see a row installed months ago.

  ## The pages, and why they look the way they do

  Three pattern pages in `/:lang` PATH mode, which is what seeded and starter content uses here:

      /:lang/docs                        every document the site publishes
      /:lang/docs/:workspace             one document's front page and its contents
      /:lang/docs/:workspace/*section    one page of it, with its notes — headless/switch for the
                                         page switch filed under headless (`MishkaDocument.Address`)

  A document given an address of its own is read there instead, on two pages of the same design
  written when the address is set — see `ensure_address!/3`.

  No static route in the host application's router answers any of them — the hand-written marketing
  the user keeps now sits under `mish-`, `/mish-chelekom/docs` and
  `/mish-cms/extensions/documentation` — and the `/:lang` prefix is what guarantees it stays that
  way. `MishkaCmsWeb.DocumentProvisionRoutesTest` derives the router's own list rather than
  repeating it here.

  The bare `/docs` is NOT provisioned, and the prefix is not what made it free: no static route
  ever answered `/docs`, which is why `MishkaCmsCore.Dev.Seeds` could already publish a page there.
  A row of ours could not fill the `:lang` segment the bases below are built from, so every link
  off it would name a language nobody asked for; and the address is the site's own to publish at.

  ONE ROW PER PAGE, not one per language. `:lang` is a capture, and `MishkaCmsCore.Runtime.Languages`
  admits only the site's own languages in it — so `/fa/docs` answers on a site that publishes Persian
  and falls through to the 404 on one that does not.

  ## One document, one URL

  Every block is given `lang={@page.language}` and a `params` map the language has been taken out
  of — the snippet included, on a page belonging to somebody else — which is one rule rather than
  two: a page's language is read off the page, and no block is left to find it in a query string.
  `MishkaCmsCore.Runtime.PageEditions.language/3` is what makes that one rule enough for a page this
  module has never seen: it is the `:lang` capture where the path has one and the page row's own
  language where it has none, so there is no page whose language a block has to guess at. A
  workspace slug belongs to ONE edition, so `/fa/docs/<an-english-slug>` draws "That page is not
  published." rather than the English document inside a Persian, right-to-left shell.

  Handing `@query_params` through whole would work today — `MishkaCmsWeb.RuntimeLive` merges the
  captured `lang` over the query string precisely so `/fa/docs?lang=xyz` cannot undo the check that
  let the page answer — but it would work by that precedence rather than by anything these pages
  say, and a block would then be taking its language from a key a visitor also writes. `lang_param`
  is left at its default, because on a base that names the language as a segment it decides nothing:
  `doc_href/5` carries the code in the path and writes no query key at all.

  The bases the blocks build links from keep the capture IN them — `doc_base="/:lang/docs"`, not
  `"/" <> @page.language <> "/docs"`. A component fills the `:lang` segment with the language of the
  ROW it is linking to, which is the language the reader will be reading in when they arrive, and
  builds the address the site's URL mode gives it (`site_path/2`,
  `MishkaCmsCore.Runtime.LiveViewHelpers`): `/docs/<slug>` in a first language the site leaves
  unprefixed, `/fa/docs/<slug>` in Persian. A base with the page's own language baked in would offer
  every translation under the language the reader is leaving.

  `base`, which only the index's pager has, stays a real URL: nothing appends a slug to it, and its
  `?page=2` has to be somewhere a reader could have typed.

  ## The header, the footer and the language nav are the layout's

  Every page below hangs on the site's `site-main` layout when the site has one, and
  draws only what the design shows between its header and its footer: the logo, the Docs and GitHub
  links, the sign-in menu, the dark-mode switch and the language switcher are `site-header`'s, and
  the footer is `site-footer`'s. The layout hands the header `@page_languages`, which is this same
  page's URL with the `lang` capture swapped and every OTHER capture kept as it was. On `/:lang/docs`
  that is exactly right, so the index draws no language links of its own. On the two document paths
  it is not: the `:workspace` and `:section` captures are slugs of one edition, and the Persian
  edition of a document has Persian slugs, so the header would offer `/fa/docs/<english-slug>`, a URL
  its own page answers as not published. `doc-switcher` is what those pages carry instead, in the
  bar under the header: it maps the document and the page being read to their translations by
  `language_group_id` and links to the slugs that edition really has.

  Every template stays inside what BOTH renderers assign: `@page`, `@query_params` and
  `@page_languages`. The admin's Preview tab assigns no visitor and no captures (see
  `MishkaCmsCore.Runtime.RuntimePreview`), which is why no URL here is built from a capture — only
  from `@page.language`, which a preview does assign.
  """

  require Ash.Query

  alias MishkaCmsCore.Runtime.ExtensionProvision
  alias MishkaDocument.Kit

  @section "document"
  @snippet_name "Latest documents"
  @layout_name "site-main"

  # THE DOCUMENTATION'S ADDRESSES, WRITTEN ONCE. A page's path, the base a block builds links to it
  # from and the URL the index's pager writes are all the same string — `/:lang/docs/:workspace` is
  # where a document is read, and `/:lang/docs` is both what a block appends that document's slug to
  # and where the index says it is — and they were eleven separate literals, three paths, six bases
  # and two URLs, each one its own chance to write a path this site does not answer.
  # The moduledoc above says why the `lang` capture stays IN a base rather than the page's own
  # language being written into it, and `live_url/1` is the other half of that: a URL nothing fills
  # in later carries the language the reader already has.
  @docs "/:lang/docs"
  @document "#{@docs}/:workspace"
  @document_page "#{@document}/*section"

  @typedoc "See `MishkaCmsCore.Runtime.ExtensionProvision.report/0`."
  @type report :: ExtensionProvision.report()

  # THE DOCUMENTATION'S OWN AREAS, created when it is installed — with its components and its
  # pages, not with the core's names — so a site that never installs it has none to grant.
  @permissions [
    {"admin:dashboard:document:*", "The whole document extension on the dashboard."},
    {"admin:dashboard:document:workspace",
     "Workspaces, their versions and lineage, other users' follows, the Home workspace form and the Workspace Versions screen."},
    {"admin:dashboard:document:section",
     "Sections, notes, drafts, tags, issues and issue comments, other users' bookmarks, section views, and their screens."},
    {"admin:api:document:*", "The whole document extension over the admin JSON:API."},
    {"admin:api:document:workspace", "Workspace, workspace version and version lineage routes."},
    {"admin:api:document:section", "Section, note, draft, tag, issue and issue comment routes."}
  ]

  @doc """
  What this extension declares about itself, for
  `MishkaCmsCore.Runtime.ExtensionProvision` — the bundle, the section its pages belong to, the
  pages themselves and the snippet.

  `pages` and `snippet.source` take the SITE because a stored `<.component>` call names the site
  whose component it draws, so the markup cannot be written until the site is known.
  """
  @spec manifest() :: ExtensionProvision.manifest()
  def manifest do
    %{
      app: :mishka_document,
      bundle_path: Kit.bundle_path(),
      section: @section,
      pages: &page_attrs_for/1,
      snippet: %{name: @snippet_name, source: &latest_documents/1},
      permissions: @permissions
    }
  end

  @doc """
  Gives `site` everything the documentation ships and it is missing, and returns what happened as
  `%{permissions: names, components: names, pages: paths, snippets: names, renamed_pages: renamed,
  skipped_pages: held}` — `permissions` empty once any site has installed it, the next three empty
  on a site that already has it all, `renamed_pages`
  naming every sample page written under a name of its own because the one it asked for was taken,
  and `skipped_pages` naming every one something already there holds, so the caller can say which
  rather than leave it to the logs.

  Takes the site record the hook is handed, or its id. Raises when the site is not there, or when a
  write is refused for any reason but a page being taken.

  `opts` takes `:actor` — whoever asked for this. Every row of the site is then written as them,
  through the action their own role may use, and the resource's policy answers for it; the
  permission names, shared by every site, are written by the system. Leave it out and the whole run
  writes as the system, which is what the installer wizard and the dev seeds do: they have no
  session behind them. See `MishkaCmsCore.Runtime.ExtensionProvision.ensure!/4`.
  """
  @spec ensure!(map() | String.t(), map(), keyword()) :: report()
  def ensure!(site, answers \\ %{}, opts \\ []),
    do: ExtensionProvision.ensure!(manifest(), site, answers, opts)

  @doc """
  Creates the documentation's permission names that are not stored yet, and returns the ones it created —
  for a site found already set up without a run (`MishkaCmsCore.Install.Extensions.installed?/2`).
  """
  @spec ensure_permissions() :: [String.t()]
  def ensure_permissions, do: ExtensionProvision.ensure_permissions(manifest())

  @doc "The component names this extension's bundle ships, read off the bundle itself."
  @spec component_names() :: [String.t()]
  def component_names, do: ExtensionProvision.component_names(manifest())

  @doc """
  The bundle version these pages are written against, stamped onto every page this writes.

  It is the KIT's version rather than the extension's: the pages and the components are one release
  together — a page drawing a component the site has not got renders an error where the block should
  be — and the kit is what `MishkaCmsCore.Runtime.Handlers.UiKitUpgrade` already versions.
  """
  @spec bundle_version() :: String.t() | nil
  def bundle_version, do: ExtensionProvision.bundle_version(manifest())

  @doc """
  The base the documents with no address of their own are read under, by their slug:
  `/:lang/docs`. A document's own address may not be under it (`MishkaDocument.Address.check/1`).
  """
  @spec docs_base() :: String.t()
  def docs_base, do: @docs

  @doc """
  Gives a document at `address` the two pages it is read at — its front page, and every page of it
  (`MishkaDocument.Address.page_paths/1`) — on `site`, where the site has no page at that path yet.
  A page the site already has at either path, its own design among them, is left as it is.

  Written as `opts[:actor]`, who needs what `MishkaCmsCore.Runtime.ExtensionProvision.required/1`
  names; leave it out and the system writes. Returns the report `ensure!/3` gives.
  """
  @spec ensure_address!(map() | String.t(), String.t(), keyword()) :: report()
  def ensure_address!(site, address, opts \\ []) do
    paths = Map.values(MishkaDocument.Address.page_paths(address))

    if held?(site_id_of(site), paths),
      do: %{
        version: bundle_version(),
        permissions: [],
        components: [],
        pages: [],
        snippets: [],
        renamed_pages: [],
        skipped_pages: paths
      },
      else: ExtensionProvision.ensure!(address_manifest(address), site, %{}, opts)
  end

  @doc """
  The names `actor` is missing to give a document at `address` its pages on `site_id` — `[]` when
  the site already has a page at both paths, so nothing would be written.
  """
  @spec address_permissions_missing(String.t(), String.t(), map() | nil) :: [String.t()]
  def address_permissions_missing(site_id, address, actor) do
    paths = Map.values(MishkaDocument.Address.page_paths(address))

    if held?(site_id, paths),
      do: [],
      else: ExtensionProvision.missing(address_manifest(address), actor)
  end

  defp site_id_of(%{id: site_id}), do: site_id
  defp site_id_of(site_id) when is_binary(site_id), do: site_id

  # Whether the site already has a page at every one of these paths.
  defp held?(site_id, paths) do
    held = site_id |> held_paths(paths) |> MapSet.new()
    Enum.all?(paths, &MapSet.member?(held, &1))
  end

  # THE PATHS OF THE SITE THAT A PAGE ALREADY ANSWERS, as the system: whether a page is there decides
  # what is asked of the writer, and has to be known whether or not they may read pages.
  defp held_paths(site_id, paths) do
    MishkaCmsCore.Runtime.Page
    |> Ash.Query.for_read(:master_read, %{}, authorize?: false)
    |> Ash.Query.filter(site_id == ^site_id and path in ^paths)
    |> Ash.Query.select([:path])
    |> Ash.read(authorize?: false, page: [limit: length(paths)])
    |> case do
      {:ok, %{results: rows}} -> Enum.map(rows, & &1.path)
      _unreadable -> []
    end
  end

  defp address_manifest(address) do
    %{
      app: :mishka_document,
      bundle_path: Kit.bundle_path(),
      section: @section,
      pages: &address_page_attrs_for(&1, address)
    }
  end

  defp address_page_attrs_for(%{name: site_name} = site, address) do
    paths = MishkaDocument.Address.page_paths(address)
    layout = layout_for(site)

    Enum.map(
      [
        %{
          name: "Document " <> address,
          title: "Document",
          path: paths.document,
          description: nil,
          extra: %{"record" => "docs:document"},
          format: :heex,
          template: document(site_name, address),
          active: true
        },
        %{
          name: "Document page " <> address,
          title: "Document page",
          path: paths.page,
          description: nil,
          extra: %{"record" => "docs:page"},
          format: :heex,
          template: document(site_name, address),
          active: true
        }
      ],
      &Map.merge(&1, layout)
    )
  end

  @doc "The paths of the sample pages, in the order they are created."
  @spec page_paths() :: [String.t()]
  def page_paths, do: Enum.map(page_definitions(), & &1.path)

  @doc """
  The paths of the two sample pages that read one document: `:workspace` its front page, `:section`
  one page of it. Each is filled with a document's language and slugs by
  `MishkaCmsCore.Runtime.Languages.url/3` — what `MishkaDocument.Plugins.SitemapUrls` lists.
  """
  @spec item_paths() :: %{workspace: String.t(), section: String.t()}
  def item_paths, do: %{workspace: @document, section: @document_page}

  @doc """
  The sample pages as this checkout ships them, as the attribute maps a page create takes.

  `ensure!/1` writes the ones the site has no row for; `MishkaCmsCore.Runtime.PageSamples` compares
  the same maps against the rows a site already has, which is how an admin is offered a newer
  version of a page they are already serving. Both read them from here, so the two can never be
  describing different pages.

  Takes the site record or its id, and the actor to read it as — `nil` for a caller with no session
  behind it.
  """
  @spec sample_pages(map() | String.t(), map() | nil) :: [map()]
  def sample_pages(site, actor \\ nil),
    do: ExtensionProvision.pages(manifest(), site, actor)

  @doc "What the snippet is called in the Studio's list."
  @spec snippet_name() :: String.t()
  def snippet_name, do: @snippet_name

  # THE PAGES THEMSELVES, which is the one thing only this extension knows. `section` and `site_id`
  # are put on by `ExtensionProvision`, so neither can disagree with the manifest or be forgotten.
  defp page_attrs_for(%{name: site_name} = site) do
    layout = layout_for(site)

    Enum.map(page_definitions(), fn definition ->
      Map.merge(
        %{
          name: definition.name,
          title: definition.title,
          path: definition.path,
          description: definition.description,
          extra: shows(definition),
          format: :heex,
          template: definition.template.(site_name),
          active: true
        },
        layout
      )
    end)
  end

  # THE LAYOUT THE PAGES ARE DRAWN IN, which is what gives them their header and footer: the site's
  # `site-main`, the one its home page hangs on (`MishkaCmsCore.Install.StarterContent`), when it
  # has one. The templates below draw only what sits between the two, so a page written with no
  # layout would have neither. A site installed without the starter content has no such layout and
  # gets the pages bare, which is all this can give it: the layout is core's to write, not an
  # extension's. Read as the system, because whether a layout is there decides what the page is,
  # whoever pressed the button.
  defp layout_for(site) do
    site_id = site_id_of(site)

    MishkaCmsCore.Runtime.Layout
    |> Ash.Query.for_read(:read_any, %{}, authorize?: false)
    |> Ash.Query.filter(site_id == ^site_id and name == ^@layout_name)
    |> Ash.Query.select([:id])
    |> Ash.read(authorize?: false, page: [limit: 1])
    |> case do
      {:ok, %{results: [%{id: layout_id}]}} -> %{layout_id: layout_id}
      _no_such_layout -> %{}
    end
  end

  # The kind of record a page shows, which `MishkaDocument.Plugins.PageSeo` answers for whatever
  # path the page is later given.
  defp shows(%{record: record}), do: %{"record" => record}
  defp shows(_shows_none), do: %{}

  # ---------------------------------------------------------------------------
  # The sample pages
  # ---------------------------------------------------------------------------

  defp page_definitions do
    [
      %{
        name: "Documentation",
        title: "Documentation",
        path: @docs,
        description: "Every document the site publishes, as cards",
        template: &index/1
      },
      %{
        name: "Document",
        title: "Document",
        path: @document,
        record: "docs:document",
        description: nil,
        template: &document/1
      },
      %{
        name: "Document page",
        title: "Document page",
        path: @document_page,
        record: "docs:page",
        description: nil,
        template: &document/1
      }
    ]
  end

  # THE LIBRARY, drawn between the layout's header and its footer: the hero, the search, the
  # documents flagged Featured as cards and the rest as rows. `doc-workspace-list` draws the search
  # and both groups, because the search narrows what it reads and the split is how it pages them:
  # `q` and `page` travel in `params`, so a page of results has an address of its own.
  #
  # `featured_text` is empty because the cards ARE the featured ones here, which is all the badge
  # would say; the language links are the layout's `site-header`, which `@page_languages` is right
  # for on this path.
  defp index(site) do
    """
    <div class="mx-auto w-full max-w-[1280px] flex-1 px-8 pb-24">
      <section class="flex flex-col items-center gap-4 pt-[72px] text-center">
        <span class="text-[12px] font-semibold tracking-[0.16em] text-subtle dark:text-subtle-dark">
          DOCUMENTATION
        </span>
        <h1 class="font-newsreader text-[clamp(44px,6vw,72px)] leading-none font-normal tracking-[-0.03em] text-balance">
          Everything, <em class="text-brand italic dark:text-[#a9a2f7]">written down</em>.
        </h1>
        <p class="max-w-[520px] text-[17px] leading-[1.6] text-dim dark:text-dim-dark">
          Guides, references and handbooks — versioned and available in several languages.
        </p>
      </section>

      <.component
        component_name="doc-workspace-list"
        site="#{site}"
        id="doc-index"
        current_user={assigns[:current_user]}
        live_visit={assigns[:live_visit] == true}
        heading=""
        lang={@page.language}
        per_page={12}
        sort="order"
        show_description={true}
        show_languages={true}
        show_details={true}
        show_search={true}
        split_featured={true}
        featured_text=""
        updated_text=""
        read_text="Open"
        doc_base="#{@docs}"
        base={#{live_url(@docs)}}
        params={Map.drop(@query_params, ["lang"])}
        empty_text="Nothing is published here yet."
      />
    </div>
    """
  end

  # ONE TEMPLATE FOR BOTH DOCUMENT PATHS, because they are one screen. `/:lang/docs/:workspace`
  # captures no `section`, so `doc-section` draws the document's overview and `doc-toc` — which
  # hides itself under two entries — draws nothing; every other block reads exactly the same URL on
  # both. Two paths rather than one `*rest` because `*rest` must match at least one segment (see
  # `MishkaCmsCore.Runtime.States.WebRunTimeMetaDataState`), so a front page would have no address.
  #
  # `params` is what carries `:workspace`, `:section` and `?v=` to all four blocks, which read them
  # by name out of that one map. The language is the one key taken out of it, for the reason the
  # moduledoc gives.
  #
  # THE FLEX ROW WRAPS RATHER THAN SWITCHING AT A BREAKPOINT, as the design's does: the contents
  # take 240px and the page 520px or more, so the contents sit above the page wherever the two
  # do not fit, and the on-this-page list beside the page wherever 200px more do. An empty list
  # takes no room: `doc-toc` draws nothing under two entries, and its wrapper is hidden then.
  defp document(site, address \\ nil) do
    """
    <div class="flex flex-1 flex-col">
      <div class="border-b border-edge dark:border-edge-dark">
        <div class="mx-auto w-full max-w-[1280px] px-8 py-3.5">
    #{indent(offered(site, {:switcher, address}), 6)}
        </div>
      </div>

      <div class="mx-auto w-full max-w-[1280px] flex-1 px-8 pb-24">
        <div class="flex flex-wrap items-start gap-12 pt-10">
          <aside class="max-h-[calc(100vh-3rem)] max-w-full flex-[0_0_240px] overflow-y-auto pb-6 min-[880px]:sticky min-[880px]:top-6">
            <.component
              component_name="doc-sidebar"
              site="#{site}"
              id="doc-contents"
              current_user={assigns[:current_user]}#{serves(address, 14)}
              heading=""
              lang={@page.language}
              doc_base="#{@docs}"
              params={Map.drop(@query_params, ["lang"])}
              show_filter={true}
            />
          </aside>

          <div class="flex min-w-0 flex-[1_1_520px] flex-wrap items-start gap-12">
            <div class="min-w-0 flex-[1_1_480px]">
              <.component
                component_name="doc-section"
                site="#{site}"
                id="doc-page"
                current_user={assigns[:current_user]}#{serves(address, 16)}
                crumb_current={true}
                lang={@page.language}
                doc_base="#{@docs}"
                params={Map.drop(@query_params, ["lang"])}
              />
            </div>

            <div class="sticky top-6 w-[200px] flex-none pt-4 [&:not(:has([data-role='doc-toc']>*))]:hidden">
              <.component
                component_name="doc-toc"
                site="#{site}"
                id="doc-on-this-page"
                current_user={assigns[:current_user]}#{serves(address, 16)}
                heading="ON THIS PAGE"
                lang={@page.language}
                doc_base="#{@docs}"
                params={Map.drop(@query_params, ["lang"])}
              />
            </div>
          </div>
        </div>
      </div>
    </div>
    """
  end

  # The block an author drops on a home page — the TODO's "last documents", which is this same
  # component cut to the few most recently changed. `lang={@page.language}` and a `params` map the
  # language has been taken out of, which is the SAME rule the three pages above follow, and it holds
  # here for the reason it holds there: `@page.language` is the `:lang` capture where the author's
  # page has one and the page row's own language where it has none — see
  # `MishkaCmsCore.Runtime.PageEditions.language/3` — so there is no page this block can land on
  # whose language it has to guess at. A `?lang=` left to decide instead would list English documents
  # on a Persian page, whose shell is drawn `<html lang="fa" dir="rtl">` from that same row.
  # `doc_base` carries the capture, so every card still links under its own document's language.
  defp latest_documents(site) do
    """
    <section data-role="doc-latest" class="rounded-[24px] border border-edge bg-surface p-5 sm:p-7 dark:border-edge-dark dark:bg-surface-dark">
      <.component
        component_name="doc-workspace-list"
        site="#{site}"
        id="doc-latest"
        current_user={assigns[:current_user]}
        heading="Latest documentation"
        per_page={3}
        sort="updated"
        show_description={true}
        show_details={true}
        show_pager={false}
        lang={@page.language}
        doc_base="#{@docs}"
        params={Map.drop(@query_params, ["lang"])}
        read_text="Read the docs"
        empty_text="Nothing is published here yet."
      />
    </section>
    """
  end

  # THE BAR UNDER THE LAYOUT'S HEADER ON A DOCUMENT'S PAGES: where the reader is (Docs, then the
  # document), the version being read and the languages the document is in. It is `doc-switcher`
  # rather than the header's own language switcher for the reason the moduledoc gives: the other
  # captures of these paths are one edition's slugs, and only the switcher knows what the next
  # edition calls them.
  defp offered(site, {:switcher, address}) do
    """
    <.component
      component_name="doc-switcher"
      site="#{site}"
      id="doc-switcher"
      current_user={assigns[:current_user]}#{serves(address, 6)}
      show="both"
      show_crumb={true}
      version_text=""
      lang={@page.language}
      doc_base="#{@docs}"
      params={Map.drop(@query_params, ["lang"])}
      show_banner={true}
    />
    """
  end

  # A PAGE AT A DOCUMENT'S OWN ADDRESS NAMES IT, so every block reads that document rather than one
  # a slug in the URL names, and writes no `?lang=`: the address is one edition's, and says which.
  defp serves(nil, _indent), do: ""

  defp serves(address, indent),
    do: "\n" <> String.duplicate(" ", indent) <> ~s|path="#{address}" lang_param=""|

  # ONE OF THE ADDRESSES ABOVE AS A URL A READER COULD HAVE TYPED, written as the `site_path/2` the
  # template calls: the `lang` capture filled in with the language this page is being read in, at
  # the address the site's URL mode gives it, which is what the index's pager and its search write
  # to the address bar.
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
