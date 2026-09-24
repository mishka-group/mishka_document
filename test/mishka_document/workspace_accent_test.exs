defmodule MishkaDocument.Test.WorkspaceAccentTest do
  @moduledoc """
  The workspace card's two colour rules.

  Its chrome is banded by completion, so the bands must not drift: 30/50/80 are the boundaries, each
  has to land on the band it names rather than the one below, and blue is exactly 100 — the whole
  point of it is that it means finished.

  Its badges stay language-coloured. The design names five languages; `Workspace.language` accepts any
  ISO-639-1 string, so the real requirement is that EVERY language gets a stable colour — not that
  five do and the rest collapse onto one.
  """
  use ExUnit.Case, async: true

  alias MishkaDocument.WorkspaceAccent

  defp stroke(language, status \\ :active),
    do: WorkspaceAccent.of(%{language: language, status: status}).stroke

  describe "the languages the design names" do
    test "each wears exactly the colour the design gives it" do
      assert stroke("en") == "#5b57d6"
      assert stroke("fa") == "#1f9d6b"
      assert stroke("ru") == "#c17d1a"
      assert stroke("fr") == "#c94f86"
      assert stroke("de") == "#2f86c4"
    end
  end

  describe "a language the design never named" do
    test "still gets a colour, and always the same one" do
      for language <- ~w(ar zh pt es tr ja ko hi sw nl eu) do
        colour = stroke(language)

        assert colour in ["#5b57d6", "#1f9d6b", "#c17d1a", "#c94f86", "#2f86c4"],
               "#{language} fell outside the palette"

        assert stroke(language) == colour, "#{language} is not stable across calls"
      end
    end

    test "does not collapse every language onto one colour" do
      colours = ~w(ar zh pt es tr ja ko hi sw nl eu vi th) |> Enum.map(&stroke/1) |> Enum.uniq()

      assert length(colours) > 1,
             "every unnamed language hashed to the same colour — the spread is broken"
    end

    test "never steals a named language's slot by accident of casing" do
      assert stroke("EN") == stroke("en")
      assert stroke(" FA ") == stroke("fa")
    end
  end

  describe "archived" do
    test "goes grey whatever the language says" do
      for language <- ~w(en fa ru fr de ar) do
        assert stroke(language, :archived) == "#9a978f"
      end
    end

    test "reads archived from archived_at too, not only status" do
      accent =
        WorkspaceAccent.of(%{
          language: "fa",
          status: :active,
          archived_at: ~U[2026-07-16 00:00:00Z]
        })

      assert accent.stroke == "#9a978f"
    end
  end

  describe "blank language" do
    test "falls back to English, as the design and the attribute default both do" do
      assert stroke(nil) == stroke("en")
      assert stroke("") == stroke("en")
      assert stroke("   ") == stroke("en")
    end
  end

  describe "the card's chrome, banded by completion" do
    defp progress(completion),
      do: WorkspaceAccent.for_progress(%{health_metrics: %{completion: completion}}).stroke

    test "each band wears its own tone" do
      assert progress(0) == "#d5544b"
      assert progress(15) == "#d5544b"
      assert progress(35) == "#cf8a24"
      assert progress(65) == "#5b57d6"
      assert progress(90) == "#1f9d6b"
      assert progress(100) == "#2f86c4"
    end

    test "the boundaries land on the band they name, not the one below" do
      assert progress(29) == "#d5544b"
      assert progress(30) == "#cf8a24", "30% has started"
      assert progress(49) == "#cf8a24"
      assert progress(50) == "#5b57d6", "50% is in progress"
      assert progress(79) == "#5b57d6"
      assert progress(80) == "#1f9d6b", "80% is success"
    end

    test "blue means finished, so 99% is not blue" do
      assert progress(99) == "#1f9d6b", "99% is still success — blue is reserved for done"
      assert progress(100) == "#2f86c4"
    end

    test "a completion past 100 still reads as complete rather than falling through" do
      assert progress(120) == "#2f86c4"
    end

    test "a workspace nobody can measure reads as behind rather than crashing" do
      assert WorkspaceAccent.for_progress(%{health_metrics: %Ash.NotLoaded{}}).stroke == "#d5544b"
      assert WorkspaceAccent.for_progress(%{}).stroke == "#d5544b"
    end

    test "archived is grey whatever the progress says" do
      archived = %{status: :archived, health_metrics: %{completion: 100}}

      assert WorkspaceAccent.for_progress(archived).stroke == "#9a978f"
    end

    test "the chrome ignores language entirely" do
      en = %{language: "en", health_metrics: %{completion: 90}}
      fa = %{language: "fa", health_metrics: %{completion: 90}}

      assert WorkspaceAccent.for_progress(en) == WorkspaceAccent.for_progress(fa),
             "two workspaces equally done must look equally done"
    end

    test "every band carries the full slot set the card paints with" do
      for completion <- [10, 50, 95] do
        accent = WorkspaceAccent.for_progress(%{health_metrics: %{completion: completion}})

        for slot <- [:bar, :solid, :tile, :chip, :track, :fill, :stroke] do
          assert is_binary(Map.get(accent, slot)), "#{completion}% is missing #{slot}"
        end
      end
    end
  end

  test "the language accent still keeps its own colours, for the badges" do
    assert stroke("en") != stroke("fa"),
           "the badge is the one place language colour still tells editions apart"
  end

  test "every accent carries the full slot set the card paints with" do
    slots = [:bar, :solid, :tile, :chip, :track, :fill, :stroke]

    for language <- ~w(en fa ru fr de ar), status <- [:active, :archived] do
      accent = WorkspaceAccent.of(%{language: language, status: status})

      for slot <- slots do
        assert is_binary(Map.get(accent, slot)), "#{language}/#{status} is missing #{slot}"
      end
    end
  end
end
