defmodule MishkaDocument.Resources.Changes.StartFromSourceSection do
  @moduledoc """
  A draft of an existing page of a document starts with that page's SEO Tags, structured data and
  permissions — each one the draft is not given itself — so applying it does not take them off
  the page (`MishkaDocument.Resources.Changes.AutoApplySectionDraft`). What the draft holds from
  then on is what applying it writes: a draft edited to name no permission opens the page to
  everyone once it is applied.

      create :create do
        change MishkaDocument.Resources.Changes.StartFromSourceSection
      end
  """
  use Ash.Resource.Change

  @carried [:seo_tags, :schema, :permissions]

  @impl true
  def change(changeset, _opts, _context), do: Ash.Changeset.before_action(changeset, &carry/1)

  defp carry(changeset) do
    with id when is_binary(id) <- Ash.Changeset.get_attribute(changeset, :source_section_id),
         site_id when is_binary(site_id) <-
           Ash.Changeset.get_attribute(changeset, :site_id) || changeset.tenant,
         {:ok, section} <-
           Ash.get(MishkaDocument.Section, id, tenant: site_id, authorize?: false) do
      Enum.reduce(@carried, changeset, &carry(&2, &1, Map.get(section, &1)))
    else
      _no_source -> changeset
    end
  end

  defp carry(changeset, field, value) do
    case Ash.Changeset.get_attribute(changeset, field) do
      empty when empty in [nil, []] ->
        Ash.Changeset.force_change_attribute(changeset, field, value)

      _given ->
        changeset
    end
  end
end
