defmodule MishkaDocument.Plugins.PageSeo do
  @moduledoc """
  Gives each document and each page of one its own head on the documentation page that serves it,
  through the `runtime:page:seo` mishka_installer hook `MishkaCmsWeb.RuntimeLive` fires in
  `handle_params/3` (see `MishkaCmsCore.Runtime.Seo` for the map it is handed and what the head
  builds from it).

  A page is matched by the kind of record it says it shows (`record`, its `extra`'s `"record"`):
  `"docs:document"`, a document's front page, or `"docs:page"`, one page of a document — the kinds
  `MishkaDocument.Plugins.PageRecords` names. Its path may be anything that captures `workspace`,
  and `section` for a page. Every other page is handed back untouched before anything is read. A
  kind has one owner, so the answer for one of these halts the chain: no later plugin is asked.

  ## What is read

  One read, through `:public_list` as `doc-section` reads it, on the page's site: the active
  document the `workspace` capture names in the page's language. On `/:lang/docs/:workspace/:section`
  it brings its published versions and, in each, the approved page the `section` capture names; the
  page shown is the one in the version `?v=` names, else in the version marked latest, else in the
  newest published one.

  ## What it returns

  Every value is a default: what the page sets in its own SEO — a title, a description, a tag,
  structured data — wins, and may name the variables below, `{{doc.title}} · {{workspace.name}}`.

    * `title`, `description` — the document's name and description on its front page; the page's
      title and the start of its text on one of its pages;
    * `type` — `"article"`;
    * `tags` — the document's or the page's own `seo_tags`; a page that holds no robots meta of its
      own takes its document's, as a CMS page takes its layout's;
    * `schema` — its own `schema` when it holds one, else a `TechArticle`; then a
      `BreadcrumbList`, Documentation → the document → the page;
    * `vars` — `doc.title`, `doc.description`, `doc.url`, `doc.version`, `doc.published_at`,
      `doc.modified_at` (the front page or the page of it this address shows), and
      `workspace.name`, `workspace.description`, `workspace.url` (the document);
    * `var_docs` — those variables in the current locale, whether or not this request filled them.
      Called with no `params` — an editor asking which variables a page has — that is all it
      changes.

  `permissions` is not a default: the document's on its front page; on one of its pages, the page's
  own, else its nearest parent page's, else its document's
  (`MishkaDocument.Resources.Calculations.EffectivePermissions`). `MishkaCmsWeb.RuntimeLive` opens
  the address only for whoever holds one of them, after the page's own, and the head keeps it out
  of an index.

  A capture that names nothing a reader may open changes nothing else, and the page answers 404 as
  it does without this. A note is drawn inside its page and has no address of its own, so its own
  SEO is not read here.

  A module because a mishka_installer hook is one. Registered in `MishkaDocument.Application`.
  """

  use Gettext, backend: MishkaCmsCore.Gettext
  use MishkaInstaller.Event.Hook, event: "runtime:page:seo", initial: %{priority: 60}

  require Ash.Query

  alias MishkaCmsCore.Runtime.{Languages, PageEditions, Seo}
  alias MishkaCmsCore.Settings
  alias MishkaDocument.{Provision, Section, Workspace, WorkspaceVersion}

  @workspace_fields [
    :id,
    :name,
    :slug,
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

    with slug when is_binary(slug) and slug != "" <- params["section"],
         %Workspace{} = workspace <- read(seo, versions: versions(slug)),
         {version, %Section{} = section} <- shown(workspace.versions, params["v"]) do
      answer(seo, workspace, %{
        page?: true,
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

  # The document the `workspace` capture names, in the page's language, on the page's site; `nil`
  # when the request names none or none is shown.
  defp read(%{params: %{"workspace" => slug}, site_id: site_id} = seo, loads)
       when is_binary(slug) and slug != "" and is_binary(site_id) do
    Workspace
    |> Ash.Query.for_read(:public_list, %{}, tenant: site_id, authorize?: false)
    |> Ash.Query.filter(slug == ^slug)
    |> in_language(seo.language)
    |> Ash.Query.select(@workspace_fields)
    |> Ash.Query.load(loads)
    |> Ash.read(tenant: site_id, authorize?: false, page: [limit: 1])
    |> case do
      {:ok, %{results: [workspace | _rest]}} -> workspace
      _none -> nil
    end
  end

  defp read(_seo, _loads), do: nil

  defp in_language(query, language) when is_binary(language) and language != "",
    do: Ash.Query.filter(query, language == ^language)

  defp in_language(query, _no_language), do: query

  # Every published version, each with its approved page under `slug`.
  defp versions(slug) do
    WorkspaceVersion
    |> Ash.Query.select(@version_fields)
    |> Ash.Query.load(
      sections:
        Section
        |> Ash.Query.filter(slug == ^slug)
        |> Ash.Query.select(@section_fields)
        |> Ash.Query.load(:effective_permissions)
    )
  end

  # The version a reader is shown — the one `asked` names, else the one marked latest, else the
  # newest published — and its page, or `nil` when it has none.
  defp shown(versions, asked) do
    newest = Enum.sort_by(versions, &{moment(&1.published_at), moment(&1.inserted_at)}, :desc)

    version =
      Enum.find(newest, &(&1.version_number == asked)) ||
        Enum.find(newest, & &1.is_latest_for_version) || List.first(newest)

    case version do
      %WorkspaceVersion{sections: [section | _rest]} -> {version, section}
      _none -> nil
    end
  end

  defp moment(%DateTime{} = at), do: DateTime.to_unix(at, :microsecond)
  defp moment(_never), do: 0

  defp answer(seo, workspace, record) do
    base = base(seo)
    docs_url = address(Path.dirname(Provision.item_paths().workspace), seo, base)
    workspace_url = address(Provision.item_paths().workspace, seo, base)
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

  # `path` filled with this request's captures, on `base`.
  defp address(path, %{params: params}, base),
    do:
      path
      |> PageEditions.path(Map.take(params, [Languages.capture(), "workspace"]))
      |> Seo.absolute(base)

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
