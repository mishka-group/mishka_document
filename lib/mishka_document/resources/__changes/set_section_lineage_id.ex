defmodule MishkaDocument.Resources.Changes.SetSectionLineageId do
  @moduledoc """
  Automatically sets section_lineage_id for tracking section versions across workspace versions.

  - New sections (no source): section_lineage_id = record.id after insert
  - Cloned sections (has source): section_lineage_id = source's section_lineage_id, copied as the
    write runs, after its validations. It may name a first section that has since been deleted; a
    first section of another site is refused.
  - A section_lineage_id the writer gives is kept, and must name a section of the same site.
  """
  use Ash.Resource.Change
  use Gettext, backend: MishkaCmsCore.Gettext

  alias MishkaCmsCore.Runtime.Resources.Validations.SameSiteReference

  @impl true
  def change(changeset, _opts, _context) do
    section_lineage_id = Ash.Changeset.get_attribute(changeset, :section_lineage_id)
    source_section_id = Ash.Changeset.get_attribute(changeset, :source_section_id)

    cond do
      # Already has lineage_id (explicitly provided)
      !is_nil(section_lineage_id) ->
        changeset

      # Has source section - copy its lineage_id
      !is_nil(source_section_id) ->
        Ash.Changeset.before_action(changeset, &copy_lineage_from_source(&1, source_section_id))

      # New section - set lineage_id = record.id after insert
      true ->
        own_lineage_after_insert(changeset)
    end
  end

  defp copy_lineage_from_source(changeset, source_section_id) do
    case Ash.get(MishkaDocument.Section, source_section_id,
           action: :read_any,
           authorize?: false
         ) do
      {:ok, source} when not is_nil(source) ->
        # Use source's lineage_id, or source's own id if it doesn't have one yet
        lineage_id = source.section_lineage_id || source.id

        changeset
        |> Ash.Changeset.force_change_attribute(:section_lineage_id, lineage_id)
        |> hold_lineage_to_site(lineage_id)

      _ ->
        # Source not found - fall back to setting lineage_id after insert
        own_lineage_after_insert(changeset)
    end
  end

  defp hold_lineage_to_site(changeset, lineage_id) do
    case Ash.get(MishkaDocument.Section, lineage_id,
           action: :master_get,
           authorize?: false,
           not_found_error?: false
         ) do
      {:ok, nil} -> changeset
      _first_or_unknown -> refuse_unless_same_site(changeset)
    end
  end

  defp refuse_unless_same_site(changeset) do
    {:ok, opts} =
      SameSiteReference.init(
        field: :section_lineage_id,
        resource: MishkaDocument.Section,
        label: dgettext_noop("errors", "section"),
        read_action: :master_get
      )

    case SameSiteReference.validate(changeset, opts, %Ash.Resource.Validation.Context{}) do
      :ok -> changeset
      {:error, refusal} -> Ash.Changeset.add_error(changeset, refusal)
    end
  end

  defp own_lineage_after_insert(changeset) do
    Ash.Changeset.after_action(changeset, fn _changeset, record ->
      record
      |> Ash.Changeset.for_update(:update, %{section_lineage_id: record.id},
        tenant: record.site_id,
        authorize?: false
      )
      |> Ash.update()
    end)
  end
end
