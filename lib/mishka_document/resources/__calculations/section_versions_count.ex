# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_document/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaDocument.Resources.Calculations.SectionVersionsCount do
  @moduledoc """
  How many versions a section has: the sections of its own site that share its
  `section_lineage_id`, itself included. A section with no lineage, or one the reader cannot
  read the lineage of, counts as `1`.

  The count is read as whoever asked for the calculation, in the site of the section.

      calculate :section_versions_count, :integer, SectionVersionsCount
  """
  use Ash.Resource.Calculation

  require Ash.Query

  alias MishkaDocument.Section

  @impl true
  def load(_query, _opts, _context), do: [:id, :site_id, :section_lineage_id]

  @impl true
  def calculate(sections, _opts, context) do
    counts =
      sections
      |> Enum.filter(& &1.section_lineage_id)
      |> Enum.group_by(& &1.site_id, & &1.section_lineage_id)
      |> Map.new(fn {site_id, lineage_ids} ->
        {site_id, counts_in(site_id, Enum.uniq(lineage_ids), context)}
      end)

    Enum.map(sections, fn
      %{section_lineage_id: nil} -> 1
      section -> counts |> Map.get(section.site_id, %{}) |> Map.get(section.section_lineage_id, 1)
    end)
  end

  defp counts_in(site_id, lineage_ids, context) do
    query =
      Section
      |> Ash.Query.filter(section_lineage_id in ^lineage_ids)
      |> Ash.Query.select([:section_lineage_id])

    case Ash.read(query, Keyword.put(Ash.Scope.to_opts(context, tenant: site_id), :page, false)) do
      {:ok, rows} -> Enum.frequencies_by(rows, & &1.section_lineage_id)
      {:error, _refused} -> %{}
    end
  end
end
