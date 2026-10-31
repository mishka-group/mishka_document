# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_document/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaDocument.ConnCase do
  @moduledoc """
  Test case for the extension's JSON API, standing in for the CMS's `MishkaCmsWeb.ConnCase`.

  Same contract as the CMS's — a sandboxed connection per test and a `conn` to drive it with — but
  pointed at this extension's own `MishkaDocument.TestEndpoint`, so the suite runs without the CMS around
  it. See the test-only `MishkaDocument.Repo` shim for how the database is reached.

  The rest is the core's, which ships it in its `lib` for an extension's suite: the sandbox
  (`MishkaCmsCore.DataCase.setup_sandbox/1`), `make_api_request/3` (`MishkaCmsCore.ConnCase`, which
  calls the endpoint `config :mishka_cms_core, endpoint: …` names, this one), and the sites, users and
  runtime records a request needs (`MishkaCmsCore.Test.Factory`). What is added here is
  `await_event_announcements/0`, because it decides when a page may be opened, and `settle/2`,
  because it decides when an open page may be read.
  """

  use ExUnit.CaseTemplate

  import ExUnit.Assertions, only: [assert_receive: 1]

  using do
    quote do
      @endpoint MishkaDocument.TestEndpoint

      import Plug.Conn
      import Phoenix.ConnTest
      import MishkaCmsCore.ConnCase
      import MishkaCmsCore.Test.Factory
      import MishkaDocument.ConnCase
    end
  end

  setup tags do
    MishkaCmsCore.DataCase.setup_sandbox(tags)

    {:ok, conn: Phoenix.ConnTest.build_conn()}
  end

  @doc """
  Returns once `MishkaDocument.EventLog` has announced every event the calling test wrote.

  The log announces each event on `"event_log:created"` a second time, from a task of its own a
  moment after the write. A page subscribed to that topic re-renders when the announcement lands, so
  a page opened before then is redrawn under whatever the test is doing to it. Call this after the
  writes and before opening the page:

      await_event_announcements()
      {:ok, view, _html} = live(conn, path)
  """
  @spec await_event_announcements() :: :ok
  def await_event_announcements do
    caller = self()

    Process.list()
    |> Enum.filter(&announcing_for?(&1, caller))
    |> Enum.map(&Process.monitor/1)
    |> Enum.each(fn ref -> assert_receive {:DOWN, ^ref, :process, _pid, _reason} end)
  end

  @doc """
  Returns `view` once it has taken every message already sent to it and the reads they started
  have finished.

  A write the test makes reaches an open page as a broadcast, and the page often hands it to a
  component with `send_update/3`, a message to itself that starts the component's
  `start_async/3` or `assign_async/3`. `render_async/2` alone can ask for the page's reads before
  that message is taken, and so return before the read begins. The `render/1` first makes the page
  take the broadcast, which queues its message ahead of the `render_async/2` that follows:

      create_workspace!(site_id: site.id)
      settle(view)
  """
  @spec settle(view, timeout()) :: view when view: struct()
  def settle(view, timeout \\ 5_000) do
    Phoenix.LiveViewTest.render(view)
    Phoenix.LiveViewTest.render_async(view, timeout)
    view
  end

  defp announcing_for?(pid, caller) do
    case Process.info(pid, :dictionary) do
      {:dictionary, dictionary} ->
        match?({MishkaDocument.EventLog, _fun, 0}, dictionary[:"$initial_call"]) and
          caller in List.wrap(dictionary[:"$callers"])

      nil ->
        false
    end
  end
end
