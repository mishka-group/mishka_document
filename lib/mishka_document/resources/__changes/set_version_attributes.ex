defmodule MishkaDocument.Resources.Changes.SetVersionAttributes do
  @moduledoc """
  Change module for setting custom version attributes from context.

  This change is used by PaperTrail version resources to populate custom
  attributes (change_description, change_version, review statuses) from
  the context when a version record is created.

  Using a proper Change module with atomic support avoids warnings about
  non-atomic updates on version resources.
  """
  use Ash.Resource.Change

  @doc """
  Declares this change as atomic-compatible.

  Version attribute changes can be done atomically at the database level
  since they're simple attribute assignments.
  """
  def atomic(_changeset, opts, context) do
    attributes = opts[:attributes] || []

    atomic_changes =
      attributes
      |> Enum.map(fn attribute ->
        case Map.get(context, attribute) do
          nil -> nil
          value -> {attribute, {:atomic, value}}
        end
      end)
      |> Enum.reject(&is_nil/1)
      |> Map.new()

    {:ok, atomic_changes}
  end

  def change(changeset, opts, context) do
    attributes = opts[:attributes] || []

    Enum.reduce(attributes, changeset, fn attribute, acc ->
      maybe_set_from_context(acc, attribute, context)
    end)
  end

  defp maybe_set_from_context(changeset, attribute, context) do
    case Map.get(context, attribute) do
      nil -> changeset
      value -> Ash.Changeset.change_attribute(changeset, attribute, value)
    end
  end
end
