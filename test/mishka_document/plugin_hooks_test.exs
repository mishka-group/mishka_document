# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_document/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaDocument.PluginHooksTest do
  @moduledoc """
  The reusable plugin-hook notifier on this extension's resources really does dispatch
  `document:<resource>:after_<action>` when the real Ash action runs — asserted end to end through the
  live `MishkaInstaller` event engine, not by inspecting the notifier.

  See `MishkaCmsCore.PluginHooksTest` for the same proof on the library's own resources.
  """
  use MishkaDocument.DataCase, async: false

  import MishkaDocument.Test.Factory

  alias MishkaInstaller.Event.{Event, EventHandler}
  alias MishkaDocument.Test.Plugins.SectionAfterCreate

  @event "document:section:after_create"

  setup do
    Process.register(self(), :__plugin_hook_probe__)
    register_plugin(SectionAfterCreate, @event)
    on_exit(fn -> Event.unregister(:name, SectionAfterCreate, false) end)
    :ok
  end

  test "section :create dispatches document:section:after_create" do
    section = create_section!()
    id = section.id

    assert_receive {:document_section_after_create, ^id, _meta}, 5000
  end

  defp register_plugin(module, event) do
    {:ok, _} =
      Event.write(%{
        name: module,
        event: event,
        extension: :mishka_installer,
        status: :started
      })

    :ok = EventHandler.do_compile(event, :start, false)
  end
end
