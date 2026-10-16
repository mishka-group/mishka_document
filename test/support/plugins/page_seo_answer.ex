# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_document/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaDocument.Test.Plugins.PageSeoAnswer do
  @moduledoc """
  Test plugin: answers `document:page:seo` with the function a test stored (`answer!/1`), handed the
  answer and its `meta`, and reports each ask to the `:__page_seo_probe__` process.
  """
  use MishkaInstaller.Event.Hook, event: "document:page:seo"

  @impl true
  def call(seo, meta) do
    if pid = Process.whereis(:__page_seo_probe__), do: send(pid, {:page_seo_asked, seo, meta})

    {:reply, :persistent_term.get({__MODULE__, :answer}, fn seo, _meta -> seo end).(seo, meta)}
  end

  @doc "Answers each ask with `fun.(seo, meta)` until `forget!/0`."
  def answer!(fun) when is_function(fun, 2), do: :persistent_term.put({__MODULE__, :answer}, fun)

  @doc "Answers each ask with the answer it was handed."
  def forget!, do: :persistent_term.erase({__MODULE__, :answer})
end
