defmodule MishkaDocument.Resources.Changes.ContentFacts do
  @moduledoc """
  The components a page's or a note's `content` names, worked out when it is written — reading
  either works out nothing:

    * `content_components` — the names its markers give
      (`MishkaCmsCore.Runtime.ContentComponents.names/1`), `nil` when it names none. A site's
      stylesheet is built from them — see `MishkaDocument.Plugins.ContentComponents`.

  Worked out in a `before_action` hook, which runs after every change an action lists — the
  `guardedstruct` sanitizer and `MishkaDocument.Resources.Changes.HighlightCode` included — so they
  are read off the content that is stored. Every write works them out again from the content it
  stores, whether or not it changed it, so a row never names what its content does not.

  ## The stylesheet

  A write that makes a name live on its site — an approved page or note names it now and did not
  before, and no other approved page or note of the site names it — rebuilds the site's stylesheet,
  through `MishkaCmsCore.Runtime.Compilers.TailwindCompiler.schedule/1`. The job is enqueued in the
  write's own transaction, so a write rolled back asks for nothing. A name dropped, or a page sent
  back to review, rebuilds nothing.

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

  @impl true
  def change(changeset, _opts, _context) do
    changeset
    |> Ash.Changeset.before_action(&facts/1)
    |> Ash.Changeset.after_action(&restyle/2)
  end

  defp facts(changeset) do
    case Ash.Changeset.get_attribute(changeset, :content) do
      content when is_binary(content) ->
        Ash.Changeset.force_change_attribute(
          changeset,
          :content_components,
          stored_names(content)
        )

      _no_content ->
        Ash.Changeset.force_change_attribute(changeset, :content_components, nil)
    end
  end

  defp stored_names(content) do
    case ContentComponents.names(content) do
      [] -> nil
      names -> names
    end
  end

  defp restyle(changeset, record) do
    case newly_live(changeset.data, record) do
      [] -> :ok
      names -> rebuild(record, Enum.reject(names, &named_elsewhere?(record, &1)))
    end

    {:ok, record}
  end

  defp rebuild(_record, []), do: :ok
  defp rebuild(record, _unstyled), do: TailwindCompiler.schedule(record.site_id)

  @doc """
  The component names `record` makes live that `was` did not: the names of an approved page or note,
  less the names it had while approved before the write.
  """
  @spec newly_live(map(), map()) :: [String.t()]
  def newly_live(was, record), do: live_names(record) -- live_names(was)

  defp live_names(%{
         content_review_status: :approved,
         technical_review_status: :approved,
         content_components: names
       })
       when is_list(names),
       do: names

  defp live_names(_record), do: []

  # READ AS THE SYSTEM, as the site's stylesheet is built: a page locked to some readers draws its
  # components for them, so it is styled whoever reads it.
  defp named_elsewhere?(record, name) do
    Enum.any?(@drawn, fn resource ->
      resource
      |> Ash.Query.for_read(:public_list, %{}, tenant: record.site_id, authorize?: false)
      |> Ash.Query.filter(has(content_components, ^name))
      |> other_than(record)
      |> Ash.exists?(tenant: record.site_id, authorize?: false)
    end)
  end

  defp other_than(%{resource: resource} = query, %{__struct__: resource, id: id}),
    do: Ash.Query.filter(query, id != ^id)

  defp other_than(query, _record), do: query
end
