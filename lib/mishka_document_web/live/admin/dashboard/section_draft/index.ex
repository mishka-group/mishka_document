# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_document/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaDocumentWeb.Live.Admin.Dashboard.SectionDraft.Index do
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
      |> assign(:page_title, gettext("Section Drafts"))
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
    url_state = UrlSync.decode(checked(params), uri, MishkaDocument.SectionDraft)
    {:noreply, assign(socket, :url_state, url_state)}
  end

  defp subscribe_when_connected(socket, user) do
    if connected?(socket), do: subscribe_to_pubsub(socket, user), else: socket
  end

  defp subscribe_to_pubsub(socket, %User{site_id: nil}) do
    Phoenix.PubSub.subscribe(MishkaCmsCore.PubSub, "section_draft:created")
    Phoenix.PubSub.subscribe(MishkaCmsCore.PubSub, "section_draft:updated")
    Phoenix.PubSub.subscribe(MishkaCmsCore.PubSub, "section_draft:destroyed")
    socket
  end

  defp subscribe_to_pubsub(socket, %User{site_id: site_id}) when is_binary(site_id) do
    Phoenix.PubSub.subscribe(MishkaCmsCore.PubSub, "section_draft:#{site_id}:created")
    Phoenix.PubSub.subscribe(MishkaCmsCore.PubSub, "section_draft:#{site_id}:updated")

    Phoenix.PubSub.subscribe(
      MishkaCmsCore.PubSub,
      "section_draft:#{site_id}:destroyed"
    )

    socket
  end

  defp subscribe_to_pubsub(socket, _), do: socket

  defp close_form_modal(socket) do
    js = MishkaCmsCore.CoreComponents.hide_modal("section-draft-form-modal")

    push_event(socket, "gervaz:exec-js", %{
      target: "section-draft-form-modal",
      js: Jason.encode!(js.ops)
    })
  end

  @impl true
  def handle_info({:form_saved, :create, _result}, socket) do
    {:noreply,
     socket
     |> close_form_modal()
     |> put_flash(:info, gettext("Section draft created successfully"))}
  end

  @impl true
  def handle_info({:form_saved, :update, _result}, socket) do
    {:noreply,
     socket
     |> close_form_modal()
     |> put_flash(:info, gettext("Section draft updated successfully"))}
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
        section_draft =
          case current_user do
            %User{site_id: nil} ->
              Ash.get!(MishkaDocument.SectionDraft, id,
                action: :master_get,
                actor: current_user,
                load: [
                  :site,
                  :master_workspace_version,
                  :master_source_section,
                  :master_parent_section,
                  :created_by_user
                ]
              )

            %User{site_id: site_id} when is_binary(site_id) ->
              Ash.get!(MishkaDocument.SectionDraft, id,
                actor: current_user,
                tenant: site_id,
                load: [
                  :site,
                  :workspace_version,
                  :source_section,
                  :parent_section,
                  :created_by_user
                ]
              )
          end

        %{section_draft: section_draft}
      end)

    {:noreply, socket}
  end

  @impl true
  def handle_info(
        %Phoenix.Socket.Broadcast{
          topic: "section_draft" <> _,
          payload: %Ash.Notifier.Notification{} = notification
        },
        socket
      ) do
    send_update(MishkaGervaz.Table.Web.Live,
      id: "section-drafts-table",
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
      id: "section-drafts-table",
      expanded_html: html
    )

    {:noreply, socket}
  end

  @impl true
  def handle_async({:load_expanded, _id}, {:exit, reason}, socket) do
    send_update(MishkaGervaz.Table.Web.Live,
      id: "section-drafts-table",
      expanded_error: reason
    )

    {:noreply, socket}
  end

  defp render_expanded_content(%{section_draft: sd}) do
    wv =
      cond do
        !match?(%Ash.NotLoaded{}, sd.master_workspace_version) -> sd.master_workspace_version
        !match?(%Ash.NotLoaded{}, sd.workspace_version) -> sd.workspace_version
        true -> nil
      end

    wv_name = if wv, do: wv.version_name, else: gettext("Unknown")

    source =
      cond do
        !match?(%Ash.NotLoaded{}, sd.master_source_section) -> sd.master_source_section
        !match?(%Ash.NotLoaded{}, sd.source_section) -> sd.source_section
        true -> nil
      end

    source_title = if source, do: source.title, else: "-"

    parent =
      cond do
        !match?(%Ash.NotLoaded{}, sd.master_parent_section) -> sd.master_parent_section
        !match?(%Ash.NotLoaded{}, sd.parent_section) -> sd.parent_section
        true -> nil
      end

    parent_title = if parent, do: parent.title, else: "-"

    creator =
      if sd.created_by_user && !match?(%Ash.NotLoaded{}, sd.created_by_user),
        do: sd.created_by_user.email,
        else: MishkaCmsCore.Accounts.Helper.label(:unknown)

    assigns = %{
      sd: sd,
      wv_name: wv_name,
      source_title: source_title,
      parent_title: parent_title,
      creator: creator
    }

    ~H"""
    <div class="space-y-3">
      <div class="grid grid-cols-2 md:grid-cols-3 gap-4 text-sm">
        <div>
          <span class="font-semibold text-gray-500">{gettext("Title:")}</span>
          <p class="text-gray-900">{@sd.title}</p>
        </div>
        <div>
          <span class="font-semibold text-gray-500">{gettext("Slug:")}</span>
          <p dir="ltr" class="text-gray-900 rtl:text-right">/{@sd.slug}</p>
        </div>
        <div>
          <span class="font-semibold text-gray-500">{gettext("Language:")}</span>
          <p dir="ltr" class="text-gray-900 rtl:text-right">{@sd.language}</p>
        </div>
        <div>
          <span class="font-semibold text-gray-500">{gettext("Version:")}</span>
          <p dir="ltr" class="text-gray-900 rtl:text-right">{@sd.change_version}</p>
        </div>
        <div>
          <span class="font-semibold text-gray-500">{gettext("Increment Type:")}</span>
          <p class="text-gray-900">{Labels.increment_label(@sd.version_increment_type)}</p>
        </div>
        <div>
          <span class="font-semibold text-gray-500">{gettext("Order:")}</span>
          <p class="text-gray-900">{@sd.order_position}</p>
        </div>
        <div>
          <span class="font-semibold text-gray-500">{gettext("Content Review:")}</span>
          <p class="text-gray-900">{DocumentSection.review_label(@sd.content_review_status)}</p>
        </div>
        <div>
          <span class="font-semibold text-gray-500">{gettext("Technical Review:")}</span>
          <p class="text-gray-900">{DocumentSection.review_label(@sd.technical_review_status)}</p>
        </div>
        <div>
          <span class="font-semibold text-gray-500">{gettext("Applied:")}</span>
          <p class="text-gray-900">
            {if @sd.applied_at,
              do: Calendar.strftime(@sd.applied_at, "%Y-%m-%d %H:%M"),
              else: gettext("Not applied")}
          </p>
        </div>
        <div>
          <span class="font-semibold text-gray-500">{gettext("Site:")}</span>
          <p class="text-gray-900">
            {if @sd.site && !match?(%Ash.NotLoaded{}, @sd.site),
              do: @sd.site.name,
              else: gettext("Unknown")}
          </p>
        </div>
        <div>
          <span class="font-semibold text-gray-500">{gettext("Workspace Version:")}</span>
          <p class="text-gray-900">{@wv_name}</p>
        </div>
        <div>
          <span class="font-semibold text-gray-500">{gettext("Source Section:")}</span>
          <p class="text-gray-900">{@source_title}</p>
        </div>
        <div>
          <span class="font-semibold text-gray-500">{gettext("Parent Section:")}</span>
          <p class="text-gray-900">{@parent_title}</p>
        </div>
        <div>
          <span class="font-semibold text-gray-500">{gettext("Created By:")}</span>
          <p dir="auto" class="text-gray-900">{@creator}</p>
        </div>
      </div>
      <%= if @sd.content do %>
        <div>
          <span class="font-semibold text-gray-500">{gettext("Content:")}</span>
          <p class="text-gray-900 text-sm mt-1 whitespace-pre-wrap bg-gray-50 p-2 rounded">
            {String.slice(@sd.content, 0, 500)}{if String.length(@sd.content) > 500,
              do: "...",
              else: ""}
          </p>
        </div>
      <% end %>
      <div class="flex items-center justify-between mt-2">
        <div class="text-xs text-gray-500">
          {gettext("Created: %{date}", date: Calendar.strftime(@sd.inserted_at, "%Y-%m-%d %H:%M"))}
        </div>
        <a
          href={"/admin/dashboard/document/note-drafts?note_drafts_filter_section_draft_id=#{@sd.id}&return_to=#{@sd.workspace_version_id}"}
          class="inline-flex items-center gap-1.5 px-3 py-1.5 text-xs font-medium text-amber-700 bg-amber-50 border border-amber-200 rounded-lg hover:bg-amber-100 transition-colors"
        >
          <span class="hero-document-text w-3.5 h-3.5"></span> {gettext("View Note Drafts")}
        </a>
      </div>
    </div>
    """
    |> Phoenix.HTML.Safe.to_iodata()
    |> IO.iodata_to_binary()
  end
end
