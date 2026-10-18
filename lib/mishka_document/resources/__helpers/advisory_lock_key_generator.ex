# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_document/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaDocument.Resources.Helpers.AdvisoryLockKeyGenerator do
  @moduledoc """
  Extends AshEvents default advisory lock key generator to support nil tenants.

  This is needed for master admin actions that bypass multi-tenancy (nil tenant).
  For non-nil tenants, delegates to the default AshEvents implementation.
  """
  alias AshEvents.AdvisoryLockKeyGenerator.Default, as: DefaultKeyGenerator

  use AshEvents.AdvisoryLockKeyGenerator

  @impl true
  def generate_key!(changeset, default_integer) do
    case changeset.tenant do
      # When tenant is nil (master context), use the default key
      nil ->
        default_integer

      # For all other cases, use the default AshEvents implementation
      _ ->
        DefaultKeyGenerator.generate_key!(changeset, default_integer)
    end
  end
end
