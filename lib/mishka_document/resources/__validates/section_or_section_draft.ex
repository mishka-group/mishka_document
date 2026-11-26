# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_document/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaDocument.Resources.Validations.SectionOrSectionDraft do
  @moduledoc """
  Holds a note draft to exactly one place: a page (`section_id`) or a page draft
  (`section_draft_id`). A draft naming neither, or both, is refused.

      validate MishkaDocument.Resources.Validations.SectionOrSectionDraft

  The refusal is kept untranslated (`dgettext_noop`, `errors` domain of `MishkaCmsCore.Gettext`),
  as the resource's own messages are.
  """
  use Ash.Resource.Validation
  use Gettext, backend: MishkaCmsCore.Gettext

  @impl true
  def validate(changeset, _opts, _context) do
    check(
      Ash.Changeset.get_attribute(changeset, :section_id),
      Ash.Changeset.get_attribute(changeset, :section_draft_id)
    )
  end

  defp check(nil, nil),
    do:
      {:error,
       message: dgettext_noop("errors", "Must specify either section_id or section_draft_id.")}

  defp check(section_id, section_draft_id)
       when not is_nil(section_id) and not is_nil(section_draft_id),
       do:
         {:error,
          message: dgettext_noop("errors", "Cannot specify both section_id and section_draft_id.")}

  defp check(_section_id, _section_draft_id), do: :ok
end
