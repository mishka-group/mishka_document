# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_document/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaDocument.ContentTextTest do
  @moduledoc """
  A page's content is HTML, and what it reads as is its text: a card's preview and its word count
  are of that text, not of its markup.
  """
  use MishkaDocument.DataCase, async: false

  alias MishkaDocument.{ContentText, NoteDraft, Section, SectionDraft}

  doctest MishkaDocument.ContentText

  @content ~s(<h2 dir="auto">Install</h2><p dir="auto">Run <code>mix setup</code>, then&nbsp;start.</p>)

  test "reads a rich page as its text, one block a word apart from the next" do
    assert ContentText.text(@content) == "Install Run mix setup , then start."
    assert ContentText.preview(@content, 11) == "Install Run"
  end

  test "counts the words of a page, a section draft and a note draft in their text" do
    site = create_site!(active: true)
    admin = create_user_with_permissions!(["admin:dashboard:document:section"], site_id: site.id)
    section = create_section!(site_id: site.id, content: @content)

    section_draft =
      create_section_draft!(
        site_id: site.id,
        workspace_version_id: section.workspace_version_id,
        content: @content
      )

    note_draft =
      create_note_draft!(
        site_id: site.id,
        section_id: section.id,
        workspace_version_id: section.workspace_version_id,
        content: @content
      )

    for {resource, record} <- [
          {Section, section},
          {SectionDraft, section_draft},
          {NoteDraft, note_draft}
        ] do
      loaded = Ash.load!(record, :content_word_count, actor: admin, tenant: site.id)

      assert loaded.content_word_count == 7,
             "#{inspect(resource)} counted #{loaded.content_word_count} words"
    end
  end
end
