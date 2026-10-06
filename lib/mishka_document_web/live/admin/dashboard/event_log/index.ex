defmodule MishkaDocumentWeb.Live.Admin.Dashboard.EventLog.Index do
  @moduledoc """
  Admin event-log page at `/admin/dashboard/document/event-logs`. Mounts the standard
  `MishkaGervaz.Table.Web.Live` over `MishkaDocument.EventLog`, drawn by the shared
  `MishkaCmsCoreWeb.Templates.ActivityTimeline` — the same timeline as the unified log at
  `/admin/dashboard/runtime/activity`.

  Renders from the sibling `index.html.heex`.
  """
  use MishkaCmsCore.ExtensionLiveView

  alias MishkaDocument.EventLog
  alias MishkaGervaz.Table.Web.UrlSync

  @table_id "event-logs-table"

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket),
      do: Phoenix.PubSub.subscribe(MishkaCmsCore.PubSub, "event_log:created")

    {:ok,
     socket
     |> assign(:page_title, gettext("Event Logs"))
     |> assign(:url_state, nil)
     |> assign(:counts, nil)
     |> load_counts()}
  end

  @doc """
  The KPI totals, off the render path: each is a COUNT over the same action the table reads, so they
  should never hold the timeline up.
  """
  @impl true
  def handle_async(:counts, {:ok, counts}, socket),
    do: {:noreply, assign(socket, :counts, counts)}

  def handle_async(:counts, {:exit, _reason}, socket), do: {:noreply, socket}

  defp load_counts(socket) do
    user = socket.assigns[:current_user]

    if connected?(socket),
      do: MishkaGervaz.Messages.start_async(socket, :counts, fn -> EventLog.counts(user) end),
      else: socket
  end

  @impl true
  def handle_params(params, uri, socket) do
    url_state = UrlSync.decode(params, uri, EventLog)
    {:noreply, assign(socket, :url_state, url_state)}
  end

  @impl true
  def handle_info(
        %Phoenix.Socket.Broadcast{
          topic: "event_log" <> _,
          payload: %Ash.Notifier.Notification{} = notification
        },
        socket
      ) do
    send_update(MishkaGervaz.Table.Web.Live,
      id: @table_id,
      pubsub_notification: notification
    )

    {:noreply, load_counts(socket)}
  end

  @impl true
  def handle_info({:put_flash, kind, message}, socket) do
    {:noreply, put_flash(socket, kind, message)}
  end

  @impl true
  def handle_info(_msg, socket), do: {:noreply, socket}

  @doc "The KPI row: `{label, counts key, label classes, dot classes}`; the total carries no dot."
  def kpi_cards do
    [
      {gettext("Total events"), :total, "text-[#a8a5a0]", nil},
      {gettext("Info"), :info, "text-[#177a53]", "bg-[#1f9d6b]"},
      {gettext("Warning"), :warn, "text-[#a5691a]", "bg-[#cf8a24]"}
    ]
  end

  @doc "A count with thousands separators — `1284` reads as `1,284`."
  def delimited(number) when is_integer(number) do
    number
    |> Integer.to_string()
    |> String.graphemes()
    |> Enum.reverse()
    |> Enum.chunk_every(3)
    |> Enum.map_join(",", &Enum.join/1)
    |> String.reverse()
  end

  def delimited(_number), do: "0"
end
