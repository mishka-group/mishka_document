# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_document/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaDocument.DataCase do
  @moduledoc """
  Test case for anything that touches the database but not the web layer — the resources, their
  actions and policies, the version trail, the dashboard queries.

  Stands in for the CMS's `MishkaCms.DataCase` so this suite runs without the CMS around it. Each
  test gets its own sandboxed connection and everything it writes is rolled back at the end;
  `async: false` (the default here) shares that connection with any process the test spawns, which
  the async data loaders behind the dashboard widgets rely on.

  See `MishkaDocument.ConnCase` for tests that go through the JSON API instead.
  """

  use ExUnit.CaseTemplate

  @repo Application.compile_env!(:mishka_cms_core, :repo)

  using do
    quote do
      alias MishkaDocument.Repo

      import Ecto
      import Ecto.Changeset
      import Ecto.Query
      import MishkaDocument.DataCase
      import MishkaDocument.Test.Factory
      import MishkaDocument.Test.VersionHelpers
    end
  end

  setup tags do
    setup_sandbox(tags)
    :ok
  end

  @doc "Checks out a sandboxed connection for the test, shared with its spawned processes unless async."
  def setup_sandbox(tags) do
    pid = Ecto.Adapters.SQL.Sandbox.start_owner!(@repo, shared: not tags[:async])
    on_exit(fn -> Ecto.Adapters.SQL.Sandbox.stop_owner(pid) end)
  end

  @doc """
  Runs `fun` and returns `{result, statements}`: what it returned, and the SQL of every statement
  the repo ran meanwhile, in the order they ran.

      {_page, statements} = with_queries(fn -> Ash.read!(Section, tenant: site.id) end)
  """
  @spec with_queries((-> result)) :: {result, [String.t()]} when result: var
  def with_queries(fun) do
    owner = self()
    handler = {__MODULE__, make_ref()}
    event = @repo.config() |> Keyword.fetch!(:telemetry_prefix) |> Kernel.++([:query])

    :telemetry.attach(handler, event, &__MODULE__.forward_query/4, owner)

    try do
      {fun.(), drain_queries([])}
    after
      :telemetry.detach(handler)
    end
  end

  @doc false
  def forward_query(_event, _measurements, %{query: query}, owner),
    do: send(owner, {:query, query})

  defp drain_queries(acc) do
    receive do
      {:query, query} -> drain_queries([query | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  @doc """
  Turns changeset errors into a map of field to messages.

      assert %{password: ["password is too short"]} = errors_on(changeset)
  """
  def errors_on(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {message, opts} ->
      Regex.replace(~r"%{(\w+)}", message, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
  end
end
