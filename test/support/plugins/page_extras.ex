defmodule MishkaDocument.Test.Plugins.PageExtras do
  @moduledoc """
  Test plugin: answers `document:page:extras` with the function a test stored (`answer!/1`), and
  reports each ask to the `:__page_extras_probe__` process, with the process that asked.
  """
  use MishkaInstaller.Event.Hook, event: "document:page:extras"

  @impl true
  def call(state) do
    if pid = Process.whereis(:__page_extras_probe__) do
      send(pid, {:page_extras_asked, state})
      send(pid, {:page_extras_asker, self()})
    end

    {:reply, :persistent_term.get({__MODULE__, :answer}, & &1).(state)}
  end

  @doc "Answers each ask with `fun.(state)` until `forget!/0`."
  def answer!(fun) when is_function(fun, 1), do: :persistent_term.put({__MODULE__, :answer}, fun)

  @doc "Answers each ask with the state it was handed."
  def forget!, do: :persistent_term.erase({__MODULE__, :answer})
end
