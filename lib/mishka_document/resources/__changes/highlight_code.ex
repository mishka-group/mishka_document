# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_document/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaDocument.Resources.Changes.HighlightCode do
  @moduledoc """
  Highlights the code blocks of a page's `content` — a section's, a note's or a draft of either — with Makeup,
  once, when it is written.

  A block is a `<pre>` holding one `<code class="language-x">` whose code is still plain text, and
  whose language names a lexer Makeup has registered — by name (`elixir`, `iex`, `heex`, `eex`,
  `erlang`, `erl`, `html`, `json`, `diff`, `sql`, `js`, `javascript`, `ts`, `typescript`, `css`) or
  by file extension (`ex`, `exs`, `hrl`, `htm`, `patch`). It is stored as
  `<pre class="highlight"><code class="language-x">` with one `<span class="…">` per token, the
  classes the kit's `doc-code-highlight` stylesheet colours. Reading a page highlights nothing.

  Left as written:

    * a block whose code already holds markup — highlighted here before;
    * a block with no `language-` class, or one no lexer answers to (`sh`, `bash`, `shell`…);
    * a `<code>` that is not the only thing in its `<pre>`, and inline `<code>`;
    * a block whose lexer raises or takes longer than five seconds. Each block is lexed in its own
      task under `MishkaDocument.HighlightSupervisor`, so that block stays plain and the page is
      still written.

  ## After the sanitizer

  `content` is sanitized by the `guardedstruct` change, which Ash runs after every change an action
  lists. This one does its work in a `before_action` hook, which runs after all of them, so what it
  reads is the sanitizer's HTML: attributes double-quoted, and text escaped as `&amp;`, `&lt;` and
  `&gt;` and nothing else. The blocks are found in that shape and the tokens are written in it, so
  the code stays text — a `<script>` in a code block is `&lt;script&gt;` before and after — and
  saving a highlighted page again leaves its content as it is.

  ## Usage

      update :update do
        change MishkaDocument.Resources.Changes.HighlightCode
      end
  """
  use Ash.Resource.Change

  @supervisor MishkaDocument.HighlightSupervisor

  @timeout :timer.seconds(5)

  # A `<pre>` holding one `<code>` and nothing else, and that `<code>` holding text and nothing else.
  @block ~r{<pre((?:\s[^>]*)?)>(\s*)<code((?:\s[^>]*)?)>([^<]*)</code>(\s*)</pre>}

  @class ~r{\sclass="([^"]*)"}

  # The sanitizer writes `&` only as the start of one of these three, so a block holding any other
  # is not its output and is left as it is.
  @unknown_entity ~r{&(?!amp;|lt;|gt;)}

  @escapes %{"&" => "&amp;", "<" => "&lt;", ">" => "&gt;"}

  @unescapes Map.new(@escapes, fn {char, entity} -> {entity, char} end)

  @impl true
  def change(changeset, _opts, _context) do
    Ash.Changeset.before_action(changeset, fn changeset ->
      case Ash.Changeset.fetch_change(changeset, :content) do
        {:ok, content} when is_binary(content) ->
          Ash.Changeset.force_change_attribute(changeset, :content, highlight(content))

        _unchanged ->
          changeset
      end
    end)
  end

  @doc """
  `html` with every plain code block of a known language highlighted, and nothing else changed.
  """
  @spec highlight(String.t()) :: String.t()
  def highlight(html) when is_binary(html) do
    case @block |> Regex.scan(html) |> Enum.uniq() |> Enum.flat_map(&block/1) do
      [] ->
        html

      blocks ->
        highlighted = blocks |> lex() |> Map.new()

        Regex.replace(@block, html, fn whole, _pre, _lead, _code, _text, _trail ->
          Map.get(highlighted, whole, whole)
        end)
    end
  end

  defp block([whole, pre, lead, code, text, trail]) do
    with {:ok, language} <- language(code),
         {:ok, lexer} <- lexer(language),
         {:ok, source} <- source(text) do
      [{whole, lexer, source, {pre, lead, code, trail}}]
    else
      :error -> []
    end
  end

  defp language(code) do
    case Regex.run(@class, code, capture: :all_but_first) do
      [classes] -> classes |> String.split() |> Enum.find_value(:error, &language_class/1)
      nil -> :error
    end
  end

  defp language_class("language-" <> language) when language != "",
    do: {:ok, String.downcase(language)}

  defp language_class(_class), do: nil

  defp lexer(language) do
    with :error <- Makeup.Registry.fetch_lexer_by_name(language),
         do: Makeup.Registry.fetch_lexer_by_extension(language)
  end

  defp source(text) do
    cond do
      String.trim(text) == "" -> :error
      not String.valid?(text) -> :error
      Regex.match?(@unknown_entity, text) -> :error
      true -> {:ok, String.replace(text, Map.keys(@unescapes), &Map.fetch!(@unescapes, &1))}
    end
  end

  defp wrap({pre, lead, code, trail}, tokens),
    do: "<pre#{highlight_class(pre)}>#{lead}<code#{code}>#{tokens}</code>#{trail}</pre>"

  defp highlight_class(pre) do
    case Regex.run(@class, pre, capture: :all_but_first) do
      nil ->
        ~s( class="highlight") <> pre

      [classes] ->
        if "highlight" in String.split(classes),
          do: pre,
          else: Regex.replace(@class, pre, ~s( class="\\1 highlight"), global: false)
    end
  end

  defp lex(blocks) do
    @supervisor
    |> Task.Supervisor.async_stream_nolink(
      blocks,
      fn {_whole, {lexer, options}, source, _around} -> tokens(lexer, options, source) end,
      timeout: @timeout,
      on_timeout: :kill_task
    )
    |> Enum.zip(blocks)
    |> Enum.flat_map(fn
      {{:ok, tokens}, {whole, _lexer, _source, around}} -> [{whole, wrap(around, tokens)}]
      {{:exit, _reason}, _block} -> []
    end)
  end

  defp tokens(lexer, options, source) do
    source
    |> lexer.lex(options)
    |> Enum.reduce([], &segment/2)
    |> Enum.reverse()
    |> Enum.map(&span/1)
    |> IO.iodata_to_binary()
  end

  # NO TEXT IN A BLOCK IS WHITESPACE ALONE. The sanitizer parses a page again on every save and
  # every render, and its parser drops a text node holding only whitespace — `foo \n` then `bar`
  # came back as `foobar`. So whitespace is carried by the token before it, or by the one after when
  # it opens the block, and tokens of one class in a row share a span. That also leaves a block
  # with about a third of the spans it would carry otherwise.
  defp segment({type, _meta, value}, segments) do
    class = Makeup.Token.Utils.css_class_for_token_type(type)
    # A token's value is a string, a single character or a list of either, as the lexer made it.
    text = value |> List.wrap() |> IO.chardata_to_string()

    case segments do
      [{before_class, before} | rest] ->
        cond do
          blank?(text) -> [{before_class, before <> text} | rest]
          blank?(before) or before_class == class -> [{class, before <> text} | rest]
          true -> [{class, text} | segments]
        end

      [] ->
        [{class, text}]
    end
  end

  defp blank?(text), do: String.trim(text) == ""

  defp span({nil, text}), do: escape(text)
  defp span({class, text}), do: [~s(<span class="), class, ~s(">), escape(text), "</span>"]

  defp escape(text), do: String.replace(text, Map.keys(@escapes), &Map.fetch!(@escapes, &1))
end
