# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_document/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaDocument.Plugins.ContentComponents do
  @moduledoc """
  Tells a site's stylesheet which components its documentation's text draws, which icons it names
  and which classes it writes, through the `runtime:compile:content_components` hook
  `MishkaCmsCore.Runtime.Compilers.TailwindCompiler.content_components/1` fires while it builds a
  site's stylesheet: the names the site's approved pages and notes list in `content_components`,
  the icon classes they list in `content_icons` and the classes they list in `content_classes`,
  which `MishkaDocument.Resources.Changes.ContentFacts` stores when either is written. The kit's
  `doc-section`, which draws both with `rich_content`, then reaches those components
  (`MishkaCmsCore.Runtime.Compilers.CssClosure`), the stylesheet carries a rule for each icon, and
  it is built with each class.

  Read as the system, as the sitemap reads them (`MishkaDocument.Plugins.SitemapUrls`): a page
  locked to some readers draws its components, icons and classes for them, so it counts. Only the
  rows that name a component, an icon or a class are read, and only those columns.

  And the block only the bar under the header draws, `doc-switcher`
  (`MishkaDocument.Plugins.PageFrame`): no page or layout names it, so nothing else would bring its
  classes into the stylesheet. Registered in MishkaDocument.Application.
  """

  use MishkaInstaller.Event.Hook,
    event: "runtime:compile:content_components",
    initial: %{priority: 60}

  require Ash.Query

  alias MishkaCmsCore.Runtime.Compilers.SitemapCompiler
  alias MishkaDocument.{Note, Section}
  alias MishkaDocument.Plugins.PageFrame

  @impl true
  def call(%{site_id: site_id, components: names, icons: icons} = data)
      when is_binary(site_id) and is_list(names) and is_list(icons) do
    found = stored(site_id)

    {:reply,
     data
     |> Map.merge(%{
       components: names ++ found.components ++ PageFrame.bar_components(),
       icons: icons ++ found.icons
     })
     |> with_classes(found.classes)}
  end

  def call(data), do: {:reply, data}

  defp with_classes(%{classes: classes} = data, found) when is_list(classes),
    do: %{data | classes: classes ++ found}

  defp with_classes(data, _found), do: data

  @facts [:content_components, :content_icons, :content_classes]

  # The component names, the icons and the classes, each once, in one read of each resource.
  defp stored(site_id) do
    [Section, Note]
    |> Stream.flat_map(fn resource ->
      resource
      |> Ash.Query.for_read(:public_list, %{}, tenant: site_id, authorize?: false)
      |> Ash.Query.filter(
        not is_nil(content_components) or not is_nil(content_icons) or
          not is_nil(content_classes)
      )
      |> Ash.Query.select(@facts)
      |> SitemapCompiler.stream_rows(tenant: site_id, authorize?: false)
    end)
    |> Enum.reduce({MapSet.new(), MapSet.new(), MapSet.new()}, fn row, {named, shown, written} ->
      {Enum.into(row.content_components || [], named), Enum.into(row.content_icons || [], shown),
       Enum.into(row.content_classes || [], written)}
    end)
    |> then(fn {named, shown, written} ->
      %{
        components: MapSet.to_list(named),
        icons: MapSet.to_list(shown),
        classes: MapSet.to_list(written)
      }
    end)
  end
end
