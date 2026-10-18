# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_document/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaDocument.Dashboard.ScopeTest do
  @moduledoc """
  `MishkaDocument.Dashboard.Scope` reads the dashboard's figures as the viewer, so the resources'
  policies and multitenancy keep a site's admin to their own site and a viewer to the areas they hold.
  """
  use MishkaDocument.DataCase, async: false

  @moduletag :capture_log

  import MishkaDocument.Test.Factory

  alias MishkaDocument.Dashboard.Scope
  alias MishkaDocument.Issue

  setup do
    site = create_site!()
    other = create_site!()

    create_issue!(site_id: site.id, title: "Mine one")
    create_issue!(site_id: site.id, title: "Mine two")
    create_issue!(site_id: other.id, title: "Theirs")

    {:ok,
     site: site,
     other: other,
     master: create_user_with_permissions!(["admin:dashboard:*"]),
     admin: create_user_with_permissions!(["admin:dashboard:*"], site_id: site.id),
     nobody: create_user_with_permissions!(["admin:dashboard:runtime:page"], site_id: site.id)}
  end

  describe "read_for/2" do
    test "names the master read with the master as actor, and no tenant", %{master: master} do
      assert {:master_read, [actor: ^master]} = Scope.read_for(master)
      assert {:read_any, [actor: ^master]} = Scope.read_for(master, :read_any)
    end

    test "names the primary read with the site as tenant for a site user", %{
      admin: admin,
      site: site
    } do
      site_id = site.id
      assert {:read, [actor: ^admin, tenant: ^site_id]} = Scope.read_for(admin)
      assert {:read, [actor: ^admin, tenant: ^site_id]} = Scope.read_for(admin, :read_any)
    end

    test "refuses a missing viewer instead of reading as a master" do
      assert_raise ArgumentError, fn -> Scope.read_for(missing()) end
      assert_raise ArgumentError, fn -> Scope.query(Issue, missing()) end
    end
  end

  describe "count/1 and list/2" do
    test "a master reads every site, a site admin only its own", %{master: master, admin: admin} do
      assert Scope.count(Scope.query(Issue, master)) >= 3
      assert Scope.count(Scope.query(Issue, admin)) == 2

      titles = Issue |> Scope.query(admin) |> Ash.Query.sort(:title) |> Scope.list()
      assert Enum.map(titles, & &1.title) == ["Mine one", "Mine two"]
    end

    test "list/2 takes the first records of a paginated read and of one that is not", %{
      master: master,
      admin: admin
    } do
      assert [_] = Issue |> Scope.query(admin) |> Scope.list(1)
      assert [_, _] = Issue |> Scope.query(admin) |> Scope.list(5)
      assert [_] = Issue |> Scope.query(master) |> Scope.list(1)
    end

    test "a viewer without the resource's area reads no data and does not raise", %{
      nobody: nobody
    } do
      assert Scope.count(Scope.query(Issue, nobody)) == 0
      assert Scope.list(Scope.query(Issue, nobody)) == []
      assert Scope.list(Scope.query(Issue, nobody), 3) == []
    end

    test "a site user is refused the master read, so a missing filter cannot widen a read", %{
      admin: admin,
      other: other
    } do
      for opts <- [[actor: admin], [actor: admin, tenant: other.id]] do
        query = Ash.Query.for_read(Issue, :master_read, %{}, opts)

        assert {:error, _refused} = Ash.read(query)
        assert Scope.count(query) == 0
        assert Scope.list(query) == []
      end
    end

    test "a failed read that is not a refusal is no data too", %{admin: admin} do
      query = Ash.Query.for_read(Issue, :read, %{}, actor: admin)

      assert Scope.count(query) == 0
      assert Scope.list(query) == []
    end
  end

  defp missing, do: List.first([])
end
