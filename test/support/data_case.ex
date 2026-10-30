# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_document/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaDocument.DataCase do
  @moduledoc """
  Test case for anything that touches the database but not the web layer — the resources, their
  actions and policies, the version trail, the dashboard queries.

  The core's `MishkaCmsCore.DataCase` with this extension's fixtures on top. The sandbox is the
  core's (`MishkaCmsCore.DataCase.setup_sandbox/1`): each test gets its own sandboxed connection and
  everything it writes is rolled back at the end; `async: false` (the default here) shares that
  connection with any process the test spawns, which the async data loaders behind the dashboard
  widgets rely on, and puts the site cache and the runtime modules back as the test found them.

  The helpers come from the core too — `errors_on/1` and the rest of `MishkaCmsCore.DataCase`, the
  sites, users and runtime records of `MishkaCmsCore.Test.Factory`, `MishkaCmsCore.Test.VersionHelpers`
  — and this case adds the documentation's own: its records (`MishkaDocument.Test.Factory`) and the
  SQL a block ran (`with_queries/1`).

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
      import MishkaCmsCore.DataCase
      import MishkaCmsCore.Test.Factory
      import MishkaCmsCore.Test.VersionHelpers
      import MishkaDocument.DataCase
      import MishkaDocument.Test.Factory
    end
  end

  setup tags do
    MishkaCmsCore.DataCase.setup_sandbox(tags)
    :ok
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
end
