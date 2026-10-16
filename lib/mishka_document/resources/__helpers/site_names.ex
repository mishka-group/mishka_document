# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_document/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaDocument.Resources.Helpers.SiteNames do
  @moduledoc """
  Ash preparation that resolves, for the whole page in ONE query, the site name the master's
  site badge (`event_site` column) shows on each event-log row.

  A row's `site_id` lives in its JSONB `metadata`/`data`, not a column or relationship, so it cannot
  be preloaded and a naive column would read one `MishkaCmsCore.Runtime.Site` per row. This
  after_action instead gathers every distinct id on the page, reads all their names at once
  (`:read_any`, tenancy bypassed — it only names the master's own badge and never widens which rows a
  viewer sees), and stamps the resolved display name onto each record's metadata (`:site_name`); the
  column then just reads it.

  Only a master (a user whose `site_id` is nil) sees the badge, so every other read, a tenant's or
  one with no actor, skips the lookup entirely. A page with no site_ids does no read at all, and a
  site that no longer exists falls back to a truncated id.

  See `MishkaDocument.EventLog` and `MishkaCmsCoreWeb.Templates.ActivityTimeline`.
  """
  use Ash.Resource.Preparation

  require Ash.Query

  @impl true
  def prepare(query, _opts, %{actor: %{id: _, site_id: nil}}) do
    Ash.Query.after_action(query, fn _query, records -> {:ok, stamp(records)} end)
  end

  def prepare(query, _opts, _context), do: query

  defp stamp(records) do
    names = records |> site_ids() |> resolve()

    Enum.map(records, fn record ->
      Ash.Resource.put_metadata(record, :site_name, display(site_id(record), names))
    end)
  end

  defp site_ids(records) do
    records
    |> Enum.map(&site_id/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

  defp resolve([]), do: %{}

  defp resolve(site_ids) do
    case MishkaCmsCore.Runtime.Site
         |> Ash.Query.filter(id in ^site_ids)
         |> Ash.Query.select([:id, :name])
         |> Ash.read(action: :read_any, authorize?: false, page: false) do
      {:ok, sites} -> Map.new(sites, &{&1.id, &1.name})
      _error -> %{}
    end
  end

  defp display(nil, _names), do: nil

  defp display(site_id, names),
    do: Map.get(names, site_id) || String.slice(site_id, 0, 8) <> "..."

  defp site_id(%{metadata: %{"site_id" => id}}) when is_binary(id), do: id
  defp site_id(%{data: %{"site_id" => id}}) when is_binary(id), do: id
  defp site_id(_record), do: nil
end
