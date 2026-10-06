defmodule MishkaDocument.Resources.Changes.EnsureSingleLatestVersion do
  @moduledoc """
  Ensures only one version is marked as latest per workspace.

  When `is_latest_for_version` is set to true, automatically unmarks
  all other versions in the same workspace.
  """
  use Ash.Resource.Change

  require Ash.Query

  @impl true
  def change(changeset, _opts, _context) do
    Ash.Changeset.after_action(changeset, fn _changeset, result ->
      if result.is_latest_for_version do
        MishkaDocument.WorkspaceVersion
        |> Ash.Query.filter(
          workspace_id == ^result.workspace_id and
            is_latest_for_version == true and
            id != ^result.id
        )
        |> Ash.read!(tenant: result.site_id, authorize?: false)
        |> Enum.each(fn version ->
          version
          |> Ash.Changeset.for_update(:update, %{is_latest_for_version: false},
            tenant: result.site_id,
            authorize?: false
          )
          |> Ash.update!()
        end)
      end

      {:ok, result}
    end)
  end
end
