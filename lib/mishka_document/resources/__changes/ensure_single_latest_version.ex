# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_document/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaDocument.Resources.Changes.EnsureSingleLatestVersion do
  @moduledoc """
  Ensures only one version is marked as latest per workspace.

  When `is_latest_for_version` is set to true, automatically unmarks
  all other versions in the same workspace, as whoever made the change.
  """
  use Ash.Resource.Change

  require Ash.Query

  @impl true
  def change(changeset, _opts, context) do
    Ash.Changeset.after_action(changeset, fn _changeset, result ->
      if result.is_latest_for_version do
        MishkaDocument.WorkspaceVersion
        |> Ash.Query.filter(
          workspace_id == ^result.workspace_id and
            is_latest_for_version == true and
            id != ^result.id
        )
        |> Ash.read!(Ash.Scope.to_opts(context, tenant: result.site_id))
        |> Enum.each(fn version ->
          version
          |> Ash.Changeset.for_update(
            :update,
            %{is_latest_for_version: false},
            Ash.Scope.to_opts(context, tenant: result.site_id)
          )
          |> Ash.update!()
        end)
      end

      {:ok, result}
    end)
  end
end
