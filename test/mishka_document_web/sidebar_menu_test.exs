# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_document/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaDocumentWeb.Test.SidebarMenuTest do
  @moduledoc """
  The document extension's `"sidebar:menus"` plugin: that it contributes its entry to the admin nav,
  and that the entry is only shown to admins holding a document permission.

  The plugin registers asynchronously (it retries until mnesia is up), so the hook-level test polls
  the way the widget-registration tests do. `call/1` is also exercised directly, which needs no
  running GenServer at all.
  """
  use MishkaDocument.DataCase

  alias MishkaCmsCore.Accounts.Checks.AccessPermissions
  alias MishkaCmsCore.Sidebar
  alias MishkaDocumentWeb.SidebarMenu

  @path "/admin/dashboard/document"

  defp menu_item(user) do
    user
    |> Sidebar.menu()
    |> Map.fetch!(:main)
    |> Enum.find_value(fn entry ->
      entry
      |> Map.get(:items, [])
      |> Enum.find(&(&1.key == "document"))
    end)
  end

  # Registration is asynchronous — the plugin retries until mnesia is ready — so there is no signal
  # to wait on but the registry itself. Same bounded poll the widget-registration tests use.
  defp wait_for_registration(remaining \\ 5_000) do
    cond do
      Enum.any?(Sidebar.collect().items, &(&1.key == "document")) ->
        :ok

      remaining <= 0 ->
        flunk("MishkaDocumentWeb.SidebarMenu never registered on #{Sidebar.event()}")

      true ->
        Process.sleep(100)
        wait_for_registration(remaining - 100)
    end
  end

  describe "credit — the documentation's own name and page, under every page it owns" do
    test "names it for the link and for a page that is not a link" do
      wait_for_registration()

      for module <- [
            MishkaDocumentWeb.Live.Admin.Dashboard.Home.Index,
            MishkaDocumentWeb.Live.Admin.Dashboard.Section.Index
          ] do
        assert Sidebar.credit(module) ==
                 %{
                   name: "Mishka Document",
                   url: "https://mishka.tools/cms/extensions/documentation"
                 }
      end
    end
  end

  describe "the plugin" do
    test "appends its item to the payload without touching what is already there" do
      seeded = Sidebar.core_menu()

      assert {:reply, %{items: items, groups: groups}} = SidebarMenu.call(seeded)
      assert groups == seeded.groups

      assert Enum.map(items, & &1.key) -- Enum.map(seeded.items, & &1.key) ==
               Enum.map(SidebarMenu.items(), & &1.key)
    end

    test "declares an entry the core never names, in the core's Plugins section" do
      item = Enum.find(SidebarMenu.items(), &(&1.key == "document"))

      assert item.group == "plugins"
      assert item.path == @path
      assert item.nav
      refute Enum.any?(Sidebar.core_menu().items, &(&1.key == "document"))
    end

    test "is registered on the event once the plugin engine is up" do
      wait_for_registration()

      assert Enum.any?(Sidebar.collect().items, &(&1.path == @path))
    end
  end

  describe "who sees it" do
    setup do
      wait_for_registration()
      :ok
    end

    # The entry's own gate. The core's Plugins section around it has a gate of its own, which is the
    # core's to answer.
    defp link_shown?(names) do
      AccessPermissions.match?(create_user_with_permissions!(names), %{},
        permissions: SidebarMenu.permissions("document")
      )
    end

    test "a workspace admin and a section editor are shown the entry" do
      assert link_shown?(["admin:dashboard:document:workspace"])
      assert link_shown?(["admin:dashboard:document:section"])
    end

    test "a whole-extension admin, a full dashboard admin and a holder of everything are too" do
      assert link_shown?(["admin:dashboard:document:*"])
      assert link_shown?(["admin:dashboard:*"])
      assert link_shown?(["*"])
    end

    test "an admin of another area, or of the document API only, is not" do
      refute link_shown?(["admin:dashboard:runtime:page"])
      refute link_shown?(["admin:api:document:*"])
    end

    test "a full dashboard admin finds it in the menu, where it used to be refused" do
      assert %{label: "Documents"} =
               menu_item(create_user_with_permissions!(["admin:dashboard:*"]))
    end

    # The entry is asked on its own, as the menu asks it: the Plugins section around it has a gate
    # of its own, which alone can hide the entry from a page admin whatever the entry's gate says.
    test "an admin of another area is not given the entry, and the menu draws no Plugins for it" do
      entry = Enum.find(Sidebar.collect().items, &(&1.key == "document"))
      page_admin = create_user_with_permissions!(["admin:dashboard:runtime:page"])

      assert Sidebar.visible_to?(
               entry,
               create_user_with_permissions!(["admin:dashboard:document:section"])
             )

      refute Sidebar.visible_to?(entry, page_admin)
      refute menu_item(page_admin)
      refute Enum.any?(Sidebar.menu(page_admin).main, &(Map.get(&1, :key) == "plugins"))
    end
  end

  describe "pages, not just the link" do
    test "only the entry itself is a link; every other page is nav: false" do
      assert Enum.filter(SidebarMenu.items(), & &1.nav) |> Enum.map(& &1.key) == ["document"]
    end

    test "every routed admin page has a declaration, so none is left without a gate" do
      declared = MapSet.new(SidebarMenu.items(), & &1.path)

      for {:live, path, _module, _action} <- MishkaDocumentWeb.Routes.routes(:admin) do
        full = Path.join("/admin/dashboard", path)
        assert MapSet.member?(declared, full), "#{full} has no declaration, so no gate"
      end
    end

    test "workspace pages and section pages are gated apart" do
      assert SidebarMenu.permissions("document.workspace_version") == [
               "admin:dashboard:document:workspace"
             ]

      for key <- ~w(document.sections document.sections_by_workspace document.tags
                    document.issues document.section_drafts document.note_drafts) do
        assert SidebarMenu.permissions(key) == ["admin:dashboard:document:section"], key
      end
    end

    test "the LINK carries the union, since holding either is reason to see the section" do
      assert SidebarMenu.permissions("document") ==
               ["admin:dashboard:document:workspace", "admin:dashboard:document:section"]

      assert SidebarMenu.permissions("document.event_logs") ==
               SidebarMenu.permissions("document")
    end

    test "an unknown key raises instead of quietly gating nothing" do
      assert_raise ArgumentError, ~r/no sidebar item declares the key/, fn ->
        SidebarMenu.permissions("document.nope")
      end
    end
  end

  describe "PageGuard sees these declarations" do
    setup do
      wait_for_registration()
      :ok
    end

    test "EVERY routed admin page is declared — an omission would LOCK the page" do
      declared = MapSet.new(SidebarMenu.items(), & &1.module)

      for {:live, path, module, _action} <- MishkaDocumentWeb.Routes.routes(:admin) do
        assert MapSet.member?(declared, module),
               "#{path} (#{inspect(module)}) has no declaration, so PageGuard would refuse it"
      end
    end

    test "an undeclared module is refused, never waved through" do
      assert Sidebar.permissions_for_module(Some.Undeclared.Page) == []
    end

    test "the split is real: workspace pages and section pages answer differently" do
      assert Sidebar.permissions_for_module(
               MishkaDocumentWeb.Live.Admin.Dashboard.WorkspaceVersion.Index
             ) == ["admin:dashboard:document:workspace"]

      assert Sidebar.permissions_for_module(MishkaDocumentWeb.Live.Admin.Dashboard.Issue.Index) ==
               ["admin:dashboard:document:section"]
    end

    test "a section editor cannot satisfy the workspace-version page" do
      editor = create_user_with_permissions!(["admin:dashboard:document:section"])

      sections =
        Sidebar.permissions_for_module(MishkaDocumentWeb.Live.Admin.Dashboard.Issue.Index)

      workspace =
        Sidebar.permissions_for_module(
          MishkaDocumentWeb.Live.Admin.Dashboard.WorkspaceVersion.Index
        )

      assert AccessPermissions.match?(editor, %{}, permissions: sections)
      refute AccessPermissions.match?(editor, %{}, permissions: workspace)
    end

    test "the parameterised routes are declared too, so none is refused by omission" do
      for module <- [
            MishkaDocumentWeb.Live.Admin.Dashboard.Section.Index,
            MishkaDocumentWeb.Live.Admin.Dashboard.WorkspaceVersion.Index
          ] do
        refute Sidebar.permissions_for_module(module) == []
      end
    end
  end
end
