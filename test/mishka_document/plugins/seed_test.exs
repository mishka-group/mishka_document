# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_document/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaDocument.Plugins.SeedTest do
  @moduledoc """
  The documentation's parts on core's `installer:seed` event (`MishkaDocument.Plugins.Seed`): listed with the
  flags, installers and link the checklist and the dev header read, it answers only its own key, and
  appends exactly one report per part it runs.

  `pages` goes through `installer:extension:install`, so `MishkaDocument.Plugins.Installer` is
  registered too. `samples` runs on a site that already has a workspace, so it takes the re-run
  path (`:already_seeded`) instead of writing five products' documentation.
  """
  use MishkaDocument.DataCase, async: false

  import MishkaDocument.Test.Factory

  alias MishkaCmsCore.Install.{Extensions, Seeds}
  alias MishkaCmsCore.Test.Installer, as: TestInstaller
  alias MishkaDocument.Plugins.{Installer, Seed}
  alias MishkaDocument.Test.Plugins.ProvisionSnippetSaved
  alias MishkaInstaller.Event.{Event, EventHandler, Hook}

  # Registered by hand for the reason `MishkaDocument.ProvisionTest`'s `listening!/0` gives: this
  # suite's registry is not up when the extension's supervisor starts its plugins. The CMS is not
  # installed yet, as during the installer's own run, so the install is answered with no actor.
  setup do
    :persistent_term.erase(:mishka_installed)

    for plugin <- [Seed, Installer] do
      {:ok, _registered} = plugin.register()
      {:ok, _started} = plugin.start()
      :ok = EventHandler.do_compile(plugin.config(:__event__), :start, false)
    end

    TestInstaller.register!(ProvisionSnippetSaved, "runtime:provision:snippets")

    on_exit(fn ->
      :persistent_term.erase(:mishka_installed)
      Event.unregister(:name, Seed, false)
    end)

    :ok
  end

  defp payload(key, part, site_id) do
    test = self()

    %{
      key: key,
      part: part,
      parts: ["pages", "samples"],
      env: :dev,
      size: :normal,
      site_id: site_id,
      users: [],
      answers: %{},
      foundation: %{},
      opts: [],
      progress: fn line -> send(test, {:progress, line}) end,
      reports: []
    }
  end

  defp docs(env) do
    env |> Seeds.plugins() |> Enum.find(&(&1.key == "mishka_document"))
  end

  # A PRODUCTION BUILD sets neither flag; the suite's own config sets `:env_test?`.
  defp as_production_build do
    flags =
      for key <- [:env_dev?, :env_test?], do: {key, Application.get_env(:mishka_cms_core, key)}

    Enum.each(flags, fn {key, _value} -> Application.delete_env(:mishka_cms_core, key) end)

    on_exit(fn ->
      for {key, value} <- flags,
          value != nil,
          do: Application.put_env(:mishka_cms_core, key, value)
    end)
  end

  test "is one of the documentation's plugins, supervised in every build" do
    assert Seed in MishkaDocument.Application.plugins()
    assert Seed.config(:__event__) == Seeds.event()
  end

  test "lists pages for both installers and samples for the dev one, both ticked, with its link" do
    assert %{parts: [pages, samples]} = docs(:dev)

    assert %{id: "pages", envs: [:dev, :prod], required: false, default: true, nav: []} = pages
    assert pages.label == "Documentation pages and components"

    assert %{id: "samples", envs: [:dev], required: false, default: true} = samples
    assert samples.nav == [%{label: "Docs", path: "/docs"}]

    assert %{parts: [%{id: "pages"}]} = docs(:prod)
  end

  test "hands another extension's key back untouched" do
    sent = payload("mishka_blog", "pages", Ecto.UUID.generate())

    assert Seed.call(sent) == {:reply, sent}
    refute_received {:progress, _line}
  end

  test "pages installs the documentation through the installer and records the site as set up" do
    site = create_site!()
    refute Extensions.installed?(site.id, :mishka_document)

    assert %{reports: [report]} =
             Hook.call(Seeds.event(), %{payload("mishka_document", "pages", site.id) | env: :prod})

    assert report.pages != []
    assert Extensions.installed?(site.id, :mishka_document)
  end

  test "pages reports the refusal as an error, and records nothing" do
    site = create_site!()
    MishkaCmsCore.Install.mark_installed!()

    assert %{reports: [%{error: {:extension_failed, _message}}]} =
             Hook.call(Seeds.event(), payload("mishka_document", "pages", site.id))

    refute Extensions.installed?(site.id, :mishka_document)
  end

  test "samples runs the documentation's dev seed for its own key and appends exactly one report" do
    site = create_site!()
    create_workspace!(site_id: site.id, slug: "documented-before")

    assert %{reports: [:already_seeded]} =
             Hook.call(Seeds.event(), payload("mishka_document", "samples", site.id))

    assert_received {:progress, "Writing the documentation's sample pages…"}
  end

  test "a production build lists no samples part and refuses one that arrives anyway" do
    as_production_build()
    site = create_site!()
    create_workspace!(site_id: site.id, slug: "documented-before")

    for env <- [:dev, :prod], do: assert(%{parts: [%{id: "pages"}]} = docs(env))
    assert {:error, :dev_in_production} = Seeds.run(:dev)

    assert %{reports: [%{error: :dev_in_production}]} =
             Hook.call(Seeds.event(), payload("mishka_document", "samples", site.id))

    refute_received {:progress, _line}
  end
end
