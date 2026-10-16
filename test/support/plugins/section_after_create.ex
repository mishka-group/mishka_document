# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_document/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaDocument.Test.Plugins.SectionAfterCreate do
  @moduledoc "Test plugin: reports `document:section:after_create` to the `:__plugin_hook_probe__` process."
  use MishkaInstaller.Event.Hook, event: "document:section:after_create"

  @impl true
  def call(record, meta) do
    if pid = Process.whereis(:__plugin_hook_probe__),
      do: send(pid, {:document_section_after_create, record.id, meta})

    {:reply, record}
  end
end
