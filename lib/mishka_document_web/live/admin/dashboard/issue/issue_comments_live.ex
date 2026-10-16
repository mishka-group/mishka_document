# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_document/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaDocumentWeb.Live.Admin.Dashboard.Issue.IssueCommentsLive do
  @moduledoc """
  The comments thread of a single issue, rendered inside the expanded issue card.

  It is a `Phoenix.LiveComponent` mounted by `MishkaDocumentWeb.Templates.IssueCard`
  once an issue row is expanded, and it owns everything below the action bar: the
  comment list, the "Load more comments" pager and the "Add Comment" button, which is
  hidden for issues whose status is `:closed` or `:resolved`.

  Comments are read 20 at a time, newest first, through the `:read` action for tenant
  users and `:master_read` for master users, and are held in a LiveView stream so that
  paging only appends DOM nodes and keeps the scroll position intact. Sending the
  component a `:pubsub_event` assign of `{:created, comment}`, `{:updated, comment}` or
  `{:deleted, comment}` patches the stream in place without a refetch.

  ## Usage

      <.live_component
        module={MishkaDocumentWeb.Live.Admin.Dashboard.Issue.IssueCommentsLive}
        id={"issue-comments-" <> to_string(@record.id)}
        issue_id={@record.id}
        issue_status={@record.status}
        current_user={current_user}
        master_user?={master_user}
      />

  ## Attributes

    * `:issue_id` - the issue whose comments are listed; changing it reloads the stream.
    * `:issue_status` - the issue status, used to gate the "Add Comment" button.
    * `:current_user` - the actor the comments are read as; a `nil` `site_id` means master.
    * `:master_user?` - when `true`, the author shown is the master contributor and every
      comment offers Edit and Delete. Otherwise a comment a master wrote offers neither,
      because `MishkaDocument.IssueComment` refuses a tenant both.

  The `"edit_comment"`, `"delete_comment"` and `"add_comment"` events bubble up to the
  parent LiveView, while `"load_more_comments"` is handled here. A comment pushed in through
  `:pubsub_event` must carry the same loads the list reads it with, `:authored_by_master?`
  included for a tenant.

  See `MishkaDocumentWeb.Templates.IssueCard` for the card this component is embedded in.
  """

  use Phoenix.LiveComponent
  use Gettext, backend: MishkaCmsCore.Gettext

  import MishkaCmsCore.CoreComponents, only: [icon: 1]

  alias MishkaCmsCore.Accounts.Helper
  alias MishkaCmsCore.Accounts.User
  require Ash.Query

  @comments_per_page 20

  @impl true
  def mount(socket) do
    {:ok,
     socket
     |> assign(:comments_count, 0)
     |> assign(:has_more, false)
     |> assign(:loading, true)
     |> stream(:comments, [])}
  end

  @impl true
  def update(%{pubsub_event: {:created, comment}}, socket) do
    {:ok,
     socket
     |> stream_insert(:comments, comment, at: 0)
     |> assign(:comments_count, socket.assigns.comments_count + 1)}
  end

  def update(%{pubsub_event: {:updated, comment}}, socket) do
    {:ok, stream_insert(socket, :comments, comment)}
  end

  def update(%{pubsub_event: {:deleted, comment}}, socket) do
    {:ok,
     socket
     |> stream_delete(:comments, comment)
     |> assign(:comments_count, max(socket.assigns.comments_count - 1, 0))}
  end

  def update(assigns, socket) do
    old_issue_id = socket.assigns[:issue_id]
    socket = assign(socket, assigns)

    socket =
      if socket.assigns[:issue_id] && socket.assigns[:issue_id] != old_issue_id do
        load_initial_comments(socket)
      else
        socket
      end

    {:ok, socket}
  end

  @impl true
  def handle_event("load_more_comments", _params, socket) do
    offset = socket.assigns.comments_count

    {new_comments, has_more} =
      load_comments_query(socket.assigns.current_user, socket.assigns.issue_id, offset)

    {:noreply,
     socket
     |> stream(:comments, new_comments)
     |> assign(:has_more, has_more)
     |> assign(:comments_count, socket.assigns.comments_count + length(new_comments))}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div>
      <div class="mb-2.5 text-[11px] font-bold text-[#8a877f]">{gettext("Comments")}</div>

      <div :if={@loading} class="flex items-center justify-center gap-2.5 py-6">
        <div class="size-4 animate-spin rounded-full border-2 border-[#e0ddd6] border-t-[#5b57d6]">
        </div>
        <span class="text-[12px] font-medium text-[#8a877f]">{gettext("Loading comments…")}</span>
      </div>

      <div
        :if={!@loading}
        id={"comments-stream-" <> to_string(@issue_id)}
        phx-update="stream"
        class="flex max-h-[280px] flex-col overflow-y-auto rounded-[12px] border border-[#f0efea] bg-white"
      >
        <div id={"comments-empty-" <> to_string(@issue_id)} class="hidden only:block">
          <div class="flex flex-col items-center py-7 text-center">
            <span class="mb-[9px] grid size-[38px] place-items-center rounded-[10px] bg-[#f4f3ee] text-[#c3c0b8]">
              <.icon name="hero-chat-bubble-left-right" class="size-[18px]" />
            </span>
            <span class="text-[12px] font-semibold text-[#a8a5a0]">{gettext("No comments yet")}</span>
            <span class="mt-[3px] text-[10.5px] font-medium text-[#c3c0b8]">
              {gettext("Be the first to comment on this issue.")}
            </span>
          </div>
        </div>
        <div
          :for={{dom_id, comment} <- @streams.comments}
          id={dom_id}
          class="group flex gap-[11px] border-b border-[#f4f3ee] px-[15px] py-[13px] last:border-b-0"
        >
          <span class="grid size-[30px] flex-none place-items-center rounded-[9px] bg-[#f2f1fc] text-[#8985d8]">
            <.icon name="hero-user" class="size-[15px]" />
          </span>
          <div class="min-w-0 flex-1">
            <div class="flex flex-wrap items-center gap-2">
              <span dir="auto" class="text-[12px] font-bold text-[#1b1a18]">
                {contributor_email(comment, @master_user?)}
              </span>
              <span class="size-[3px] flex-none rounded-full bg-[#c3c0b8]"></span>
              <span class="text-[10.5px] font-medium text-[#a8a5a0]">
                {Calendar.strftime(comment.inserted_at, "%Y-%m-%d %H:%M")}
              </span>
              <div
                :if={changeable?(comment, @master_user?)}
                class="-my-1 ms-auto flex flex-none items-center gap-1 opacity-0 transition-opacity focus-within:opacity-100 group-hover:opacity-100"
              >
                <button
                  id={"edit-comment-" <> to_string(comment.id)}
                  phx-click="edit_comment"
                  phx-value-comment-id={comment.id}
                  phx-value-issue-id={@issue_id}
                  class="rounded-md p-1 text-[#a8a5a0] transition-colors hover:bg-[#f2f1fc] hover:text-[#5b57d6]"
                  title={gettext("Edit comment")}
                >
                  <.icon name="hero-pencil-square" class="size-3.5" />
                </button>
                <button
                  id={"delete-comment-" <> to_string(comment.id)}
                  phx-click="delete_comment"
                  phx-value-comment-id={comment.id}
                  data-confirm={gettext("Permanently delete this comment?")}
                  class="rounded-md p-1 text-[#a8a5a0] transition-colors hover:bg-[#fbeceb] hover:text-[#d5544b]"
                  title={gettext("Delete comment")}
                >
                  <.icon name="hero-trash" class="size-3.5" />
                </button>
              </div>
            </div>
            <p class={[
              "mt-1 whitespace-pre-wrap text-[12.5px] font-medium leading-[1.5] text-[#5c5a54]"
            ]}>
              {comment.content}
            </p>
          </div>
        </div>
      </div>

      <div class="flex flex-col items-start">
        <button
          :if={@has_more}
          phx-click="load_more_comments"
          phx-target={@myself}
          class="mt-2.5 inline-flex items-center gap-1.5 text-[12px] font-semibold text-[#4f4bcc] transition-opacity hover:opacity-70"
        >
          <.icon name="hero-chevron-down" class="size-3" />
          <span>{gettext("Load more comments")}</span>
        </button>

        <button
          :if={@issue_status not in [:closed, :resolved]}
          phx-click="add_comment"
          phx-value-issue-id={@issue_id}
          class="mt-3.5 inline-flex h-[38px] items-center gap-[7px] rounded-[10px] border border-dashed border-[#d9d7d0] bg-white px-[15px] text-[12px] font-semibold text-[#4f4bcc] transition-colors hover:border-[#5b57d6] hover:bg-[#faf9ff]"
        >
          <.icon name="hero-plus" class="size-[15px]" />
          <span>{gettext("Add Comment")}</span>
        </button>
      </div>
    </div>
    """
  end

  defp contributor_email(comment, true = _master_user?) do
    case comment.master_contributor do
      %Ash.NotLoaded{} -> Helper.label(:unknown)
      nil -> Helper.label(:unknown)
      c -> c.email
    end
  end

  # A tenant cannot load a master's user record, so a master's comment arrives with no contributor —
  # and so does one whose author was deleted. `authored_by_master?` tells the two apart.
  defp contributor_email(comment, _master_user?) do
    case {comment.contributor, comment.authored_by_master?} do
      {%{email: email}, _authored_by_master?} -> email
      {_no_contributor, true} -> Helper.label(:master)
      _unknown -> Helper.label(:unknown)
    end
  end

  # The resource refuses a tenant's edit or delete of a master's comment, so the buttons are not
  # offered for one. A comment whose authorship was not loaded offers nothing rather than a button
  # that may only fail.
  defp changeable?(_comment, true = _master_user?), do: true
  defp changeable?(%{authored_by_master?: false}, _master_user?), do: true
  defp changeable?(_comment, _master_user?), do: false

  defp load_initial_comments(socket) do
    {comments, has_more} =
      load_comments_query(socket.assigns.current_user, socket.assigns.issue_id, 0)

    socket
    |> stream(:comments, comments, reset: true)
    |> assign(:has_more, has_more)
    |> assign(:loading, false)
    |> assign(:comments_count, length(comments))
  end

  defp load_comments_query(current_user, issue_id, offset) do
    {action, query_opts, loads} =
      case current_user do
        %User{site_id: nil} ->
          {:master_read, [actor: current_user], [:master_contributor]}

        %User{site_id: site_id} when is_binary(site_id) ->
          {:read, [actor: current_user, tenant: site_id], [:contributor, :authored_by_master?]}
      end

    page_result =
      MishkaDocument.IssueComment
      |> Ash.Query.for_read(action, %{}, query_opts)
      |> Ash.Query.filter(issue_id == ^issue_id)
      |> Ash.Query.load(loads)
      |> Ash.Query.sort(inserted_at: :desc)
      |> Ash.read!(page: [offset: offset, limit: @comments_per_page])

    {page_result.results, page_result.more?}
  end
end
