# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_document/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaDocumentWeb.Test.FormReopenTest do
  @moduledoc """
  The document pages keep their forms mounted in a modal and only hide them, so a close that sends
  the form nothing — the modal's close icon, Escape, a click outside it — leaves what was typed in
  it. Opening the form again starts it over: the page's add button on the empty create form, a row's
  Edit on the record read again.

  A close is therefore nothing at all here: each case types into the form, sends nothing, and opens
  the form again the way the page does. The tags page draws a plain form; the note drafts page's
  `content` is the content editor.
  """
  use MishkaDocument.ConnCase

  import Phoenix.LiveViewTest
  import MishkaDocument.Test.Factory

  alias MishkaCmsCore.Accounts.{Permission, User, UserPermission}
  alias MishkaCmsCore.Runtime.States.SiteState

  require Ash.Query

  @password "Password123!"
  @await 5_000
  @tags "/admin/dashboard/document/tags"
  @drafts "/admin/dashboard/document/note-drafts"
  @tag_form "#tag_form-form"
  @tag_name "#tag_form-form_name"
  @draft_form "#note_draft_form-form"
  @draft_content "#note_draft_form-form_content-editor-value"
  @draft_surface "#note_draft_form-form_content-editor-surface"

  setup %{conn: conn} do
    SiteState.clear()

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

    :ok = MishkaCmsCore.Install.Extensions.mark_installed!(site.id, :mishka_document, "test")

    n = System.unique_integer([:positive])
    workspace = create_workspace!(site_id: site.id, skip_version: true, name: "Handbook #{n}")
    version = create_workspace_version!(workspace_id: workspace.id, site_id: site.id)
    section = create_section!(site_id: site.id, workspace_version_id: version.id)

    draft =
      create_note_draft!(
        site_id: site.id,
        section_id: section.id,
        workspace_version_id: version.id,
        content: "<p>Saved draft #{n}</p>"
      )

    {:ok, conn: log_in(on_host(conn), admin!("reopen-#{n}@example.com")), n: n, draft: draft}
  end

  defp open(conn, path) do
    {:ok, view, _html} = live(conn, path)
    render_async(view, @await)
    view
  end

  defp add(view, button) do
    html = view |> element(button) |> render_click()
    render_async(view, @await)
    {view, html}
  end

  defp edit(view, record, form) do
    view
    |> element(~s([phx-click*="#{record.id}"][phx-click*='"event":"edit"']))
    |> render_click()

    render_async(view, @await)
    assert has_element?(view, "#{form}[method=put]")
    view
  end

  defp type(view, form, field, value) do
    view
    |> form(form, %{"form" => %{field => value}})
    |> render_change(%{"_target" => ["form", field]})

    render_async(view, @await)
    view
  end

  defp value(view, selector) do
    node = view |> element(selector) |> render() |> LazyHTML.from_fragment()

    case LazyHTML.attribute(node, "value") do
      [value] -> value
      [] -> node |> LazyHTML.text() |> String.trim()
    end
  end

  defp editor_value(view) do
    view
    |> element(@draft_surface)
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.attribute("data-value")
  end

  test "Add Tag after a create closed without saving opens the empty create form", ctx do
    {view, _html} = ctx.conn |> open(@tags) |> add("#add-document-tag-btn")

    type(view, @tag_form, "name", "Half typed #{ctx.n}")
    assert value(view, @tag_name) == "Half typed #{ctx.n}"

    {view, _html} = add(view, "#add-document-tag-btn")

    assert has_element?(view, "#{@tag_form}[method=post]")
    assert value(view, @tag_name) == ""
  end

  test "Add Note Draft after a create closed without saving draws the content editor anew", ctx do
    {view, _html} = ctx.conn |> open(@drafts) |> add("#add-note-draft-btn")

    type(view, @draft_form, "content", "<p>Half written</p>")
    assert value(view, @draft_content) == "<p>Half written</p>"
    assert editor_value(view) == ["<p>Half written</p>"]

    {view, html} = add(view, "#add-note-draft-btn")

    assert html |> LazyHTML.from_document() |> LazyHTML.query(@draft_surface) |> Enum.count() == 0
    assert has_element?(view, "#{@draft_form}[method=post]")
    assert value(view, @draft_content) == ""
    assert editor_value(view) in [[], [""]]
  end

  test "Add Note Draft after an edit closed without saving opens the empty create form", ctx do
    view = ctx.conn |> open(@drafts) |> edit(ctx.draft, @draft_form)

    assert editor_value(view) == ["<p>Saved draft #{ctx.n}</p>"]
    type(view, @draft_form, "content", "<p>Unsaved</p>")

    {view, _html} = add(view, "#add-note-draft-btn")

    assert has_element?(view, "#{@draft_form}[method=post]")
    assert value(view, @draft_content) == ""
    assert editor_value(view) in [[], [""]]
  end

  test "Edit on the draft it was closed on reads the draft again", ctx do
    view = ctx.conn |> open(@drafts) |> edit(ctx.draft, @draft_form)

    type(view, @draft_form, "content", "<p>Unsaved</p>")
    assert value(view, @draft_content) == "<p>Unsaved</p>"

    edit(view, ctx.draft, @draft_form)

    assert value(view, @draft_content) == "<p>Saved draft #{ctx.n}</p>"
    assert editor_value(view) == ["<p>Saved draft #{ctx.n}</p>"]
  end

  defp on_host(conn) do
    conn
    |> Map.put(:host, "localhost")
    |> Map.update!(:req_headers, &[{"host", "localhost"} | List.keydelete(&1, "host", 0)])
  end

  defp admin!(email) do
    {:ok, user} =
      User
      |> Ash.Changeset.for_create(
        :register_with_password,
        %{email: email, password: @password, password_confirmation: @password},
        authorize?: false
      )
      |> Ash.create()

    UserPermission
    |> Ash.Changeset.for_create(:assign, %{}, authorize?: false)
    |> Ash.Changeset.force_change_attribute(:user_id, user.id)
    |> Ash.Changeset.force_change_attribute(:permission_id, star_permission().id)
    |> Ash.create!(authorize?: false)

    user
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

  defp log_in(conn, user) do
    conn
    |> Plug.Test.init_test_session(%{})
    |> Plug.Conn.put_session(:master_mode, true)
    |> AshAuthentication.Plug.Helpers.store_in_session(user)
  end
end
