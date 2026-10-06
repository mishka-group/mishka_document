defmodule MishkaDocument.ActivityDiscoveryTest do
  @moduledoc """
  The activity log finds THIS extension's event log, and the shared source claims its broadcasts.

  `MishkaCmsCore.Activity.Discovery` scans every configured domain at run time and names no extension,
  so the only place the claim "it reaches this extension" can be tested is here, where this extension
  is the thing being installed. `MishkaCmsCore.Activity.DiscoveryTest` covers the scan's invariants;
  each extension asserts its own half.
  """
  use ExUnit.Case, async: true

  alias MishkaCmsCore.Activity.Discovery
  alias MishkaCmsCore.Activity.Sources.EventLog, as: EventLogSource

  test "event_logs/0 discovers this extension's event log" do
    assert MishkaDocument.EventLog in Discovery.event_logs()
  end

  test "the EventLog source claims a broadcast carrying this extension's event log" do
    broadcast = %Phoenix.Socket.Broadcast{
      topic: "event_log:created",
      event: "create",
      payload: %Ash.Notifier.Notification{resource: MishkaDocument.EventLog, data: %{id: "x"}}
    }

    assert EventLogSource.handles?(broadcast)
    refute EventLogSource.handles?(%Phoenix.Socket.Broadcast{payload: %{__oban__: true}})
  end
end
