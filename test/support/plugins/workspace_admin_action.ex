# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_document/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaDocument.Test.Plugins.WorkspaceAdminAction do
  @moduledoc """
  Test plugin on `document:workspace:admin_actions`: reports what it is handed to the
  `:__admin_actions_probe__` process and adds one action opening
  `MishkaDocument.Test.Plugins.WorkspaceAdminActionPanel`, beside actions of shapes the screen
  leaves out.
  """
  use MishkaInstaller.Event.Hook, event: "document:workspace:admin_actions"

  alias MishkaDocument.Test.Plugins.WorkspaceAdminActionPanel

  @impl true
  def call(%{actions: actions} = state) do
    if pid = Process.whereis(:__admin_actions_probe__),
      do: send(pid, {:admin_actions_asked, Map.delete(state, :actions)})

    probe = %{
      id: "probe",
      label: "Probe action",
      icon: "hero-bolt",
      component: WorkspaceAdminActionPanel,
      assigns: %{greeting: "hello", workspace: :overridden}
    }

    malformed = [
      %{probe | id: "Not An Id"},
      %{probe | id: "no-component", component: String},
      %{probe | id: "no-label", label: ""},
      %{probe | id: "bad-icon", icon: "fa-bolt"},
      %{probe | id: "bad-assigns", assigns: [greeting: "hello"]},
      %{probe | label: "The same id again"},
      :not_an_action
    ]

    {:reply, %{state | actions: actions ++ [probe | malformed]}}
  end
end
