# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_document/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaDocument.Resources.Changes.SetEventMetadata do
  @moduledoc """
  Sets event metadata for activity log tracking.

  This change adds workspace_id, workspace_version_id, section_id, and other
  relevant metadata to the changeset context for AshEvents tracking.

  ## Options

    * `:resource_type` - The type of resource (required):
      - `:section` - workspace_version_id is on the record
      - `:note` - section_id is on the record, traces through section
      - `:section_draft` - workspace_version_id on record, uses source_section_id
      - `:note_draft` - workspace_version_id and section_id on record

    * `:for_action` - The action type (optional, defaults to `:update`):
      - `:create` - Uses changeset attributes
      - `:update` / `:destroy` - Uses changeset.data

  ## Usage

      change {MishkaDocument.Resources.Changes.SetEventMetadata,
              resource_type: :section, for_action: :create}

      change {MishkaDocument.Resources.Changes.SetEventMetadata,
              resource_type: :note, for_action: :update}
  """
  use Ash.Resource.Change

  @impl true
  def init(opts) do
    resource_type = Keyword.get(opts, :resource_type)

    if resource_type in [:section, :note, :section_draft, :note_draft] do
      {:ok, opts}
    else
      {:error,
       "resource_type must be one of :section, :note, :section_draft, :note_draft, got: #{inspect(resource_type)}"}
    end
  end

  @impl true
  def change(changeset, opts, context) do
    resource_type = Keyword.fetch!(opts, :resource_type)
    for_action = Keyword.get(opts, :for_action, :update)

    metadata = build_metadata(changeset, context, resource_type, for_action)
    Ash.Changeset.put_context(changeset, :ash_events_metadata, metadata)
  end

  # Section: workspace_version_id is directly on the record
  defp build_metadata(changeset, context, :section, :create) do
    workspace_version_id = Ash.Changeset.get_attribute(changeset, :workspace_version_id)
    # For master_create, site_id comes from attribute; for create, from context.tenant
    site_id = context.tenant || Ash.Changeset.get_attribute(changeset, :site_id)

    workspace_id = lookup_workspace_id(workspace_version_id, site_id)

    %{
      site_id: site_id,
      workspace_id: workspace_id,
      workspace_version_id: workspace_version_id,
      title: Ash.Changeset.get_attribute(changeset, :title)
    }
  end

  defp build_metadata(changeset, context, :section, _action) do
    workspace_version_id = changeset.data.workspace_version_id
    site_id = context.tenant || changeset.data.site_id

    workspace_id = lookup_workspace_id(workspace_version_id, site_id)

    %{
      site_id: site_id,
      workspace_id: workspace_id,
      workspace_version_id: workspace_version_id,
      title: Ash.Changeset.get_attribute(changeset, :title) || changeset.data.title
    }
  end

  # Note: section_id is on the record, need to trace through section
  defp build_metadata(changeset, context, :note, :create) do
    section_id = Ash.Changeset.get_attribute(changeset, :section_id)
    # For master_create, site_id comes from attribute; for create, from context.tenant
    site_id = context.tenant || Ash.Changeset.get_attribute(changeset, :site_id)

    {workspace_id, workspace_version_id} = lookup_workspace_from_section(section_id, site_id)

    %{
      site_id: site_id,
      workspace_id: workspace_id,
      workspace_version_id: workspace_version_id,
      section_id: section_id,
      title: Ash.Changeset.get_attribute(changeset, :title)
    }
  end

  defp build_metadata(changeset, context, :note, _action) do
    section_id = changeset.data.section_id
    site_id = context.tenant || changeset.data.site_id

    {workspace_id, workspace_version_id} = lookup_workspace_from_section(section_id, site_id)

    %{
      site_id: site_id,
      workspace_id: workspace_id,
      workspace_version_id: workspace_version_id,
      section_id: section_id,
      title: Ash.Changeset.get_attribute(changeset, :title) || changeset.data.title
    }
  end

  # SectionDraft: workspace_version_id on record, source_section_id for section_id
  defp build_metadata(changeset, context, :section_draft, :create) do
    workspace_version_id = Ash.Changeset.get_attribute(changeset, :workspace_version_id)
    source_section_id = Ash.Changeset.get_attribute(changeset, :source_section_id)
    # For master_create, site_id comes from attribute; for create, from context.tenant
    site_id = context.tenant || Ash.Changeset.get_attribute(changeset, :site_id)

    workspace_id = lookup_workspace_id(workspace_version_id, site_id)

    %{
      site_id: site_id,
      workspace_id: workspace_id,
      workspace_version_id: workspace_version_id,
      section_id: source_section_id,
      title: Ash.Changeset.get_attribute(changeset, :title)
    }
  end

  defp build_metadata(changeset, context, :section_draft, _action) do
    workspace_version_id = changeset.data.workspace_version_id
    source_section_id = changeset.data.source_section_id
    site_id = context.tenant || changeset.data.site_id

    workspace_id = lookup_workspace_id(workspace_version_id, site_id)

    %{
      site_id: site_id,
      workspace_id: workspace_id,
      workspace_version_id: workspace_version_id,
      section_id: source_section_id,
      title: Ash.Changeset.get_attribute(changeset, :title) || changeset.data.title
    }
  end

  # NoteDraft: workspace_version_id and section_id directly on record
  defp build_metadata(changeset, context, :note_draft, :create) do
    workspace_version_id = Ash.Changeset.get_attribute(changeset, :workspace_version_id)
    section_id = Ash.Changeset.get_attribute(changeset, :section_id)
    # For master_create, site_id comes from attribute; for create, from context.tenant
    site_id = context.tenant || Ash.Changeset.get_attribute(changeset, :site_id)

    workspace_id = lookup_workspace_id(workspace_version_id, site_id)

    %{
      site_id: site_id,
      workspace_id: workspace_id,
      workspace_version_id: workspace_version_id,
      section_id: section_id,
      title: Ash.Changeset.get_attribute(changeset, :title)
    }
  end

  defp build_metadata(changeset, context, :note_draft, _action) do
    workspace_version_id = changeset.data.workspace_version_id
    section_id = changeset.data.section_id
    site_id = context.tenant || changeset.data.site_id

    workspace_id = lookup_workspace_id(workspace_version_id, site_id)

    %{
      site_id: site_id,
      workspace_id: workspace_id,
      workspace_version_id: workspace_version_id,
      section_id: section_id,
      title: Ash.Changeset.get_attribute(changeset, :title) || changeset.data.title
    }
  end

  # Helper: lookup workspace_id from workspace_version_id
  defp lookup_workspace_id(nil, _site_id), do: nil

  defp lookup_workspace_id(workspace_version_id, site_id) do
    case Ash.get(MishkaDocument.WorkspaceVersion, workspace_version_id,
           tenant: site_id,
           authorize?: false
         ) do
      {:ok, version} when not is_nil(version) -> version.workspace_id
      _ -> nil
    end
  end

  # Helper: lookup workspace info from section_id
  defp lookup_workspace_from_section(nil, _site_id), do: {nil, nil}

  defp lookup_workspace_from_section(section_id, site_id) do
    case Ash.get(MishkaDocument.Section, section_id,
           tenant: site_id,
           authorize?: false
         ) do
      {:ok, section} when not is_nil(section) ->
        workspace_id = lookup_workspace_id(section.workspace_version_id, site_id)
        {workspace_id, section.workspace_version_id}

      _ ->
        {nil, nil}
    end
  end
end
