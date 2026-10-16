# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_document/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaDocument.Resources.Helpers.ClearRecordsForReplay do
  @moduledoc """
  Implements the clear records behavior for event replay.

  Since we're using events purely for activity tracking (not event sourcing),
  this is a minimal implementation that does nothing.
  """
  @behaviour AshEvents.ClearRecordsForReplay

  @impl true
  def clear_records!(_query) do
    # We don't support replay - events are for audit/activity tracking only
    :ok
  end
end
