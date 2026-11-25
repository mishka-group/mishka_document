# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_document/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaDocumentWeb.Test.DoctorChecksTest do
  @moduledoc """
  The check and repair window on the document dashboard lists the checks installed extensions add
  on `"doctor:checks"` (`MishkaCmsCore.Install.DoctorChecks`), as the signed-in admin.

  How the checks are collected, run and repaired is covered in core, where it lives. What can only
  be asserted here is that this dashboard hands the window its admin at all: with no actor the
  window lists no check. The plugin is `MishkaDocument.Test.Plugins.DoctorChecksProbe`, whose one
  check asks for `admin:dashboard:document:section`. `async: false`: the plugin registry is
  process-global.
  """
  use MishkaDocument.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias MishkaCmsCore.Install.{DoctorChecks, Extensions}
  alias MishkaCmsCore.Runtime.States.SiteState
  alias MishkaCmsCore.Test.Installer, as: TestInstaller
  alias MishkaDocument.Provision
  alias MishkaDocument.Test.Plugins.DoctorChecksProbe

  # What setting up, checking and repairing the documentation asks for, and the page's own area.
  @provision ["admin:dashboard:runtime:*", "admin:dashboard:document:workspace"]

  setup %{conn: conn} do
    SiteState.clear()

    site = create_site!(name: "localhost", host: "localhost", active: true, master: true)

    SiteState.save(Map.take(site, [:id, :name, :host, :priority, :active, :master]))
    :persistent_term.put(:mishka_installed, true)

    on_exit(fn ->
      :persistent_term.erase(:mishka_installed)
      SiteState.clear()
    end)

    report = Provision.ensure!(site)
    :ok = Extensions.mark_installed!(site.id, :mishka_document, report.version)

    TestInstaller.register!(DoctorChecksProbe, DoctorChecks.event())

    conn =
      conn
      |> Map.put(:host, "localhost")
      |> Map.update!(:req_headers, &[{"host", "localhost"} | List.keydelete(&1, "host", 0)])

    {:ok, conn: conn, site: site}
  end

  test "lists the check an extension adds to an admin holding its area", %{conn: conn, site: site} do
    admin =
      create_user_with_permissions!(["admin:dashboard:document:section" | @provision],
        site_id: site.id
      )

    view = open_doctor(conn, admin)

    assert has_element?(view, "[data-check='probe:probe'][data-outcome=ok]", "Probe check")

    close(view)
  end

  test "an admin without the check's area is not shown it", %{conn: conn, site: site} do
    admin = create_user_with_permissions!(@provision, site_id: site.id)

    view = open_doctor(conn, admin)

    assert has_element?(view, "#document-kit-upgrade-checks-none")
    refute has_element?(view, "[data-check='probe:probe']")
    refute render(view) =~ "Probe check"

    close(view)
  end

  defp open_doctor(conn, admin) do
    {:ok, view, _html} = live(log_in(conn, admin), "/admin/dashboard/document")

    view |> element("#document-kit-upgrade-open") |> render_click()
    render_async(view, 5_000)
    view
  end

  defp log_in(conn, user) do
    conn
    |> Plug.Test.init_test_session(%{})
    |> Plug.Conn.put_session(:master_mode, false)
    |> AshAuthentication.Plug.Helpers.store_in_session(user)
  end

  # The dashboard's figures and its workspaces table load in `start_async/3`; a view stopped while
  # one is in flight raises on the way down once the test's sandbox owner is gone.
  defp close(view) do
    render_async(view, 5_000)
    ref = Process.monitor(view.pid)
    GenServer.stop(view.pid, :normal)
    assert_receive {:DOWN, ^ref, :process, _pid, _reason}
  end
end
