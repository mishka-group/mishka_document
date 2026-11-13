# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_document/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaDocument.Resources.Calculations.WorkspaceMaintainers do
  @moduledoc """
  Calculates unique maintainers for a workspace based on EventLog.

  Maintainers are users who have successfully created or updated:
  - Sections belonging to workspace versions of the workspace
  - Notes belonging to sections of the workspace

  Returns a map with:
  - `count` - number of unique maintainers, at most 100
  - `maintainers` - list of `%{"user_id", "email", "name"}`: the 100 who wrote most recently,
    listed by `"name"`, then `"user_id"`

  `"email"` is the address when the reader may see it — a master sees everyone's, a site user its
  own site's — and `nil` otherwise. `"name"` is what a screen shows: the email, "Master" for a
  master, "Unknown" for anyone else (`MishkaCmsCore.Accounts.Helper.who/4`). Neither which
  maintainers are listed nor their order depends on an address the reader does not see.

  A workspace with a `site_id` counts only the pages and notes of its own site; one with none
  counts every site's. Uses raw SQL for performance with large datasets: one statement for the
  whole batch of workspaces, so a page of cards costs one query however many cards it has.
  """
  use Ash.Resource.Calculation

  alias Ecto.Adapters.SQL
  alias MishkaCmsCore.Accounts.Helper

  @repo Application.compile_env!(:mishka_cms_core, :repo)

  @maintainers_sql """
  SELECT t.workspace_id, m.user_id, m.email, m.site_id
  FROM (SELECT DISTINCT * FROM unnest($1::uuid[], $2::uuid[])) AS t(workspace_id, site_id)
  CROSS JOIN LATERAL (
    WITH workspace_sections AS (
      SELECT DISTINCT s.id
      FROM mishka_document_sections s
      INNER JOIN mishka_document_workspace_versions wv ON s.workspace_version_id = wv.id
      WHERE wv.workspace_id = t.workspace_id
        AND (t.site_id IS NULL OR s.site_id = t.site_id)
    ),
    workspace_notes AS (
      SELECT DISTINCT n.id
      FROM mishka_document_notes n
      INNER JOIN workspace_sections ws ON n.section_id = ws.id
    ),
    maintainer_events AS (
      SELECT el.actor_id, max(el.occurred_at) AS last_wrote_at
      FROM mishka_document_event_logs el
      WHERE el.actor_id IS NOT NULL
        AND el.action IN ('create', 'master_create', 'update', 'master_update')
        AND (
          (el.resource = 'Elixir.MishkaDocument.Section' AND el.record_id IN (SELECT id FROM workspace_sections))
          OR
          (el.resource = 'Elixir.MishkaDocument.Note' AND el.record_id IN (SELECT id FROM workspace_notes))
        )
      GROUP BY el.actor_id
    )
    SELECT u.id AS user_id, u.email, u.site_id
    FROM maintainer_events me
    INNER JOIN users u ON me.actor_id = u.id
    ORDER BY me.last_wrote_at DESC, u.id
    LIMIT 100
  ) m
  """

  @impl true
  def load(_query, _opts, _context), do: [:id, :site_id]

  @impl true
  def calculate([], _opts, _context), do: []

  def calculate(records, _opts, context) do
    maintainers = maintainers(records)

    Enum.map(records, fn workspace ->
      maintainers
      |> Map.get(workspace.id, [])
      |> then(&%{"count" => length(&1), "maintainers" => &1})
      |> seen_by(context.actor)
    end)
  end

  defp seen_by(%{"maintainers" => maintainers} = info, reader) do
    listed =
      maintainers
      |> Enum.map(&maintainer(&1, reader))
      |> Enum.sort_by(&{String.downcase(&1["name"]), &1["user_id"]})

    %{info | "maintainers" => listed}
  end

  defp maintainer(%{"user_id" => id, "email" => email, "site_id" => site_id}, reader) do
    user = Helper.visible_to(%{email: email, site_id: site_id}, reader)

    %{
      "user_id" => id,
      "email" => user && email,
      "name" => Helper.who(user, is_nil(site_id), :unknown)
    }
  end

  defp maintainers(records) do
    {workspace_ids, site_ids} =
      records
      |> Enum.map(&{Ecto.UUID.dump!(&1.id), dump(&1.site_id)})
      |> Enum.unzip()

    case SQL.query(@repo, @maintainers_sql, [workspace_ids, site_ids]) do
      {:ok, %{rows: rows}} ->
        Enum.group_by(rows, fn [workspace_id | _] -> Ecto.UUID.load!(workspace_id) end, fn
          [_workspace_id, user_id, email, user_site_id] ->
            %{
              "user_id" => Ecto.UUID.load!(user_id),
              "email" => email,
              "site_id" => user_site_id && Ecto.UUID.load!(user_site_id)
            }
        end)

      {:error, _} ->
        %{}
    end
  end

  defp dump(nil), do: nil
  defp dump(site_id), do: Ecto.UUID.dump!(site_id)
end
