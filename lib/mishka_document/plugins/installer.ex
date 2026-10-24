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
  nothing else until an admin asks for the documentation from the Documents menu — which is the only honest
  default, because a site may be a shop that will never have documentation.

  The request's `:actor` is whoever pressed the button and must hold what
  `MishkaCmsCore.Runtime.ExtensionProvision.required/1` names. A request with no actor is the
  install wizard's own run and is answered only until the CMS is installed
  (`MishkaCmsCore.Install.installed?/0`); after that it is refused like an actor holding nothing.
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

  alias MishkaCmsCore.Install
  alias MishkaCmsCore.Runtime.ExtensionProvision
  alias MishkaDocument.Provision

  @key "mishka_document"

  @doc """
  Installs the documentation when the payload names it, and hands the payload on untouched when it does not.

  The report goes back in `:reports` rather than as the reply itself, because every plugin on this
  event sees every call: replying with the report would make the next plugin's payload a report.
  """
  @impl true
  # ONLY AN INSTALL IS ANSWERED. A site this extension was installed on carries the record core writes
  # after the run (`MishkaCmsCore.Install.Extensions.installed?/2`), so core's `ask: :status`, asked of
  # a site with no record, is of a site that has never had it: handed back untouched, it reads as
  # not installed.
  def call(%{key: @key, site_id: site_id, ask: :install, reports: reports} = payload)
      when is_binary(site_id) do
    answers = Map.get(payload, :answers, %{})

    # THE ACTOR RIDES ON THE PAYLOAD, put there by whoever asked. The wizard sends none — it runs
    # before there is a user — and a dashboard sends the session's, so what this writes is written
    # as them and the resource's own policy answers for it. NOBODY IS ANSWERED ONLY WHILE THE CMS IS
    # BEING INSTALLED: once it is, a request with no actor is refused like an actor holding nothing.
    actor = Map.get(payload, :actor)

    report =
      case missing(actor) do
        [] ->
          Provision.ensure!(site_id, answers, actor: actor)

        names ->
          %{
            error:
              gettext("Setting the documentation up needs these permissions: %{names}",
                names: Enum.join(names, ", ")
              )
          }
      end

    {:reply, %{payload | reports: reports ++ [report]}}
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

  defp missing(nil) do
    if Install.installed?(),
      do: ExtensionProvision.missing(Provision.manifest(), nil),
      else: []
  end

  defp missing(actor), do: ExtensionProvision.missing(Provision.manifest(), actor)

  defp install_failed_message do
    gettext("The install did not finish. Press Install again; details are in the server log.")
  end
end
