# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_document/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaDocument.Test.Plugins.ProvisionSnippetSaved do
  @moduledoc """
  Test plugin for `runtime:provision:snippets`, standing in for a visual editor: the core keeps no
  snippet of its own, and the editor that does (`mishka_cms_builder`) is not part of this suite.

  It saves nothing. It sends the calling process `{:snippet_offered, payload}` — what a provision
  hands an editor — and answers that it saved the snippet, as an editor that had none of that name
  does.
  """
  use MishkaInstaller.Event.Hook, event: "runtime:provision:snippets"

  @impl true
  def call(%{snippet: %{name: name}} = payload) do
    send(self(), {:snippet_offered, payload})
    {:reply, %{payload | installed: payload.installed ++ [name]}}
  end
end
