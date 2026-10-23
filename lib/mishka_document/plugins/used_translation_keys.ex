# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_document/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaDocument.Plugins.UsedTranslationKeys do
  @moduledoc """
  Names the words the documentation looks up in a site's translations, through the
  `runtime:translations:used_keys` mishka_installer hook (`MishkaCmsCore.Runtime.Translations.used_keys/1`).

  The words of the bar under the header (`MishkaDocument.Plugins.PageFrame.words/0`) are asked for by
  a plugin, not by a template, so nothing a page, a component or a layout says holds them. Without
  this, "Remove unused" on the site's translations would delete them, and what a translator wrote
  for them, as words nobody asks for.

  Registered in `MishkaDocument.Application`.
  """

  use MishkaInstaller.Event.Hook,
    event: "runtime:translations:used_keys",
    initial: %{priority: 50}

  alias MishkaDocument.Plugins.PageFrame

  @impl true
  def call(%{keys: keys} = data) when is_list(keys),
    do: {:reply, %{data | keys: keys ++ PageFrame.words()}}

  def call(data), do: {:reply, data}
end
