# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_document/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaDocument.Test.Plugins.DoctorChecksProbe do
  @moduledoc """
  Test plugin on `doctor:checks` (`MishkaCmsCore.Install.DoctorChecks`): answers the check and
  repair window of `:mishka_document` with one check, "Probe check", that only an admin holding
  `admin:dashboard:document:section` is shown, and that always answers `:ok`. It does NOT stand for
  any real extension's checks.
  """
  use MishkaInstaller.Event.Hook, event: "doctor:checks"

  @impl true
  def call(%{app: :mishka_document, checks: checks} = data) do
    probe = %{
      id: "probe",
      label: "Probe check",
      permission: "admin:dashboard:document:section",
      group: "Probe",
      group_id: "probe",
      run: fn _site_id, _actor -> :ok end
    }

    {:reply, %{data | checks: checks ++ [probe]}}
  end

  def call(data), do: {:reply, data}
end
