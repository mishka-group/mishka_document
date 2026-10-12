defmodule MishkaDocument.Plugins.PageSeo do
  @moduledoc """
  Gives each document and each page of one its own head on the documentation page that serves it,
  through the `runtime:page:seo` mishka_installer hook `MishkaCmsWeb.RuntimeLive` fires in
  `handle_params/3` (see `MishkaCmsCore.Runtime.Seo` for the map it is handed and what the head
  builds from it).

  A page is matched by the kind of record it says it shows (`record`, its `extra`'s `"record"`):
  `"docs:document"`, a document's front page, or `"docs:page"`, one page of a document — the kinds
  `MishkaDocument.Plugins.PageRecords` names. Its path is a document's own address,
  `/chelekom/docs` and `/chelekom/docs/*section` (`MishkaDocument.Address`), which names that
  document; or anything that captures `workspace`, and `*section` for a page, whose slug names a
  document with no address of its own. Every other page is handed back untouched before anything
  is read. A kind has one owner, so the answer
  for one of these halts the chain: no later plugin is asked.

  ## What is read

  One read, through `:public_list` as `doc-section` reads it, on the page's site, as the system: the
  active document whose own address the page is at, else the one the `workspace` capture names, in
  the page's language. A slug names only a document with no address of its own: one that has an
  address is read there and nowhere else, so `/docs/<its slug>` names nothing. For one of its pages it brings its published versions and, in each, the approved
  pages as a tree; the version shown is the one `?v=` names, else the one marked latest, else the
  newest published, and the page is the one at the address the `section` capture holds —
  `headless/switch` — read once more for its own text and lock. A version's front page is at the
  document's own address and nowhere under it (`MishkaDocument.Address`), so a `section` naming its
  slug names nothing.

  ## What it returns

  Every value is a default: what the page sets in its own SEO — a title, a description, a tag,
  structured data — wins, and may name the variables below, `{{doc.title}} · {{workspace.name}}`.

    * `title`, `description` — the document's name and description on its front page, whether it
      draws the page its version marks as its front page there or the landing; the page's title and
      the start of its text on one of its pages;
    * `type` — `"article"`;
    * `tags` — the document's or the page's own `seo_tags`; a page that holds no robots meta of its
      own takes its document's, as a CMS page takes its layout's;
    * `schema` — its own `schema` when it holds one, else a `TechArticle`; then a
      `BreadcrumbList`, Documentation → the document → the page;
    * `url` — the canonical address: the document's own address where it has one, with the page's
      under it, so the head names the one address a reader and a crawler are sent to; else the
      address asked;
    * `vars` — `doc.title`, `doc.description`, `doc.url`, `doc.version`, `doc.published_at`,
      `doc.modified_at` (the front page or the page of it this address shows), and
      `workspace.name`, `workspace.description`, `workspace.url` (the document);
    * `card` — what its share card (`MishkaCmsCore.Runtime.ShareCard`) shows besides the title and
      description: "Documentation" above a document's front page, the document's name above one of
      its pages, and the version;
    * `var_docs` — those variables in the current locale, whether or not this request filled them.
      Called with no `params` — an editor asking which variables a page has — that is all it
      changes.

  `permissions` is not a default: the document's on its front page; on one of its pages, the page's
  own, else its nearest parent page's, else its document's
  (`MishkaDocument.Resources.Calculations.EffectivePermissions`). `MishkaCmsWeb.RuntimeLive` opens
  the address only for whoever holds one of them, after the page's own, and the head keeps it out
  of an index. That is why the read is the system's: a read as the visitor would leave a locked
  record out for exactly the visitor the page has to refuse.

  A capture that names nothing a reader may open changes nothing else, and the page answers 404 as
  it does without this. A note is drawn inside its page and has no address of its own, so its own
  SEO is not read here.

  A module because a mishka_installer hook is one. Registered in `MishkaDocument.Application`.
  """

  use Gettext, backend: MishkaCmsCore.Gettext
  use MishkaInstaller.Event.Hook, event: "runtime:page:seo", initial: %{priority: 60}

  require Ash.Query

  alias MishkaCmsCore.Runtime.{Languages, Seo}
  alias MishkaCmsCore.Settings
  alias MishkaDocument.{Address, Provision, Section, Workspace, WorkspaceVersion}

  @workspace_fields [
    :id,
    :name,
    :slug,
    :path,
    :description,
    :language,
    :seo_tags,
    :schema,
    :permissions,
    :inserted_at,
    :updated_at
  ]

  @version_fields [
    :id,
    :workspace_id,
    :version_number,
    :is_latest_for_version,
    :published_at,
    :inserted_at
  ]

  @section_fields [
    :id,
    :workspace_version_id,
    :title,
    :slug,
    :content,
    :seo_tags,
    :schema,
    :permissions,
    :inserted_at,
    :updated_at
  ]

  # How much of a page's text its description takes.
  @summary 160

  @impl true
  def call(%{record: "docs:document"} = seo), do: {:reply, :halt, front_page(seo)}
  def call(%{record: "docs:page"} = seo), do: {:reply, :halt, document_page(seo)}
  def call(seo), do: {:reply, seo}

  defp front_page(seo) do
    seo = %{seo | var_docs: docs()}

    case read(seo, []) do
      %Workspace{} = workspace ->
        answer(seo, workspace, %{
          page?: false,
          segments: [],
          title: workspace.name,
          description: workspace.description,
          version: nil,
          published: workspace.inserted_at,
          modified: workspace.updated_at,
          seo_tags: workspace.seo_tags,
          schema: workspace.schema,
          permissions: workspace.permissions
        })

      nil ->
        seo
    end
  end

  defp document_page(%{params: params} = seo) do
    seo = %{seo | var_docs: docs()}

    with wanted when is_binary(wanted) and wanted != "" <- params["section"],
         %Workspace{} = workspace <- read(seo, versions: versions()),
         {version, tree} <- shown(workspace.versions, params["v"]),
         %{id: id} = page <- Address.page_at(tree, wanted),
         %Section{} = section <- section(id, seo.site_id) do
      answer(seo, workspace, %{
        page?: true,
        segments: Map.get(Address.paths(tree), page.id, []),
        title: section.title,
        description: summary(section.content),
        version: version.version_number,
        published: version.published_at || section.inserted_at,
        modified: section.updated_at,
        seo_tags: page_tags(section.seo_tags, workspace.seo_tags),
        schema: section.schema,
        permissions: section.effective_permissions
      })
    else
      _nothing_shown -> seo
    end
  end

  # The document whose own address the page is at, else the one with no address of its own the
  # `workspace` capture names, in the page's language, on the page's site; `nil` when the request
  # names none or none is shown. Read as the system, because what it reads is the lock
  # `MishkaCmsWeb.RuntimeLive` admits the visitor by: read as a visitor who may not open it, a locked
  # document or page is no record at all, and the page is handed no permissions to refuse them with.
  # The hook names no visitor either, and the head built here reaches only a visitor the page
  # admitted.
  defp read(%{site_id: site_id} = seo, loads) when is_binary(site_id),
    do: Enum.find_value(own_address(seo) ++ by_slug(seo), &read(&1, seo, loads))

  defp read(_seo, _loads), do: nil

  defp own_address(%{page: %{path: path}}) do
    case Address.of_page(path) do
      nil -> []
      address -> [{:path, address}]
    end
  end

  defp own_address(_seo), do: []

  defp by_slug(%{params: %{"workspace" => slug}}) when is_binary(slug) and slug != "",
    do: [{:slug, slug}]

  defp by_slug(_seo), do: []

  defp read(named, %{site_id: site_id} = seo, loads) do
    Workspace
    |> Ash.Query.for_read(:public_list, %{}, tenant: site_id, authorize?: false)
    |> named_by(named)
    |> in_language(seo.language)
    |> Ash.Query.select(@workspace_fields)
    |> Ash.Query.load(loads)
    |> Ash.read(tenant: site_id, authorize?: false, page: [limit: 1])
    |> case do
      {:ok, %{results: [workspace | _rest]}} -> workspace
      _none -> nil
    end
  end

  defp named_by(query, {:slug, slug}),
    do: Ash.Query.filter(query, slug == ^slug and is_nil(path))

  defp named_by(query, {:path, address}), do: Ash.Query.filter(query, path == ^address)

  defp in_language(query, language) when is_binary(language) and language != "",
    do: Ash.Query.filter(query, language == ^language)

  defp in_language(query, _no_language), do: query

  # Every published version, each with its approved pages as a tree — what a page's address is
  # followed through (`MishkaDocument.Address.page_at/2`).
  defp versions do
    WorkspaceVersion
    |> Ash.Query.select(@version_fields)
    |> Ash.Query.load(
      sections: Ash.Query.select(Section, [:id, :slug, :parent_section_id, :front_page])
    )
  end

  # The version a reader is shown — the one `asked` names, else the one marked latest, else the
  # newest published — and its pages, or `nil` when there is none.
  defp shown(versions, asked) do
    newest = Enum.sort_by(versions, &{moment(&1.published_at), moment(&1.inserted_at)}, :desc)

    version =
      Enum.find(newest, &(&1.version_number == asked)) ||
        Enum.find(newest, & &1.is_latest_for_version) || List.first(newest)

    case version do
      %WorkspaceVersion{sections: pages} when is_list(pages) -> {version, pages}
      _none -> nil
    end
  end

  # The page shown, with its text and its lock, read as the system for the reason `read/3` gives.
  defp section(id, site_id) do
    Section
    |> Ash.Query.for_read(:public_list, %{}, tenant: site_id, authorize?: false)
    |> Ash.Query.filter(id == ^id)
    |> Ash.Query.select(@section_fields)
    |> Ash.Query.load(:effective_permissions)
    |> Ash.read(tenant: site_id, authorize?: false, page: [limit: 1])
    |> case do
      {:ok, %{results: [section | _rest]}} -> section
      _none -> nil
    end
  end

  defp moment(%DateTime{} = at), do: DateTime.to_unix(at, :microsecond)
  defp moment(_never), do: 0

  # What a share card (`MishkaCmsCore.Runtime.ShareCard`) shows of it: "Documentation" above a
  # document's front page, the document's name above one of its pages, and the version.
  defp card(workspace, %{page?: true} = record),
    do: %{eyebrow: workspace.name, meta: version(record)}

  defp card(_workspace, record), do: %{eyebrow: gettext("Documentation"), meta: version(record)}

  defp version(%{version: version}) when is_binary(version) and version != "",
    do: [gettext("Version %{version}", version: version)]

  defp version(_no_version), do: []

  defp answer(seo, workspace, record) do
    base = base(seo)
    docs_url = edition_url(Provision.docs_base(), workspace, seo, base)
    workspace_url = document_url(workspace, [], seo, base)
    seo = %{seo | url: document_url(workspace, record.segments, seo, base) || seo.url}
    published = iso8601(record.published)
    modified = iso8601(record.modified)

    article =
      compact(%{
        "@context" => "https://schema.org",
        "@type" => "TechArticle",
        "headline" => record.title,
        "description" => record.description,
        "datePublished" => published,
        "dateModified" => modified,
        "version" => record.version,
        "inLanguage" => workspace.language,
        "mainEntityOfPage" => seo.url,
        "publisher" => publisher(seo.site_id, base)
      })

    trail = [
      {gettext("Documentation"), docs_url},
      {workspace.name, workspace_url},
      record.page? && {record.title, seo.url}
    ]

    %{
      seo
      | title: record.title,
        description: record.description,
        type: "article",
        language: workspace.language,
        tags: List.wrap(record.seo_tags),
        schema: own_schema(record.schema, article) ++ breadcrumb(trail),
        permissions: List.wrap(record.permissions),
        card: card(workspace, record),
        vars:
          Map.merge(
            seo.vars,
            compact(%{
              "doc.title" => record.title,
              "doc.description" => record.description,
              "doc.url" => seo.url,
              "doc.version" => record.version,
              "doc.published_at" => published,
              "doc.modified_at" => modified,
              "workspace.name" => workspace.name,
              "workspace.description" => workspace.description,
              "workspace.url" => workspace_url
            })
          )
    }
  end

  # A `BreadcrumbList` of each `{name, address}` that has an address; nothing when none has.
  defp breadcrumb(trail) do
    case Enum.filter(trail, &match?({_name, item} when is_binary(item), &1)) do
      [] ->
        []

      items ->
        [
          %{
            "@context" => "https://schema.org",
            "@type" => "BreadcrumbList",
            "itemListElement" =>
              items
              |> Enum.with_index(1)
              |> Enum.map(fn {{name, item}, position} ->
                %{"@type" => "ListItem", "position" => position, "name" => name, "item" => item}
              end)
          }
        ]
    end
  end

  # The record's own JSON-LD, else the one built for it.
  defp own_schema([_ | _] = own, _built), do: own
  defp own_schema(_none, built), do: [built]

  # A page's own tags, with its document's robots meta when it holds none of its own.
  defp page_tags(own, document) do
    case robots(own) do
      [] -> List.wrap(own) ++ robots(document)
      _own_robots -> List.wrap(own)
    end
  end

  defp robots(tags),
    do: tags |> Seo.stored_tags() |> Enum.filter(&match?(%{id: "robots"}, Seo.entry_of(&1)))

  # THE ADDRESS OF A DOCUMENT, OR OF ONE OF ITS PAGES, on `base`: under its own address where it has
  # one, which is then the one canonical address of it wherever it was asked for; under the
  # documentation's base by its slug where it has not — the address asked, filled as the page fills
  # it.
  defp document_url(%{path: own} = workspace, segments, seo, base)
       when is_binary(own) and own != "",
       do: edition_url(Enum.join([own | segments], "/"), workspace, seo, base)

  defp document_url(workspace, [], %{params: params, site_id: site_id}, base) do
    Provision.item_paths().workspace
    |> Languages.url(
      params
      |> Map.take([Languages.capture()])
      |> Map.merge(%{"lang" => workspace.language, "workspace" => workspace.slug}),
      site_id
    )
    |> Seo.absolute(base)
  end

  defp document_url(_workspace, _segments, _seo, _base), do: nil

  # `path` in the language of the edition being described, at the address the site's URL mode gives
  # it, on `base`.
  defp edition_url(path, workspace, %{site_id: site_id}, base),
    do: path |> Languages.url(%{"lang" => workspace.language}, site_id) |> Seo.absolute(base)

  defp publisher(site_id, base) do
    case Settings.get("site.title", nil, site_id) do
      name when is_binary(name) and name != "" ->
        compact(%{"@type" => "Organization", "name" => name, "url" => base})

      _no_title ->
        nil
    end
  end

  # The start of a page's text, without its markup.
  defp summary(html) when is_binary(html) do
    text =
      html
      |> String.replace(~r/<[^>]*>/, " ")
      |> String.replace(["&nbsp;", "&lt;", "&gt;", "&quot;", "&#39;", "&amp;"], fn
        "&nbsp;" -> " "
        "&lt;" -> "<"
        "&gt;" -> ">"
        "&quot;" -> "\""
        "&#39;" -> "'"
        "&amp;" -> "&"
      end)
      |> String.replace(~r/\s+/u, " ")
      |> String.trim()

    cond do
      text == "" -> nil
      String.length(text) <= @summary -> text
      true -> String.slice(text, 0, @summary - 1) |> String.trim_trailing() |> Kernel.<>("…")
    end
  end

  defp summary(_no_text), do: nil

  # The address of the site the canonical address is on, as `Seo.base/1` writes it.
  defp base(%{url: url}) when is_binary(url),
    do: url |> URI.parse() |> Map.get(:host) |> Seo.base()

  defp base(_no_url), do: nil

  defp iso8601(%DateTime{} = at), do: at |> DateTime.truncate(:second) |> DateTime.to_iso8601()
  defp iso8601(_never), do: nil

  defp compact(map), do: Map.reject(map, fn {_key, value} -> value in [nil, "", []] end)

  defp docs do
    [
      var(
        "doc.title",
        gettext("Page title"),
        gettext("The document's name on its front page, the page's title on one of its pages.")
      ),
      var(
        "doc.description",
        gettext("Page summary"),
        gettext("The document's description, or the start of the page's text.")
      ),
      var("doc.url", gettext("Page address"), gettext("This page's canonical address.")),
      var(
        "doc.version",
        gettext("Version"),
        gettext("The version this page is shown from. Empty on a document's front page.")
      ),
      var(
        "doc.published_at",
        gettext("Published"),
        gettext("When this was first published, as an ISO 8601 date.")
      ),
      var(
        "doc.modified_at",
        gettext("Modified"),
        gettext("When this page last changed, as an ISO 8601 date.")
      ),
      var("workspace.name", gettext("Document name"), gettext("The name of the document.")),
      var(
        "workspace.description",
        gettext("Document description"),
        gettext("The document's description.")
      ),
      var(
        "workspace.url",
        gettext("Document address"),
        gettext("The address of the document's front page.")
      )
    ]
  end

  defp var(key, label, help), do: %{key: key, label: label, help: help}
end
