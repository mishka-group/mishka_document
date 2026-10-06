defmodule MishkaDocument.Resources.Calculations.WordCount do
  @moduledoc """
  Reusable calculation for counting words in a content field.

  This module provides a simple word counting calculation that can be used
  across multiple resources (Section, Note, SectionDraft, NoteDraft).

  The calculation:
  - Returns 0 for nil or non-string content
  - Trims whitespace
  - Splits on any whitespace characters
  - Removes empty strings
  - Returns the count of remaining words
  """
  use Ash.Resource.Calculation

  @impl true
  def calculate(records, _opts, _context) do
    Enum.map(records, fn record ->
      if is_binary(record.content) do
        record.content
        |> String.trim()
        |> String.split(~r/\s+/)
        |> Enum.reject(&(&1 == ""))
        |> length()
      else
        0
      end
    end)
  end
end
