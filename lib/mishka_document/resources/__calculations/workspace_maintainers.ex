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

  Uses raw SQL for performance with large datasets.
  """
  use Ash.Resource.Calculation

  alias Ecto.Adapters.SQL
  alias MishkaCmsCore.Accounts.Helper

  @repo Application.compile_env!(:mishka_cms_core, :repo)

  @impl true
  def calculate(records, _opts, context) do
    Enum.map(records, fn workspace ->
      workspace.id
      |> get_maintainers_for_workspace(workspace.site_id)
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

  # The one interpolation in the query is `site_sql`: one of two fixed strings. Every value goes in
  # through `$1` and `$2`.
  # sobelow_skip ["SQL.Query"]
  defp get_maintainers_for_workspace(workspace_id, site_id) do
    # Convert UUIDs to binary for PostgreSQL
    {:ok, workspace_uuid} = Ecto.UUID.dump(workspace_id)

    {site_sql, params} =
      if site_id do
        {:ok, site_uuid} = Ecto.UUID.dump(site_id)
        {"AND s.site_id = $2", [workspace_uuid, site_uuid]}
      else
        # Master user - no site filtering
        {"", [workspace_uuid]}
      end

    sql = """
    WITH workspace_sections AS (
      -- Get all section IDs belonging to this workspace (through workspace versions)
      SELECT DISTINCT s.id
      FROM mishka_document_sections s
      INNER JOIN mishka_document_workspace_versions wv ON s.workspace_version_id = wv.id
      WHERE wv.workspace_id = $1
        #{site_sql}
    ),
    workspace_notes AS (
      -- Get all note IDs belonging to sections of this workspace
      SELECT DISTINCT n.id
      FROM mishka_document_notes n
      INNER JOIN workspace_sections ws ON n.section_id = ws.id
    ),
    maintainer_events AS (
      -- Each actor who created/updated sections or notes for this workspace, and when it last did
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
    SELECT
      u.id as user_id,
      u.email,
      u.site_id
    FROM maintainer_events me
    INNER JOIN users u ON me.actor_id = u.id
    ORDER BY me.last_wrote_at DESC, u.id
    LIMIT 100
    """

    case SQL.query(@repo, sql, params) do
      {:ok, %{rows: rows}} ->
        maintainers =
          Enum.map(rows, fn [user_id, email, user_site_id] ->
            %{
              "user_id" => Ecto.UUID.load!(user_id),
              "email" => email,
              "site_id" => user_site_id && Ecto.UUID.load!(user_site_id)
            }
          end)

        %{
          "count" => length(maintainers),
          "maintainers" => maintainers
        }

      {:error, _} ->
        %{"count" => 0, "maintainers" => []}
    end
  end
end
