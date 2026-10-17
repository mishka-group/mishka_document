# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_document/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaDocument.Resources.Calculations.SectionMaintainers do
  @moduledoc """
  Calculates unique maintainers count for a section based on EventLog.

  Maintainers are users who have successfully created or updated:
  - The section itself (direct changes)
  - Notes belonging to this section (via metadata.section_id)

  The log is read once for every section asked about and as whoever asked, so a viewer counts the
  maintainers in the events its role may read (`MishkaDocument.Resources.Helpers.Contributors`);
  a viewer who may read none counts `0`.
  """
  use Ash.Resource.Calculation

  alias MishkaDocument.Resources.Helpers.Contributors

  @impl true
  def load(_query, _opts, _context), do: [:id]

  @impl true
  def calculate(sections, _opts, context) do
    counts =
      sections |> Enum.map(& &1.id) |> Contributors.writer_counts(Ash.Scope.to_opts(context))

    Enum.map(sections, &Map.get(counts, &1.id, 0))
  end
end
