defmodule MishkaDocumentWeb.Templates.DocumentCardTest do
  @moduledoc """
  The workspace card's data reads. Every one of them has to survive a record the viewer is not allowed
  to see all of: `health_metrics` and `maintainers_info` are field-policy gated, so they arrive as
  `%Ash.NotLoaded{}` rather than a map, and a card that crashes on that takes the whole page down.
  """
  use ExUnit.Case, async: true

  alias MishkaDocumentWeb.Templates.DocumentCard

  describe "the flagship's completion ring" do
    test "an empty workspace leaves the whole ring undrawn, a done one fills it" do
      assert DocumentCard.ring_offset(0) == 257.6
      assert DocumentCard.ring_offset(100) == 0.0
    end

    test "half done offsets half the circumference" do
      assert DocumentCard.ring_offset(50) == 128.8
    end

    test "the design's own figure lands where the design draws it" do
      assert DocumentCard.ring_offset(82) == 46.4
    end
  end

  describe "metrics a viewer cannot see" do
    test "unloaded health_metrics reads as zero rather than crashing" do
      record = %{health_metrics: %Ash.NotLoaded{}}

      assert DocumentCard.completion(record) == 0
      assert DocumentCard.metric(record, :sections_count) == 0
    end

    test "unloaded maintainers_info reads as zero contributors" do
      assert DocumentCard.contributors(%{maintainers_info: %Ash.NotLoaded{}}) == 0
    end

    test "an unloaded versions aggregate reads as zero" do
      assert DocumentCard.versions_count(%{versions_count: %Ash.NotLoaded{}}) == 0
    end

    test "a loaded metric is read straight through" do
      record = %{health_metrics: %{completion: 82, sections_count: 80}}

      assert DocumentCard.completion(record) == 82
      assert DocumentCard.metric(record, :sections_count) == 80
    end

    test "a loaded maintainers_info reads its string key, as the calculation writes it" do
      assert DocumentCard.contributors(%{maintainers_info: %{"count" => 14}}) == 14
    end

    test "a metric the map simply lacks reads as zero" do
      assert DocumentCard.metric(%{health_metrics: %{}}, :sections_count) == 0
    end
  end

  describe "language editions" do
    defp grouped(variants),
      do: %{id: "a", language_group_id: "g", language_variants: variants}

    test "an ungrouped workspace has no siblings to show" do
      assert DocumentCard.editions(%{language_group_id: nil}) == []
    end

    test "a workspace never lists itself as its own edition" do
      record =
        grouped([
          %{id: "a", language: "en", status: :active},
          %{id: "b", language: "fa", status: :active}
        ])

      assert [%{language: "fa"}] = DocumentCard.editions(record)
    end

    test "duplicate languages collapse and the order is stable" do
      record =
        grouped([
          %{id: "a", language: "en", status: :active},
          %{id: "c", language: "ru", status: :active},
          %{id: "b", language: "fa", status: :active},
          %{id: "d", language: "fa", status: :active}
        ])

      assert ["fa", "ru"] = DocumentCard.editions(record) |> Enum.map(& &1.language)
    end

    test "unloaded variants read as no editions rather than crashing" do
      assert DocumentCard.editions(grouped(%Ash.NotLoaded{})) == []
    end

    test "each edition carries its own language's accent, not the workspace's" do
      record =
        grouped([
          %{id: "a", language: "en", status: :active},
          %{id: "b", language: "fa", status: :active}
        ])

      assert [%{accent: %{stroke: "#1f9d6b"}}] = DocumentCard.editions(record)
    end

    test "an archived sibling shows grey, whatever its language" do
      record =
        grouped([
          %{id: "a", language: "en", status: :active},
          %{id: "b", language: "fa", status: :archived}
        ])

      assert [%{accent: %{stroke: "#9a978f"}}] = DocumentCard.editions(record)
    end
  end

  describe "archived" do
    test "reads from either status or archived_at" do
      assert DocumentCard.archived?(%{status: :archived})
      assert DocumentCard.archived?(%{status: :active, archived_at: ~U[2026-07-16 00:00:00Z]})
      refute DocumentCard.archived?(%{status: :active, archived_at: nil})
    end
  end
end
