defmodule MishkaDocument.Resources.Changes.ContentFacts do
  @moduledoc """
  The components, the icons and the classes a page's or a note's `content` names, worked out when
  it is written — reading either works out nothing:

    * `content_components` — the names its markers give
      (`MishkaCmsCore.Runtime.ContentComponents.names/1`), `nil` when it names none. A site's
      stylesheet is built from them — see `MishkaDocument.Plugins.ContentComponents`.
    * `content_icons` — the icon classes it names, in a marker's attribute or in its HTML
      (`MishkaCmsCore.Runtime.ContentComponents.icons/1`), `nil` when it names none. The site's
      stylesheet carries a rule for each — see `MishkaDocument.Plugins.ContentComponents`.
    * `content_classes` — the classes it writes: its HTML's class lists, a marker's `class` and
      `*_class` attributes, and the attributes its component takes a class string in
      (`MishkaCmsCore.Runtime.ContentComponents.site_classes/2`), `nil` when it writes none. The
      site's stylesheet is built with each — see `MishkaDocument.Plugins.ContentComponents`.

  Worked out in a `before_action` hook, which runs after every change an action lists — the
  `guardedstruct` sanitizer and `MishkaDocument.Resources.Changes.HighlightCode` included — so they
  are read off the content that is stored. Every write works them out again from the content it
  stores, whether or not it changed it, so a row never names what its content does not.

  ## The stylesheet

  A write that makes a name, an icon or a class live on its site — an approved page or note names it
  now and did not before, and no other approved page or note of the site names it — rebuilds the
  site's stylesheet, through `MishkaCmsCore.Runtime.Compilers.TailwindCompiler.schedule/1`. The job
  is enqueued in the write's own transaction, so a write rolled back asks for nothing. A name, an
  icon or a class dropped, or a page sent back to review, rebuilds nothing.

  ## Usage

      update :update do
        change MishkaDocument.Resources.Changes.HighlightCode
        change MishkaDocument.Resources.Changes.ContentFacts
      end
  """
  use Ash.Resource.Change

  require Ash.Query

  alias MishkaCmsCore.Runtime.Compilers.{SitemapCompiler, TailwindCompiler}
  alias MishkaCmsCore.Runtime.ContentComponents

  # Where a site's text is drawn from: a page's own, and its notes'.
  @drawn [MishkaDocument.Section, MishkaDocument.Note]

  # What a site's stylesheet is built from, each a list an approved page or note makes live.
  @styled [:content_components, :content_icons, :content_classes]

  @impl true
  def change(changeset, _opts, _context) do
    changeset
    |> Ash.Changeset.before_action(&facts/1)
    |> Ash.Changeset.after_action(&restyle/2)
  end

  defp facts(changeset) do
    content = Ash.Changeset.get_attribute(changeset, :content)

    changeset
    |> Ash.Changeset.force_change_attribute(
      :content_components,
      stored(ContentComponents.names(content))
    )
    |> Ash.Changeset.force_change_attribute(
      :content_icons,
      stored(ContentComponents.icons(content))
    )
    |> Ash.Changeset.force_change_attribute(
      :content_classes,
      stored(ContentComponents.site_classes(content, site_of(changeset)))
    )
  end

  defp site_of(changeset),
    do: Ash.Changeset.get_attribute(changeset, :site_id) || changeset.tenant

  defp stored([]), do: nil
  defp stored(found), do: found

  defp restyle(changeset, record) do
    case Enum.any?(@styled, &unstyled?(changeset.data, record, &1)) do
      true -> TailwindCompiler.schedule(record.site_id)
      false -> :ok
    end

    {:ok, record}
  end

  defp unstyled?(was, record, fact) do
    case newly_live(was, record, fact) do
      [] -> false
      live -> not named_elsewhere?(record, fact, live)
    end
  end

  @doc """
  What `record` makes live of `fact` that `was` did not — its component names
  (`:content_components`, the default), its icons (`:content_icons`) or its classes
  (`:content_classes`): what an approved page or note lists, less what it listed while approved
  before the write.
  """
  @spec newly_live(map(), map(), :content_components | :content_icons | :content_classes) ::
          [String.t()]
  def newly_live(was, record, fact \\ :content_components),
    do: live(record, fact) -- live(was, fact)

  defp live(
         %{content_review_status: :approved, technical_review_status: :approved} = record,
         fact
       ) do
    case Map.get(record, fact) do
      listed when is_list(listed) -> listed
      _nothing -> []
    end
  end

  defp live(_record, _fact), do: []

  # Whether every one of `values` is named by another approved page or note: the rows naming any of
  # them, read until each is found.
  #
  # READ AS THE SYSTEM, as the site's stylesheet is built: a page locked to some readers draws its
  # components, icons and classes for them, so it is styled whoever reads it.
  defp named_elsewhere?(record, fact, values) do
    @drawn
    |> Enum.reduce_while(MapSet.new(values), fn resource, unnamed ->
      case unnamed_after(resource, record, fact, unnamed) do
        [] -> {:halt, []}
        left -> {:cont, MapSet.new(left)}
      end
    end)
    |> Enum.empty?()
  end

  defp unnamed_after(resource, record, fact, unnamed) do
    resource
    |> Ash.Query.for_read(:public_list, %{}, tenant: record.site_id, authorize?: false)
    |> Ash.Query.filter(intersects(^ref(fact), ^MapSet.to_list(unnamed)))
    |> Ash.Query.select([fact])
    |> other_than(record)
    |> SitemapCompiler.stream_rows(tenant: record.site_id, authorize?: false)
    |> Enum.reduce_while(unnamed, fn row, unnamed ->
      left = MapSet.difference(unnamed, MapSet.new(Map.get(row, fact) || []))

      case MapSet.size(left) do
        0 -> {:halt, left}
        _some -> {:cont, left}
      end
    end)
    |> MapSet.to_list()
  end

  defp other_than(%{resource: resource} = query, %{__struct__: resource, id: id}),
    do: Ash.Query.filter(query, id != ^id)

  defp other_than(query, _record), do: query
end
