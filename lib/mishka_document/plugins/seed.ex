# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_document/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaDocument.Plugins.Seed do
  @moduledoc """
  The documentation's parts of the installer's checklist: a plugin on `installer:seed`
  (`MishkaCmsCore.Install.Seeds`).

  Subscribing is the whole declaration. The installer lists the documentation's row with its two
  parts, the host's seed scripts run them with every other plugin's, and the `samples` part's `nav`
  puts `/docs` in every dev site's `Dev` dropdown. Priority 20 runs the documentation after the
  blog.

  | part | | installers |
  | --- | --- | --- |
  | `pages` | ticked at the start | dev, prod |
  | `samples` | ticked at the start | dev |

  Under its own key (`"mishka_document"`) it appends one report to `reports`; any other key goes back
  untouched.

    * `pages` asks `MishkaCmsCore.Install.Extensions.install/4` for the documentation, so
      `MishkaDocument.Plugins.Installer` writes the components, pages and permissions and the site
      is recorded as set up (`mishka_document.installed`). A refusal is reported as `%{error: reason}`.
    * `samples` runs `MishkaDocument.Dev.Seeds.dev_seed/3` at `size: :normal` and
      `MishkaDocument.Dev.Seeds.stress_seed/2`, at its default volumes, at `size: :stress`.

  SAMPLE DATA NEVER REACHES A PRODUCTION BUILD. Core does not show or run a `:dev` part there, and a
  `samples` call that arrives anyway is answered with `%{error: :dev_in_production}` and writes
  nothing (`MishkaCmsCore.Install.Seeds.production_build?/0`).
  """

  use Gettext, backend: MishkaCmsCore.Gettext

  use MishkaInstaller.Event.Hook,
    event: "installer:seed",
    initial: %{
      priority: 20,
      extra: [
        %{
          id: "pages",
          label: gettext_noop("Documentation pages and components"),
          summary:
            gettext_noop("The pages, components and permissions a site's documentation runs on"),
          envs: [:dev, :prod],
          default: true
        },
        %{
          id: "samples",
          label: gettext_noop("Sample documentation"),
          summary:
            gettext_noop("Five products' docs in versions and languages, with notes and issues"),
          envs: [:dev],
          default: true,
          nav: [%{label: "Docs", path: "/docs"}]
        }
      ]
    }

  alias MishkaCmsCore.Install.{Extensions, Seeds}
  alias MishkaDocument.Dev.Seeds, as: DevSeeds

  @key "mishka_document"

  @impl true
  def call(%{key: @key, part: part, reports: reports} = payload) do
    new_payload = %{payload | reports: reports ++ [run(part, payload)]}
    {:reply, new_payload}
  end

  def call(payload), do: {:reply, payload}

  defp run("pages", %{site_id: site_id} = payload) do
    case Extensions.install(site_id, @key, Map.get(payload, :answers, %{})) do
      {:ok, report} -> report
      {:error, reason} -> %{error: reason}
    end
  end

  defp run("samples", payload) do
    if Seeds.production_build?(), do: %{error: :dev_in_production}, else: sample(payload)
  end

  defp run(part, _payload), do: %{error: {:unknown_part, part}}

  defp sample(%{size: :stress, site_id: site_id, users: users}),
    do: DevSeeds.stress_seed(site_id, users)

  defp sample(%{site_id: site_id, users: users, progress: progress}),
    do: DevSeeds.dev_seed(site_id, users, progress)
end
