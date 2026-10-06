defmodule MishkaDocument.WorkspaceAccent do
  @moduledoc """
  The two colours a workspace card wears: one for how far along it is, one for what language it is in.

  ## The card's chrome says how done it is — `for_progress/1`

  Its bar, tile, completion track, stat icons and ring are banded by completion:

  | Completion | Reads as    | Colour           |
  | ---------- | ----------- | ---------------- |
  | `0–29`     | behind      | red `#d5544b`    |
  | `30–49`    | started     | amber `#cf8a24`  |
  | `50–79`    | in progress | indigo `#5b57d6` |
  | `80–99`    | success     | green `#1f9d6b`  |
  | `100`      | complete    | blue `#2f86c4`   |

  Blue is exactly 100 and nothing else — its whole job is to mean *finished*, and 99% is not finished,
  so the last stretch stays green. Every tone is one the design already uses: the three its Logs and
  Issues panels wear, plus two from its language palette.

  Colouring the chrome by *language* is what the design does, but it does not survive this list. The
  list shows one row per document (`MishkaDocument.WorkspaceScope`), so every row is a master, and in
  practice masters are nearly all one language — every card came out the same colour, and the colour
  said nothing. Completion varies per card and is the thing worth reading across a grid.

  ## The badges still say which language — `of/1`

  The language badge and the edition chips keep their language colour, because that is the one place
  the colour still carries information: `EN · Primary` beside `FA · 100%` is only legible if the two
  differ. The design names five — EN indigo, FA green, RU amber, FR pink, DE blue — but `language` is
  a free ISO-639-1 string, so an unnamed one (`ar`, `zh`, `pt`) is *hashed* into the same five rather
  than all falling back to one. `:erlang.phash2/2` is stable, so a language keeps its colour for good
  (the same trick `MishkaCmsCore.Activity.Helpers.avatar_tone/1` uses for actor avatars).

  An archived workspace ignores both and goes grey — archived reads as inactive before it reads as
  Farsi or as 80% done.

  Every value is a Tailwind class, not a hex string: the runtime CSS compiler only emits a class it
  can see written out, so the palette has to be literal (see `MishkaCmsCoreWeb.Templates.…` ports).

      iex> MishkaDocument.WorkspaceAccent.of(%{language: "en", status: :active}).bar
      "bg-[#5b57d6]"

      iex> MishkaDocument.WorkspaceAccent.for_progress(%{health_metrics: %{completion: 92}}).bar
      "bg-[#1f9d6b]"
  """

  # The five bands, in order. Every tone is one the design already uses — the three its Logs and
  # Issues panels wear, plus two from its language palette — so the card invents no new colour.
  alias MishkaCmsCore.LanguageAccent

  @behind %{
    bar: "bg-[#d5544b]",
    solid: "text-[#d5544b]",
    tile: "bg-[#fbe9e7] text-[#d5544b]",
    chip: "border-[#f3d6d2] bg-[#fbe9e7] text-[#b3433a]",
    track: "bg-[#fbe9e7]",
    fill: "bg-[#d5544b]",
    stroke: "#d5544b"
  }

  @started %{
    bar: "bg-[#cf8a24]",
    solid: "text-[#cf8a24]",
    tile: "bg-[#fbf1df] text-[#cf8a24]",
    chip: "border-[#f0e2c4] bg-[#fbf1df] text-[#a5691a]",
    track: "bg-[#fbf1df]",
    fill: "bg-[#cf8a24]",
    stroke: "#cf8a24"
  }

  @underway %{
    bar: "bg-[#5b57d6]",
    solid: "text-[#5b57d6]",
    tile: "bg-[#eeedfb] text-[#5b57d6]",
    chip: "border-[#dcdbf5] bg-[#eeedfb] text-[#4f4bcc]",
    track: "bg-[#edecfa]",
    fill: "bg-[#5b57d6]",
    stroke: "#5b57d6"
  }

  @success %{
    bar: "bg-[#1f9d6b]",
    solid: "text-[#1f9d6b]",
    tile: "bg-[#e6f6ee] text-[#1f9d6b]",
    chip: "border-[#cdeadb] bg-[#e6f6ee] text-[#177a53]",
    track: "bg-[#e6f6ee]",
    fill: "bg-[#1f9d6b]",
    stroke: "#1f9d6b"
  }

  @complete %{
    bar: "bg-[#2f86c4]",
    solid: "text-[#2f86c4]",
    tile: "bg-[#e6f1fa] text-[#2f86c4]",
    chip: "border-[#cfe3f4] bg-[#e6f1fa] text-[#276fa3]",
    track: "bg-[#e6f1fa]",
    fill: "bg-[#2f86c4]",
    stroke: "#2f86c4"
  }

  @started_from 30
  @underway_from 50
  @success_from 80
  @complete_at 100

  @doc """
  The accent a workspace's *chrome* wears — how far along it is, or grey once archived.

  `health_metrics` is field-policy gated, so it can arrive unloaded; a workspace nobody can measure
  reads as 0% and shows as behind rather than crashing the card.
  """
  @spec for_progress(map()) :: map()
  def for_progress(%{status: :archived}), do: LanguageAccent.archived()
  def for_progress(%{archived_at: at}) when not is_nil(at), do: LanguageAccent.archived()

  def for_progress(%{health_metrics: %{completion: completion}}) when is_number(completion),
    do: for_completion(completion)

  def for_progress(_workspace), do: for_completion(0)

  # The band a completion percentage falls in. `complete` is exactly 100 and nothing else: the point of
  # blue is that it means finished, and 99% is not finished.
  defp for_completion(completion) when is_number(completion) do
    cond do
      completion >= @complete_at -> @complete
      completion >= @success_from -> @success
      completion >= @underway_from -> @underway
      completion >= @started_from -> @started
      true -> @behind
    end
  end

  @doc "The accent a workspace's language badge wears — its language's colour, or grey once archived."
  @spec of(map()) :: map()
  defdelegate of(workspace), to: LanguageAccent
end
