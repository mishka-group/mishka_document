defmodule MishkaDocument.Resources.Changes.AutoApplySectionDraft do
  @moduledoc """
  Automatically applies section draft changes when both approvals are granted.

  This change is triggered on SectionDraft update actions. When both
  content_review_status and technical_review_status are set to :approved,
  it automatically applies the section.
  """
  use Ash.Resource.Change

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

    if draft.source_section_id do
      # UPDATING EXISTING SECTION
      update_existing_section(draft, tenant, context)
    else
      # CREATING NEW SECTION
      create_new_section(draft, tenant, context)
    end
  end

  defp update_existing_section(draft, tenant, _context) do
    case Ash.get(MishkaDocument.Section, draft.source_section_id,
           tenant: tenant,
           authorize?: false
         ) do
      {:ok, section} ->
        # Update the section with draft data
        section
        |> Ash.Changeset.for_update(
          :update,
          %{
            title: draft.title,
            slug: draft.slug,
            content: draft.content,
            order_position: draft.order_position,
            change_version: draft.change_version,
            parent_section_id: draft.parent_section_id,
            schema: draft.schema,
            seo_tags: draft.seo_tags,
            permissions: draft.permissions,
            language: draft.language,
            language_group_id: draft.language_group_id
          },
          tenant: tenant,
          authorize?: false
        )
        |> Ash.update!()

        # Mark draft as applied and return the updated draft
        updated_draft = mark_draft_applied(draft, tenant)

        {:ok, updated_draft}

      {:error, _} = error ->
        error
    end
  end

  defp create_new_section(draft, tenant, _context) do
    # Build base params
    base_params = %{
      workspace_version_id: draft.workspace_version_id,
      parent_section_id: draft.parent_section_id,
      title: draft.title,
      slug: draft.slug,
      content: draft.content,
      order_position: draft.order_position,
      change_version: draft.change_version,
      content_review_status: :approved,
      technical_review_status: :approved,
      schema: draft.schema,
      seo_tags: draft.seo_tags,
      permissions: draft.permissions,
      language: draft.language
    }

    # Only include language_group_id if it has a value (not nil)
    # If nil, SetLanguageGroupId change will auto-set it to section's own ID
    params =
      if draft.language_group_id do
        Map.put(base_params, :language_group_id, draft.language_group_id)
      else
        base_params
      end

    # Create new section
    case MishkaDocument.Section
         |> Ash.Changeset.for_create(
           :create,
           params,
           tenant: tenant,
           authorize?: false
         )
         |> Ash.create() do
      {:ok, _new_section} ->
        # Mark draft as applied and return the updated draft
        updated_draft = mark_draft_applied(draft, tenant)

        {:ok, updated_draft}

      {:error, _} = error ->
        error
    end
  end

  defp mark_draft_applied(draft, tenant) do
    draft
    |> Ash.Changeset.for_update(
      :mark_applied,
      %{applied_at: DateTime.utc_now()},
      tenant: tenant,
      authorize?: false
    )
    |> Ash.update!()
  end
end
