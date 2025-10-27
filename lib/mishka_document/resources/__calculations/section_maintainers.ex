defmodule MishkaDocument.Resources.Calculations.SectionMaintainers do
  @moduledoc """
  Calculates unique maintainers count for a section based on EventLog.

  Maintainers are users who have successfully created or updated:
  - The section itself (direct changes)
  - Notes belonging to this section (via metadata.section_id)

  Uses raw SQL for performance with large datasets.
  """
  use Ash.Resource.Calculation

  @repo Application.compile_env!(:mishka_cms_core, :repo)

  @impl true
  def calculate(records, _opts, _context) do
    Enum.map(records, fn section ->
      get_maintainers_count(section.id, section.site_id)
    end)
  end

  defp get_maintainers_count(section_id, site_id) do
    section_id_str = to_string(section_id)

    {site_sql, params} =
      if site_id do
        site_id_str = to_string(site_id)
        {"AND el.metadata->>'site_id' = $2", [section_id_str, site_id_str]}
      else
        # Master user - no site filtering
        {"", [section_id_str]}
      end

    sql = """
    SELECT COUNT(DISTINCT el.actor_id)
    FROM mishka_document_event_logs el
    WHERE el.actor_id IS NOT NULL
      AND el.action IN ('create', 'master_create', 'update', 'master_update')
      #{site_sql}
      AND (
        -- Direct section changes
        (el.resource = 'Elixir.MishkaDocument.Section' AND el.record_id::text = $1)
        OR
        -- Notes belonging to this section (via metadata)
        (el.resource = 'Elixir.MishkaDocument.Note' AND el.metadata->>'section_id' = $1)
      )
    """

    case Ecto.Adapters.SQL.query(@repo, sql, params) do
      {:ok, %{rows: [[count]]}} when is_number(count) ->
        if is_float(count), do: trunc(count), else: count

      _ ->
        0
    end
  end
end
