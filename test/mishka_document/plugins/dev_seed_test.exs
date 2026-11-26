# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_document/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaDocument.Plugins.DevSeedTest do
  @moduledoc """
  The documentation's seed on core's `dev:seed` event (`MishkaDocument.Plugins.DevSeed`): registered
  with the label, summary and link the installer's dev step and the dev header read, it answers only
  its own key, and answers it by running the documentation's dev seed and appending one report.

  The seed is run on a site that already has a workspace, so it takes the re-run path
  (`:already_seeded`) instead of writing five products' documentation.
  """
  use MishkaDocument.DataCase, async: false

  import MishkaDocument.Test.Factory

  alias MishkaCmsCore.Dev.Seeds
  alias MishkaDocument.Plugins.DevSeed
  alias MishkaInstaller.Event.{Event, EventHandler, Hook}

  # Registered by hand for the reason `MishkaDocument.ProvisionTest`'s `listening!/0` gives: this
  # suite's registry is not up when the extension's supervisor starts its plugins.
  setup do
    {:ok, _registered} = DevSeed.register()
    {:ok, _started} = DevSeed.start()
    on_exit(fn -> Event.unregister(:name, DevSeed, false) end)
    :ok = EventHandler.do_compile(Seeds.event(), :start, false)
    :ok
  end

  defp payload(key, site_id) do
    test = self()

    %{
      key: key,
      site_id: site_id,
      users: [],
      size: :dev,
      progress: fn line -> send(test, {:progress, line}) end,
      reports: []
    }
  end

  test "is one of the documentation's plugins, listed for the dev step with its label, summary and link" do
    assert DevSeed in MishkaDocument.Application.plugins()

    assert [category] = Enum.filter(Seeds.categories(), &(&1.key == "mishka_document"))
    assert category.label == "Mishka Document"
    assert category.summary != ""
    assert category.nav == [{"Docs", "/docs"}]
  end

  test "hands another extension's key back untouched" do
    sent = payload("mishka_blog", Ecto.UUID.generate())

    assert DevSeed.call(sent) == {:reply, sent}
    refute_received {:progress, _line}
  end

  test "runs the documentation's dev seed for its own key and appends exactly one report" do
    site = create_site!()
    create_workspace!(site_id: site.id, slug: "documented-before")

    assert %{reports: [:already_seeded]} =
             Hook.call(Seeds.event(), payload("mishka_document", site.id))

    assert_received {:progress, "Writing the documentation's sample pages…"}
  end
end
