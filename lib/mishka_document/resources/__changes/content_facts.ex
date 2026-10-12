defmodule MishkaDocument.Resources.Changes.ContentFacts do
  @moduledoc """
  The components and the icons a page's or a note's `content` names, worked out when it is written
  — reading either works out nothing:

    * `content_components` — the names its markers give
      (`MishkaCmsCore.Runtime.ContentComponents.names/1`), `nil` when it names none. A site's
      stylesheet is built from them — see `MishkaDocument.Plugins.ContentComponents`.
    * `content_icons` — the icon classes it names, in a marker's attribute or in its HTML
      (`MishkaCmsCore.Runtime.ContentComponents.icons/1`), `nil` when it names none. The site's
      stylesheet carries a rule for each — see `MishkaDocument.Plugins.ContentComponents`.

  Worked out in a `before_action` hook, which runs after every change an action lists — the
  `guardedstruct` sanitizer and `MishkaDocument.Resources.Changes.HighlightCode` included — so they
  are read off the content that is stored. Every write works them out again from the content it
  stores, whether or not it changed it, so a row never names what its content does not.

  ## The stylesheet

  A write that makes a name or an icon live on its site — an approved page or note names it now and
  did not before, and no other approved page or note of the site names it — rebuilds the site's
  stylesheet, through `MishkaCmsCore.Runtime.Compilers.TailwindCompiler.schedule/1`. The job is
  enqueued in the write's own transaction, so a write rolled back asks for nothing. A name or an
  icon dropped, or a page sent back to review, rebuilds nothing.

  ## Usage

      update :update do
        change MishkaDocument.Resources.Changes.HighlightCode
        change MishkaDocument.Resources.Changes.ContentFacts
      end
  """
  use Ash.Resource.Change

  require Ash.Query

  alias MishkaCmsCore.Runtime.Compilers.TailwindCompiler
  alias MishkaCmsCore.Runtime.ContentComponents

  # Where a site's text is drawn from: a page's own, and its notes'.
  @drawn [MishkaDocument.Section, MishkaDocument.Note]

  # What a site's stylesheet is built from, each a list an approved page or note makes live.
  @styled [:content_components, :content_icons]

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
  end

  defp stored([]), do: nil
  defp stored(found), do: found

  defp restyle(changeset, record) do
    case Enum.any?(@styled, &unstyled?(changeset.data, record, &1)) do
      true -> TailwindCompiler.schedule(record.site_id)
      false -> :ok
    end

    {:ok, record}
  end

  defp unstyled?(was, record, fact),
    do: was |> newly_live(record, fact) |> Enum.any?(&(not named_elsewhere?(record, fact, &1)))

  @doc """
  What `record` makes live of `fact` that `was` did not — its component names
  (`:content_components`, the default) or its icons (`:content_icons`): what an approved page or
  note lists, less what it listed while approved before the write.
  """
  @spec newly_live(map(), map(), :content_components | :content_icons) :: [String.t()]
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

  # READ AS THE SYSTEM, as the site's stylesheet is built: a page locked to some readers draws its
  # components and icons for them, so it is styled whoever reads it.
  defp named_elsewhere?(record, fact, value) do
    Enum.any?(@drawn, fn resource ->
      resource
      |> Ash.Query.for_read(:public_list, %{}, tenant: record.site_id, authorize?: false)
      |> Ash.Query.filter(has(^ref(fact), ^value))
      |> other_than(record)
      |> Ash.exists?(tenant: record.site_id, authorize?: false)
    end)
  end

  defp other_than(%{resource: resource} = query, %{__struct__: resource, id: id}),
    do: Ash.Query.filter(query, id != ^id)

  defp other_than(query, _record), do: query
end
