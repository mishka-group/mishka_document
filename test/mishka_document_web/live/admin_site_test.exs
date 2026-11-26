# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_document/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaDocumentWeb.Test.AdminSiteTest do
  @moduledoc """
  The documentation's admin pages follow the site a master picked in the top bar
  (`MishkaCmsCore.Accounts.AdminSite`), the one pick every page reads:

    * All sites shows every site's workspaces, each card naming its site, and the setup picker
      starts on the site the request is for;
    * one site shows that site's workspaces alone, and the setup and check window is that site's,
      with no picker that could start on another;
    * a pick made on another page reaches an open page live.
  """
  use MishkaDocument.ConnCase

  @moduletag :capture_log

  import Phoenix.LiveViewTest
  import MishkaDocument.Test.Factory

  alias MishkaCmsCore.Accounts.{AdminSite, Permission, User, UserPermission}
  alias MishkaCmsCore.Runtime.States.SiteState

  require Ash.Query

  @password "Password123!"
  @home "/admin/dashboard/document"

  setup %{conn: conn} do
    SiteState.clear()

    home = cached_site!(name: "localhost", host: "localhost", master: true)
    other = cached_site!(name: "beta", host: "beta.test", master: false)

    :persistent_term.put(:mishka_installed, true)
    on_exit(fn -> :persistent_term.erase(:mishka_installed) end)

    for site <- [home, other],
        do:
          :ok =
            MishkaCmsCore.Install.Extensions.mark_installed!(site.id, :mishka_document, "test")

    create_workspace!(site_id: home.id, name: "Home Handbook")
    create_workspace!(site_id: other.id, name: "Beta Handbook")

    master = create_master!()

    conn =
      conn
      |> Map.put(:host, "localhost")
      |> Map.update!(:req_headers, &[{"host", "localhost"} | List.keydelete(&1, "host", 0)])
      |> log_in(master)

    {:ok, conn: conn, master: master, home: home, other: other}
  end

  test "All sites lists every site's workspaces, each card naming its site", %{conn: conn} do
    {:ok, view, _html} = live(conn, @home)
    html = render_async(view, 5_000)

    assert html =~ "Home Handbook"
    assert html =~ "Beta Handbook"
    assert card_sites(html) == ["beta", "localhost"]
  end

  test "with one site picked the workspaces are that site's alone", %{
    conn: conn,
    master: master,
    other: other
  } do
    :ok = AdminSite.keep(master, other.id)

    {:ok, view, _html} = live(conn, @home)
    html = render_async(view, 5_000)

    assert html =~ "Beta Handbook"
    refute html =~ "Home Handbook"
    refute has_element?(view, ~s([data-testid="document-card-site"]))
  end

  test "the setup window is the picked site's, and starts on the request's site for All sites", %{
    conn: conn,
    master: master,
    home: home,
    other: other
  } do
    {:ok, view, _html} = live(conn, @home)

    assert has_element?(view, ~s(#document-kit-upgrade-site option[selected][value="#{home.id}"]))
    assert has_element?(view, ~s(#document-kit-upgrade-site option[value="#{other.id}"]))

    :ok = AdminSite.keep(master, other.id)
    {:ok, view, _html} = live(conn, @home)

    refute has_element?(view, "#document-kit-upgrade-site")
    assert view |> element("#document-kit-upgrade-site-fixed") |> render() =~ other.name
  end

  test "a pick made on another page opens the open page again in the picked site", %{
    conn: conn,
    master: master,
    other: other
  } do
    {:ok, view, _html} = live(conn, @home)
    render_async(view, 5_000)

    :ok = Task.await(Task.async(fn -> AdminSite.keep(master, other.id) end))

    assert {@home, _flash} = assert_redirect(view)
  end

  defp card_sites(html) do
    html
    |> LazyHTML.from_fragment()
    |> LazyHTML.query(~s([data-testid="document-card-site"]))
    |> Enum.map(&String.trim(LazyHTML.text(&1)))
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp cached_site!(attrs) do
    site = create_site!(Keyword.put(attrs, :active, true))
    SiteState.save(Map.take(site, [:id, :name, :host, :priority, :active, :master]))
    site
  end

  defp create_master! do
    {:ok, user} =
      User
      |> Ash.Changeset.for_create(
        :register_with_password,
        %{email: "docpicker@example.com", password: @password, password_confirmation: @password},
        authorize?: false
      )
      |> Ash.create()

    star =
      case Permission |> Ash.Query.filter(name == "*") |> Ash.read_one!(authorize?: false) do
        nil ->
          Permission
          |> Ash.Changeset.for_create(:create, %{name: "*"}, authorize?: false)
          |> Ash.create!()

        permission ->
          permission
      end

    UserPermission
    |> Ash.Changeset.for_create(:assign, %{}, authorize?: false)
    |> Ash.Changeset.force_change_attribute(:user_id, user.id)
    |> Ash.Changeset.force_change_attribute(:permission_id, star.id)
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
