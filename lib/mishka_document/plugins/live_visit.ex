# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_document/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaDocument.Plugins.LiveVisit do
  @moduledoc """
  Gives a page a `live_visit` assign: `true` when the reader reached it by a live navigation, a click
  on a link of the site or the browser's Back and Forward, and `false` on a full load.

  `doc-workspace-list` takes it as its `live_visit` attribute and, when it is `true`, draws skeleton
  cards and streams the cards in behind them, where a full load serves them in the page's HTML.

  ## Where it is read

  A LiveView can read `Phoenix.LiveView.get_connect_params/1` only in its own `mount/3`, and a live
  component never. So it is answered on `RuntimeLive.OnMount.AfterCompile`, which
  `MishkaCmsWeb.RuntimeLive` fires from `mount/3` with the socket, and kept as an assign for the
  page to hand down. The client sends `"_live_referer"` when the join comes from a live navigation,
  and never on the first connection after a full load.

  A module because a mishka_installer hook is one. Registered in `MishkaDocument.Application`.
  """

  use MishkaInstaller.Event.Hook,
    event: "RuntimeLive.OnMount.AfterCompile",
    initial: %{priority: 50}

  @impl true
  def call(%Phoenix.LiveView.Socket{} = socket),
    do: {:reply, Phoenix.Component.assign(socket, :live_visit, live_visit?(socket))}

  def call(state), do: {:reply, state}

  defp live_visit?(socket) do
    with true <- Phoenix.LiveView.connected?(socket),
         %{"_live_referer" => referer} when is_binary(referer) and referer != "" <-
           Phoenix.LiveView.get_connect_params(socket) do
      true
    else
      _full_load_or_not_connected -> false
    end
  end
end
