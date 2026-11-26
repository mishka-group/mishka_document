# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_document/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaDocument.Plugins.DevSeed do
  @moduledoc """
  Adds the documentation's sample data to the dev seeds: a plugin on
  `MishkaCmsCore.Dev.Seeds.event/0`.

  Subscribing is the whole declaration. The installer's dev step lists the documentation under the
  label and summary below, the host's seed scripts run it with every other seed, and `nav` puts
  `/docs` in every dev site's `Dev` dropdown. Priority 20 seeds the documentation after the blog.

  Under its own key (`"mishka_document"`) it runs `MishkaDocument.Dev.Seeds.dev_seed/3` for
  `size: :dev` and `MishkaDocument.Dev.Seeds.stress_seed/2`, at its default volumes, for
  `size: :stress`, and appends what the seed returned to `reports`. Any other key goes back
  untouched.

  DEV ONLY. `MishkaDocument.Application` supervises it only where the config sets `:env_dev?` or
  `:env_test?`, so a production build never registers it.
  """

  use Gettext, backend: MishkaCmsCore.Gettext

  use MishkaInstaller.Event.Hook,
    event: MishkaCmsCore.Dev.Seeds.event(),
    initial: %{
      priority: 20,
      extra: [
        %{
          label: gettext_noop("Mishka Document"),
          summary:
            gettext_noop("Five products' docs in versions and languages, with notes and issues"),
          nav: [%{label: "Docs", path: "/docs"}]
        }
      ]
    }

  alias MishkaDocument.Dev.Seeds

  @key "mishka_document"

  @impl true
  def call(%{key: @key, reports: reports} = payload),
    do: {:reply, %{payload | reports: reports ++ [seed(payload)]}}

  def call(payload), do: {:reply, payload}

  defp seed(%{size: :dev, site_id: site_id, users: users, progress: progress}),
    do: Seeds.dev_seed(site_id, users, progress)

  defp seed(%{size: :stress, site_id: site_id, users: users}),
    do: Seeds.stress_seed(site_id, users)
end
