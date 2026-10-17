# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_document/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaDocument.Resources.Helpers.Labels do
  @moduledoc """
  The small words, numbers and dates the document resources' tables draw in their cells.

  A table cell only receives the fields it `requires`, and a field the viewer's policy hides arrives
  as a struct rather than a value, so each function here takes `term()` and answers a safe value for
  anything it was not given.

      Labels.version_label("1.2.0")   #=> "v1.2.0"
      Labels.counted(%Ash.NotLoaded{})  #=> 0
  """
  use MishkaGervaz.Messages, backend: MishkaCmsCore.Gettext

  alias MishkaCmsCore.Localized

  @typedoc "A badge a cell draws: its words and the Tailwind classes it wears."
  @type badge :: %{label: String.t(), class: String.t()}

  # The review-chip palette every document table uses, so a status reads the same colour whichever
  # view you land on (`MishkaDocumentWeb.Templates.DocumentSection`'s cards use the same colours).
  @reviews %{
    approved: %{label: gettext_noop("Approved"), class: "bg-[#e6f6ee] text-[#177a53]"},
    pending: %{label: gettext_noop("Pending"), class: "bg-[#fbf1df] text-[#a5691a]"},
    rejected: %{label: gettext_noop("Rejected"), class: "bg-[#fbe9e7] text-[#b3433a]"},
    needs_revision: %{label: gettext_noop("Needs Revision"), class: "bg-[#f4ecfb] text-[#8a4bcc]"},
    archived: %{label: gettext_noop("Archived"), class: "bg-[#f2f1ec] text-[#6d6a63]"}
  }

  @unknown_review %{label: "—", class: "bg-[#f2f1ec] text-[#8a877f]"}

  @doc """
  The badge a review status wears, `%{label: label, class: classes}`, with the label in the viewer's
  language. A status that is none of the five reads as a dash.
  """
  @spec review_badge(term()) :: badge()
  def review_badge(status) when is_map_key(@reviews, status),
    do: translate_label(@reviews[status])

  def review_badge(_unknown), do: @unknown_review

  @doc "A badge map with its `:label` message id translated into the viewer's language."
  @spec translate_label(badge()) :: badge()
  def translate_label(%{label: label} = badge),
    do: %{badge | label: Gettext.gettext(MishkaCmsCore.Gettext, label)}

  # A `requires`-selected aggregate or calculation arrives as a truthy `%Ash.NotLoaded{}` or
  # `%Ash.ForbiddenField{}` when the viewer's field policy hides it, so `|| 0` lets the struct
  # through and the row renders it. Matching on the integer is what actually guards the cell.
  @doc "A count as a cell draws it: the integer itself, else `0`."
  @spec counted(term()) :: non_neg_integer()
  def counted(value) when is_integer(value) and value >= 0, do: value
  def counted(_unloaded), do: 0

  @doc """
  The first of `fields` of `record` that is loaded, `nil` when none is or the loaded one holds `nil`.

  A record read by a master carries its relationships under `master_` names, one read by a site
  user under the plain ones; the other set stays `%Ash.NotLoaded{}`.

      Labels.first_loaded(draft, [:master_section, :section])
  """
  @spec first_loaded(map(), [atom()]) :: term()
  def first_loaded(record, fields) do
    fields
    |> Enum.map(&Map.fetch!(record, &1))
    |> Enum.find(&(not match?(%Ash.NotLoaded{}, &1)))
  end

  @doc "The word for a kind of version bump, in the viewer's language."
  @spec increment_label(term()) :: String.t()
  def increment_label(:major), do: gettext("major")
  def increment_label(:minor), do: gettext("minor")
  def increment_label(:patch), do: gettext("patch")
  def increment_label(:prerelease), do: gettext("prerelease")
  def increment_label(:none), do: gettext("none")
  def increment_label(other), do: to_string(other)

  @doc "A version number as a tag reads it, `v1.2.0`; a record without one reads as `v0.0.1`."
  @spec version_label(term()) :: String.t()
  def version_label(version) when is_binary(version) and version != "", do: "v" <> version
  def version_label(_missing), do: "v0.0.1"

  @doc "The day a record was written, in the viewer's language; a dash for anything that is not a time."
  @spec inserted_on(term()) :: String.t()
  def inserted_on(at) when is_struct(at, DateTime) or is_struct(at, NaiveDateTime),
    do: Localized.date(at, :yMMMd)

  def inserted_on(_missing), do: "—"
end
