# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_document/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaDocument.Dashboard.Scope do
  @moduledoc """
  Every read of the document dashboard's widgets (`MishkaDocument.Dashboard.Widgets`) as the user
  viewing it, through the resource's own policies.

  `query/3` starts the read of a resource for the viewer:

    * a master (a user whose `site_id` is nil) reads through the resource's master read —
      `:master_read` unless another is named — with no tenant, so it reads every site;
    * a site user reads through the resource's primary `:read` with its own site as the tenant, so
      it reads that site alone.

  Refine the query with filters, sorts, selects and loads, then run it with `count/1` or `list/2`.
  The viewer is the query's actor, so the resource's policies decide what it reads: a viewer who
  does not hold the area a resource belongs to is refused, or has every row filtered out. Both run
  without raising and give a refused or failed read as no data — `0` from `count/1`, `[]` from
  `list/2`.

      MishkaDocument.Issue
      |> Scope.query(user)
      |> Ash.Query.filter(status == :open)
      |> Scope.count()

  The viewer is required: `MishkaCmsCore.Dashboard.Widget.scope/1` tells a master from a site user
  and raises on a missing user, which is never read as a master.
  """
  require Logger

  alias MishkaCmsCore.Dashboard.Widget

  @doc """
  The read action and the options to read with as `user`: `{master_action, [actor: user]}` for a
  master, `{:read, [actor: user, tenant: site_id]}` for a user of the site `site_id`.
  """
  @spec read_for(map(), atom()) :: {atom(), keyword()}
  def read_for(user, master_action \\ :master_read) do
    case Widget.scope(user) do
      nil -> {master_action, [actor: user]}
      site_id -> {:read, [actor: user, tenant: site_id]}
    end
  end

  @doc """
  A query of `resource` read as `user` — the action and options of `read_for/2`.
  """
  @spec query(Ash.Resource.t(), map(), atom()) :: Ash.Query.t()
  def query(resource, user, master_action \\ :master_read) do
    {action, opts} = read_for(user, master_action)

    Ash.Query.for_read(resource, action, %{}, opts)
  end

  @doc """
  How many records `query` reads, or `0` when the read is refused or fails.
  """
  @spec count(Ash.Query.t()) :: non_neg_integer()
  def count(query) do
    case Ash.count(query) do
      {:ok, count} -> count
      {:error, error} -> no_data(query, error, 0)
    end
  end

  @doc """
  The records `query` reads: the first `limit` of them, or every one for `:all`. `[]` when the read
  is refused or fails.

  `:all` needs an action whose pagination is optional: a site user's `:read`, or a master read that
  sets `required?: false`, such as `MishkaDocument.Workspace`'s `:read_any`.
  """
  @spec list(Ash.Query.t(), pos_integer() | :all) :: [struct()]
  def list(query, limit \\ :all)

  def list(query, :all) do
    case Ash.read(query, page: false) do
      {:ok, records} -> records
      {:error, error} -> no_data(query, error, [])
    end
  end

  def list(query, limit) when is_integer(limit) and limit > 0 do
    {limited, opts} = limited(query, limit)

    case Ash.read(limited, opts) do
      {:ok, %{results: records}} -> records
      {:ok, records} when is_list(records) -> records
      {:error, error} -> no_data(query, error, [])
    end
  end

  defp limited(%{action: %{pagination: pagination}} = query, limit) when is_map(pagination),
    do: {query, [page: [limit: limit]]}

  defp limited(query, limit), do: {Ash.Query.limit(query, limit), []}

  defp no_data(_query, %Ash.Error.Forbidden{}, empty), do: empty

  defp no_data(query, error, empty) do
    Logger.warning(
      "document dashboard read of #{inspect(query.resource)}.#{query.action.name} failed: " <>
        Exception.message(error)
    )

    empty
  end
end
