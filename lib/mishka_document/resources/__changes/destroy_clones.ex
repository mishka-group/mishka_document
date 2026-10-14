defmodule MishkaDocument.Resources.Changes.DestroyClones do
  @moduledoc """
  Deleting a version deletes every version cloned from it, however deep, each through the same
  delete (`:destroy`, under the version's site) with the same actor — so each is refused, deleted with its pages and notes, logged and
  broadcast as its own delete would be. The database's `source_version_id` reference deletes a
  clone too, for a delete made past the action.

  Refused, with nothing deleted, when a version that would go with it is the latest of its
  document, so the latest is never deleted through another.

      destroy :destroy do
        change MishkaDocument.Resources.Changes.DestroyClones
      end
  """
  use Ash.Resource.Change
  use Gettext, backend: MishkaCmsCore.Gettext

  require Ash.Query

  alias MishkaDocument.Resources.Helpers.VersionClones
  alias MishkaDocument.WorkspaceVersion

  @impl true
  def change(changeset, _opts, context) do
    Ash.Changeset.before_action(changeset, &destroy_clones(&1, context))
  end

  defp destroy_clones(%{data: version} = changeset, context) do
    opts = VersionClones.as_caller(context, changeset.context)

    with {:ok, %{} = all} <- VersionClones.of([version], opts),
         clones = Map.fetch!(all, version.id),
         :ok <- none_latest(clones),
         :ok <- destroy_direct(version, opts) do
      changeset
    else
      {:latest, clone} ->
        Ash.Changeset.add_error(changeset,
          field: :is_latest_for_version,
          message:
            dgettext(
              "errors",
              "Cannot delete: %{version}, cloned from this version, is the latest. Mark another version as latest first.",
              version: clone.version_number
            )
        )

      {:error, error} ->
        Ash.Changeset.add_error(changeset, error)
    end
  end

  defp none_latest(clones) do
    case Enum.find(clones, & &1.is_latest_for_version) do
      nil -> :ok
      clone -> {:latest, clone}
    end
  end

  # The versions cloned from this one, each deleting its own clones in turn, under the version's
  # site whoever deletes it.
  defp destroy_direct(version, opts) do
    opts = [tenant: version.site_id] ++ opts

    WorkspaceVersion
    |> Ash.Query.for_read(:read, %{}, opts)
    |> Ash.Query.filter(source_version_id == ^version.id)
    |> Ash.bulk_destroy(
      :destroy,
      %{},
      opts ++
        [
          strategy: [:stream],
          transaction: false,
          return_errors?: true,
          stop_on_error?: true,
          notify?: true
        ]
    )
    |> case do
      %Ash.BulkResult{status: :success} ->
        :ok

      %Ash.BulkResult{errors: [_ | _] = errors} ->
        {:error, Ash.Error.to_error_class(errors)}

      %Ash.BulkResult{} ->
        {:error,
         Ash.Error.to_error_class(dgettext_noop("errors", "A cloned version was not deleted."))}
    end
  end
end
