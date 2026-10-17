# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_document/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaDocumentWeb.Live.Admin.Dashboard.NoteDraft.Index do
  use MishkaCmsCore.ExtensionLiveView

  alias MishkaCmsCore.Accounts.User
  alias MishkaDocument.Resources.Helpers.Labels
  alias MishkaDocumentWeb.Templates.DocumentSection
  alias MishkaGervaz.Table.Web.UrlSync

  @impl true
  def mount(params, _session, socket) do
    current_user = socket.assigns.current_user

    socket =
      socket
      |> assign(:page_title, gettext("Note Drafts"))
      |> assign(:url_state, nil)
      |> assign(:return_to, checked(params)["return_to"])
      |> subscribe_when_connected(current_user)

    {:ok, socket}
  end

  # `return_to` is a version's id; anything else is dropped before the table keeps it in the URL.
  defp checked(params) do
    case Ecto.UUID.cast(params["return_to"]) do
      {:ok, version_id} -> Map.put(params, "return_to", version_id)
      :error -> Map.delete(params, "return_to")
    end
  end

  @impl true
  def handle_params(params, uri, socket) do
    url_state = UrlSync.decode(checked(params), uri, MishkaDocument.NoteDraft)
    {:noreply, assign(socket, :url_state, url_state)}
  end

  defp subscribe_when_connected(socket, user) do
    if connected?(socket), do: subscribe_to_pubsub(socket, user), else: socket
  end

  defp subscribe_to_pubsub(socket, %User{site_id: nil}) do
    Phoenix.PubSub.subscribe(MishkaCmsCore.PubSub, "note_draft:created")
    Phoenix.PubSub.subscribe(MishkaCmsCore.PubSub, "note_draft:updated")
    Phoenix.PubSub.subscribe(MishkaCmsCore.PubSub, "note_draft:destroyed")
    socket
  end

  defp subscribe_to_pubsub(socket, %User{site_id: site_id}) when is_binary(site_id) do
    Phoenix.PubSub.subscribe(MishkaCmsCore.PubSub, "note_draft:#{site_id}:created")
    Phoenix.PubSub.subscribe(MishkaCmsCore.PubSub, "note_draft:#{site_id}:updated")
    Phoenix.PubSub.subscribe(MishkaCmsCore.PubSub, "note_draft:#{site_id}:destroyed")
    socket
  end

  defp subscribe_to_pubsub(socket, _), do: socket

  defp close_form_modal(socket) do
    js = MishkaCmsCore.CoreComponents.hide_modal("note-draft-form-modal")

    push_event(socket, "gervaz:exec-js", %{
      target: "note-draft-form-modal",
      js: Jason.encode!(js.ops)
    })
  end

  @impl true
  def handle_info({:form_saved, :create, _result}, socket) do
    {:noreply,
     socket
     |> close_form_modal()
     |> put_flash(:info, gettext("Note draft created successfully"))}
  end

  @impl true
  def handle_info({:form_saved, :update, _result}, socket) do
    {:noreply,
     socket
     |> close_form_modal()
     |> put_flash(:info, gettext("Note draft updated successfully"))}
  end

  @impl true
  def handle_info({:form_cancelled, _resource}, socket) do
    {:noreply, close_form_modal(socket)}
  end

  @impl true
  def handle_info({:row_action, _event, _payload}, socket), do: {:noreply, socket}

  @impl true
  def handle_info({:show_modal, _record}, socket), do: {:noreply, socket}

  @impl true
  def handle_info({:put_flash, kind, message}, socket) do
    {:noreply, put_flash(socket, kind, message)}
  end

  @impl true
  def handle_info({:expand_row, id}, socket) do
    current_user = socket.assigns.current_user

    socket =
      MishkaGervaz.Messages.start_async(socket, {:load_expanded, id}, fn ->
        note_draft =
          case current_user do
            %User{site_id: nil} ->
              Ash.get!(MishkaDocument.NoteDraft, id,
                action: :master_get,
                actor: current_user,
                load: [
                  :site,
                  :master_workspace_version,
                  :master_section,
                  :master_section_draft,
                  :master_source_note,
                  :created_by_user
                ]
              )

            %User{site_id: site_id} when is_binary(site_id) ->
              Ash.get!(MishkaDocument.NoteDraft, id,
                actor: current_user,
                tenant: site_id,
                load: [
                  :site,
                  :workspace_version,
                  :section,
                  :section_draft,
                  :source_note,
                  :created_by_user
                ]
              )
          end

        %{note_draft: note_draft}
      end)

    {:noreply, socket}
  end

  @impl true
  def handle_info(
        %Phoenix.Socket.Broadcast{
          topic: "note_draft" <> _,
          payload: %Ash.Notifier.Notification{} = notification
        },
        socket
      ) do
    send_update(MishkaGervaz.Table.Web.Live,
      id: "note-drafts-table",
      pubsub_notification: notification
    )

    {:noreply, socket}
  end

  @impl true
  def handle_info(_msg, socket), do: {:noreply, socket}

  @impl true
  def handle_async({:load_expanded, _id}, {:ok, data}, socket) do
    html = render_expanded_content(data)

    send_update(MishkaGervaz.Table.Web.Live,
      id: "note-drafts-table",
      expanded_html: html
    )

    {:noreply, socket}
  end

  @impl true
  def handle_async({:load_expanded, _id}, {:exit, reason}, socket) do
    send_update(MishkaGervaz.Table.Web.Live,
      id: "note-drafts-table",
      expanded_error: reason
    )

    {:noreply, socket}
  end

  defp render_expanded_content(%{note_draft: nd}) do
    wv =
      cond do
        !match?(%Ash.NotLoaded{}, nd.master_workspace_version) -> nd.master_workspace_version
        !match?(%Ash.NotLoaded{}, nd.workspace_version) -> nd.workspace_version
        true -> nil
      end

    wv_name = if wv, do: wv.version_name, else: gettext("Unknown")

    section =
      cond do
        !match?(%Ash.NotLoaded{}, nd.master_section) -> nd.master_section
        !match?(%Ash.NotLoaded{}, nd.section) -> nd.section
        true -> nil
      end

    section_title = if section, do: section.title, else: gettext("None")

    section_draft =
      cond do
        !match?(%Ash.NotLoaded{}, nd.master_section_draft) -> nd.master_section_draft
        !match?(%Ash.NotLoaded{}, nd.section_draft) -> nd.section_draft
        true -> nil
      end

    section_draft_title = if section_draft, do: section_draft.title, else: gettext("None")

    source_note =
      cond do
        !match?(%Ash.NotLoaded{}, nd.master_source_note) -> nd.master_source_note
        !match?(%Ash.NotLoaded{}, nd.source_note) -> nd.source_note
        true -> nil
      end

    source_note_title = if source_note, do: source_note.title, else: "-"

    creator =
      if nd.created_by_user && !match?(%Ash.NotLoaded{}, nd.created_by_user),
        do: nd.created_by_user.email,
        else: MishkaCmsCore.Accounts.Helper.label(:unknown)

    assigns = %{
      nd: nd,
      wv_name: wv_name,
      section_title: section_title,
      section_draft_title: section_draft_title,
      source_note_title: source_note_title,
      creator: creator
    }

    ~H"""
    <div class="space-y-3">
      <div class="grid grid-cols-2 md:grid-cols-3 gap-4 text-sm">
        <div>
          <span class="font-semibold text-gray-500">{gettext("Title:")}</span>
          <p class="text-gray-900">{@nd.title}</p>
        </div>
        <div>
          <span class="font-semibold text-gray-500">{gettext("Version:")}</span>
          <p dir="ltr" class="text-gray-900 rtl:text-right">{@nd.change_version}</p>
        </div>
        <div>
          <span class="font-semibold text-gray-500">{gettext("Increment Type:")}</span>
          <p class="text-gray-900">{Labels.increment_label(@nd.version_increment_type)}</p>
        </div>
        <div>
          <span class="font-semibold text-gray-500">{gettext("Order:")}</span>
          <p class="text-gray-900">{@nd.order_position}</p>
        </div>
        <div>
          <span class="font-semibold text-gray-500">{gettext("Content Review:")}</span>
          <p class="text-gray-900">{DocumentSection.review_label(@nd.content_review_status)}</p>
        </div>
        <div>
          <span class="font-semibold text-gray-500">{gettext("Technical Review:")}</span>
          <p class="text-gray-900">{DocumentSection.review_label(@nd.technical_review_status)}</p>
        </div>
        <div>
          <span class="font-semibold text-gray-500">{gettext("Applied:")}</span>
          <p class="text-gray-900">
            {if @nd.applied_at,
              do: Calendar.strftime(@nd.applied_at, "%Y-%m-%d %H:%M"),
              else: gettext("Not applied")}
          </p>
        </div>
        <div>
          <span class="font-semibold text-gray-500">{gettext("Site:")}</span>
          <p class="text-gray-900">
            {if @nd.site && !match?(%Ash.NotLoaded{}, @nd.site),
              do: @nd.site.name,
              else: gettext("Unknown")}
          </p>
        </div>
        <div>
          <span class="font-semibold text-gray-500">{gettext("Workspace Version:")}</span>
          <p class="text-gray-900">{@wv_name}</p>
        </div>
        <div>
          <span class="font-semibold text-gray-500">{gettext("Section:")}</span>
          <p class="text-gray-900">{@section_title}</p>
        </div>
        <div>
          <span class="font-semibold text-gray-500">{gettext("Section Draft:")}</span>
          <p class="text-gray-900">{@section_draft_title}</p>
        </div>
        <div>
          <span class="font-semibold text-gray-500">{gettext("Source Note:")}</span>
          <p class="text-gray-900">{@source_note_title}</p>
        </div>
        <div>
          <span class="font-semibold text-gray-500">{gettext("Created By:")}</span>
          <p dir="auto" class="text-gray-900">{@creator}</p>
        </div>
      </div>
      <%= if @nd.content do %>
        <div>
          <span class="font-semibold text-gray-500">{gettext("Content:")}</span>
          <p class="text-gray-900 text-sm mt-1 whitespace-pre-wrap bg-gray-50 p-2 rounded max-h-40 overflow-auto">
            {String.slice(@nd.content, 0, 500)}{if String.length(@nd.content) > 500,
              do: "...",
              else: ""}
          </p>
        </div>
      <% end %>
      <div class="flex items-center justify-between mt-2">
        <div class="text-xs text-gray-500">
          {gettext("Created: %{date}", date: Calendar.strftime(@nd.inserted_at, "%Y-%m-%d %H:%M"))}
        </div>
        <div class="flex items-center gap-2">
          <%= if @nd.section_draft_id do %>
            <a
              href={"/admin/dashboard/document/section-drafts?section_drafts_filter_workspace_version_id=#{@nd.workspace_version_id}&return_to=#{@nd.workspace_version_id}"}
              class="inline-flex items-center gap-1.5 px-3 py-1.5 text-xs font-medium text-purple-700 bg-purple-50 border border-purple-200 rounded-lg hover:bg-purple-100 transition-colors"
            >
              <span class="hero-document-duplicate w-3.5 h-3.5"></span> {gettext(
                "View Section Drafts"
              )}
            </a>
          <% end %>
          <%= if @nd.section_id do %>
            <a
              href={"/admin/dashboard/document/sections/#{@nd.workspace_version_id}"}
              class="inline-flex items-center gap-1.5 px-3 py-1.5 text-xs font-medium text-blue-700 bg-blue-50 border border-blue-200 rounded-lg hover:bg-blue-100 transition-colors"
            >
              <span class="hero-rectangle-stack w-3.5 h-3.5"></span> {gettext("View Sections")}
            </a>
          <% end %>
        </div>
      </div>
    </div>
    """
    |> Phoenix.HTML.Safe.to_iodata()
    |> IO.iodata_to_binary()
  end
end
