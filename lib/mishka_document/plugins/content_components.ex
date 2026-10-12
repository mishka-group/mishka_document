defmodule MishkaDocument.Plugins.ContentComponents do
  @moduledoc """
  Tells a site's stylesheet which components its documentation's text draws, through the
  `runtime:compile:content_components` hook
  `MishkaCmsCore.Runtime.Compilers.TailwindCompiler.content_components/1` fires while it builds a
  site's stylesheet: the names the site's approved pages and notes list in `content_components`,
  which `MishkaDocument.Resources.Changes.ContentFacts` stores when either is written. The kit's
  `doc-section`, which draws both with `rich_content`, then reaches those components
  (`MishkaCmsCore.Runtime.Compilers.CssClosure`).

  Read as the system, as the sitemap reads them (`MishkaDocument.Plugins.SitemapUrls`): a page
  locked to some readers draws its components for them, so it counts. Only the rows that name a
  component are read, and only that column. Registered in `MishkaDocument.Application`.
  """

  use MishkaInstaller.Event.Hook,
    event: "runtime:compile:content_components",
    initial: %{priority: 60}

  require Ash.Query

  alias MishkaCmsCore.Runtime.Compilers.SitemapCompiler
  alias MishkaDocument.{Note, Section}

  @impl true
  def call(%{site_id: site_id, components: names} = data)
      when is_binary(site_id) and is_list(names),
      do: {:reply, %{data | components: names ++ named(site_id)}}

  def call(data), do: {:reply, data}

  defp named(site_id) do
    [Section, Note]
    |> Stream.flat_map(fn resource ->
      resource
      |> Ash.Query.for_read(:public_list, %{}, tenant: site_id, authorize?: false)
      |> Ash.Query.filter(not is_nil(content_components))
      |> Ash.Query.select([:content_components])
      |> SitemapCompiler.stream_rows(tenant: site_id, authorize?: false)
      |> Stream.flat_map(& &1.content_components)
    end)
    |> Enum.uniq()
  end
end
