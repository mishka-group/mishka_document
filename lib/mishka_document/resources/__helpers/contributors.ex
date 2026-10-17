# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_document/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaDocument.Resources.Helpers.Contributors do
  @moduledoc """
  Who wrote the pages and notes of a document, read from `MishkaDocument.EventLog`.

  A contributor is an account that created or updated a `MishkaDocument.Section`, or a
  `MishkaDocument.Note` of one. Every function reads the log with the `opts` it is given: `actor:`,
  and `authorize?:` when the caller reads without checks, which `Ash.Scope.to_opts/2` takes from a
  calculation's context. The event log's own policy then decides which events that actor may see: a
  master reads every site's, a site admin its own site's, and an actor holding neither document area,
  or none, reads none and gets an empty answer.

      Contributors.writers_in_version(version_id, actor: user)  #=> ["user-id", ...]
  """
  require Ash.Query

  alias MishkaDocument.{EventLog, Note, Section}

  @written [:create, :master_create, :update, :master_update]

  @doc """
  The ids of the accounts that wrote any page or note of the workspace version `version_id`.
  """
  @spec writers_in_version(String.t(), keyword()) :: [String.t()]
  def writers_in_version(version_id, opts) when is_binary(version_id) do
    EventLog
    |> Ash.Query.filter(
      not is_nil(actor_id) and action in ^@written and resource in ^[Section, Note] and
        fragment("(?->>'workspace_version_id') = ?::text", metadata, ^version_id)
    )
    |> Ash.Query.select([:actor_id])
    |> read(opts)
    |> Enum.map(& &1.actor_id)
    |> Enum.uniq()
  end

  @doc """
  The ids of the pages written by any of the accounts `user_ids`. A site admin is answered only
  with what accounts of its own site wrote.
  """
  @spec sections_written_by([String.t()], keyword()) :: [String.t()]
  def sections_written_by(user_ids, opts) when is_list(user_ids) do
    EventLog
    |> Ash.Query.filter(actor_id in ^user_ids and action in ^@written and resource == ^Section)
    |> same_site_writers(Keyword.get(opts, :actor))
    |> Ash.Query.select([:record_id])
    |> read(opts)
    |> Enum.map(& &1.record_id)
    |> Enum.uniq()
  end

  @doc """
  How many accounts wrote each page of `section_ids`, itself or one of its notes, as a map by
  section id. A page nobody is known to have written is not in the map.
  """
  @spec writer_counts([String.t()], keyword()) :: %{String.t() => non_neg_integer()}
  def writer_counts([], _opts), do: %{}

  def writer_counts(section_ids, opts) when is_list(section_ids) do
    EventLog
    |> Ash.Query.filter(
      not is_nil(actor_id) and action in ^@written and
        ((resource == ^Section and record_id in ^section_ids) or
           (resource == ^Note and
              fragment(
                "(?->>'section_id') = ANY(?)",
                metadata,
                type(^section_ids, {:array, :string})
              )))
    )
    |> Ash.Query.select([:actor_id, :record_id, :resource, :metadata])
    |> read(opts)
    |> Enum.group_by(&section_of/1, & &1.actor_id)
    |> Map.new(fn {section_id, writers} -> {section_id, writers |> Enum.uniq() |> length()} end)
  end

  defp section_of(%{resource: Section, record_id: id}), do: id
  defp section_of(%{resource: Note, metadata: %{"section_id" => id}}), do: id

  defp same_site_writers(query, %{site_id: site_id}) when is_binary(site_id),
    do: Ash.Query.filter(query, actor.site_id == ^site_id)

  defp same_site_writers(query, _master_or_nobody), do: query

  defp read(query, opts) do
    case Ash.read(query, Keyword.put(opts, :page, false)) do
      {:ok, events} -> events
      {:error, _refused} -> []
    end
  end
end
