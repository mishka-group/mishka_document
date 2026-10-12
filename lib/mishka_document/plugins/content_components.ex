defmodule MishkaDocument.Plugins.ContentComponents do
  @moduledoc """
  Tells a site's stylesheet which components its documentation's text draws and which icons it
  names, through the `runtime:compile:content_components` hook
  `MishkaCmsCore.Runtime.Compilers.TailwindCompiler.content_components/1` fires while it builds a
  site's stylesheet: the names the site's approved pages and notes list in `content_components`,
  and the icon classes they list in `content_icons`, which
  `MishkaDocument.Resources.Changes.ContentFacts` stores when either is written. The kit's
  `doc-section`, which draws both with `rich_content`, then reaches those components
  (`MishkaCmsCore.Runtime.Compilers.CssClosure`), and the stylesheet carries a rule for each icon.

  Read as the system, as the sitemap reads them (`MishkaDocument.Plugins.SitemapUrls`): a page
  locked to some readers draws its components and icons for them, so it counts. Only the rows that
  name a component or an icon are read, and only those columns. Registered in
  `MishkaDocument.Application`.
  """

  use MishkaInstaller.Event.Hook,
    event: "runtime:compile:content_components",
    initial: %{priority: 60}

  require Ash.Query

  alias MishkaCmsCore.Runtime.Compilers.SitemapCompiler
  alias MishkaDocument.{Note, Section}

  @impl true
  def call(%{site_id: site_id, components: names, icons: icons} = data)
      when is_binary(site_id) and is_list(names) and is_list(icons) do
    {named, shown} = stored(site_id)

    {:reply, %{data | components: names ++ named, icons: icons ++ shown}}
  end

  def call(data), do: {:reply, data}

  # The component names and the icons, each once, in one read of each resource.
  defp stored(site_id) do
    [Section, Note]
    |> Stream.flat_map(fn resource ->
      resource
      |> Ash.Query.for_read(:public_list, %{}, tenant: site_id, authorize?: false)
      |> Ash.Query.filter(not is_nil(content_components) or not is_nil(content_icons))
      |> Ash.Query.select([:content_components, :content_icons])
      |> SitemapCompiler.stream_rows(tenant: site_id, authorize?: false)
    end)
    |> Enum.reduce({MapSet.new(), MapSet.new()}, fn row, {named, shown} ->
      {Enum.into(row.content_components || [], named), Enum.into(row.content_icons || [], shown)}
    end)
    |> then(fn {named, shown} -> {MapSet.to_list(named), MapSet.to_list(shown)} end)
  end
end
