# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_document/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaDocumentWeb.Live.Admin.Dashboard.VersionsModal do
  @moduledoc """
  The version history of a dashboard list page: a modal that lists one record's versions a page at a
  time, previews one of them, and restores one. The page keeps the template, its `:versions_modal`
  and the one-line event handlers; everything they do is here.

  Every function takes the page's socket and returns it, with the assigns the template reads:
  `:versions`, `:versions_record_id`, `:versions_record_name`, `:versions_loading`,
  `:versions_page`, `:versions_per_page`, `:versions_total`, `:version_masters` and
  `:preview_version_id`.

      @versions [
        resource: MishkaDocument.Section,
        name: :title,
        modal: "section-versions-modal",
        not_found: gettext_noop("Section not found or access denied")
      ]

      def mount(_params, _session, socket) do
        {:ok, VersionsModal.assign_defaults(socket)}
      end

      def handle_event("restore_version", %{"version-id" => id}, socket),
        do: {:noreply, VersionsModal.restore(socket, @versions, id)}

      def handle_info({:row_action, "show_versions", %{"id" => id}}, socket),
        do: {:noreply, VersionsModal.show(socket, @versions, id)}

      def handle_async(:load_versions, result, socket),
        do: {:noreply, VersionsModal.loaded(socket, @versions, result)}

  The versions are read, and a version is restored, as the signed-in user in `:current_user`: a
  master through the master actions and every site, a site's admin through the site's own.

  ## Options

  * `:resource` - Required. The record's resource. It needs the `:get_with_versions` and
    `:master_get_with_versions` reads, a `Version` resource beside it, and the
    `:restore_version_api` and `:master_restore_version_api` actions.
  * `:name` - Required. The attribute shown as the modal's subtitle.
  * `:modal` - Required. The DOM id of the versions modal.
  * `:not_found` - Required. The flash for a record that cannot be read.
  * `:load` - What else the read loads, as `[master: [...], site: [...]]`.
  * `:loaded` - A `(socket, record)` function run once the versions are in, to assign more.
  """
  use Gettext, backend: MishkaCmsCore.Gettext

  import Phoenix.Component, only: [assign: 3]
  import Phoenix.LiveView, only: [push_event: 3, put_flash: 3]

  alias MishkaCmsCore.Accounts.User
  alias MishkaCmsCoreWeb.Templates.VersionHistory

  require Ash.Query

  @per_page 10

  @doc """
  The assigns a page starts with, no record selected and the modal empty.
  """
  @spec assign_defaults(Phoenix.LiveView.Socket.t()) :: Phoenix.LiveView.Socket.t()
  def assign_defaults(socket) do
    socket
    |> assign(:versions_record_id, nil)
    |> assign(:versions_record_name, nil)
    |> assign(:versions, [])
    |> assign(:version_masters, MapSet.new())
    |> assign(:versions_loading, false)
    |> assign(:preview_version_id, nil)
    |> assign(:versions_page, 1)
    |> assign(:versions_total, 0)
    |> assign(:versions_per_page, @per_page)
  end

  @doc """
  Shows the modal `id`. A modal opened by `:if` snaps in and out, gone from the DOM before its own
  transition can run, so the modals stay rendered and are driven by the `gervaz:exec-js` bridge the
  Gervaz form uses.
  """
  @spec open_modal(Phoenix.LiveView.Socket.t(), String.t()) :: Phoenix.LiveView.Socket.t()
  def open_modal(socket, id),
    do: exec_modal_js(socket, id, MishkaCmsCore.CoreComponents.show_modal(id))

  @doc "Hides the modal `id`, the way `open_modal/2` shows it."
  @spec close_modal(Phoenix.LiveView.Socket.t(), String.t()) :: Phoenix.LiveView.Socket.t()
  def close_modal(socket, id),
    do: exec_modal_js(socket, id, MishkaCmsCore.CoreComponents.hide_modal(id))

  @doc """
  Opens the modal for the record `record_id` and starts reading its first page of versions.
  """
  @spec show(Phoenix.LiveView.Socket.t(), keyword(), String.t()) :: Phoenix.LiveView.Socket.t()
  def show(socket, config, record_id) do
    socket
    |> assign(:versions_record_id, record_id)
    |> assign(:versions_record_name, nil)
    |> assign(:versions, [])
    |> assign(:versions_page, 1)
    |> assign(:versions_total, 0)
    |> assign(:preview_version_id, nil)
    |> open_modal(config[:modal])
    |> load(config)
  end

  @doc "Forgets the record and its versions, as when the modal is dismissed."
  @spec reset(Phoenix.LiveView.Socket.t()) :: Phoenix.LiveView.Socket.t()
  def reset(socket) do
    socket
    |> assign(:versions_record_id, nil)
    |> assign(:versions_record_name, nil)
    |> assign(:versions, [])
    |> assign(:versions_page, 1)
    |> assign(:versions_total, 0)
    |> assign(:preview_version_id, nil)
  end

  @doc "Reads the current page of the selected record's versions in the background."
  @spec load(Phoenix.LiveView.Socket.t(), keyword()) :: Phoenix.LiveView.Socket.t()
  def load(socket, config) do
    %{
      current_user: current_user,
      versions_record_id: record_id,
      versions_page: page,
      versions_per_page: per_page
    } = socket.assigns

    offset = (page - 1) * per_page

    socket
    |> assign(:versions_loading, true)
    |> MishkaGervaz.Messages.start_async(:load_versions, fn ->
      read_versions(config, current_user, record_id, per_page, offset)
    end)
  end

  @doc "Goes to the previous page of versions; on the first page the socket is left as it is."
  @spec previous_page(Phoenix.LiveView.Socket.t(), keyword()) :: Phoenix.LiveView.Socket.t()
  def previous_page(%{assigns: %{versions_page: page}} = socket, config) when page > 1 do
    socket
    |> assign(:versions_page, page - 1)
    |> assign(:preview_version_id, nil)
    |> load(config)
  end

  def previous_page(socket, _config), do: socket

  @doc "Goes to the next page of versions; on the last page the socket is left as it is."
  @spec next_page(Phoenix.LiveView.Socket.t(), keyword()) :: Phoenix.LiveView.Socket.t()
  def next_page(socket, config) do
    %{versions_page: page, versions_total: total, versions_per_page: per_page} = socket.assigns

    if page < ceil(total / per_page) do
      socket
      |> assign(:versions_page, page + 1)
      |> assign(:preview_version_id, nil)
      |> load(config)
    else
      socket
    end
  end

  @doc "Opens the preview of the version `version_id`, or closes it when it is already open."
  @spec toggle_preview(Phoenix.LiveView.Socket.t(), String.t()) :: Phoenix.LiveView.Socket.t()
  def toggle_preview(%{assigns: %{preview_version_id: version_id}} = socket, version_id),
    do: assign(socket, :preview_version_id, nil)

  def toggle_preview(socket, version_id), do: assign(socket, :preview_version_id, version_id)

  @doc """
  Restores the selected record to the version `version_id`. On success the modal closes and a flash
  says so; otherwise the modal stays and the flash is the refusal.
  """
  @spec restore(Phoenix.LiveView.Socket.t(), keyword(), String.t()) :: Phoenix.LiveView.Socket.t()
  def restore(socket, config, version_id) do
    %{current_user: current_user, versions_record_id: record_id} = socket.assigns

    case restore_as(config[:resource], current_user, record_id, version_id) do
      {:ok, _record} ->
        socket
        |> close_modal(config[:modal])
        |> reset()
        |> put_flash(:success, gettext("Version restored successfully"))

      {:error, error} ->
        put_flash(
          socket,
          :error,
          MishkaGervaz.Errors.extract_error_message(error, config[:resource])
        )
    end
  end

  @doc """
  Takes the result of the `:load_versions` async started by `load/2`: the versions on success, a
  flash on a failure, and the modal closed when the record cannot be read.
  """
  @spec loaded(Phoenix.LiveView.Socket.t(), keyword(), term()) :: Phoenix.LiveView.Socket.t()
  def loaded(socket, config, {:ok, {:ok, {record, versions, total, masters}}}) do
    socket
    |> assign(:versions_record_name, Map.get(record, config[:name]))
    |> assign(:versions, versions)
    |> assign(:version_masters, masters)
    |> assign(:versions_total, total)
    |> assign(:versions_loading, false)
    |> loaded_extra(config[:loaded], record)
  end

  def loaded(socket, config, {:ok, {:error, :not_found}}) do
    socket
    |> assign(:versions_loading, false)
    |> close_modal(config[:modal])
    |> reset()
    |> put_flash(:error, Gettext.gettext(MishkaCmsCore.Gettext, config[:not_found]))
  end

  def loaded(socket, _config, _failed) do
    socket
    |> assign(:versions_loading, false)
    |> put_flash(:error, gettext("Failed to load versions"))
  end

  defp loaded_extra(socket, nil, _record), do: socket
  defp loaded_extra(socket, assign_more, record), do: assign_more.(socket, record)

  defp exec_modal_js(socket, id, js) do
    push_event(socket, "gervaz:exec-js", %{target: id, js: Jason.encode!(js.ops)})
  end

  # Built and run with the signed-in user: an action checks the user it was built with.
  defp restore_as(resource, %User{site_id: nil} = current_user, record_id, version_id) do
    resource
    |> Ash.ActionInput.for_action(
      :master_restore_version_api,
      %{id: record_id, version_id: version_id},
      actor: current_user
    )
    |> Ash.run_action(actor: current_user)
  end

  defp restore_as(resource, %User{site_id: site_id} = current_user, record_id, version_id)
       when is_binary(site_id) do
    resource
    |> Ash.ActionInput.for_action(
      :restore_version_api,
      %{id: record_id, version_id: version_id},
      tenant: site_id
    )
    |> Ash.run_action(actor: current_user, tenant: site_id)
  end

  defp read_versions(config, current_user, record_id, per_page, offset) do
    resource = config[:resource]
    {action, opts, loads} = scope(config, current_user)

    resource
    |> Ash.Query.for_read(action, %{versions_limit: per_page, versions_offset: offset}, opts)
    |> Ash.Query.filter(id: record_id)
    |> Ash.Query.load(loads)
    |> Ash.read_one(opts)
    |> case do
      {:ok, nil} -> {:error, :not_found}
      {:ok, record} -> with_total(record, resource, record_id, current_user)
      {:error, _reason} = error -> error
    end
  end

  defp with_total(record, resource, record_id, current_user) do
    resource
    |> AshPaperTrail.Resource.Info.version_resource()
    |> Ash.Query.for_read(:read_any, %{}, actor: current_user)
    |> Ash.Query.filter(version_source_id: record_id)
    |> Ash.count(actor: current_user)
    |> case do
      {:ok, total} ->
        versions = record.sorted_versions || []
        {:ok, {record, versions, total, VersionHistory.master_ids(versions)}}

      {:error, _reason} = error ->
        error
    end
  end

  defp scope(config, %User{site_id: nil} = current_user),
    do: {:master_get_with_versions, [actor: current_user], loads(config, :master)}

  defp scope(config, %User{site_id: site_id} = current_user) when is_binary(site_id),
    do: {:get_with_versions, [actor: current_user, tenant: site_id], loads(config, :site)}

  defp loads(config, kind), do: config |> Keyword.get(:load, []) |> Keyword.get(kind, [])
end
