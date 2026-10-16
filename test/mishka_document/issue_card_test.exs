# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_document/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaDocumentWeb.Templates.IssueCardTest do
  @moduledoc """
  The decisions the issue card makes on its own.

  `transitions/1` is the whole status machine — the resource's transition actions accept any status and
  only set one, so nothing else stands between `:closed` and a "Mark In Progress" button. It has to
  never offer the state an issue is already in, and it has to survive a record read without a status.

  `MishkaCmsCoreWeb.Templates.CardChrome.range_label/3` is the count over the list, and the issue card
  hands it `"0 issues"` for an empty set. The last page holds a remainder rather than a full page, so
  the figure it prints must be clamped by the total rather than by where the page would end.

  `type_badge/1` and `status_badge/1` are lookups over closed sets — both attributes are `one_of`
  atoms — so what matters is coverage: every value the resource can hold needs its own colour, no two
  may collide, and a record missing the field must still draw. Their classes have to stay literal
  Tailwind, because the runtime CSS compiler only emits a class it can see written out.
  """
  use ExUnit.Case, async: true

  alias MishkaCmsCoreWeb.Templates.CardChrome, as: Shared
  alias MishkaDocumentWeb.Templates.IssueCard

  @types [:typo, :broken_link, :incorrect_content, :suggestion, :review_feedback, :other]
  @statuses [:open, :in_progress, :resolved, :closed]

  defp events(status), do: IssueCard.transitions(%{status: status}) |> Enum.map(&elem(&1, 0))

  defp range(state), do: Shared.range_label(state, 20, "0 issues")

  describe "transitions/1" do
    test "an open issue can be started, resolved or closed" do
      assert events(:open) == ["mark_in_progress", "mark_resolved", "mark_closed"]
    end

    test "an issue already in progress is not offered in progress again" do
      assert events(:in_progress) == ["mark_resolved", "mark_closed"]
    end

    test "a resolved issue can be reopened or closed" do
      assert events(:resolved) == ["reopen", "mark_closed"]
    end

    test "a closed issue is terminal but for reopening" do
      assert events(:closed) == ["reopen"]
    end

    test "never offers the state the issue is already in" do
      for {status, event} <- [
            {:in_progress, "mark_in_progress"},
            {:resolved, "mark_resolved"},
            {:closed, "mark_closed"},
            {:open, "reopen"}
          ] do
        refute event in events(status), "#{status} was offered #{event}"
      end
    end

    test "offers nothing rather than raising when the status is missing" do
      assert IssueCard.transitions(%{}) == []
      assert IssueCard.transitions(%{status: nil}) == []
      assert IssueCard.transitions(%{status: :nonsense}) == []
    end

    test "every transition carries an event, a label and a tone" do
      for status <- [:open, :in_progress, :resolved, :closed],
          {event, label, tone} <- IssueCard.transitions(%{status: status}) do
        assert is_binary(event) and event != ""
        assert is_binary(label) and label != ""
        assert tone =~ "bg-", "#{event} has no background tone"
      end
    end
  end

  describe "range_label/3" do
    test "counts the slice on a full first page" do
      assert range(%{total_count: 48, page: 1}) == "Showing 1–20 of 48"
    end

    test "counts the slice on a middle page" do
      assert range(%{total_count: 48, page: 2}) == "Showing 21–40 of 48"
    end

    test "clamps the last page to the remainder rather than a full page" do
      assert range(%{total_count: 48, page: 3}) == "Showing 41–48 of 48"
    end

    test "handles a single partial page" do
      assert range(%{total_count: 7, page: 1}) == "Showing 1–7 of 7"
    end

    test "says nothing was found rather than counting from one" do
      assert range(%{total_count: 0, page: 1}) == "0 issues"
      assert range(%{total_count: nil, page: 1}) == "0 issues"
    end

    test "survives a state that has not counted yet" do
      assert range(%{}) == "0 issues"
    end
  end

  describe "type_badge/1" do
    test "covers every issue_type the resource allows" do
      for type <- @types do
        assert %{label: label, chip: chip, dot: dot} = IssueCard.type_badge(%{issue_type: type})
        assert label != "", "#{type} has no label"
        assert chip =~ "bg-[#" and chip =~ "text-[#", "#{type} has no chip colour"
        assert dot =~ "bg-[#", "#{type} has no dot"
      end
    end

    test "gives no two types the same colour" do
      chips = Enum.map(@types, &IssueCard.type_badge(%{issue_type: &1}).chip)

      assert length(Enum.uniq(chips)) == length(@types)
    end

    test "keeps the hex the design gives each type" do
      assert IssueCard.type_badge(%{issue_type: :suggestion}).dot == "bg-[#6d69e6]"
      assert IssueCard.type_badge(%{issue_type: :typo}).dot == "bg-[#a566e0]"
      assert IssueCard.type_badge(%{issue_type: :broken_link}).dot == "bg-[#e5484d]"
      assert IssueCard.type_badge(%{issue_type: :incorrect_content}).dot == "bg-[#d4569b]"
      assert IssueCard.type_badge(%{issue_type: :other}).dot == "bg-[#a8a5a0]"
    end

    test "reads an underscored atom as words" do
      assert IssueCard.type_badge(%{issue_type: :broken_link}).label == "Broken link"
      assert IssueCard.type_badge(%{issue_type: :incorrect_content}).label == "Incorrect content"
    end

    test "falls back to :other for an unknown or missing type" do
      other = IssueCard.type_badge(%{issue_type: :other})

      assert IssueCard.type_badge(%{issue_type: :nonsense}) == other
      assert IssueCard.type_badge(%{}) == other
      assert IssueCard.type_badge(%{issue_type: nil}) == other
    end
  end

  describe "status_badge/1" do
    test "covers every status the resource allows" do
      for status <- @statuses do
        assert %{label: label, chip: chip} = IssueCard.status_badge(%{status: status})
        assert label != "", "#{status} has no label"
        assert chip =~ "bg-[#" and chip =~ "text-[#", "#{status} has no chip colour"
      end
    end

    test "gives no two statuses the same colour" do
      chips = Enum.map(@statuses, &IssueCard.status_badge(%{status: &1}).chip)

      assert length(Enum.uniq(chips)) == length(@statuses)
    end

    test "keeps the hex the Documents dashboard already uses" do
      assert IssueCard.status_badge(%{status: :open}).chip == "bg-[#fbf1df] text-[#a5691a]"
      assert IssueCard.status_badge(%{status: :in_progress}).chip == "bg-[#eef1fc] text-[#3a5bc4]"
      assert IssueCard.status_badge(%{status: :resolved}).chip == "bg-[#e6f6ee] text-[#177a53]"
      assert IssueCard.status_badge(%{status: :closed}).chip == "bg-[#f2f1ec] text-[#6d6a63]"
    end

    test "falls back to :open for an unknown or missing status" do
      open = IssueCard.status_badge(%{status: :open})

      assert IssueCard.status_badge(%{status: :nonsense}) == open
      assert IssueCard.status_badge(%{}) == open
    end
  end

  describe "the badge palette" do
    test "matches the resource's own enums, so no value can go uncoloured" do
      constraint = fn attribute ->
        MishkaDocument.Issue
        |> Ash.Resource.Info.attribute(attribute)
        |> Map.fetch!(:constraints)
        |> Keyword.fetch!(:one_of)
        |> Enum.sort()
      end

      assert constraint.(:issue_type) == Enum.sort(@types)
      assert constraint.(:status) == Enum.sort(@statuses)
    end

    test "is written out literally, so the runtime CSS compiler can match it" do
      classes =
        Enum.flat_map(@types, fn type ->
          %{chip: chip, dot: dot} = IssueCard.type_badge(%{issue_type: type})
          String.split(chip) ++ String.split(dot)
        end) ++
          Enum.flat_map(@statuses, &String.split(IssueCard.status_badge(%{status: &1}).chip))

      for class <- classes do
        assert class =~ ~r/^(bg|text)-\[#[0-9a-f]{6}\]$/i,
               "#{class} is not a literal colour utility"
      end
    end
  end

  describe "the template's contract with Gervaz" do
    test "declares the features the resource asks for" do
      for feature <- [:filter, :select, :bulk_actions, :paginate, :expand] do
        assert feature in IssueCard.features(), "#{feature} is not declared"
      end
    end

    test "is the template the Issue resource points at" do
      config = MishkaGervaz.Resource.Info.table_config(MishkaDocument.Issue)

      assert get_in(config, [:presentation, :template]) == IssueCard
      assert get_in(config, [:presentation, :ui_adapter]) == MishkaCmsCoreWeb.UIAdapters.Admin
    end

    test "every column the resource marks sortable names a real field to sort by" do
      fields = MishkaDocument.Issue |> Ash.Resource.Info.attributes() |> Enum.map(& &1.name)

      sortable =
        MishkaGervaz.Resource.Info.table_config(MishkaDocument.Issue)
        |> get_in([:columns, :list])
        |> Kernel.||([])
        |> Enum.filter(& &1.sortable)

      assert sortable != [], "the Sort by menu would have nothing to offer"

      for column <- sortable, field <- column.sort_field do
        assert field in fields, "#{column.name} sorts by #{field}, which is not an attribute"
      end
    end
  end
end
