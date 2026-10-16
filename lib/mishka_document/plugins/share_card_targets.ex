# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_document/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaDocument.Plugins.ShareCardTargets do
  @moduledoc """
  A plain mishka_installer plugin: answers `MishkaCmsCore.Runtime.ShareCard.targets_event/0` with
  the documentation's share cards on the site asked, under `"mishka_document"` — every published
  document's front page and every page of it, in each language and version a visitor reaches
  (`MishkaDocument.ShareCards.targets/1`). Names its producer alone when asked for names, and
  nothing when another producer is asked (`MishkaCmsCore.Runtime.ShareCard.put_targets/3`).

  Answering is what puts the Redraw button in the documentation's "on this site" modal
  (`MishkaCmsCoreWeb.Live.Admin.Components.ExtensionInstallerPanel.doctor_modal/1`) and its row on
  the SEO settings. Registered in `MishkaDocument.Application`.
  """
  use MishkaInstaller.Event.Hook,
    event: MishkaCmsCore.Runtime.ShareCard.targets_event(),
    initial: %{priority: 60}

  alias MishkaCmsCore.Runtime.ShareCard
  alias MishkaDocument.ShareCards

  @producer "mishka_document"

  @doc "The name the documentation's targets are put under: `\"#{@producer}\"`."
  @spec producer() :: String.t()
  def producer, do: @producer

  @impl true
  def call(%{site_id: site_id} = data),
    do: {:reply, ShareCard.put_targets(data, @producer, fn -> ShareCards.targets(site_id) end)}

  def call(data), do: {:reply, data}
end
