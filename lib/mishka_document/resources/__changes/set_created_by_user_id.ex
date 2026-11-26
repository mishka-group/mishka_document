# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_document/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaDocument.Resources.Changes.SetCreatedByUserId do
  @moduledoc """
  Names the actor as the record's author, in `created_by_user_id`, when the write gives no author
  of its own. An author the form picks is kept, and a write with no actor, or an actor with no id,
  leaves the field as it is.

      create :create do
        change MishkaDocument.Resources.Changes.SetCreatedByUserId
      end
  """
  use Ash.Resource.Change

  @impl true
  def change(changeset, _opts, context) do
    author(changeset, Ash.Changeset.get_attribute(changeset, :created_by_user_id), context.actor)
  end

  defp author(changeset, nil, %{id: user_id}),
    do: Ash.Changeset.force_change_attribute(changeset, :created_by_user_id, user_id)

  defp author(changeset, _author, _actor), do: changeset
end
