# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_document/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaDocument.Resources.Calculations.WordCount do
  @moduledoc """
  Reusable calculation for counting words in a content field.

  This module provides a simple word counting calculation that can be used
  across multiple resources (Section, Note, SectionDraft, NoteDraft).

  The words are those of the content's text, without its markup (`MishkaDocument.ContentText`):
  `<p dir="auto">Hello world</p>` is two. No content is none.
  """
  use Ash.Resource.Calculation

  @impl true
  def calculate(records, _opts, _context),
    do: Enum.map(records, &MishkaDocument.ContentText.word_count(&1.content))
end
