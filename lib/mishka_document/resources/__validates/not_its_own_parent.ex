# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_document/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaDocument.Resources.Validations.NotItsOwnParent do
  @moduledoc """
  Refuses a write that makes a record its own parent: the attribute `:field` may not hold the
  record's own id. Any other record, or none, is let through, and so is every create, whose record
  has no id yet. The refusal is `:message` on `:field`.

      validate {MishkaDocument.Resources.Validations.NotItsOwnParent,
                field: :parent_section_id,
                message: dgettext_noop("errors", "Section cannot be its own parent.")}

  ## Options

    * `:field` - required. The attribute holding the parent's id.
    * `:message` - required. The refusal.
  """
  use Ash.Resource.Validation

  @impl true
  def init(opts) do
    if Enum.all?([:field, :message], &Keyword.has_key?(opts, &1)),
      do: {:ok, opts},
      else: {:error, "NotItsOwnParent takes :field and :message"}
  end

  @impl true
  def validate(changeset, opts, _context) do
    parent_id = Ash.Changeset.get_attribute(changeset, opts[:field])

    if not is_nil(parent_id) and parent_id == changeset.data.id,
      do: {:error, field: opts[:field], message: opts[:message]},
      else: :ok
  end
end
