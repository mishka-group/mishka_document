# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_document/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaDocumentWeb.Live.Admin.Dashboard.WorkspaceVersion.Index do
  use MishkaCmsCore.ExtensionLiveView

  alias MishkaCmsCore.Accounts.User
  alias MishkaCmsCore.CoreComponents
  alias MishkaDocument.WorkspaceVersion
  alias MishkaGervaz.Table.Web.UrlSync

  # The fields the clone form draws, each showing its own errors; any other is shown above them.
  @clone_fields [:version_number, :version_name, :description]

  # A delete takes the versions cloned from the deleted one with it, and a clone made or made
  # independent changes what deleting its source would take: the table reads every row again after
  # each, so each row's delete confirmation names what it would take.
  @rereads [:destroy, :master_destroy, :detach, :master_detach]

  @impl true
  def mount(%{"id" => workspace_id}, _session, socket) do
    current_user = socket.assigns.current_user
    workspace = load_workspace(current_user, workspace_id)

    socket =
      socket
      |> assign(:page_title, gettext("Workspace Versions"))
      |> assign(:workspace_id, workspace_id)
      |> assign(:workspace, workspace)
      |> assign(:url_state, nil)
      |> assign_clone(nil, nil)
      |> subscribe_when_connected(current_user)

    {:ok, socket}
  end

  @impl true
  def handle_params(params, uri, socket) do
    url_state = UrlSync.decode(params, uri, MishkaDocument.WorkspaceVersion)
    {:noreply, assign(socket, :url_state, url_state)}
  end

  defp subscribe_when_connected(socket, user) do
    if connected?(socket), do: subscribe_to_pubsub(socket, user), else: socket
  end

  defp subscribe_to_pubsub(socket, %User{site_id: nil}) do
    Phoenix.PubSub.subscribe(MishkaCmsCore.PubSub, "workspace_version:created")
    Phoenix.PubSub.subscribe(MishkaCmsCore.PubSub, "workspace_version:updated")
    Phoenix.PubSub.subscribe(MishkaCmsCore.PubSub, "workspace_version:destroyed")
    socket
  end

  defp subscribe_to_pubsub(socket, %User{site_id: site_id}) when is_binary(site_id) do
    Phoenix.PubSub.subscribe(
      MishkaCmsCore.PubSub,
      "workspace_version:#{site_id}:created"
    )

    Phoenix.PubSub.subscribe(
      MishkaCmsCore.PubSub,
      "workspace_version:#{site_id}:updated"
    )

    Phoenix.PubSub.subscribe(
      MishkaCmsCore.PubSub,
      "workspace_version:#{site_id}:destroyed"
    )

    socket
  end

  defp subscribe_to_pubsub(socket, _), do: socket

  defp close_form_modal(socket) do
    js = MishkaCmsCore.CoreComponents.hide_modal("workspace-version-form-modal")

    push_event(socket, "gervaz:exec-js", %{
      target: "workspace-version-form-modal",
      js: Jason.encode!(js.ops)
    })
  end

  @impl true
  def handle_info({:form_saved, :create, result}, socket) do
    {:noreply,
     socket
     |> close_form_modal()
     |> put_flash(:info, created_message(result))}
  end

  @impl true
  def handle_info({:form_saved, :update, _result}, socket) do
    {:noreply,
     socket
     |> close_form_modal()
     |> put_flash(:info, gettext("Workspace version updated successfully"))}
  end

  @impl true
  def handle_info({:form_cancelled, _resource}, socket) do
    {:noreply, close_form_modal(socket)}
  end

  @impl true
  def handle_info({:row_action, "clone", %{"id" => id}}, socket) do
    user = socket.assigns.current_user

    with true <- WorkspaceVersion.clone_allowed?(user),
         {:ok, %WorkspaceVersion{workspace_id: workspace_id} = source}
         when workspace_id == socket.assigns.workspace_id <- load_version(user, id) do
      {:noreply, assign_clone(socket, source, clone_form(user, source))}
    else
      _refused_or_missing ->
        {:noreply, put_flash(socket, :error, gettext("This version cannot be copied."))}
    end
  end

  @impl true
  def handle_info({:row_action, _event, _payload}, socket), do: {:noreply, socket}

  @impl true
  def handle_info({:show_modal, _id}, socket), do: {:noreply, socket}

  @impl true
  def handle_info(
        %Phoenix.Socket.Broadcast{
          topic: "workspace_version" <> _,
          payload: %Ash.Notifier.Notification{data: data} = notification
        },
        socket
      ) do
    if Map.get(data, :workspace_id) == socket.assigns.workspace_id do
      send_update(
        MishkaGervaz.Table.Web.Live,
        [id: "workspace-versions-table"] ++ refresh(notification)
      )
    end

    {:noreply, socket}
  end

  @impl true
  def handle_info({:put_flash, kind, message}, socket) do
    {:noreply, put_flash(socket, kind, message)}
  end

  @impl true
  def handle_info(_msg, socket), do: {:noreply, socket}

  @impl true
  def handle_event(
        "validate_clone",
        %{"clone" => params},
        %{assigns: %{clone_form: %{}}} = socket
      ),
      do:
        {:noreply,
         assign(socket, :clone_form, AshPhoenix.Form.validate(socket.assigns.clone_form, params))}

  def handle_event(
        "clone_version",
        %{"clone" => params},
        %{assigns: %{cloning?: false, clone_form: %{} = form}} = socket
      ) do
    {:noreply,
     socket
     |> assign(cloning?: true, clone_notice: [])
     |> MishkaGervaz.Messages.start_async(:clone_version, fn ->
       AshPhoenix.Form.submit(form.source, params: params)
     end)}
  end

  def handle_event("close_clone", _params, socket),
    do: {:noreply, assign(socket, clone_source: nil, clone_form: nil, clone_notice: [])}

  def handle_event(_event, _params, socket), do: {:noreply, socket}

  @impl true
  def handle_async(:clone_version, {:ok, {:ok, version}}, socket),
    do: {:noreply, socket |> assign_clone(nil, nil) |> put_flash(:info, created_message(version))}

  def handle_async(:clone_version, {:ok, {:error, form}}, socket),
    do: {:noreply, refuse_clone(socket, form)}

  def handle_async(:clone_version, {:exit, _reason}, socket),
    do: {:noreply, refuse_clone(socket, nil)}

  # The form shows what refused the copy; a form closed while it ran tells it in a flash.
  defp refuse_clone(%{assigns: %{clone_source: nil}} = socket, form) do
    [message | _more] = clone_errors(form)

    socket
    |> assign(:cloning?, false)
    |> put_flash(:error, message)
  end

  defp refuse_clone(socket, nil),
    do: assign(socket, cloning?: false, clone_notice: clone_errors(nil))

  defp refuse_clone(socket, form),
    do:
      assign(socket,
        cloning?: false,
        clone_form: to_form(form),
        clone_notice: form |> clone_errors() |> Enum.drop(field_errors(form))
      )

  # What a created version says: what it copied, when it was copied from another.
  defp created_message(%WorkspaceVersion{__metadata__: %{cloned: cloned}} = version) do
    gettext("Version %{version} created from %{source} — %{pages}, %{notes} copied",
      version: version.version_number,
      source: cloned.from,
      pages: ngettext("1 page", "%{count} pages", cloned.pages),
      notes: ngettext("1 note", "%{count} notes", cloned.notes)
    )
  end

  defp created_message(_version), do: gettext("Workspace version created successfully")

  defp refresh(%Ash.Notifier.Notification{action: %{name: name}}) when name in @rereads,
    do: [gervaz_refresh: true]

  defp refresh(%Ash.Notifier.Notification{
         action: %{type: :create},
         data: %{source_version_id: id}
       })
       when is_binary(id),
       do: [gervaz_refresh: true]

  defp refresh(notification), do: [pubsub_notification: notification]

  defp assign_clone(socket, source, form),
    do: assign(socket, clone_source: source, clone_form: form, clone_notice: [], cloning?: false)

  defp clone_form(%User{site_id: nil} = user, source),
    do: source |> clone_form_for(:master_clone, actor: user) |> to_form()

  defp clone_form(%User{site_id: site_id} = user, source),
    do: source |> clone_form_for(:clone, actor: user, tenant: site_id) |> to_form()

  defp clone_form_for(source, action, opts) do
    AshPhoenix.Form.for_create(
      WorkspaceVersion,
      action,
      [
        as: "clone",
        transform_params: fn params, _type ->
          Map.put(params, "source_version_id", source.id)
        end
      ] ++ opts
    )
  end

  # Every reason the copy was refused, those of the form's own fields first; one that names no
  # reason when nothing does.
  defp clone_errors(nil), do: [gettext("The version could not be copied. Nothing was written.")]

  defp clone_errors(form) do
    {fields, others} =
      form
      |> AshPhoenix.Form.errors(format: :raw)
      |> Enum.split_with(fn {field, _error} -> field in @clone_fields end)

    case Enum.map(fields ++ others, fn {_field, error} ->
           CoreComponents.translate_error(error)
         end) do
      [] -> clone_errors(nil)
      messages -> messages
    end
  end

  defp field_errors(form),
    do:
      form
      |> AshPhoenix.Form.errors(format: :raw)
      |> Enum.count(fn {field, _error} -> field in @clone_fields end)

  defp load_version(%User{site_id: nil} = user, id),
    do: Ash.get(WorkspaceVersion, id, action: :master_get, actor: user)

  defp load_version(%User{site_id: site_id} = user, id) when is_binary(site_id),
    do: Ash.get(WorkspaceVersion, id, action: :read, actor: user, tenant: site_id)

  defp load_version(_user, _id), do: :error

  defp load_workspace(%User{site_id: nil} = user, workspace_id) do
    case Ash.get(MishkaDocument.Workspace, workspace_id, action: :master_get, actor: user) do
      {:ok, workspace} -> workspace
      _ -> nil
    end
  end

  defp load_workspace(%User{site_id: site_id} = user, workspace_id) when is_binary(site_id) do
    case Ash.get(MishkaDocument.Workspace, workspace_id,
           action: :read,
           actor: user,
           tenant: site_id
         ) do
      {:ok, workspace} -> workspace
      _ -> nil
    end
  end

  defp load_workspace(_, _), do: nil
end
