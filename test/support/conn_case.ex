# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_document/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaDocument.ConnCase do
  @moduledoc """
  Test case for the extension's JSON API, standing in for the CMS's `MishkaCmsWeb.ConnCase`.

  Same contract as the CMS's — a sandboxed connection per test and a `conn` to drive it with — but
  pointed at this extension's own `MishkaDocument.TestEndpoint`, so the suite runs without the CMS around
  it. See the test-only `MishkaDocument.Repo` shim for how the database is reached.

  `make_api_request/3` is here rather than in the factory: it builds requests, it does not build data.
  `await_event_announcements/0` is here because it decides when a page may be opened.
  """

  use ExUnit.CaseTemplate

  import ExUnit.Assertions, only: [assert_receive: 1]

  using do
    quote do
      @endpoint MishkaDocument.TestEndpoint

      import Plug.Conn
      import Phoenix.ConnTest
      import MishkaDocument.ConnCase
    end
  end

  setup tags do
    pid = Ecto.Adapters.SQL.Sandbox.start_owner!(MishkaDocument.Repo, shared: not tags[:async])
    on_exit(fn -> Ecto.Adapters.SQL.Sandbox.stop_owner(pid) end)

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

  defp announcing_for?(pid, caller) do
    case Process.info(pid, :dictionary) do
      {:dictionary, dictionary} ->
        match?({MishkaDocument.EventLog, _fun, 0}, dictionary[:"$initial_call"]) and
          caller in List.wrap(dictionary[:"$callers"])

      nil ->
        false
    end
  end

  @doc """
  Calls the JSON:API the way a client does, and returns the `Plug.Conn` it answered with.

  The conn is built by hand rather than through `Phoenix.ConnTest.post/3` because JSON:API puts
  structure in the query string — `page[limit]=2`, `included_page[posts][limit]=1` — which Plug
  leaves as flat bracketed keys. `parse_json_api_params/1` folds those back into the nested maps the
  router expects.

  `host` matters: the tenant plug resolves which site a request belongs to from it, so a test that
  changes hosts is testing a different tenant.

  ## Options
    * `:method`  — defaults to `"POST"`
    * `:host`    — defaults to `"localhost"`
    * `:headers` — extra request headers, e.g. the bearer token from signing in
  """
  @spec make_api_request(String.t(), term(), keyword()) :: Plug.Conn.t()
  def make_api_request(path, data, opts \\ []) do
    headers = Keyword.get(opts, :headers, [])
    host = Keyword.get(opts, :host, "localhost")
    method = Keyword.get(opts, :method, "POST")

    {base_path, query_string} =
      case String.split(path, "?", parts: 2) do
        [p, q] -> {p, q}
        [p] -> {p, ""}
      end

    query_params =
      case query_string do
        "" -> %{}
        q -> q |> URI.decode_query() |> parse_json_api_params()
      end

    %Plug.Conn{} = conn = Phoenix.ConnTest.build_conn()

    %{
      conn
      | host: host,
        method: String.upcase("#{method}"),
        request_path: path,
        path_info: base_path |> String.trim_leading("/") |> String.split("/"),
        query_string: query_string,
        query_params: query_params,
        params: query_params
    }
    |> put_default_headers()
    |> put_custom_headers(headers)
    |> Map.put(:body_params, %{"data" => data})
    |> Map.update!(:params, fn existing ->
      Map.merge(parse_json_api_params(existing), %{"data" => data})
    end)
    |> MishkaDocument.TestEndpoint.call([])
  end

  defp put_default_headers(conn) do
    conn
    |> Plug.Conn.put_req_header("content-type", "application/vnd.api+json")
    |> Plug.Conn.put_req_header("accept", "application/vnd.api+json")
  end

  defp put_custom_headers(conn, headers) do
    Enum.reduce(headers, conn, fn {key, value}, acc ->
      Plug.Conn.put_req_header(acc, key, value)
    end)
  end

  # `page[limit]=2` and `included_page[posts][limit]=1` arrive as flat keys; the router wants
  # `%{"page" => %{"limit" => "2"}}`. Two levels is as deep as the API's own routes go.
  defp parse_json_api_params(params) when is_map(params) do
    Enum.reduce(params, %{}, fn {key, value}, acc -> put_json_api_param(acc, key, value) end)
  end

  defp parse_json_api_params(_params), do: %{}

  defp put_json_api_param(acc, key, value) do
    cond do
      match = Regex.run(~r/^(\w+)\[(\w+)\]\[(\w+)\]$/, key) ->
        [_, parent, child1, child2] = match

        Map.update(acc, parent, %{child1 => %{child2 => value}}, fn existing ->
          Map.update(existing, child1, %{child2 => value}, &Map.put(&1, child2, value))
        end)

      match = Regex.run(~r/^(\w+)\[(\w+)\]$/, key) ->
        [_, parent, child] = match

        Map.update(acc, parent, %{child => value}, &Map.put(&1, child, value))

      true ->
        Map.put(acc, key, value)
    end
  end
end
