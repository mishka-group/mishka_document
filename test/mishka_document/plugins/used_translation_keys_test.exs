# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_document/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaDocument.Plugins.UsedTranslationKeysTest do
  @moduledoc """
  The words the documentation looks up in a site's translations, named to
  `MishkaCmsCore.Runtime.Translations.used_keys/1`: the bar under the header asks for them from a
  plugin, so no template holds them, and "Remove unused" would delete them and what a translator
  wrote for them if nothing said they are asked for.
  """
  use MishkaDocument.DataCase, async: false

  alias MishkaCmsCore.Runtime.Translations
  alias MishkaDocument.Plugins.{PageFrame, UsedTranslationKeys}

  setup do
    {:ok, site: create_site!(active: true)}
  end

  describe "as a plugin" do
    test "is supervised by this extension" do
      assert UsedTranslationKeys in MishkaDocument.Application.plugins()
    end

    test "answers the event core asks for the keys on" do
      assert UsedTranslationKeys.config(:__event__) == Translations.used_keys_event()
    end

    test "adds the bar's words to the keys it is handed, and keeps the others" do
      assert {:reply, %{site_id: nil, keys: ["Blog", "Docs"]}} =
               UsedTranslationKeys.call(%{site_id: nil, keys: ["Blog"]})

      assert PageFrame.words() == ["Docs"]
    end

    test "hands anything else back as it came" do
      assert {:reply, :other} = UsedTranslationKeys.call(:other)
    end
  end

  describe "the keys a site uses" do
    # Whether an earlier test left the plugin registered depends on the order they ran in, so the
    # case starts with it taken off the event.
    test "include the bar's words once the plugin is registered, and not before", %{site: site} do
      event = Translations.used_keys_event()

      unregistered = fn ->
        MishkaInstaller.Event.Event.unregister(:name, UsedTranslationKeys, false)
        MishkaInstaller.Event.EventHandler.do_compile(event, :start, false)
      end

      unregistered.()
      on_exit(unregistered)

      refute "Docs" in Translations.used_keys(site.id)

      MishkaCmsCore.PluginRegistrations.reconcile(false)
      {:ok, _registered} = UsedTranslationKeys.register()
      :ok = MishkaInstaller.Event.EventHandler.do_compile(event, :start, false)

      for word <- PageFrame.words() do
        assert word in Translations.used_keys(site.id)
        assert word in Translations.used_keys(nil)
      end
    end
  end
end
