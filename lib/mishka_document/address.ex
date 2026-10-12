defmodule MishkaDocument.Address do
  @moduledoc """
  A document's own address — where it is read when its admin gives it one, `/chelekom/docs` — and
  where each of its pages is read under it.

  A document with no address is read under the documentation's base by its slug, as it always was:
  `/docs/<slug>`, its pages `/docs/<slug>/<page>`. One with an address is read there and nowhere
  else: `/chelekom/docs`, its pages `/chelekom/docs/<page>`, and `/docs/chelekom` is a missing
  page, as any slug that names no document there is.

  A page's own part of the address is the slugs of the pages it is filed under, then its own:
  `headless/switch` is the page `switch` filed under `headless`. A slug is unique among the pages
  that share its parent, so the same name may be used under two parents — `/chelekom/docs/tabs` and
  `/chelekom/docs/headless/tabs` are two pages.

  A version's front page (`front_page`, a page at the top) is drawn at the document's own address:
  its own part of the address is empty, so `/chelekom/docs` is that page, `/chelekom/docs/<its slug>`
  is a missing page, and the pages filed under it sit directly under the document's address.

  An address is a site path: segments of lower-case letters, digits and dashes, and `:lang` at most
  once, where the site's language goes, as in a page's path. The rules live here because the
  document, its pages, the head and the sitemap all read them, and must agree.
  """

  @lang ":lang"

  @section_capture "*section"

  @segment ~r/\A[a-z0-9]+(?:-[a-z0-9]+)*\z/

  @doc """
  The address as it is stored: trimmed, lower case, one leading slash and no trailing one. `nil` for
  nothing at all, and a value that is not a path is handed back as it was, for `check/1` to refuse.

      normalize(" /Chelekom/Docs/ ") #=> "/chelekom/docs"
      normalize("")                   #=> nil
  """
  @spec normalize(term()) :: String.t() | nil
  def normalize(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      given -> given |> String.downcase() |> parsed() |> stored(given)
    end
  end

  def normalize(_nothing), do: nil

  defp parsed(value) do
    case URI.new(value) do
      {:ok, %URI{scheme: nil, host: nil, query: nil, fragment: nil, path: path}}
      when is_binary(path) ->
        {:ok, path}

      _not_a_path ->
        :error
    end
  end

  defp stored({:ok, path}, given) do
    case String.split(path, "/", trim: true) do
      [] -> given
      segments -> "/" <> Enum.join(segments, "/")
    end
  end

  defp stored(:error, given), do: given

  @doc """
  `:ok` for a stored address the site can answer, else `{:error, reason}`: `:not_a_path`, or
  `:in_docs_base` for one under the base the documents with no address are read in.
  """
  @spec check(String.t()) :: :ok | {:error, :not_a_path | :in_docs_base}
  def check(address) when is_binary(address) do
    segments = segments(address)

    cond do
      segments == [] or normalize(address) != address ->
        {:error, :not_a_path}

      Enum.count(segments, &(&1 == @lang)) > 1 ->
        {:error, :not_a_path}

      not Enum.all?(segments, &(&1 == @lang or Regex.match?(@segment, &1))) ->
        {:error, :not_a_path}

      in_docs_base?(segments) ->
        {:error, :in_docs_base}

      true ->
        :ok
    end
  end

  @doc "The segments of an address, `:lang` among them."
  @spec segments(String.t()) :: [String.t()]
  def segments(address) when is_binary(address), do: String.split(address, "/", trim: true)

  @doc """
  Whether one address holds the other — the same, or one under the other — so one document's pages
  would answer at the other's: `/chelekom/docs` and `/chelekom/docs/headless` overlap.
  """
  @spec overlap?(String.t(), String.t()) :: boolean()
  def overlap?(one, other) do
    [short, long] = Enum.sort_by([segments(one), segments(other)], &length/1)
    List.starts_with?(long, short)
  end

  @doc "Whether an address holds the site's language."
  @spec language?(String.t()) :: boolean()
  def language?(address), do: @lang in segments(address)

  @doc """
  The two page paths a document at `address` is read at: its front page, and every page of it.
  """
  @spec page_paths(String.t()) :: %{document: String.t(), page: String.t()}
  def page_paths(address), do: %{document: address, page: address <> "/" <> @section_capture}

  @doc """
  The address a page at `page_path` serves — the page path itself, or the path a `*section` capture
  closes — and `nil` for any other kind of path.

      of_page("/chelekom/docs/*section") #=> "/chelekom/docs"
  """
  @spec of_page(term()) :: String.t() | nil
  def of_page(page_path) when is_binary(page_path) do
    own =
      case Enum.reverse(segments(page_path)) do
        [@section_capture | above] -> Enum.reverse(above)
        _no_capture -> segments(page_path)
      end

    if own != [] and Enum.all?(own, &(&1 == @lang or not String.starts_with?(&1, [":", "*"]))),
      do: "/" <> Enum.join(own, "/"),
      else: nil
  end

  def of_page(_no_path), do: nil

  @doc """
  A page's own part of its address, root first: the slugs of the pages it is drawn under, then its
  own, a front page's left out — `[]` for the front page itself. `parent_of` answers the parent each
  page is drawn under, or `nil` at the top — which may not be the parent it names, when that one is
  not published. A parent chain deeper than twenty, which only a loop makes, stops there.
  """
  @spec section_path(map(), (map() -> map() | nil)) :: [String.t()]
  def section_path(section, parent_of), do: climb(section, parent_of, [], 0)

  @doc """
  Every page's own part of its address among `sections` — the pages of one version a reader is
  shown, each with its `id`, `slug`, `parent_section_id` and `front_page` — as
  `%{id => ["headless", "switch"]}`, and `[]` for the front page.

  A page is under its parent when that parent is among them and walking up from it reaches the top;
  otherwise it is at the top. That is the rule the documentation's blocks draw the contents by, so a
  page's address is where the reader finds it.
  """
  @spec paths([map()]) :: %{optional(term()) => [String.t()]}
  def paths(sections) when is_list(sections) do
    by_id = Map.new(sections, &{&1.id, &1})
    Map.new(sections, &{&1.id, section_path(&1, fn page -> drawn_under(by_id, page) end)})
  end

  @doc """
  The page among `sections` whose own part of the address is `segments` — `["headless", "switch"]`,
  or the `"headless/switch"` a `*section` capture holds — or `nil`. Nothing asked, `[]` or `""`, is
  the front page, when they hold one.
  """
  @spec page_at([map()], [String.t()] | String.t()) :: map() | nil
  def page_at(sections, wanted) when is_binary(wanted), do: page_at(sections, segments(wanted))

  def page_at(sections, []) when is_list(sections), do: Enum.find(sections, &front_page?/1)

  def page_at(sections, [_ | _] = segments) when is_list(sections) do
    paths = paths(sections)
    Enum.find(sections, &(Map.get(paths, &1.id) == segments))
  end

  def page_at(_sections, _nothing_asked), do: nil

  @doc "Whether a page is its version's front page, drawn at its document's own address."
  @spec front_page?(map()) :: boolean()
  def front_page?(section), do: Map.get(section, :front_page) == true

  defp drawn_under(by_id, page) do
    case Map.get(by_id, page.parent_section_id) do
      nil -> nil
      parent -> if rooted?(by_id, page, 0), do: parent, else: nil
    end
  end

  defp rooted?(_by_id, _page, depth) when depth >= 20, do: false
  defp rooted?(_by_id, %{parent_section_id: nil}, _depth), do: true

  defp rooted?(by_id, page, depth) do
    case Map.get(by_id, page.parent_section_id) do
      nil -> true
      parent -> rooted?(by_id, parent, depth + 1)
    end
  end

  defp climb(nil, _parent_of, path, _depth), do: path
  defp climb(_section, _parent_of, path, depth) when depth >= 20, do: path

  defp climb(section, parent_of, path, depth),
    do: climb(parent_of.(section), parent_of, own_part(section, path), depth + 1)

  defp own_part(section, path) do
    if front_page?(section), do: path, else: [section.slug | path]
  end

  defp in_docs_base?(segments) do
    base = MishkaDocument.Provision.docs_base() |> segments() |> Enum.reject(&(&1 == @lang))

    segments
    |> Enum.reject(&(&1 == @lang))
    |> List.starts_with?(base)
  end
end
