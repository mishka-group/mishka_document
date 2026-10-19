# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_document/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaDocument.Plugins.LiveVisitTest do
  @moduledoc """
  What a page is told about how its reader got there: `live_visit`, read from the connect params in
  `mount/3`, the one place a LiveView can read them, off the socket `MishkaCmsWeb.RuntimeLive` hands
  `RuntimeLive.OnMount.AfterCompile`.

  The plugin is registered by hand where the event is fired, for the reason
  `MishkaDocument.ProvisionTest`'s `listening!/0` gives, and the socket is built the way the channel
  builds one for a mount: connected when it has a transport, the connect params in its private.
  """
  use MishkaDocument.DataCase, async: false

  alias MishkaDocument.Plugins.LiveVisit
  alias MishkaInstaller.Event.EventHandler
  alias MishkaInstaller.Event.Hook

  @event "RuntimeLive.OnMount.AfterCompile"

  setup do
    {:ok, _registered} = LiveVisit.register()
    :ok = EventHandler.do_compile(@event, :start, false)
    :ok
  end

  defp mount_socket(connect_params, transport_pid \\ self()) do
    %Phoenix.LiveView.Socket{
      transport_pid: transport_pid,
      assigns: %{__changed__: %{}},
      private: %{connect_params: connect_params, connect_info: %{}}
    }
  end

  defp live_visit(socket), do: Hook.call(@event, socket).assigns.live_visit

  test "is one of the plugins this extension's supervisor starts" do
    assert LiveVisit in MishkaDocument.Application.plugins()
  end

  test "says a reader who followed a link, or pressed Back, arrived by a live navigation" do
    assert live_visit(mount_socket(%{"_live_referer" => "http://localhost:4000/cms"}))
  end

  test "says a reader who loaded the address did not" do
    refute live_visit(mount_socket(%{"_mounts" => 0}))
    refute live_visit(mount_socket(%{"_live_referer" => nil}))
    refute live_visit(mount_socket(%{"_live_referer" => ""}))
  end

  test "says nothing was navigated to while the page is only being served" do
    refute live_visit(mount_socket(%{"_live_referer" => "http://localhost:4000/cms"}, nil))
  end

  test "hands back whatever it is given that is not a socket" do
    assert Hook.call(@event, %{not: :a_socket}) == %{not: :a_socket}
  end
end
