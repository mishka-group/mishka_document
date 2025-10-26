defmodule MishkaDocument.Resources.Helpers.DayMarks do
  @moduledoc """
  Ash preparation that tells each event-log row whether it opens a new day in the timeline, and — when
  it does — how many events that whole day holds. The day heading
  `MishkaCmsCoreWeb.Templates.ActivityTimeline` draws is built from both.

  A LiveView stream never hands a row its predecessor, so the marks are decided here, where the page
  is still an ordered list, and carried on each record's metadata (`:first_of_day?`, `:day_count`).

  Both figures are counted through the very same query the page read — the tenant scope of
  `MishkaDocument.Resources.Helpers.TenantSiteFilter` and whatever filters are active — so a heading
  can never disagree with the rows under it. They count the whole day rather than the loaded window:
  the log pages with `load_more`, and a heading counting only the loaded rows would keep climbing as
  you scroll.
  """
  use Ash.Resource.Preparation

  require Ash.Query

  @impl true
  def prepare(query, _opts, _context) do
    Ash.Query.after_action(query, fn query, records -> {:ok, mark(query, records)} end)
  end

  defp mark(_query, []), do: []

  defp mark(query, [first | _rest] = records) do
    counted = Ash.Query.unset(query, [:limit, :offset])
    day_counts = day_counts(counted, records)

    # The page's own first row is the only one with nothing above it to compare against. Asking
    # whether anything newer shares its day is what stops page 2 from repeating the heading page 1
    # ended on — on page 1 nothing does, so the first row opens its day.
    previous_day = if opens_day?(counted, first), do: nil, else: day_of(first)

    records
    |> Enum.map_reduce(previous_day, fn record, previous ->
      day = day_of(record)
      opens? = day != previous

      {stamp(record, opens?, if(opens?, do: Map.get(day_counts, day))), day}
    end)
    |> elem(0)
  end

  defp stamp(record, opens?, day_count) do
    record
    |> Ash.Resource.put_metadata(:first_of_day?, opens?)
    |> Ash.Resource.put_metadata(:day_count, day_count)
  end

  defp day_counts(query, records) do
    records
    |> Enum.map(&day_of/1)
    |> Enum.uniq()
    |> Map.new(fn day ->
      {start_at, end_at} = bounds(day)

      {day, count(Ash.Query.filter(query, occurred_at >= ^start_at and occurred_at < ^end_at))}
    end)
  end

  defp opens_day?(query, record) do
    at = record.occurred_at
    {_start_at, end_at} = at |> DateTime.to_date() |> bounds()

    query
    |> Ash.Query.filter(occurred_at > ^at and occurred_at < ^end_at)
    |> count()
    |> newest_of_day?()
  end

  defp newest_of_day?(0), do: true

  # A count that could not be taken must not swallow a heading: a repeated one is visible and scrolls
  # away, a missing one reads as though the day never started.
  defp newest_of_day?(nil), do: true
  defp newest_of_day?(_count), do: false

  # `nil` — never a number — is how an uncountable day says so: the heading then carries no total
  # rather than claiming "0 events".
  defp count(query) do
    case Ash.count(query) do
      {:ok, count} -> count
      {:error, _reason} -> nil
    end
  end

  defp day_of(record), do: DateTime.to_date(record.occurred_at)

  defp bounds(day) do
    {DateTime.new!(day, ~T[00:00:00.000000], "Etc/UTC"),
     DateTime.new!(Date.add(day, 1), ~T[00:00:00.000000], "Etc/UTC")}
  end
end
