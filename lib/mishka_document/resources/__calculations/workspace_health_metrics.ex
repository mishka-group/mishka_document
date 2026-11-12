# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_document/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaDocument.Resources.Calculations.WorkspaceHealthMetrics do
  @moduledoc """
  Calculates the health of a workspace from its pages, notes, drafts and issues.

  Returns a map with:
  - `completion` - percentage of sections and notes (drafts included) with both reviews approved
  - `trend` - change in completion from last month, in percentage points
  - `quality` - percentage of items without an open issue
  - `total_items` - sections and notes, drafts included
  - `approved_items` - how many of them have both reviews approved
  - `open_issues` and `resolved_issues`
  - `contributors_count` - unique authors of approved drafts
  - `active_contributors_today` - those of them whose draft changed in the last 24 hours
  - `sections_count` - live sections of the workspace

  Only the rows of the workspace's own site are counted. The database does the counting, one
  statement for the whole batch of workspaces, so a page of cards costs one query however many
  cards it has. A workspace with nothing in it gets zeros and a quality of 100.
  """
  use Ash.Resource.Calculation

  alias Ecto.Adapters.SQL

  @repo Application.compile_env!(:mishka_cms_core, :repo)

  @metrics_sql """
  SELECT t.workspace_id, m.*
  FROM (SELECT DISTINCT * FROM unnest($1::uuid[], $2::uuid[])) AS t(workspace_id, site_id)
  CROSS JOIN LATERAL (
    WITH section_count AS (
      SELECT COUNT(*) AS sections_count
      FROM mishka_document_sections s
      JOIN mishka_document_workspace_versions wv ON s.workspace_version_id = wv.id
      WHERE wv.workspace_id = t.workspace_id
        AND s.site_id = t.site_id
        AND s.archived_at IS NULL
    ),
    current_month AS (
      SELECT
        COUNT(*) AS total_items,
        COUNT(*) FILTER (
          WHERE content_review_status = 'approved' AND technical_review_status = 'approved'
        ) AS approved_items
      FROM (
        SELECT s.content_review_status, s.technical_review_status
        FROM mishka_document_sections s
        JOIN mishka_document_workspace_versions wv ON s.workspace_version_id = wv.id
        WHERE wv.workspace_id = t.workspace_id
          AND s.site_id = t.site_id
          AND s.archived_at IS NULL

        UNION ALL

        SELECT n.content_review_status, n.technical_review_status
        FROM mishka_document_notes n
        JOIN mishka_document_sections s ON n.section_id = s.id
        JOIN mishka_document_workspace_versions wv ON s.workspace_version_id = wv.id
        WHERE wv.workspace_id = t.workspace_id
          AND n.site_id = t.site_id
          AND n.archived_at IS NULL

        UNION ALL

        SELECT sd.content_review_status, sd.technical_review_status
        FROM mishka_document_section_drafts sd
        JOIN mishka_document_sections s ON sd.source_section_id = s.id
        JOIN mishka_document_workspace_versions wv ON s.workspace_version_id = wv.id
        WHERE wv.workspace_id = t.workspace_id
          AND sd.site_id = t.site_id
          AND sd.archived_at IS NULL

        UNION ALL

        SELECT nd.content_review_status, nd.technical_review_status
        FROM mishka_document_note_drafts nd
        JOIN mishka_document_workspace_versions wv ON nd.workspace_version_id = wv.id
        WHERE wv.workspace_id = t.workspace_id
          AND nd.site_id = t.site_id
          AND nd.archived_at IS NULL
      ) all_items
    ),
    last_month AS (
      SELECT
        COUNT(*) AS total_items,
        COUNT(*) FILTER (
          WHERE content_review_status = 'approved' AND technical_review_status = 'approved'
        ) AS approved_items
      FROM (
        SELECT s.content_review_status, s.technical_review_status
        FROM mishka_document_sections s
        JOIN mishka_document_workspace_versions wv ON s.workspace_version_id = wv.id
        WHERE wv.workspace_id = t.workspace_id
          AND s.site_id = t.site_id
          AND s.archived_at IS NULL
          AND s.updated_at < date_trunc('month', CURRENT_DATE)

        UNION ALL

        SELECT n.content_review_status, n.technical_review_status
        FROM mishka_document_notes n
        JOIN mishka_document_sections s ON n.section_id = s.id
        JOIN mishka_document_workspace_versions wv ON s.workspace_version_id = wv.id
        WHERE wv.workspace_id = t.workspace_id
          AND n.site_id = t.site_id
          AND n.archived_at IS NULL
          AND n.updated_at < date_trunc('month', CURRENT_DATE)
      ) last_month_items
    ),
    issue_stats AS (
      SELECT
        COUNT(*) AS total_issues,
        COUNT(*) FILTER (WHERE status = 'open') AS open_issues,
        COUNT(*) FILTER (WHERE status = 'resolved') AS resolved_issues
      FROM mishka_document_issues
      WHERE site_id = t.site_id
        AND (
          section_id IN (
            SELECT s.id
            FROM mishka_document_sections s
            JOIN mishka_document_workspace_versions wv ON s.workspace_version_id = wv.id
            WHERE wv.workspace_id = t.workspace_id AND s.site_id = t.site_id
          )
          OR note_id IN (
            SELECT n.id
            FROM mishka_document_notes n
            JOIN mishka_document_sections s ON n.section_id = s.id
            JOIN mishka_document_workspace_versions wv ON s.workspace_version_id = wv.id
            WHERE wv.workspace_id = t.workspace_id AND n.site_id = t.site_id
          )
        )
        AND archived_at IS NULL
    ),
    contributor_stats AS (
      SELECT
        COUNT(DISTINCT created_by_user_id) AS total_contributors,
        COUNT(DISTINCT created_by_user_id) FILTER (
          WHERE updated_at >= NOW() - INTERVAL '24 hours'
        ) AS active_today
      FROM (
        SELECT sd.created_by_user_id, sd.updated_at
        FROM mishka_document_section_drafts sd
        JOIN mishka_document_workspace_versions wv ON sd.workspace_version_id = wv.id
        WHERE wv.workspace_id = t.workspace_id
          AND sd.site_id = t.site_id
          AND sd.archived_at IS NULL
          AND sd.content_review_status = 'approved'
          AND sd.technical_review_status = 'approved'
          AND sd.created_by_user_id IS NOT NULL

        UNION ALL

        SELECT nd.created_by_user_id, nd.updated_at
        FROM mishka_document_note_drafts nd
        JOIN mishka_document_workspace_versions wv ON nd.workspace_version_id = wv.id
        WHERE wv.workspace_id = t.workspace_id
          AND nd.site_id = t.site_id
          AND nd.archived_at IS NULL
          AND nd.content_review_status = 'approved'
          AND nd.technical_review_status = 'approved'
          AND nd.created_by_user_id IS NOT NULL
      ) all_contributors
    )
    SELECT
      CASE
        WHEN cm.total_items = 0 THEN 0
        ELSE ROUND((cm.approved_items::numeric / cm.total_items::numeric) * 100)
      END AS completion,
      CASE
        WHEN cm.total_items = 0 THEN 0
        WHEN lm.total_items = 0 THEN
          ROUND((cm.approved_items::numeric / cm.total_items::numeric) * 100)
        ELSE
          ROUND((cm.approved_items::numeric / cm.total_items::numeric) * 100) -
          ROUND((lm.approved_items::numeric / lm.total_items::numeric) * 100)
      END AS trend,
      CASE
        WHEN cm.total_items = 0 THEN 100
        WHEN ist.total_issues = 0 THEN 100
        ELSE ROUND(((cm.total_items - ist.open_issues)::numeric / cm.total_items::numeric) * 100)
      END AS quality,
      cm.total_items,
      cm.approved_items,
      ist.open_issues,
      ist.resolved_issues,
      cs.total_contributors,
      cs.active_today,
      sc.sections_count
    FROM current_month cm, last_month lm, issue_stats ist, contributor_stats cs, section_count sc
  ) m
  """

  @keys [
    :completion,
    :trend,
    :quality,
    :total_items,
    :approved_items,
    :open_issues,
    :resolved_issues,
    :contributors_count,
    :active_contributors_today,
    :sections_count
  ]

  @empty %{
    completion: 0,
    trend: 0,
    quality: 100,
    total_items: 0,
    approved_items: 0,
    open_issues: 0,
    resolved_issues: 0,
    contributors_count: 0,
    active_contributors_today: 0,
    sections_count: 0
  }

  @impl true
  def load(_query, _opts, _context), do: [:id, :site_id]

  @impl true
  def calculate([], _opts, _context), do: []

  def calculate(records, _opts, _context) do
    metrics = metrics(records)

    Enum.map(records, &Map.get(metrics, &1.id, @empty))
  end

  defp metrics(records) do
    {workspace_ids, site_ids} =
      records
      |> Enum.map(&{Ecto.UUID.dump!(&1.id), dump(&1.site_id)})
      |> Enum.unzip()

    case SQL.query(@repo, @metrics_sql, [workspace_ids, site_ids]) do
      {:ok, %{rows: rows}} ->
        Map.new(rows, fn [workspace_id | values] ->
          {Ecto.UUID.load!(workspace_id),
           @keys |> Enum.zip(Enum.map(values, &to_int/1)) |> Map.new()}
        end)

      _ ->
        %{}
    end
  end

  defp dump(nil), do: nil
  defp dump(site_id), do: Ecto.UUID.dump!(site_id)

  defp to_int(nil), do: 0
  defp to_int(%Decimal{} = decimal), do: Decimal.to_integer(decimal)
  defp to_int(value) when is_integer(value), do: value
end
