defmodule MishkaDocument.Resources.Changes.DetachVersion do
  @moduledoc """
  Makes a cloned version independent of the version it was cloned from, in one transaction:

    * the version names no source (`source_version_id` nil);
    * none of its pages names the page it was copied from (`MishkaDocument.Section`'s
      `:detach_source`), archived ones included, so deleting the old source's pages deletes none
      of these;
    * its `MishkaDocument.WorkspaceVersionLineage` rows as the new version are deleted.

  Each page keeps its `section_lineage_id`, the id its history across versions is read by, which
  no reference ties to a row. Every write is made with the action's actor, under the version's
  site. A version with no source is refused.

  Once committed, `"document:version:detached"` is fired through
  `MishkaInstaller.Event.Hook.call/3` with
  `%{version_id: "…", source_version_id: "…", workspace_id: "…", site_id: "…", pages: 172}` and
  `meta: %{actor: actor, site_id: site_id}`. What a plugin answers is not used.

      update :detach do
        change MishkaDocument.Resources.Changes.DetachVersion
      end
  """
  use Ash.Resource.Change
  use Gettext, backend: MishkaCmsCore.Gettext

  require Ash.Query

  alias MishkaDocument.{Section, WorkspaceVersionLineage}
  alias MishkaDocument.Resources.Helpers.VersionClones
  alias MishkaInstaller.Event.Hook

  @event "document:version:detached"

  @doc "The event fired after a version is made independent."
  @spec event() :: String.t()
  def event, do: @event

  @impl true
  def change(%{data: %{source_version_id: nil}} = changeset, _opts, _context) do
    Ash.Changeset.add_error(changeset,
      field: :source_version_id,
      message: dgettext_noop("errors", "This version is not cloned from another.")
    )
  end

  def change(%{data: version} = changeset, _opts, context) do
    opts = [tenant: version.site_id] ++ VersionClones.as_caller(context, changeset.context)

    source_id = version.source_version_id

    changeset
    |> Ash.Changeset.force_change_attribute(:source_version_id, nil)
    |> Ash.Changeset.put_context(:ash_events_metadata, %{
      site_id: version.site_id,
      title: version.version_number
    })
    |> Ash.Changeset.after_action(fn _changeset, detached -> detach(detached, opts) end)
    |> Ash.Changeset.after_transaction(fn _changeset, result ->
      announce(result, source_id, context.actor)
    end)
  end

  defp detach(version, opts) do
    with {:ok, live} <- unlink_pages(version, :read, opts),
         {:ok, archived} <- unlink_pages(version, :archived, opts),
         :ok <- drop_lineage(version, opts) do
      {:ok, Ash.Resource.put_metadata(version, :detached, %{pages: live + archived})}
    end
  end

  defp unlink_pages(version, read_action, opts) do
    Section
    |> Ash.Query.for_read(read_action, %{}, opts)
    |> Ash.Query.filter(workspace_version_id == ^version.id and not is_nil(source_section_id))
    |> Ash.bulk_update(:detach_source, %{}, opts ++ bulk_opts())
    |> counted()
  end

  defp drop_lineage(version, opts) do
    WorkspaceVersionLineage
    |> Ash.Query.for_read(:read, %{}, opts)
    |> Ash.Query.filter(new_version_id == ^version.id)
    |> Ash.bulk_destroy(:destroy, %{}, opts ++ bulk_opts())
    |> counted()
    |> case do
      {:ok, _count} -> :ok
      error -> error
    end
  end

  defp bulk_opts,
    do: [
      strategy: [:stream],
      allow_stream_with: :full_read,
      transaction: false,
      return_errors?: true,
      return_records?: true,
      stop_on_error?: true,
      notify?: false
    ]

  defp counted(%Ash.BulkResult{status: :success, records: records}),
    do: {:ok, length(records || [])}

  defp counted(%Ash.BulkResult{errors: [_ | _] = errors}),
    do: {:error, Ash.Error.to_error_class(errors)}

  defp counted(%Ash.BulkResult{}),
    do:
      {:error, Ash.Error.to_error_class(dgettext_noop("errors", "The version was not detached."))}

  defp announce({:ok, version} = result, source_id, actor) do
    detached = Map.get(version.__metadata__, :detached, %{})

    Hook.call(
      @event,
      %{
        version_id: version.id,
        source_version_id: source_id,
        workspace_id: version.workspace_id,
        site_id: version.site_id,
        pages: Map.get(detached, :pages, 0)
      },
      meta: %{actor: actor, site_id: version.site_id},
      return: false
    )

    result
  end

  defp announce(result, _source_id, _actor), do: result
end
