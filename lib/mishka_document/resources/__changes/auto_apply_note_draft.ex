# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_document/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaDocument.Resources.Changes.AutoApplyNoteDraft do
  @moduledoc """
  Automatically applies note draft changes when both approvals are granted.

  This change is triggered on NoteDraft update actions. When both
  content_review_status and technical_review_status are set to :approved,
  it automatically applies the note.

  A draft of an existing note writes only the fields it changes (its `changed_fields`, kept by
  `MishkaDocument.Resources.Changes.StartFromSource`); a draft of a new note writes all of itself.

  The note is written, and the draft marked applied, as whoever approved the draft, in the draft's
  site, so the resources' own policies answer for the approval too. The note and the section draft
  it depends on are looked up by id without the approver's read policies, since a lookup of a row
  the draft names must find it whatever the approver may list.
  """
  use Ash.Resource.Change
  use Gettext, backend: MishkaCmsCore.Gettext

  require Ash.Query

  def change(changeset, _opts, context) do
    Ash.Changeset.after_action(changeset, fn _changeset, draft ->
      if should_apply?(draft) do
        apply_draft(draft, context)
      else
        {:ok, draft}
      end
    end)
  end

  defp should_apply?(draft) do
    draft.content_review_status == :approved and
      draft.technical_review_status == :approved and
      is_nil(draft.applied_at)
  end

  defp apply_draft(draft, context) do
    tenant = draft.site_id

    # Check if we need to wait for section draft
    if draft.section_draft_id do
      case check_section_draft_applied(draft.section_draft_id, tenant) do
        {:ok, _section_id} ->
          apply_note_changes(draft, tenant, context)

        {:error, :not_applied} ->
          # Section draft not yet applied, don't apply note draft yet
          {:ok, draft}

        {:error, _} = error ->
          error
      end
    else
      # No section draft dependency, apply immediately
      apply_note_changes(draft, tenant, context)
    end
  end

  defp check_section_draft_applied(section_draft_id, tenant) do
    case Ash.get(MishkaDocument.SectionDraft, section_draft_id,
           tenant: tenant,
           authorize?: false
         ) do
      {:ok, section_draft} ->
        if section_draft.applied_at do
          # Section draft has been applied, find the created section
          # We need to find the section with matching workspace_version_id and title/slug
          {:ok, :ready}
        else
          {:error, :not_applied}
        end

      {:error, _} = error ->
        error
    end
  end

  defp apply_note_changes(draft, tenant, context) do
    if draft.source_note_id do
      # UPDATING EXISTING NOTE
      update_existing_note(draft, tenant, context)
    else
      # CREATING NEW NOTE
      create_new_note(draft, tenant, context)
    end
  end

  # What the draft changes, and nothing else: a note field it leaves as the note has it is never
  # written over (`MishkaDocument.Resources.Changes.StartFromSource`).
  defp update_existing_note(draft, tenant, context) do
    case Ash.get(MishkaDocument.Note, draft.source_note_id,
           tenant: tenant,
           authorize?: false
         ) do
      {:ok, note} ->
        write(note, Map.take(draft, changes(draft)), tenant, context)

        {:ok, mark_draft_applied(draft, tenant, context)}

      {:error, _} = error ->
        error
    end
  end

  defp changes(draft),
    do: Enum.filter(MishkaDocument.NoteDraft.note_fields(), &(&1 in draft.changed_fields))

  defp write(_record, changes, _tenant, _context) when map_size(changes) == 0, do: :unchanged

  defp write(record, changes, tenant, context) do
    record
    |> Ash.Changeset.for_update(:update, changes, Ash.Scope.to_opts(context, tenant: tenant))
    |> Ash.update!()
  end

  defp create_new_note(draft, tenant, context) do
    # Determine section_id
    section_id =
      if draft.section_id do
        draft.section_id
      else
        # If section_draft_id is set, find the created section
        get_section_from_draft(draft.section_draft_id, tenant, context)
      end

    case section_id do
      nil ->
        {:error, dgettext_noop("errors", "Cannot determine section for note")}

      section_id ->
        # Create new note
        case MishkaDocument.Note
             |> Ash.Changeset.for_create(
               :create,
               %{
                 section_id: section_id,
                 title: draft.title,
                 content: draft.content,
                 order_position: draft.order_position,
                 change_version: draft.change_version,
                 content_review_status: :approved,
                 technical_review_status: :approved,
                 schema: draft.schema,
                 seo_tags: draft.seo_tags
               },
               Ash.Scope.to_opts(context, tenant: tenant)
             )
             |> Ash.create() do
          {:ok, _new_note} ->
            # Mark draft as applied and return updated draft
            updated_draft = mark_draft_applied(draft, tenant, context)

            {:ok, updated_draft}

          {:error, _} = error ->
            error
        end
    end
  end

  defp get_section_from_draft(section_draft_id, tenant, context) do
    case Ash.get(MishkaDocument.SectionDraft, section_draft_id,
           tenant: tenant,
           authorize?: false
         ) do
      {:ok, section_draft} ->
        if section_draft.source_section_id do
          # Draft was updating existing section
          section_draft.source_section_id
        else
          # Draft created new section, find it by matching criteria
          # This is a simplification - in production you might want to store the created section_id on the draft
          case MishkaDocument.Section
               |> Ash.Query.filter(
                 workspace_version_id == ^section_draft.workspace_version_id and
                   slug == ^section_draft.slug
               )
               |> Ash.read(Ash.Scope.to_opts(context, tenant: tenant)) do
            {:ok, [section | _]} -> section.id
            _ -> nil
          end
        end

      _ ->
        nil
    end
  end

  defp mark_draft_applied(draft, tenant, context) do
    draft
    |> Ash.Changeset.for_update(
      :mark_applied,
      %{applied_at: DateTime.utc_now()},
      Ash.Scope.to_opts(context, tenant: tenant)
    )
    |> Ash.update!()
  end
end
