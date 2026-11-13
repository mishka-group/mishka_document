# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_document/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaDocumentWeb.Live.Admin.Dashboard.Home.StatsLive do
  @moduledoc """
  The row of figures across the top of the Documents dashboard, each read through Ash as the admin
  looking at it — a master across every site, a site admin on their own:

    * **Total Documents** — the documents (`MishkaDocument.Workspace`), and how many were added in
      the last seven days;
    * **Contributors** — the accounts the event log (`MishkaDocument.EventLog`) has writing a
      document, a version, a page, a note or a draft of either, and how many did in the last day;
    * **Completion** — the share of pages (`MishkaDocument.Section`) both their reviews approve;
    * **Last Updated** — when a document or a page was last changed.

  A figure is drawn only when its records are the admin's to read: Completion needs the section
  area, and Last Updated reads the pages only for an admin holding it.

  A live component of its own because it has its own reads: they run after the page is drawn
  (`assign_async`), so a slow count never holds the dashboard, and each figure is a `card/1`.
  Sending it `refresh: true` reads them again, keeping the figures shown until the new ones arrive.

      <.live_component module={StatsLive} id="document-stats" current_user={@current_user} />
  """
  use Phoenix.LiveComponent
  use Gettext, backend: MishkaCmsCore.Gettext

  import MishkaCmsCore.CoreComponents, only: [icon: 1]

  require Ash.Query

  import Ash.Expr, only: [expr: 1]

  alias MishkaCmsCore.Accounts.User
  alias MishkaCmsCore.Dashboard.Widget
  alias MishkaCmsCore.Localized

  alias MishkaDocument.{
    EventLog,
    Note,
    NoteDraft,
    Section,
    SectionDraft,
    Workspace,
    WorkspaceVersion
  }

  @written [Workspace, WorkspaceVersion, Section, Note, SectionDraft, NoteDraft]

  @impl true
  def update(%{refresh: true}, socket), do: {:ok, load(socket)}

  def update(assigns, socket) do
    socket = assign(socket, id: assigns.id, current_user: assigns.current_user)

    {:ok, if(socket.assigns[:stats], do: socket, else: load(socket))}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div
      id={@id}
      data-role="kpis"
      class="mb-4 grid grid-cols-4 gap-3 max-[980px]:mb-5 max-[980px]:grid-cols-2! max-[560px]:grid-cols-1!"
    >
      <.async_result :let={cards} assign={@stats}>
        <:loading>
          <div
            :for={_ <- 1..4}
            data-role="kpi-loading"
            class="h-[118px] animate-pulse rounded-[15px] border border-[#ecebe6] bg-[#faf9f6]"
          >
          </div>
        </:loading>
        <.card :for={card <- cards} {card} />
      </.async_result>
    </div>
    """
  end

  attr :id, :string, required: true
  attr :label, :string, required: true
  attr :icon, :string, required: true
  attr :tone, :string, required: true
  attr :value, :string, required: true
  attr :note, :string, required: true
  attr :note_tone, :string, required: true

  @doc "One figure: its icon and label, the figure, and a line under it."
  def card(assigns) do
    ~H"""
    <div
      id={"document-stat-#{@id}"}
      data-role="kpi"
      class="rounded-[15px] border border-[#ecebe6] bg-white p-4 shadow-[0_1px_2px_rgba(30,28,24,0.04)]"
    >
      <div class="flex items-center gap-2">
        <span class={["grid size-7 flex-none place-items-center rounded-lg", @tone]}>
          <.icon name={@icon} class="size-[15px]" />
        </span>
        <span class="text-[10.5px] font-semibold uppercase tracking-[0.04em] text-[#a8a5a0]">
          {@label}
        </span>
      </div>
      <div
        data-role="kpi-value"
        class="mt-[11px] font-['Space_Grotesk'] text-[28px] font-semibold tracking-[-0.03em] text-[#17161a]"
      >
        {@value}
      </div>
      <div data-role="kpi-note" class={["mt-[3px] text-[11px] font-semibold", @note_tone]}>
        {@note}
      </div>
    </div>
    """
  end

  @doc """
  The figures `user` may read, in the order they are drawn, each as `card/1` takes it.

  Three reads in all, one per resource, each asking the database for every figure it gives at once.
  """
  @spec cards(User.t()) :: [map()]
  def cards(user) do
    week_ago = DateTime.add(DateTime.utc_now(), -7, :day)
    day_ago = DateTime.add(DateTime.utc_now(), -1, :day)

    documents =
      Workspace
      |> read(user)
      |> aggregate(user, [
        {:total, :count},
        {:added, :count, query: [filter: expr(inserted_at >= ^week_ago)]},
        {:updated_at, :max, field: :updated_at}
      ])

    pages =
      Section
      |> read(user)
      |> aggregate(user, [
        {:total, :count},
        {:approved, :count,
         query: [
           filter:
             expr(content_review_status == :approved and technical_review_status == :approved)
         ]},
        {:updated_at, :max, field: :updated_at}
      ])

    writers =
      EventLog
      |> read(user)
      |> Ash.Query.filter(
        resource in ^@written and action_type in [:create, :update] and not is_nil(actor_id)
      )
      |> aggregate(user, [
        {:total, :count, field: :actor_id, uniq?: true},
        {:active, :count,
         field: :actor_id, uniq?: true, query: [filter: expr(occurred_at >= ^day_ago)]}
      ])

    [
      documents(documents),
      contributors(writers),
      completion(pages),
      last_updated(documents, pages)
    ]
    |> Enum.flat_map(fn
      {:ok, card} -> [card]
      :not_readable -> []
    end)
  end

  defp load(socket) do
    user = socket.assigns.current_user

    MishkaGervaz.Messages.assign_async(socket, :stats, fn -> {:ok, %{stats: cards(user)}} end)
  end

  defp documents({:ok, %{total: total, added: added}}) do
    {:ok,
     %{
       id: "documents",
       label: gettext("Total Documents"),
       icon: "hero-document-text",
       tone: "bg-[#eeedfb] text-[#5b57d6]",
       value: Localized.number(total),
       note: gettext("+%{count} this week", count: Localized.number(added)),
       note_tone: if(added > 0, do: "text-[#1f9d6b]", else: "text-[#8a877f]")
     }}
  end

  defp documents(:not_readable), do: :not_readable

  defp contributors({:ok, %{total: total, active: active}}) do
    {:ok,
     %{
       id: "contributors",
       label: gettext("Contributors"),
       icon: "hero-users",
       tone: "bg-[#eeedfb] text-[#5b57d6]",
       value: Localized.number(total),
       note: gettext("%{count} active in the last day", count: Localized.number(active)),
       note_tone: "text-[#8a877f]"
     }}
  end

  defp contributors(:not_readable), do: :not_readable

  defp completion({:ok, %{total: total, approved: approved}}) do
    {:ok,
     %{
       id: "completion",
       label: gettext("Completion"),
       icon: "hero-check-circle",
       tone: "bg-[#fbf1df] text-[#cf8a24]",
       value: percent(approved, total),
       note:
         gettext("%{approved} of %{total} pages approved",
           approved: Localized.number(approved),
           total: Localized.number(total)
         ),
       note_tone: "text-[#8a877f]"
     }}
  end

  defp completion(:not_readable), do: :not_readable

  # Last Updated needs the documents; the pages count only for an admin who may read them.
  defp last_updated(:not_readable, _pages), do: :not_readable

  defp last_updated({:ok, %{updated_at: document_at}}, pages) do
    page_at =
      case pages do
        {:ok, %{updated_at: at}} -> at
        :not_readable -> nil
      end

    case Enum.reject([document_at, page_at], &is_nil/1) do
      [] ->
        {:ok, last_updated_card("—", gettext("Nothing written yet"))}

      changed ->
        at = Enum.max(changed, DateTime)
        {:ok, last_updated_card(Widget.relative_time(at), Localized.date(at, :yMMMd))}
    end
  end

  defp last_updated_card(value, note),
    do: %{
      id: "last-updated",
      label: gettext("Last Updated"),
      icon: "hero-clock",
      tone: "bg-[#f2f1ec] text-[#6d6a63]",
      value: value,
      note: note,
      note_tone: "text-[#8a877f]"
    }

  defp percent(_approved, 0), do: "—"
  defp percent(approved, total), do: "#{round(approved * 100 / total)}%"

  # A master reads every site's records, a site admin their own site's.
  defp read(resource, %User{site_id: nil} = user),
    do: Ash.Query.for_read(resource, :master_read, %{}, actor: user)

  defp read(resource, user), do: Ash.Query.for_read(resource, :read, %{}, read_opts(user))

  defp read_opts(%User{site_id: nil} = user), do: [actor: user]
  defp read_opts(%User{site_id: site_id} = user), do: [actor: user, tenant: site_id]

  defp aggregate(query, user, aggregates),
    do: query |> Ash.aggregate(aggregates, read_opts(user)) |> readable()

  # A read the admin's areas do not reach leaves its figure out; any other failure is a bug.
  defp readable({:ok, value}), do: {:ok, value}
  defp readable({:error, %Ash.Error.Forbidden{}}), do: :not_readable
end
