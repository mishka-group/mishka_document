# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_document/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaDocument.Plugins.Installer do
  @moduledoc """
  Installs the documentation onto one site, when asked.

  Subscribing to `installer:extension:install` is the whole declaration: the installer's own
  registry now knows this extension exists, under `:mishka_document`, at priority 50, and `:extra` below
  is what the picker draws. Nothing is registered anywhere else, and there is no list of extensions
  to keep in step with this file.

  A SITE IS NEVER SET UP BEHIND SOMEBODY'S BACK. This answers a request naming a site; it does not
  listen for a site being created. A site added to a running CMS gets its own core content and
  nothing else until an admin asks for the blog from the Documents menu — which is the only honest
  default, because a site may be a shop that will never have documentation.
  """

  use Gettext, backend: MishkaCmsCore.Gettext

  use MishkaInstaller.Event.Hook,
    event: "installer:extension:install",
    initial: %{
      priority: 50,
      extra: [
        %{
          label: gettext_noop("Documentation"),
          summary:
            gettext_noop("Versioned documents and their sections, with the pages that read them"),
          fields: []
        }
      ]
    }

  require Logger

  alias MishkaDocument.Provision

  @key "mishka_document"

  @doc """
  Installs the documentation when the payload names it, and hands the payload on untouched when it does not.

  The report goes back in `:reports` rather than as the reply itself, because every plugin on this
  event sees every call: replying with the report would make the next plugin's payload a report.
  """
  @impl true
  # IS IT ALREADY HERE? Asked of every site that carries no record of an install — every site that
  # existed before there was an installer. Only this extension knows what its own pages are called,
  # so core asks rather than guessing, and a site already running them is sent to its dashboard.
  def call(%{key: @key, site_id: site_id, ask: :status, reports: reports} = payload)
      when is_binary(site_id) do
    installed? = pages_present?(site_id)

    # A SITE FOUND ALREADY SET UP is recorded as installed without a run, so the names a run would
    # have created are created here.
    if installed?, do: Provision.ensure_permissions()

    {:reply, %{payload | reports: reports ++ [%{installed?: installed?}]}}
  end

  def call(%{key: @key, site_id: site_id, reports: reports} = payload)
      when is_binary(site_id) do
    answers = Map.get(payload, :answers, %{})

    # THE ACTOR RIDES ON THE PAYLOAD, put there by whoever asked. The wizard sends none — it runs
    # before there is a user — and a dashboard sends the session's, so what this writes is written
    # as them and the resource's own policy answers for it.
    actor = Map.get(payload, :actor)

    {:reply, %{payload | reports: reports ++ [Provision.ensure!(site_id, answers, actor: actor)]}}
  rescue
    error ->
      # THE RESCUE STAYS BECAUSE CORE OFFERS ONLY `ensure!/4`: the install writes through the
      # raising API, and one extension's failure must not take the installer down with it. WHAT THE
      # SITE DID GET STAYS WRITTEN. The components go in before the pages, so a run that raises has
      # usually written some of it, and rolling back would take away what works. The screen gets a
      # fixed message, never the exception's own text, and the logs carry the detail; a second run
      # writes only what is still missing, which is what makes pressing the button again the right
      # thing to do.
      Logger.error("[MishkaDocument] install on #{site_id} failed: #{Exception.message(error)}")
      {:reply, %{payload | reports: payload.reports ++ [%{error: install_failed_message()}]}}
  end

  def call(payload), do: {:reply, payload}

  # ANY OF THEM, not all. A site an admin has pruned still has this extension; a site that has never
  # had it has none of them.
  defp pages_present?(site_id) do
    require Ash.Query

    paths = Provision.page_paths()

    MishkaCmsCore.Runtime.Page
    |> Ash.Query.for_read(:read_any, %{}, authorize?: false)
    |> Ash.Query.filter(site_id == ^site_id and path in ^paths)
    |> Ash.Query.select([:id])
    |> Ash.read(authorize?: false, page: [limit: 1])
    |> case do
      {:ok, %{results: rows}} -> rows != []
      {:error, _unreadable} -> false
    end
  end

  defp install_failed_message do
    gettext("The install did not finish. Press Install again; details are in the server log.")
  end
end
