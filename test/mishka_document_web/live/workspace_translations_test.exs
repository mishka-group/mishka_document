defmodule MishkaDocumentWeb.Test.WorkspaceTranslationsTest do
  @moduledoc """
  The workspaces list with translated workspaces in it, as they change while it is open.

  The list shows one card per document and a chip for each other language — see
  `MishkaCmsCore.LanguageEditions`. A live update puts a changed card in by reading that one row, never
  through the hook that keeps the list to masters, so each change here arrives with the dashboard
  already open. The archive is the exception: it lists every archived edition on a card of its own.

  A master's Archive, one card or a bulk selection, is refused while a live translation remains, its
  Delete too, and a translation's Restore is refused while its master is archived — each time with
  the admin told why. A refused Archive or Delete comes with a button that archives, or deletes for
  good, those translations at once.
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
  @resource MishkaDocument.Workspace
  @repo Application.compile_env!(:mishka_cms_core, :repo)

  setup %{conn: conn} do
    SiteState.clear()
    :ok = Swoosh.TestAssertions.set_swoosh_global()
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

    # THIS SITE HAS THE DOCUMENTATION. Everything below is about the dashboard, and a site that has
    # never been set up opens on the installer instead — which is the right answer there and the
    # wrong fixture here. `MishkaDocument.ProvisionTest` is where the installer screen is driven.
    :ok = MishkaCmsCore.Install.Extensions.mark_installed!(site.id, :mishka_document, "test")

    n = System.unique_integer([:positive])

    admin = create_admin("workspace-translations-#{n}@example.com")

    conn =
      conn
      |> Map.put(:host, "localhost")
      |> Map.update!(:req_headers, &[{"host", "localhost"} | List.keydelete(&1, "host", 0)])
      |> log_in(admin)

    master = create_workspace!(site_id: site.id, name: "Handbook #{n}")

    {:ok, conn: conn, site: site, master: master, admin: admin}
  end

  defp translate!(site, master, language) do
    create_workspace!(
      site_id: site.id,
      name: "#{master.name} #{language}",
      language: language,
      language_group_id: master.id
    )
  end

  defp open_workspaces(conn) do
    {:ok, view, _html} = live(conn, @path)
    render_async(view, @await)
    view
  end

  # A CHANGE REACHES THE TABLE AS A BROADCAST THE PAGE HANDS ON WITH `send_update/3`, which the page
  # runs after the render that delivered the broadcast — so it is the second render that shows it.
  defp settle(view) do
    render(view)
    render_async(view, @await)
    view
  end

  defp card(workspace), do: ~s([data-role^="wscard"][id$="#{workspace.id}"])

  defp chip(master, edition),
    do: ~s(#{card(master)} a[href="/admin/dashboard/document/sections/workspace/#{edition.id}"])

  defp archive!(workspace, site) do
    workspace
    |> Ash.Changeset.for_destroy(:destroy, %{}, tenant: site.id, authorize?: false)
    |> Ash.destroy!()
  end

  defp open_archive(conn) do
    view = open_workspaces(conn)

    view
    |> element(~s(button[phx-click="archive_filter"][phx-value-status="archived"]))
    |> render_click()

    render_async(view, @await)
    view
  end

  # What the Archive left behind before it was refused: an archived master under a live translation.
  defp shelve_under_translation!(master) do
    Ecto.Adapters.SQL.query!(
      @repo,
      "UPDATE mishka_document_workspaces SET archived_at = now() WHERE id = $1",
      [Ecto.UUID.dump!(master.id)]
    )
  end

  defp live?(workspace),
    do:
      match?(
        {:ok, %{archived_at: nil}},
        Ash.get(@resource, workspace.id, action: :master_get, authorize?: false)
      )

  defp stored?(workspace),
    do: match?({:ok, _}, Ash.get(@resource, workspace.id, action: :master_get, authorize?: false))

  defp select(view, workspace) do
    view |> element(~s(#{card(workspace)} [phx-click="toggle_select"])) |> render_click()
    view
  end

  defp bulk(view, action) do
    view
    |> element(~s(button[phx-click="bulk_action"][phx-value-action="#{action}"]))
    |> render_click()

    render_async(view, @await)
    view
  end

  @alert "#translations-refusal-alert"
  @act "#translations-refusal-act"

  # THE ALERT ARRIVES AS AN UPDATE THE TABLE SENDS THE PAGE, run after the render that delivered the
  # click, and then reads what it shows off the page's process.
  defp refused(view) do
    render(view)
    render_async(view, @await)
    view
  end

  defp act(view) do
    view |> element(@act) |> render_click()
    view
  end

  @refused "This is the original English version. Its Persian translation is still live, so it " <>
             "can't be deleted yet. Archive or delete that translation first, then this one."
  @restore_refused "This is the Persian translation. Its original English version is archived, so " <>
                     "it can't be restored yet. Restore the original first, then this one."

  test "a translation added joins its master's card", %{conn: conn, site: site, master: master} do
    view = open_workspaces(conn)
    fa = translate!(site, master, "fa")
    settle(view)

    refute has_element?(view, card(fa)), "the new translation took a card of its own"
    assert has_element?(view, chip(master, fa)), "the master kept the chips it was drawn with"
  end

  test "a translation archived leaves its master's chips", %{
    conn: conn,
    site: site,
    master: master
  } do
    fa = translate!(site, master, "fa")
    view = open_workspaces(conn)
    assert has_element?(view, chip(master, fa))

    archive!(fa, site)
    settle(view)

    refute has_element?(view, chip(master, fa))
    refute has_element?(view, card(fa))
  end

  test "the archive lists an archived translation on a card of its own", %{
    conn: conn,
    site: site,
    master: master
  } do
    fa = translate!(site, master, "fa")
    archive!(fa, site)
    view = open_workspaces(conn)

    view
    |> element(~s(button[phx-click="archive_filter"][phx-value-status="archived"]))
    |> render_click()

    render_async(view, @await)

    assert has_element?(view, card(fa))
  end

  # THE TABLE DESTROYS WITH THE RECORD AND NO `authorize?`, which an archive hands its validations as
  # `authorize?: false`. Each of these presses the button an admin presses and reads what they are
  # told: an alert that offers to archive — or delete for good — the translations in the way, and asks
  # first, naming them.
  describe "deleting a master that has translations" do
    test "Archive keeps it while a translation is live, says why, and archives the translation at once",
         %{conn: conn, site: site, master: master} do
      fa = translate!(site, master, "fa")
      view = open_workspaces(conn)

      view |> element(~s(#{card(master)} button[phx-click="delete"])) |> render_click()
      refused(view)

      assert live?(master), "the master was archived under its live translation"
      assert live?(fa)
      assert has_element?(view, @alert, @refused)

      refute has_element?(view, "#flash-error"),
             "the alert's reason was repeated as an error flash"

      assert has_element?(view, @act, "Archive the translations")

      assert has_element?(
               view,
               ~s(#{@act}[data-confirm="Archive the Persian translation of “#{master.name}”? You can restore it later."])
             )

      act(view)

      refute live?(fa), "the quick action left the translation live"

      assert stored?(fa),
             "the quick action deleted the translation for good instead of archiving it"

      assert live?(master), "the quick action archived the original too"

      assert has_element?(
               view,
               "#translations-refusal-done",
               "You can delete “#{master.name}” now."
             )

      view |> element(~s(#{card(master)} button[phx-click="delete"])) |> render_click()

      refute live?(master)
      refute has_element?(view, "#flash-error")
    end

    test "the bulk Archive keeps it too, and archives every live translation at once", %{
      conn: conn,
      site: site,
      master: master
    } do
      fa = translate!(site, master, "fa")
      ar = translate!(site, master, "ar")

      view = conn |> open_workspaces() |> select(master) |> bulk("archive")
      refused(view)

      assert live?(master)
      assert has_element?(view, @alert, "Its translations in Arabic and Persian are still live")

      assert has_element?(
               view,
               ~s(#{@act}[data-confirm="Archive the Arabic and Persian translations of “#{master.name}”? You can restore them later."])
             )

      act(view)

      refute live?(fa)
      refute live?(ar)
      assert live?(master)

      bulk(view, "archive")

      refute live?(master)
    end

    test "Archive archives it once its translation is archived", %{
      conn: conn,
      site: site,
      master: master,
      admin: admin
    } do
      fa = translate!(site, master, "fa")
      :ok = Ash.destroy(fa, action: :master_destroy, actor: admin)
      view = open_workspaces(conn)

      view |> element(~s(#{card(master)} button[phx-click="delete"])) |> render_click()
      refused(view)

      refute live?(master)
      refute has_element?(view, "#flash-error")
      refute has_element?(view, @alert)
    end

    test "Delete keeps an archived one while its translation is live, and deletes the translation for good at once",
         %{conn: conn, site: site, master: master} do
      fa = translate!(site, master, "fa")
      shelve_under_translation!(master)
      view = open_archive(conn)

      view
      |> element(~s(#{card(master)} [phx-value-event="permanent_destroy"]))
      |> render_click()

      refused(view)

      assert stored?(master), "the master was deleted for good under its live translation"
      assert has_element?(view, @alert, @refused)
      assert has_element?(view, @act, "Delete the translations for good")

      assert has_element?(
               view,
               ~s(#{@act}[data-confirm="Delete the Persian translation of “#{master.name}” for good? This can't be undone."])
             )

      act(view)

      refute stored?(fa)
      assert stored?(master)
    end

    test "the bulk Delete keeps it too, and offers the same", %{
      conn: conn,
      site: site,
      master: master
    } do
      translate!(site, master, "fa")
      shelve_under_translation!(master)

      view = conn |> open_archive() |> select(master) |> bulk("permanent_destroy")
      refused(view)

      assert stored?(master)
      assert has_element?(view, @alert, @refused)
      assert has_element?(view, @act, "Delete the translations for good")
    end

    # AN ARCHIVED TRANSLATION IS IN NOBODY'S WAY — its Restore is what keeps it from outliving its
    # master. Holding the master back for it would refuse the selection that empties the archive of a
    # whole group, whose cards sit side by side there and go one at a time.
    test "the bulk Delete empties a whole archived group", %{
      conn: conn,
      site: site,
      master: master
    } do
      fa = translate!(site, master, "fa")
      archive!(fa, site)
      archive!(master, site)

      view = conn |> open_archive() |> select(fa) |> select(master) |> bulk("permanent_destroy")

      refute stored?(master)
      refute stored?(fa)
      refute has_element?(view, "#flash-error")
    end
  end

  # A TRANSLATION BACK UNDER AN ARCHIVED MASTER is a workspace the dashboard has no card for: it
  # shows masters and hangs the rest off them. The archive shows the whole group side by side, so a
  # selection holding all of it comes back together — which is why the group is checked once the
  # restore is written and not before it.
  describe "restoring a translation" do
    test "Restore keeps it while its master is archived, and says why", %{
      conn: conn,
      site: site,
      master: master
    } do
      fa = translate!(site, master, "fa")
      archive!(fa, site)
      archive!(master, site)
      view = open_archive(conn)

      view |> element(~s(#{card(fa)} [phx-value-event="unarchive"])) |> render_click()

      refute live?(fa), "the translation came back under its archived master"
      refute live?(master)
      assert has_element?(view, "#flash-error", @restore_refused)
    end

    test "it goes back once its master has", %{conn: conn, site: site, master: master} do
      fa = translate!(site, master, "fa")
      archive!(fa, site)
      archive!(master, site)
      view = open_archive(conn)

      view |> element(~s(#{card(master)} [phx-value-event="unarchive"])) |> render_click()
      render_async(view, @await)
      view |> element(~s(#{card(fa)} [phx-value-event="unarchive"])) |> render_click()

      assert live?(master)
      assert live?(fa)
      refute has_element?(view, "#flash-error")
    end

    # A WORKSPACE IS WRITTEN ONE ROW AT A TIME — its event log wraps each action — so the order the
    # archive's bulk read hands its rows over is the order they come back in. Two editions here,
    # because a master the read happened to put first would prove nothing.
    test "the bulk Restore brings a whole archived group back", %{
      conn: conn,
      site: site,
      master: master
    } do
      fa = translate!(site, master, "fa")
      ar = translate!(site, master, "ar")
      Enum.each([fa, ar, master], &archive!(&1, site))

      view =
        conn |> open_archive() |> select(fa) |> select(ar) |> select(master) |> bulk("unarchive")

      assert live?(master)
      assert live?(fa), "the group came back before its master did"
      assert live?(ar)
      refute has_element?(view, "#flash-error")
    end
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
