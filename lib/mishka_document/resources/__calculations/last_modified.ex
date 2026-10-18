# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_document/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaDocument.Resources.Calculations.LastModified do
  @moduledoc """
  When a section — one page of a document — last changed: the newest of its own `updated_at`, the
  `updated_at` of the notes its page shows (approved, not archived) and the time a note was
  archived, which takes the note off the page. A section with no notes keeps its own.

  The sitemap's `lastmod`, the page's `dateModified` and `doc.modified_at`, and the "Updated" line
  under the page's title read this one value. Notes are read as part of the section's own query
  (`latest_note_change_at` and `latest_note_archived_at`), so a batch of sections is one read, and
  nothing is written to a section when a note changes.

      calculate :last_modified_at, :utc_datetime_usec, LastModified
  """
  use Ash.Resource.Calculation

  @impl true
  def load(_query, _opts, _context),
    do: [:updated_at, :latest_note_change_at, :latest_note_archived_at]

  @impl true
  def calculate(sections, _opts, _context) do
    Enum.map(sections, fn section ->
      [section.updated_at, section.latest_note_change_at, section.latest_note_archived_at]
      |> Enum.reject(&is_nil/1)
      |> Enum.max(DateTime, fn -> nil end)
    end)
  end
end
