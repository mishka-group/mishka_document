# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_document/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaDocument.Resources.Calculations.BreadcrumbPath do
  @moduledoc """
  The ancestors of a section, root first and its immediate parent last, each as a map of
  `"id"`, `"title"` and `"slug"`. A section with no parent has `[]`.

  The ancestors are read as whoever asked for the calculation, in the site of the section, one
  `MishkaDocument.Section` read for each level of the tree: a parent that is archived, or that the
  reader may not read, ends the path where it stands. A section whose parent pointer leaves its
  site, or loops back, ends it there too.

      calculate :breadcrumb_path, {:array, :map}, BreadcrumbPath
  """
  use Ash.Resource.Calculation

  require Ash.Query

  alias MishkaDocument.Section

  @impl true
  def load(_query, _opts, _context), do: [:id, :site_id, :parent_section_id]

  @impl true
  def calculate(sections, _opts, context) do
    paths =
      sections
      |> Enum.filter(& &1.parent_section_id)
      |> Enum.group_by(& &1.site_id)
      |> Enum.reduce(%{}, fn {site_id, found}, paths ->
        Map.merge(paths, paths_in(site_id, found, context))
      end)

    Enum.map(sections, &Map.get(paths, &1.id, []))
  end

  defp paths_in(site_id, sections, context) do
    ancestors = read_up(site_id, Enum.map(sections, & &1.parent_section_id), %{}, context)

    Map.new(sections, &{&1.id, path(&1.parent_section_id, ancestors, [], [])})
  end

  # Walks from the parent upward, putting each ancestor in front of the ones already found.
  defp path(nil, _ancestors, found, _seen), do: found

  defp path(id, ancestors, found, seen) do
    with false <- id in seen,
         {:ok, %{} = ancestor} <- Map.fetch(ancestors, id) do
      crumb = %{"id" => ancestor.id, "title" => ancestor.title, "slug" => ancestor.slug}
      path(ancestor.parent_section_id, ancestors, [crumb | found], [id | seen])
    else
      _end_of_path -> found
    end
  end

  # Every ancestor of `ids` by id, `nil` for an id that is not there to read.
  defp read_up(site_id, ids, ancestors, context) do
    case ids
         |> Enum.reject(&is_nil/1)
         |> Enum.uniq()
         |> Enum.reject(&Map.has_key?(ancestors, &1)) do
      [] ->
        ancestors

      wanted ->
        case read(site_id, wanted, context) do
          {:ok, rows} ->
            ancestors =
              Enum.reduce(rows, Map.merge(ancestors, Map.new(wanted, &{&1, nil})), fn row, acc ->
                Map.put(acc, row.id, row)
              end)

            read_up(site_id, Enum.map(rows, & &1.parent_section_id), ancestors, context)

          {:error, _refused} ->
            ancestors
        end
    end
  end

  defp read(site_id, ids, context) do
    Section
    |> Ash.Query.filter(id in ^ids)
    |> Ash.Query.select([:id, :title, :slug, :parent_section_id])
    |> Ash.read(Keyword.put(Ash.Scope.to_opts(context, tenant: site_id), :page, false))
  end
end
