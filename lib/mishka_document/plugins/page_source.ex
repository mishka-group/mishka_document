# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_document/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaDocument.Plugins.PageSource do
  @moduledoc """
  Reads the rows a document's front page and each of its pages show, once, through the
  `runtime:page:source` mishka_installer hook `MishkaCmsWeb.RuntimeLive` fires in `handle_params/3`
  before the frame and the head (`MishkaCmsCore.Runtime.PageSource` is the contract: the map it is
  handed and where what it reads goes).

  A page is matched by the kind of record it says it shows (`record`, its `extra`'s `"record"`):
  `"docs:document"` or `"docs:page"`, the kinds `MishkaDocument.Plugins.PageRecords` names and
  `MishkaDocument.Plugins.PageSeo` and `MishkaDocument.Plugins.PageFrame` answer for. Every other
  page is handed back untouched, before anything is read. What is read, and as whom, is
  `MishkaDocument.PageSource`'s.

  Registered in `MishkaDocument.Application`.
  """

  use MishkaInstaller.Event.Hook, event: "runtime:page:source", initial: %{priority: 50}

  @records ["docs:document", "docs:page"]

  @impl true
  def call(%{record: record} = given) when record in @records,
    do: {:reply, :halt, %{given | source: MishkaDocument.PageSource.read(given)}}

  def call(given), do: {:reply, given}
end
