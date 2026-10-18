# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_document/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaDocumentWeb.Test.TableExpandTest do
  @moduledoc """
  Expanding a row of the Sections, Issues, Section drafts and Note drafts tables tells the page that
  owns the table once, so the page loads the row's detail once. Each page's receive log is traced,
  since nothing else counts the `{:expand_row, id}` messages it was sent.

  The two draft tables draw no expand button, so their test pushes the table's `expand_row` event.
  """
  use MishkaDocument.ConnCase

  @moduletag :capture_log

  import Phoenix.LiveViewTest
  import MishkaDocument.Test.Factory

  alias MishkaCmsCore.Runtime.States.SiteState

  require Ash.Query

  @section "admin:dashboard:document:section"
  @site_loads "admin:api:*"
  @await 5_000
  @dashboard "/admin/dashboard/document"

  setup %{conn: conn} do
    SiteState.clear()
    :ok = Swoosh.TestAssertions.set_swoosh_global()

    site = create_site!(name: "localhost", host: "localhost", active: true, master: true)

    SiteState.save(%{
      id: site.id,
      name: site.name,
      host: site.host,
      priority: site.priority,
      active: site.active,
      master: site.master
    })

    :persistent_term.put(:mishka_installed, true)

    on_exit(fn ->
      :persistent_term.erase(:mishka_installed)
      SiteState.clear()
    end)

    :ok = MishkaCmsCore.Install.Extensions.mark_installed!(site.id, :mishka_document, "test")

    conn =
      conn
      |> Map.put(:host, "localhost")
      |> Map.update!(:req_headers, &[{"host", "localhost"} | List.keydelete(&1, "host", 0)])

    workspace = create_workspace!(site_id: site.id, name: "Expand Handbook", status: :active)

    version =
      MishkaDocument.WorkspaceVersion
      |> Ash.Query.filter(workspace_id == ^workspace.id)
      |> Ash.read_one!(tenant: site.id, authorize?: false)

    user = create_user_with_permissions!([@site_loads, @section], site_id: site.id)

    {:ok, conn: log_in(conn, user), site: site, version: version}
  end

  test "a section's row tells its page once", ctx do
    section = create_section!(site_id: ctx.site.id, workspace_version_id: ctx.version.id)

    messages =
      expand_messages(ctx.conn, "#{@dashboard}/sections/#{ctx.version.id}", section, fn view ->
        view
        |> element(~s(button[phx-click="expand_row"][phx-value-id="#{section.id}"]))
        |> render_click()
      end)

    assert messages == [{:expand_row, section.id}]
  end

  test "an issue's row tells its page once", ctx do
    issue = create_issue!(site_id: ctx.site.id)

    messages =
      expand_messages(ctx.conn, "#{@dashboard}/issues", issue, fn view ->
        view
        |> element(~s(button[phx-click="expand_row"][phx-value-id="#{issue.id}"]))
        |> render_click()
      end)

    assert messages == [{:expand_row, issue.id}]
  end

  test "a section draft's row tells its page once", ctx do
    draft = create_section_draft!(site_id: ctx.site.id, workspace_version_id: ctx.version.id)

    messages =
      expand_messages(ctx.conn, "#{@dashboard}/section-drafts", draft, fn view ->
        view
        |> with_target("#section-drafts-table")
        |> render_click("expand_row", %{"id" => draft.id})
      end)

    assert messages == [{:expand_row, draft.id}]
  end

  test "a note draft's row tells its page once", ctx do
    draft = create_note_draft!(site_id: ctx.site.id, workspace_version_id: ctx.version.id)

    messages =
      expand_messages(ctx.conn, "#{@dashboard}/note-drafts", draft, fn view ->
        view
        |> with_target("#note-drafts-table")
        |> render_click("expand_row", %{"id" => draft.id})
      end)

    assert messages == [{:expand_row, draft.id}]
  end

  defp log_in(conn, user) do
    conn
    |> Plug.Test.init_test_session(%{})
    |> Plug.Conn.put_session(:master_mode, false)
    |> AshAuthentication.Plug.Helpers.store_in_session(user)
  end

  # Every `{:expand_row, id}` the page at `path` received while `expand.(view)` expanded `record`.
  defp expand_messages(conn, path, record, expand) do
    {:ok, view, _html} = live(conn, path)
    render_async(view, @await)
    render_async(view, @await)

    1 = :erlang.trace(view.pid, true, [:receive])

    expand.(view)
    render_async(view, @await)

    ref = :erlang.trace_delivered(view.pid)
    assert_receive {:trace_delivered, _pid, ^ref}
    :erlang.trace(view.pid, false, [:receive])

    messages = received(record.id, [])
    close(view)
    messages
  end

  defp received(id, acc) do
    receive do
      {:trace, _pid, :receive, {:expand_row, ^id} = message} -> received(id, [message | acc])
      {:trace, _pid, :receive, _other} -> received(id, acc)
    after
      0 -> Enum.reverse(acc)
    end
  end

  # A view stopped while a `start_async/3` is in flight raises once the test's sandbox owner is gone.
  defp close(view) do
    render_async(view, @await)
    ref = Process.monitor(view.pid)
    GenServer.stop(view.pid, :normal)
    assert_receive {:DOWN, ^ref, :process, _pid, _reason}
  end
end
