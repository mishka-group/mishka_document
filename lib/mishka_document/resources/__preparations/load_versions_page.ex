# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_document/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaDocument.Resources.Preparations.LoadVersionsPage do
  @moduledoc """
  Loads one page of a record's history into its `sorted_versions`, each version with the `user`
  who made it: the read's `versions_limit` versions, after skipping `versions_offset` of them,
  newest first (the version resource's own `:sorted_versions` read sorts them).

  The record's resource keeps its history through
  `MishkaDocument.Resources.Mixins.PaperTrailMixin`, and the read declares both arguments:

      read :get_with_versions do
        get? true

        argument :versions_limit, :integer, default: 20, allow_nil?: true
        argument :versions_offset, :integer, default: 0, allow_nil?: true

        prepare {MishkaDocument.Resources.Preparations.LoadVersionsPage,
                 version: MishkaDocument.Section.Version}
      end

  ## Options

    * `:version` - required. The version resource the history is kept in.
  """
  use Ash.Resource.Preparation

  @impl true
  def init(opts) do
    case Keyword.fetch(opts, :version) do
      {:ok, version} when is_atom(version) -> {:ok, opts}
      _missing -> {:error, "LoadVersionsPage takes :version, the version resource"}
    end
  end

  @impl true
  def prepare(query, opts, _context) do
    limit = Ash.Query.get_argument(query, :versions_limit)
    offset = Ash.Query.get_argument(query, :versions_offset)

    versions =
      opts[:version]
      |> Ash.Query.new()
      |> Ash.Query.load([:user])
      |> Ash.Query.limit(limit)
      |> Ash.Query.offset(offset)

    Ash.Query.load(query, sorted_versions: versions)
  end
end
