# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_document/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaDocument.Resources.Helpers.VersionClones do
  @moduledoc """
  The versions cloned from a version, and from those, however deep: every version whose
  `source_version_id` leads back to it. Deleting a version deletes them with it
  (`MishkaDocument.Resources.Changes.DestroyClones`); its delete confirmation names them
  (`MishkaDocument.Resources.Calculations.CloneNumbers`).

  Read as the caller, under each version's own site, one read a generation.

      VersionClones.of([version], actor: actor, authorize?: true)
      #=> {:ok, %{version.id => [%WorkspaceVersion{version_number: "0.0.10"}, …]}}
  """

  require Ash.Query

  alias MishkaDocument.WorkspaceVersion

  # A chain of clones deeper than this, which only a loop makes, stops there.
  @depth 50

  @fields [:id, :site_id, :source_version_id, :version_number, :is_latest_for_version]

  @doc """
  The options a write or read made for a caller is run with: its actor and authorization, and the
  shared context it came with — the admin surface its permissions are asked on among it — taken
  from the context of the change or calculation running (`context`) and of the changeset or query
  around it (`source_context`).
  """
  @spec as_caller(map(), map()) :: keyword()
  def as_caller(context, source_context) do
    [actor: context.actor, authorize?: context.authorize? != false] ++
      case Map.get(source_context || %{}, :shared) do
        %{} = shared when map_size(shared) > 0 -> [context: %{shared: shared}]
        _none -> []
      end
  end

  @doc """
  Each of `versions`' clones, nearest first, keyed by the version's id. `opts` are the caller's
  `:actor` and `:authorize?`.
  """
  @spec of([map()], keyword()) :: {:ok, %{String.t() => [map()]}} | {:error, term()}
  def of(versions, opts) do
    versions
    |> Enum.group_by(& &1.site_id, & &1.id)
    |> Enum.reduce_while({:ok, Map.new(versions, &{&1.id, []})}, fn {site_id, ids}, {:ok, acc} ->
      frontier = Enum.map(ids, &{&1, &1})
      seen = MapSet.new(ids, &{&1, &1})

      case generations(frontier, site_id, opts, acc, seen, 0) do
        {:ok, acc} -> {:cont, {:ok, acc}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  # `frontier` holds each version of the generation with the version it was asked for; one version
  # asked for may be a clone of another, so each is followed for each version it descends from.
  defp generations([], _site_id, _opts, acc, _seen, _depth), do: {:ok, acc}

  defp generations(_frontier, _site_id, _opts, acc, _seen, depth) when depth >= @depth,
    do: {:ok, acc}

  defp generations(frontier, site_id, opts, acc, seen, depth) do
    parents = frontier |> Enum.map(&elem(&1, 0)) |> Enum.uniq()
    roots_of = Enum.group_by(frontier, &elem(&1, 0), &elem(&1, 1))

    WorkspaceVersion
    |> Ash.Query.for_read(:read, %{}, [tenant: site_id] ++ opts)
    |> Ash.Query.filter(source_version_id in ^parents)
    |> Ash.Query.select(@fields)
    |> Ash.Query.sort(inserted_at: :asc, version_number: :asc)
    |> Ash.read([tenant: site_id] ++ opts)
    |> case do
      {:ok, clones} ->
        found =
          for clone <- clones,
              root <- Map.fetch!(roots_of, clone.source_version_id),
              not MapSet.member?(seen, {root, clone.id}),
              do: {clone, root}

        acc =
          Enum.reduce(found, acc, fn {clone, root}, acc ->
            Map.update!(acc, root, &(&1 ++ [clone]))
          end)

        seen =
          Enum.reduce(found, seen, fn {clone, root}, seen ->
            MapSet.put(seen, {root, clone.id})
          end)

        next = Enum.map(found, fn {clone, root} -> {clone.id, root} end)
        generations(next, site_id, opts, acc, seen, depth + 1)

      {:error, _reason} = error ->
        error
    end
  end
end
