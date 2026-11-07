# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_document/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaDocument.Resources.Changes.StampPublishedAt do
  @moduledoc """
  Gives a `MishkaDocument.WorkspaceVersion` saved as `:stable` with no `published_at` the current
  time as its `published_at`, to the second.

  A stable version always has a publish date (the table's `valid_publish_constraints` check), and
  the public docs read a version by it, so an admin who picks Stable and leaves Published At empty
  gets a version published now instead of a refused save. A date the admin gives is kept, and any
  other status is left as it is.

      update :update do
        change MishkaDocument.Resources.Changes.StampPublishedAt
      end
  """
  use Ash.Resource.Change

  @impl true
  def change(changeset, _opts, _context) do
    stamp(
      changeset,
      Ash.Changeset.get_attribute(changeset, :status),
      Ash.Changeset.get_attribute(changeset, :published_at)
    )
  end

  defp stamp(changeset, :stable, nil),
    do: Ash.Changeset.force_change_attribute(changeset, :published_at, DateTime.utc_now(:second))

  defp stamp(changeset, _status, _published_at), do: changeset
end
