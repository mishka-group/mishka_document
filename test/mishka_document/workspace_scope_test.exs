# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_document/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaDocument.Test.WorkspaceScopeTest do
  @moduledoc """
  When the workspace list collapses translations into their master, and when it stops, and which of
  its actions a viewer is shown.

  `searching?/1` is the whole of that decision: say yes when nothing was typed and a search finds
  nothing, because every match is hidden behind its English master; say no when something was typed
  and the list shows "Mishka CMS" beside "میشکا سی ام اس" — the same document twice.
  """
  use ExUnit.Case, async: true

  alias MishkaDocument.WorkspaceScope

  defp state(filter_values, filters \\ [%{name: :search, type: :text}]) do
    %{static: %{filters: filters}, filter_values: filter_values}
  end

  describe "a search is running" do
    test "when a text filter holds something" do
      assert WorkspaceScope.searching?(state(%{search: "میشکا"}))
      assert WorkspaceScope.searching?(state(%{search: "cms"}))
    end

    test "even when other filters are set alongside it" do
      assert WorkspaceScope.searching?(state(%{search: "cms", status: :active}))
    end
  end

  describe "no search is running" do
    test "when nothing has been typed" do
      refute WorkspaceScope.searching?(state(%{}))
      refute WorkspaceScope.searching?(state(%{search: nil}))
    end

    test "when the box was typed in and then cleared" do
      refute WorkspaceScope.searching?(state(%{search: ""}))
    end

    test "when the box holds only whitespace — that is a cleared box, not a query" do
      refute WorkspaceScope.searching?(state(%{search: "   "}))
    end

    test "when a non-text filter is set but nothing was searched for" do
      refute WorkspaceScope.searching?(state(%{status: :active, featured: true})),
             "picking a status is not searching — the list must stay collapsed"
    end
  end

  describe "which filter counts as the search box" do
    test "any text filter does, not one named :search" do
      state = state(%{query: "cms"}, [%{name: :query, type: :text}])

      assert WorkspaceScope.searching?(state),
             "the resource names its own filters; the scope must not hardcode one"
    end

    test "a select filter never counts, whatever it is called" do
      state = state(%{search: :active}, [%{name: :search, type: :select}])

      refute WorkspaceScope.searching?(state)
    end
  end

  describe "a state that cannot answer" do
    test "reads as not searching rather than crashing the list" do
      refute WorkspaceScope.searching?(%{})
      refute WorkspaceScope.searching?(state(nil))
    end
  end

  describe "shown?/3" do
    @section "admin:dashboard:document:section"

    defp table(status, names),
      do: %{archive_status: status, current_user: %{permissions: Enum.map(names, &%{name: &1})}}

    test "draws an action for its own records' status, to a holder of its name" do
      assert WorkspaceScope.shown?(table(:active, [@section]), :active, @section)
      assert WorkspaceScope.shown?(table(:active, ["admin:dashboard:*"]), :active, @section)
      refute WorkspaceScope.shown?(table(:archived, [@section]), :active, @section)

      refute WorkspaceScope.shown?(
               table(:active, [@section]),
               :active,
               "admin:dashboard:document:workspace"
             )

      refute WorkspaceScope.shown?(table(:active, ["admin:api:*"]), :active, @section)
      refute WorkspaceScope.shown?(%{}, :active, @section)
    end
  end
end
