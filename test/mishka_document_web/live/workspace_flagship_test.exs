# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_document/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaDocumentWeb.Test.WorkspaceFlagshipTest do
  @moduledoc """
  The workspaces grid's banner: the page's first featured, live workspace wears it and every other
  workspace stays a card. The decision comes from the rows the page streams, so it holds whether or
  not the table keeps the page's rows in its state.
  """
  use MishkaDocument.ConnCase

  import Phoenix.LiveViewTest
  import MishkaDocument.Test.Factory

  alias MishkaCmsCore.Accounts.{Permission, User, UserPermission}
  alias MishkaCmsCore.Runtime.States.SiteState

  require Ash.Query

  @password "Password123!"
  @path "/admin/dashboard/document"
  @await 5_000
  @banner ~s([data-role="wscard-flagship"])

  setup %{conn: conn} do
    SiteState.clear()
    site = master_site()

    SiteState.save(%{
      id: site.id,
      name: site.name,
      host: site.host,
      priority: site.priority,
      active: site.active,
      master: site.master
    })

    :persistent_term.put(:mishka_installed, true)
    on_exit(fn -> :persistent_term.erase(:mishka_installed) end)
    :ok = MishkaCmsCore.Install.Extensions.mark_installed!(site.id, :mishka_document, "test")

    n = System.unique_integer([:positive])

    conn =
      conn
      |> Map.put(:host, "localhost")
      |> Map.update!(:req_headers, &[{"host", "localhost"} | List.keydelete(&1, "host", 0)])
      |> log_in(create_admin("workspace-flagship-#{n}@example.com"))

    {:ok, conn: conn, site: site, n: n}
  end

  defp open_workspaces(conn) do
    {:ok, view, _html} = live(conn, @path)
    render_async(view, @await)
    view
  end

  defp banner(workspace), do: ~s([data-role="wscard-flagship"][id$="#{workspace.id}"])
  defp plain_card(workspace), do: ~s([data-role="wscard"][id$="#{workspace.id}"])

  test "the first featured workspace wears the banner and the rest stay cards", %{
    conn: conn,
    site: site,
    n: n
  } do
    older = create_workspace!(site_id: site.id, name: "Older featured #{n}", featured: true)
    newer = create_workspace!(site_id: site.id, name: "Newer featured #{n}", featured: true)
    other = create_workspace!(site_id: site.id, name: "Plain #{n}")

    view = open_workspaces(conn)

    assert has_element?(view, banner(newer))
    assert has_element?(view, plain_card(older))
    assert has_element?(view, plain_card(other))

    assert view |> render() |> LazyHTML.from_fragment() |> LazyHTML.query(@banner) |> Enum.count() ==
             1
  end

  test "a page with no featured workspace has no banner", %{conn: conn, site: site, n: n} do
    create_workspace!(site_id: site.id, name: "Plain #{n}")

    refute has_element?(open_workspaces(conn), @banner)
  end

  defp master_site do
    MishkaCmsCore.Runtime.Site
    |> Ash.Query.filter(master == true)
    |> Ash.Query.limit(1)
    |> Ash.read_one!(authorize?: false)
    |> case do
      nil -> create_site!(name: "localhost", host: "localhost", active: true, master: true)
      site -> site
    end
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

  defp create_admin(email) do
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

  defp log_in(conn, user) do
    conn
    |> Plug.Test.init_test_session(%{})
    |> Plug.Conn.put_session(:master_mode, true)
    |> AshAuthentication.Plug.Helpers.store_in_session(user)
  end
end
