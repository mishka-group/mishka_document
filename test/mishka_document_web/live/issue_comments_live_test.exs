defmodule MishkaDocumentWeb.Test.IssueCommentsLiveTest do
  @moduledoc """
  The comments under an expanded issue on the Issues page, seen by a master and by a tenant admin of
  the issue's own site — both holding every permission, so what differs is who they are.

  `MishkaDocument.IssueComment` refuses a tenant the edit and delete of a comment a master wrote,
  so the tenant is not offered either: the master's comment is labelled "Master" and carries no
  buttons, while a comment by one of the site's own users still carries both — and so does one
  whose author was deleted, which is nobody's now and reads "Unknown" rather than "Master". A
  comment posted while the thread is open arrives by PubSub and is drawn by the same rule.

  Hiding the buttons is not the rule, only its reflection: an edit or a delete of the master's
  comment pushed without one is still refused, and the tenant is told why. The edit form does not
  open at all, because the refusal lands on a field that form never draws. A master is offered both
  on every comment, the edit form opens for them, and Delete really deletes — it runs
  `:master_permanent_destroy` as the destroy action it is.
  """
  use MishkaDocument.ConnCase

  import Phoenix.LiveViewTest
  import MishkaDocument.Test.Factory

  alias MishkaCmsCore.Accounts.{Permission, User, UserPermission}
  alias MishkaCmsCore.Runtime.States.SiteState

  require Ash.Query

  @password "Password123!"

  setup %{conn: conn} do
    SiteState.clear()
    :ok = Swoosh.TestAssertions.set_swoosh_global()

    site = create_site!(name: "localhost", host: "localhost", active: true, master: true)

    SiteState.save(%{
      id: site.id,
      name: site.name,
      host: site.host,
      priority: site.priority,
      active: site.active,
      master: site.master
    })

    :persistent_term.put(:mishka_installed, true)

    on_exit(fn ->
      :persistent_term.erase(:mishka_installed)
      SiteState.clear()
    end)

    master = admin!("master@example.com")
    tenant = admin!("tenant@example.com", site.id)
    issue = create_issue!(site_id: site.id)

    {:ok,
     master_conn: log_in(on_host(conn), master),
     tenant_conn: log_in(on_host(Phoenix.ConnTest.build_conn()), tenant),
     master: master,
     tenant: tenant,
     site: site,
     issue: issue,
     master_comment:
       create_issue_comment!(site_id: site.id, issue_id: issue.id, contributor_id: master.id),
     tenant_comment:
       create_issue_comment!(site_id: site.id, issue_id: issue.id, contributor_id: tenant.id)}
  end

  test "a tenant admin gets no edit or delete on a master's comment but both on its site's", %{
    tenant_conn: conn,
    site: site,
    issue: issue,
    master_comment: master_comment,
    tenant_comment: tenant_comment
  } do
    departed = create_user!(site_id: site.id)

    orphan =
      create_issue_comment!(site_id: site.id, issue_id: issue.id, contributor_id: departed.id)

    Ash.destroy!(departed, authorize?: false)

    view = open_comments(conn, issue)

    assert has_element?(view, "#comments-#{master_comment.id}", "Master")
    refute has_element?(view, "#edit-comment-#{master_comment.id}")
    refute has_element?(view, "#delete-comment-#{master_comment.id}")

    assert has_element?(view, "#edit-comment-#{tenant_comment.id}")
    assert has_element?(view, "#delete-comment-#{tenant_comment.id}")

    assert has_element?(view, "#comments-#{orphan.id}", "Unknown")
    assert has_element?(view, "#edit-comment-#{orphan.id}")
    assert has_element?(view, "#delete-comment-#{orphan.id}")
  end

  test "a comment posted while a tenant admin has the thread open follows the same rule", %{
    tenant_conn: conn,
    master: master,
    tenant: tenant,
    site: site,
    issue: issue
  } do
    view = open_comments(conn, issue)

    by_master =
      create_issue_comment!(site_id: site.id, issue_id: issue.id, contributor_id: master.id)

    by_tenant =
      create_issue_comment!(site_id: site.id, issue_id: issue.id, contributor_id: tenant.id)

    render(view)

    assert has_element?(view, "#comments-#{by_master.id}", "Master")
    refute has_element?(view, "#delete-comment-#{by_master.id}")
    assert has_element?(view, "#delete-comment-#{by_tenant.id}")
  end

  test "a tenant admin deletes its site's comment; a master's, pushed anyway, is refused", %{
    tenant_conn: conn,
    issue: issue,
    master_comment: master_comment,
    tenant_comment: tenant_comment
  } do
    view = open_comments(conn, issue)

    view |> element("#delete-comment-#{tenant_comment.id}") |> render_click()

    refute has_element?(view, "#comments-#{tenant_comment.id}")

    render_hook(view, "delete_comment", %{"comment-id" => master_comment.id})

    assert has_element?(view, "#comments-#{master_comment.id}")
    assert has_element?(view, "#flash-error", "written by a master admin")

    assert {:ok, _still_there} =
             Ash.get(MishkaDocument.IssueComment, master_comment.id,
               action: :master_get,
               authorize?: false
             )
  end

  test "a tenant admin edits its site's comment; a master's, pushed anyway, opens no form", %{
    tenant_conn: conn,
    issue: issue,
    master_comment: master_comment,
    tenant_comment: tenant_comment
  } do
    view = open_comments(conn, issue)

    render_hook(view, "edit_comment", %{"comment-id" => master_comment.id, "issue-id" => issue.id})

    refute has_element?(view, "#issue-comment-form-modal")
    assert has_element?(view, "#flash-error", "written by a master admin")

    view |> element("#edit-comment-#{tenant_comment.id}") |> render_click()

    assert has_element?(view, "#issue-comment-form-modal")
  end

  test "a master opens the edit form on a comment a tenant admin wrote", %{
    master_conn: conn,
    issue: issue,
    tenant_comment: tenant_comment
  } do
    view = open_comments(conn, issue)

    view |> element("#edit-comment-#{tenant_comment.id}") |> render_click()

    assert has_element?(view, "#issue-comment-form-modal")
  end

  test "saving the comment form closes the comment modal and says the comment was saved", %{
    master_conn: conn,
    issue: issue,
    tenant_comment: tenant_comment
  } do
    view = open_comments(conn, issue)

    view |> element("#edit-comment-#{tenant_comment.id}") |> render_click()

    view
    |> form("##{MishkaGervaz.Resource.Info.Form.component_id(MishkaDocument.IssueComment)}-form",
      form: %{content: "Edited from the comment form"}
    )
    |> render_submit()

    render_async(view, 5_000)

    refute has_element?(view, "#issue-comment-form-modal")
    assert has_element?(view, "#flash-info", "Comment updated successfully")

    assert {:ok, %{content: "Edited from the comment form"}} =
             Ash.get(MishkaDocument.IssueComment, tenant_comment.id,
               action: :master_get,
               authorize?: false
             )
  end

  test "a master is offered edit and delete on every comment, and delete removes it", %{
    master_conn: conn,
    issue: issue,
    master_comment: master_comment,
    tenant_comment: tenant_comment
  } do
    view = open_comments(conn, issue)

    for comment <- [master_comment, tenant_comment] do
      assert has_element?(view, "#edit-comment-#{comment.id}")
      assert has_element?(view, "#delete-comment-#{comment.id}")

      view |> element("#delete-comment-#{comment.id}") |> render_click()

      refute has_element?(view, "#comments-#{comment.id}")

      assert {:error, %Ash.Error.Invalid{}} =
               Ash.get(MishkaDocument.IssueComment, comment.id,
                 action: :master_get,
                 authorize?: false
               )
    end
  end

  defp open_comments(conn, issue) do
    {:ok, view, _html} = live(conn, "/admin/dashboard/document/issues")
    render_async(view, 5_000)

    view
    |> element(~s(button[phx-click="expand_row"][phx-value-id="#{issue.id}"]))
    |> render_click()

    render_async(view, 5_000)
    view
  end

  defp on_host(conn) do
    conn
    |> Map.put(:host, "localhost")
    |> Map.update!(:req_headers, &[{"host", "localhost"} | List.keydelete(&1, "host", 0)])
  end

  defp star_permission do
    case Permission |> Ash.Query.filter(name == "*") |> Ash.read_one(authorize?: false) do
      {:ok, nil} ->
        Permission
        |> Ash.Changeset.for_create(:create, %{name: "*"}, authorize?: false)
        |> Ash.create!()

      {:ok, permission} ->
        permission
    end
  end

  defp admin!(email, site_id \\ nil) do
    {:ok, user} =
      User
      |> Ash.Changeset.for_create(
        :register_with_password,
        %{email: email, password: @password, password_confirmation: @password},
        authorize?: false
      )
      |> then(&if(site_id, do: Ash.Changeset.set_tenant(&1, site_id), else: &1))
      |> Ash.create()

    UserPermission
    |> Ash.Changeset.for_create(:assign, %{}, authorize?: false)
    |> Ash.Changeset.force_change_attribute(:user_id, user.id)
    |> Ash.Changeset.force_change_attribute(:permission_id, star_permission().id)
    |> Ash.create!(authorize?: false)

    user
  end

  defp log_in(conn, user) do
    conn
    |> Plug.Test.init_test_session(%{})
    |> Plug.Conn.put_session(:master_mode, true)
    |> AshAuthentication.Plug.Helpers.store_in_session(user)
  end
end
