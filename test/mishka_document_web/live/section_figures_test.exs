# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_document/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaDocumentWeb.Test.SectionFiguresTest do
  @moduledoc """
  What the Sections page draws from the event log and the section tree, which the database counts
  (`contributors_count`, `section_versions_count`, `breadcrumb_path` and the Contributor filter):

    * each page's card shows the pages above it, the accounts that wrote it or its notes, and how
      many versions of it there are;
    * the Contributor filter offers the accounts that wrote in the version, and keeps the pages the
      account picked wrote;
    * an admin of another area is not let into the page, so none of those figures reaches it.
  """
  use MishkaDocument.ConnCase

  @moduletag :capture_log

  import Phoenix.LiveViewTest
  import MishkaDocument.Test.Factory

  alias MishkaCmsCore.Runtime.States.SiteState
  alias MishkaDocument.{Note, Section}

  @section "admin:dashboard:document:section"
  @workspace "admin:dashboard:document:workspace"
  @site_loads "admin:api:*"
  @await 5_000

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

    :ok = MishkaCmsCore.Install.Extensions.mark_installed!(site.id, :mishka_document, "test")

    conn =
      conn
      |> Map.put(:host, "localhost")
      |> Map.update!(:req_headers, &[{"host", "localhost"} | List.keydelete(&1, "host", 0)])

    workspace =
      create_workspace!(
        site_id: site.id,
        name: "Figures Handbook",
        status: :active,
        skip_version: true
      )

    version =
      create_workspace_version!(workspace_id: workspace.id, site_id: site.id, status: :beta)

    ada = create_user!(site_id: site.id, email: "ada-writer@test.com")
    bob = create_user!(site_id: site.id, email: "bob-writer@test.com")

    guides = write!(Section, ada, site, title: "Guides", slug: "guides", version: version)

    install =
      write!(Section, bob, site,
        title: "Install",
        slug: "install",
        version: version,
        parent_section_id: guides.id
      )

    linux =
      write!(Section, bob, site,
        title: "Linux",
        slug: "linux",
        version: version,
        parent_section_id: install.id
      )

    write!(Note, ada, site, section_id: linux.id, title: "Aside", content: "A note")

    other_version =
      create_workspace_version!(workspace_id: workspace.id, site_id: site.id, status: :beta)

    create_section!(
      site_id: site.id,
      workspace_version_id: other_version.id,
      source_section_id: guides.id,
      title: "Guides",
      slug: "guides"
    )

    {:ok,
     conn: conn,
     site: site,
     version: version,
     ada: ada,
     bob: bob,
     guides: guides,
     install: install,
     linux: linux}
  end

  defp write!(Section, actor, site, attrs) do
    {version, attrs} = Keyword.pop!(attrs, :version)

    Section
    |> Ash.Changeset.for_create(
      :create,
      Map.new([workspace_version_id: version.id] ++ attrs),
      actor: actor,
      tenant: site.id,
      authorize?: false
    )
    |> Ash.create!()
  end

  defp write!(Note, actor, site, attrs) do
    Note
    |> Ash.Changeset.for_create(:create, Map.new(attrs),
      actor: actor,
      tenant: site.id,
      authorize?: false
    )
    |> Ash.create!()
  end

  defp log_in(conn, user) do
    conn
    |> Plug.Test.init_test_session(%{})
    |> Plug.Conn.put_session(:master_mode, false)
    |> AshAuthentication.Plug.Helpers.store_in_session(user)
  end

  defp admin(names, site), do: create_user_with_permissions!(names, site_id: site.id)

  defp open_sections(conn, site, version) do
    await_event_announcements()

    {:ok, view, _html} =
      live(
        log_in(conn, admin([@site_loads, @section], site)),
        "/admin/dashboard/document/sections/#{version.id}"
      )

    render_async(view, @await)
    render_async(view, @await)
    view
  end

  defp close(view) do
    render_async(view, @await)
    ref = Process.monitor(view.pid)
    GenServer.stop(view.pid, :normal)
    assert_receive {:DOWN, ^ref, :process, _pid, _reason}
  end

  defp card(section), do: "#sections-table_sections-#{section.id}"

  defp texts(view, selector) do
    view
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.query(selector)
    |> Enum.map(&(&1 |> LazyHTML.text() |> String.trim()))
  end

  defp listed(view) do
    view
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.query(~s([data-role="seccard"]))
    |> Enum.map(&(&1 |> LazyHTML.attribute("id") |> List.first()))
    |> Enum.map(&String.replace_prefix(&1, "sections-table_sections-", ""))
    |> Enum.sort()
  end

  describe "a page's card" do
    test "shows the pages above it, nearest last", %{
      conn: conn,
      site: site,
      version: version,
      linux: linux,
      install: install,
      guides: guides
    } do
      view = open_sections(conn, site, version)

      assert texts(view, "#{card(linux)} [data-role=sec-crumb]") == ["Guides", "Install"]
      assert texts(view, "#{card(install)} [data-role=sec-crumb]") == ["Guides"]
      assert texts(view, "#{card(guides)} [data-role=sec-crumb]") == []

      close(view)
    end

    test "counts the accounts that wrote the page or a note of it", %{
      conn: conn,
      site: site,
      version: version,
      linux: linux,
      install: install,
      guides: guides
    } do
      view = open_sections(conn, site, version)

      assert [linux_writers] = texts(view, "#{card(linux)} [data-role=sec-contributors]")
      assert linux_writers =~ "2"
      assert [install_writers] = texts(view, "#{card(install)} [data-role=sec-contributors]")
      assert install_writers =~ "1"
      assert [guides_writers] = texts(view, "#{card(guides)} [data-role=sec-contributors]")
      assert guides_writers =~ "1"

      close(view)
    end

    test "says how many versions there are of a page that was copied into another version", %{
      conn: conn,
      site: site,
      version: version,
      linux: linux,
      guides: guides
    } do
      view = open_sections(conn, site, version)

      assert [versions] = texts(view, "#{card(guides)} [data-role=sec-versions]")
      assert versions =~ "2"
      assert texts(view, "#{card(linux)} [data-role=sec-versions]") == []

      close(view)
    end
  end

  describe "the Contributor filter" do
    defp offered(view) do
      view |> element("#sections-table-filter-contributor") |> render_focus()
      render_async(view, @await)

      view
      |> render()
      |> LazyHTML.from_fragment()
      |> LazyHTML.query(~s(button[phx-click="relation_toggle"][phx-value-filter="contributor"]))
      |> Enum.map(&(&1 |> LazyHTML.attribute("phx-value-label") |> List.first()))
      |> Enum.sort()
    end

    defp pick(view, user) do
      view
      |> element(
        ~s(button[phx-click="relation_toggle"][phx-value-filter="contributor"][phx-value-id="#{user.id}"])
      )
      |> render_click()

      render_async(view, @await)
    end

    test "offers the accounts that wrote in the version", %{
      conn: conn,
      site: site,
      version: version
    } do
      view = open_sections(conn, site, version)

      assert offered(view) == ["ada-writer@test.com", "bob-writer@test.com"]

      close(view)
    end

    test "keeps the pages the picked accounts wrote", %{
      conn: conn,
      site: site,
      version: version,
      ada: ada,
      bob: bob,
      guides: guides,
      install: install,
      linux: linux
    } do
      view = open_sections(conn, site, version)
      assert listed(view) == Enum.sort([guides.id, install.id, linux.id])

      offered(view)
      pick(view, bob)
      assert listed(view) == Enum.sort([install.id, linux.id])

      offered(view)
      pick(view, ada)
      assert listed(view) == Enum.sort([guides.id, install.id, linux.id])

      close(view)
    end

    test "lists the pages an account wrote itself, not the ones it only wrote a note of", %{
      conn: conn,
      site: site,
      version: version,
      ada: ada,
      guides: guides
    } do
      view = open_sections(conn, site, version)

      offered(view)
      pick(view, ada)
      assert listed(view) == [guides.id]

      close(view)
    end
  end

  describe "an admin of another area" do
    test "is not let into the Sections page", %{conn: conn, site: site, version: version} do
      assert {:error, {:redirect, %{flash: %{"error" => _refused}}}} =
               live(
                 log_in(conn, admin([@site_loads, @workspace], site)),
                 "/admin/dashboard/document/sections/#{version.id}"
               )
    end
  end
end
