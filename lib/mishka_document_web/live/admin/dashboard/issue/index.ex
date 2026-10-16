# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_document/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaDocumentWeb.Live.Admin.Dashboard.Issue.Index do
  use MishkaCmsCore.ExtensionLiveView

  alias MishkaCmsCore.Accounts.User
  alias MishkaGervaz.Table.Web.UrlSync
  require Ash.Query

  @impl true
  def mount(_params, _session, socket) do
    current_user = socket.assigns.current_user
    master_user? = match?(%User{site_id: nil}, current_user)

    socket =
      socket
      |> assign(:page_title, gettext("Issues Management"))
      |> assign(:master_user?, master_user?)
      |> assign(:url_state, nil)
      |> assign(:show_comment_form, false)
      |> assign(:editing_comment_id, nil)
      |> assign(:comment_form_issue, nil)
      |> subscribe_to_pubsub(current_user)

    {:ok, socket}
  end

  @impl true
  def handle_params(params, uri, socket) do
    url_state = UrlSync.decode(params, uri, MishkaDocument.Issue)
    {:noreply, assign(socket, :url_state, url_state)}
  end

  defp subscribe_to_pubsub(socket, %User{site_id: nil}) do
    Phoenix.PubSub.subscribe(MishkaCmsCore.PubSub, "issue:created")
    Phoenix.PubSub.subscribe(MishkaCmsCore.PubSub, "issue:updated")
    Phoenix.PubSub.subscribe(MishkaCmsCore.PubSub, "issue:destroyed")
    Phoenix.PubSub.subscribe(MishkaCmsCore.PubSub, "issue_comment:created")
    Phoenix.PubSub.subscribe(MishkaCmsCore.PubSub, "issue_comment:updated")
    Phoenix.PubSub.subscribe(MishkaCmsCore.PubSub, "issue_comment:destroyed")
    socket
  end

  defp subscribe_to_pubsub(socket, %User{site_id: site_id}) when is_binary(site_id) do
    Phoenix.PubSub.subscribe(MishkaCmsCore.PubSub, "issue:#{site_id}:created")
    Phoenix.PubSub.subscribe(MishkaCmsCore.PubSub, "issue:#{site_id}:updated")
    Phoenix.PubSub.subscribe(MishkaCmsCore.PubSub, "issue:#{site_id}:destroyed")
    Phoenix.PubSub.subscribe(MishkaCmsCore.PubSub, "issue_comment:#{site_id}:created")
    Phoenix.PubSub.subscribe(MishkaCmsCore.PubSub, "issue_comment:#{site_id}:updated")
    Phoenix.PubSub.subscribe(MishkaCmsCore.PubSub, "issue_comment:#{site_id}:destroyed")
    socket
  end

  defp subscribe_to_pubsub(socket, _), do: socket

  @impl true
  def handle_event("cancel_comment_form", _params, socket) do
    {:noreply,
     socket
     |> assign(:show_comment_form, false)
     |> assign(:editing_comment_id, nil)
     |> assign(:comment_form_issue, nil)}
  end

  @impl true
  def handle_event("add_comment", %{"issue-id" => issue_id}, socket) do
    case get_issue(socket.assigns.current_user, issue_id) do
      {:ok, issue} when not is_nil(issue) ->
        {:noreply,
         socket
         |> assign(:show_comment_form, true)
         |> assign(:editing_comment_id, nil)
         |> assign(:comment_form_issue, issue)}

      _ ->
        {:noreply, put_flash(socket, :error, gettext("Issue not found"))}
    end
  end

  @impl true
  def handle_event("edit_comment", %{"comment-id" => comment_id, "issue-id" => issue_id}, socket) do
    current_user = socket.assigns.current_user

    with {:ok, issue} when not is_nil(issue) <- get_issue(current_user, issue_id),
         :ok <- editable_comment(current_user, comment_id) do
      {:noreply,
       socket
       |> assign(:show_comment_form, true)
       |> assign(:editing_comment_id, comment_id)
       |> assign(:comment_form_issue, issue)}
    else
      {:refused, message} ->
        {:noreply, put_flash(socket, :error, message)}

      _ ->
        {:noreply, put_flash(socket, :error, gettext("Issue not found"))}
    end
  end

  @impl true
  def handle_event("delete_comment", %{"comment-id" => comment_id}, socket) do
    case delete_comment(socket.assigns.current_user, comment_id) do
      {:ok, _} ->
        {:noreply, put_flash(socket, :info, gettext("Comment deleted"))}

      {:error, error} ->
        {:noreply,
         put_flash(socket, :error, error_message(error, gettext("Failed to delete comment")))}
    end
  end

  @impl true
  def handle_event("mark_in_progress", %{"issue-id" => id}, socket) do
    {:noreply, transition_status(socket, id, :mark_in_progress)}
  end

  @impl true
  def handle_event("mark_resolved", %{"issue-id" => id}, socket) do
    {:noreply, transition_status(socket, id, :mark_resolved)}
  end

  @impl true
  def handle_event("mark_closed", %{"issue-id" => id}, socket) do
    {:noreply, transition_status(socket, id, :mark_closed)}
  end

  @impl true
  def handle_event("reopen", %{"issue-id" => id}, socket) do
    {:noreply, transition_status(socket, id, :reopen)}
  end

  @impl true
  def handle_info({:expand_row, _id}, socket) do
    send_update(MishkaGervaz.Table.Web.Live,
      id: "issues-table",
      expanded_html: %{
        current_user: socket.assigns.current_user,
        master_user?: socket.assigns.master_user?
      }
    )

    {:noreply, socket}
  end

  @impl true
  def handle_info({:row_action, _event, _payload}, socket), do: {:noreply, socket}

  @impl true
  def handle_info({:form_saved, action, %MishkaDocument.IssueComment{}}, socket)
      when action in [:create, :update] do
    {:noreply,
     socket
     |> put_flash(:info, comment_saved_message(action))
     |> assign(:show_comment_form, false)
     |> assign(:editing_comment_id, nil)
     |> assign(:comment_form_issue, nil)
     |> close_form_modal("issue-comment-form-modal")}
  end

  @impl true
  def handle_info({:form_saved, :create, _result}, socket) do
    {:noreply,
     socket
     |> close_form_modal("issue-form-modal")
     |> put_flash(:info, gettext("Issue created successfully"))}
  end

  @impl true
  def handle_info({:form_saved, :update, _result}, socket) do
    {:noreply,
     socket
     |> close_form_modal("issue-form-modal")
     |> put_flash(:info, gettext("Issue updated successfully"))}
  end

  @impl true
  def handle_info({:form_cancelled, MishkaDocument.IssueComment}, socket) do
    {:noreply,
     socket
     |> assign(:show_comment_form, false)
     |> assign(:editing_comment_id, nil)
     |> assign(:comment_form_issue, nil)
     |> close_form_modal("issue-comment-form-modal")}
  end

  @impl true
  def handle_info({:form_cancelled, MishkaDocument.Issue}, socket) do
    {:noreply, close_form_modal(socket, "issue-form-modal")}
  end

  @impl true
  def handle_info(
        %Phoenix.Socket.Broadcast{
          topic: "issue:" <> _,
          payload: %Ash.Notifier.Notification{} = notification
        },
        socket
      ) do
    send_update(MishkaGervaz.Table.Web.Live,
      id: "issues-table",
      pubsub_notification: notification
    )

    {:noreply, socket}
  end

  @impl true
  def handle_info(
        %Phoenix.Socket.Broadcast{
          topic: "issue_comment" <> _,
          payload: %Ash.Notifier.Notification{data: comment, action: %{type: :create}}
        },
        socket
      ) do
    loaded_comment = load_comment_relationships(comment, socket.assigns.current_user)

    send_update(
      MishkaDocumentWeb.Live.Admin.Dashboard.Issue.IssueCommentsLive,
      id: "issue-comments-" <> to_string(comment.issue_id),
      pubsub_event: {:created, loaded_comment}
    )

    {:noreply, socket}
  end

  @impl true
  def handle_info(
        %Phoenix.Socket.Broadcast{
          topic: "issue_comment" <> _,
          payload: %Ash.Notifier.Notification{data: comment, action: %{type: :update}}
        },
        socket
      ) do
    loaded_comment = load_comment_relationships(comment, socket.assigns.current_user)

    send_update(
      MishkaDocumentWeb.Live.Admin.Dashboard.Issue.IssueCommentsLive,
      id: "issue-comments-" <> to_string(comment.issue_id),
      pubsub_event: {:updated, loaded_comment}
    )

    {:noreply, socket}
  end

  @impl true
  def handle_info(
        %Phoenix.Socket.Broadcast{
          topic: "issue_comment" <> _,
          payload: %Ash.Notifier.Notification{data: comment, action: %{type: :destroy}}
        },
        socket
      ) do
    send_update(
      MishkaDocumentWeb.Live.Admin.Dashboard.Issue.IssueCommentsLive,
      id: "issue-comments-" <> to_string(comment.issue_id),
      pubsub_event: {:deleted, comment}
    )

    {:noreply, socket}
  end

  @impl true
  def handle_info({:put_flash, kind, message}, socket) do
    {:noreply, put_flash(socket, kind, message)}
  end

  @impl true
  def handle_info(_msg, socket), do: {:noreply, socket}

  defp comment_saved_message(:create), do: gettext("Comment created successfully")
  defp comment_saved_message(:update), do: gettext("Comment updated successfully")

  defp close_form_modal(socket, modal_id) do
    js = MishkaCmsCore.CoreComponents.hide_modal(modal_id)

    Phoenix.LiveView.push_event(socket, "gervaz:exec-js", %{
      target: modal_id,
      js: Jason.encode!(js.ops)
    })
  end

  defp get_issue(%User{site_id: nil} = user, id) do
    Ash.get(MishkaDocument.Issue, id, action: :master_get, actor: user)
  end

  defp get_issue(%User{site_id: site_id} = user, id) when is_binary(site_id) do
    MishkaDocument.Issue
    |> Ash.Query.for_read(:read, %{}, tenant: site_id, actor: user)
    |> Ash.Query.filter(id: id)
    |> Ash.read_one(tenant: site_id, actor: user)
  end

  defp load_comment_relationships(comment, %User{site_id: nil} = user) do
    Ash.load!(comment, [:master_contributor], tenant: comment.site_id, actor: user)
  end

  defp load_comment_relationships(comment, %User{site_id: site_id} = user)
       when is_binary(site_id) do
    Ash.load!(comment, [:contributor, :authored_by_master?], tenant: site_id, actor: user)
  end

  # The edit form opens only on a comment the actor's update accepts. A tenant's is refused on a
  # comment a master wrote, and the form would otherwise open, save nothing and say nothing: the
  # refusal lands on `:contributor_id`, which the edit form does not draw.
  defp editable_comment(%User{site_id: nil} = user, id) do
    case Ash.get(MishkaDocument.IssueComment, id, action: :master_get, actor: user) do
      {:ok, comment} when not is_nil(comment) ->
        comment
        |> Ash.Changeset.for_update(:master_update, %{}, actor: user)
        |> changeable()

      _ ->
        {:refused, gettext("Comment not found")}
    end
  end

  defp editable_comment(%User{site_id: site_id} = user, id) when is_binary(site_id) do
    case Ash.get(MishkaDocument.IssueComment, id, tenant: site_id, actor: user) do
      {:ok, comment} when not is_nil(comment) ->
        comment
        |> Ash.Changeset.for_update(:update, %{}, tenant: site_id, actor: user)
        |> changeable()

      _ ->
        {:refused, gettext("Comment not found")}
    end
  end

  defp changeable(%Ash.Changeset{valid?: true}), do: :ok

  defp changeable(%Ash.Changeset{errors: errors}),
    do: {:refused, error_message(errors, gettext("This comment cannot be edited"))}

  # The resource's own reason when it gave one — a tenant is told a master's comment is a master's —
  # and `fallback` when it gave none a reader could use.
  defp error_message(%Ash.Error.Invalid{errors: errors}, fallback),
    do: error_message(errors, fallback)

  defp error_message(errors, fallback) when is_list(errors) do
    case for(
           %{message: message} = error when is_binary(message) <- errors,
           do: MishkaGervaz.Errors.translate_error(message, Map.get(error, :vars))
         ) do
      [] -> fallback
      messages -> Enum.join(messages, " ")
    end
  end

  defp error_message(_error, fallback), do: fallback

  defp delete_comment(%User{site_id: nil} = user, id) do
    case Ash.get(MishkaDocument.IssueComment, id, action: :master_get, actor: user) do
      {:ok, comment} when not is_nil(comment) ->
        Ash.destroy(comment,
          action: :master_permanent_destroy,
          actor: user,
          return_destroyed?: true
        )

      _ ->
        {:error, :not_found}
    end
  end

  defp delete_comment(%User{site_id: site_id} = user, id) when is_binary(site_id) do
    case Ash.get(MishkaDocument.IssueComment, id, tenant: site_id, actor: user) do
      {:ok, comment} when not is_nil(comment) ->
        Ash.destroy(comment,
          action: :permanent_destroy,
          tenant: site_id,
          actor: user,
          return_destroyed?: true
        )

      _ ->
        {:error, :not_found}
    end
  end

  defp transition_status(socket, issue_id, action_name) do
    current_user = socket.assigns.current_user

    case get_issue(current_user, issue_id) do
      {:ok, issue} when not is_nil(issue) ->
        opts =
          case current_user do
            %User{site_id: nil} -> [actor: current_user]
            %User{site_id: site_id} -> [actor: current_user, tenant: site_id]
          end

        case issue
             |> Ash.Changeset.for_update(action_name, %{}, opts)
             |> Ash.update() do
          {:ok, _updated} ->
            put_flash(socket, :info, gettext("Issue status updated"))

          {:error, _} ->
            put_flash(socket, :error, gettext("Failed to update issue status"))
        end

      _ ->
        put_flash(socket, :error, gettext("Issue not found"))
    end
  end
end
