defmodule MishkaDocument.Resources.Calculations.CloneNumbers do
  @moduledoc """
  The version numbers of every version cloned from a version, however deep, nearest first —
  what deleting it deletes with it (`MishkaDocument.Resources.Helpers.VersionClones`). Read as
  the reader.
  """
  use Ash.Resource.Calculation

  alias MishkaDocument.Resources.Helpers.VersionClones

  @impl true
  def load(_query, _opts, _context), do: [:id, :site_id]

  @impl true
  def calculate(records, _opts, context) do
    case VersionClones.of(records, VersionClones.as_caller(context, context.source_context)) do
      {:ok, clones} ->
        {:ok,
         Enum.map(records, fn record -> Enum.map(clones[record.id], & &1.version_number) end)}

      {:error, _reason} = error ->
        error
    end
  end
end
