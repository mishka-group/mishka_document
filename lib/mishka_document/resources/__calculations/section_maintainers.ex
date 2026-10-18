# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_document/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaDocument.Resources.Calculations.SectionMaintainers do
  @moduledoc """
  Calculates unique maintainers count for a section based on EventLog.

  Maintainers are users who have successfully created or updated:
  - The section itself (direct changes)
  - Notes belonging to this section (via metadata.section_id)

  Uses raw SQL for performance with large datasets: the database counts, one statement for the
  whole batch of sections. A section with a `site_id` counts only the events of its own site; a
  section with none (a master section) counts the events of every site. A section with no events
  counts 0.
  """
  use Ash.Resource.Calculation

  alias Ecto.Adapters.SQL

  @repo Application.compile_env!(:mishka_cms_core, :repo)

  @maintainers_sql """
  SELECT s.id, c.count
  FROM unnest($1::text[], $2::text[]) AS s(id, site_id)
  CROSS JOIN LATERAL (
    SELECT COUNT(DISTINCT el.actor_id) AS count
    FROM mishka_document_event_logs el
    WHERE el.actor_id IS NOT NULL
      AND el.action IN ('create', 'master_create', 'update', 'master_update')
      AND (s.site_id IS NULL OR el.metadata->>'site_id' = s.site_id)
      AND (
        -- Direct section changes
        (el.resource = 'Elixir.MishkaDocument.Section' AND el.record_id::text = s.id)
        OR
        -- Notes belonging to this section (via metadata)
        (el.resource = 'Elixir.MishkaDocument.Note' AND el.metadata->>'section_id' = s.id)
      )
  ) c
  """

  @impl true
  def load(_query, _opts, _context), do: [:id, :site_id]

  @impl true
  def calculate([], _opts, _context), do: []

  def calculate(records, _opts, _context) do
    counts = maintainers_counts(records)

    Enum.map(records, &Map.get(counts, to_string(&1.id), 0))
  end

  defp maintainers_counts(records) do
    {section_ids, site_ids} =
      records
      |> Enum.map(&{to_string(&1.id), site_id_text(&1.site_id)})
      |> Enum.unzip()

    case SQL.query(@repo, @maintainers_sql, [section_ids, site_ids]) do
      {:ok, %{rows: rows}} -> Map.new(rows, fn [section_id, count] -> {section_id, count} end)
      _ -> %{}
    end
  end

  defp site_id_text(nil), do: nil
  defp site_id_text(site_id), do: to_string(site_id)
end
