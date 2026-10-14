defmodule MishkaDocument.Test.Plugins.VersionCloned do
  @moduledoc "Test plugin: reports `document:version:cloned` to the `:__version_cloned_probe__` process."
  use MishkaInstaller.Event.Hook, event: "document:version:cloned"

  @impl true
  def call(payload, meta) do
    if pid = Process.whereis(:__version_cloned_probe__),
      do: send(pid, {:version_cloned, payload, meta})

    {:reply, payload}
  end
end
