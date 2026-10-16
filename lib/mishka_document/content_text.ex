# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_document/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaDocument.ContentText do
  @moduledoc """
  The text a page's or a note's HTML content reads as, without its markup: what its card, its row
  and its drafts preview, what its words are counted in, and what its search description is cut
  from (`MishkaDocument.Plugins.PageSeo`).

  Every tag reads as a space, so two paragraphs stay two words apart, and the entities the
  sanitizer writes are read back.

      iex> MishkaDocument.ContentText.text(~s(<p dir="auto">Tom &amp; Jerry</p><p>ran</p>))
      "Tom & Jerry ran"
  """

  @entities %{
    "&nbsp;" => " ",
    "&lt;" => "<",
    "&gt;" => ">",
    "&quot;" => "\"",
    "&#39;" => "'",
    "&amp;" => "&"
  }

  @doc """
  `html` without its tags, its entities read and its whitespace run into single spaces, on one line.
  `""` for no content.

      iex> MishkaDocument.ContentText.text(nil)
      ""
  """
  @spec text(term()) :: String.t()
  def text(html) when is_binary(html) do
    html
    |> String.replace(~r/<[^>]*>/, " ")
    |> String.replace(Map.keys(@entities), &Map.fetch!(@entities, &1))
    |> String.replace(~r/\s+/u, " ")
    |> String.trim()
  end

  def text(_no_content), do: ""

  @doc """
  The first `length` characters of `text/1`; `nil` when the content reads as nothing.

      iex> MishkaDocument.ContentText.preview("<p>Getting started</p>", 7)
      "Getting"

      iex> MishkaDocument.ContentText.preview("<p> </p>", 7)
      nil
  """
  @spec preview(term(), pos_integer()) :: String.t() | nil
  def preview(html, length) when is_integer(length) and length > 0 do
    case text(html) do
      "" -> nil
      text -> String.slice(text, 0, length)
    end
  end

  @doc """
  How many words `text/1` holds.

      iex> MishkaDocument.ContentText.word_count(~s(<p dir="auto">One two</p><p>three</p>))
      3
  """
  @spec word_count(term()) :: non_neg_integer()
  def word_count(html), do: html |> text() |> String.split() |> length()
end
