defmodule MishkaDocument.Plugins.PageRecords do
  @moduledoc """
  Names the kinds of record the documentation's pages show — a workspace's front page, one of its
  sections — on the `runtime:page:records` mishka_installer hook, for a page's "This page shows
  each" choice (see `MishkaCmsCore.Runtime.Seo.record_types/1`), each with a few of the site's own
  to preview a page with. Each is labelled as the Documents admin names it, where its Permissions
  and SEO Tags are set. `MishkaDocument.Plugins.PageSeo` answers for the same kinds.

  A module because a mishka_installer hook is one. Registered in `MishkaDocument.Application`.
  """

  use Gettext, backend: MishkaCmsCore.Gettext
  use MishkaInstaller.Event.Hook, event: "runtime:page:records", initial: %{priority: 50}

  alias MishkaCmsCore.Runtime.Languages
  alias MishkaDocument.{Section, Workspace}

  @samples 8

  @impl true
  def call(%{records: records} = state) when is_list(records),
    do: {:reply, %{state | records: records ++ types(Map.get(state, :site_id))}}

  def call(state), do: {:reply, state}

  @doc "The documentation's kinds of record for `site_id`, with its latest of each as samples."
  @spec types(String.t() | nil) :: [map()]
  def types(site_id) do
    [
      %{
        id: "docs:document",
        group: gettext("Documents"),
        label: gettext("Workspace"),
        captures: ["workspace"],
        samples: documents(site_id)
      },
      %{
        id: "docs:page",
        group: gettext("Documents"),
        label: gettext("Section"),
        captures: ["workspace", "section"],
        samples: pages(site_id)
      }
    ]
  end

  defp documents(site_id) when is_binary(site_id) do
    Workspace
    |> Ash.Query.for_read(:public_list, %{}, tenant: site_id, authorize?: false)
    |> Ash.Query.select([:name, :slug, :language])
    |> Ash.Query.sort(updated_at: :desc)
    |> Ash.read(tenant: site_id, authorize?: false, page: [limit: @samples])
    |> case do
      {:ok, %{results: rows}} ->
        for %{slug: slug, language: language} = row <- rows,
            is_binary(slug),
            do: sample(row.name, language, %{"workspace" => slug})

      _unreadable ->
        []
    end
  end

  defp documents(_no_site), do: []

  defp pages(site_id) when is_binary(site_id) do
    Section
    |> Ash.Query.for_read(:public_list, %{}, tenant: site_id, authorize?: false)
    |> Ash.Query.select([:title, :slug, :language, :workspace_version_id])
    |> Ash.Query.load(workspace_version: [workspace: [:slug]])
    |> Ash.Query.sort(updated_at: :desc)
    |> Ash.read(tenant: site_id, authorize?: false, page: [limit: @samples])
    |> case do
      {:ok, %{results: rows}} ->
        for %{slug: slug, language: language} = row <- rows,
            %{workspace: %{slug: workspace}} <- [row.workspace_version],
            is_binary(slug) and is_binary(workspace),
            do: sample(row.title, language, %{"workspace" => workspace, "section" => slug})

      _unreadable ->
        []
    end
  end

  defp pages(_no_site), do: []

  defp sample(name, language, captures),
    do: %{
      label: "#{name} · #{language}",
      params: Map.put(captures, Languages.capture(), language)
    }
end
