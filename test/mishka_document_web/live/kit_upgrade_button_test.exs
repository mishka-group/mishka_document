# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_document/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaDocumentWeb.Test.KitUpgradeButtonTest do
  @moduledoc """
  The check-and-repair modal on the document dashboard: what it reports before it writes anything,
  and what each of its three buttons writes.

  The modal, its wording and the rules behind it are
  `MishkaCmsCoreWeb.Live.Admin.Components.KitUpgradePanel` and
  `MishkaCmsCore.Runtime.Handlers.UiKitUpgrade`, which are covered where they live. What can only be
  asserted here is that this dashboard is wired to them at all — the assign, the three events and
  the permission that gates them — and that the document bundle's own five components survive being
  fingerprinted, which is what decides whether a site's rows are ever offered as safe.

  The site is provisioned and then AGED: the version stamp on its rows is put back, which is exactly
  the state a site installed from an older bundle is in.
  """
  use MishkaDocument.ConnCase

  import Phoenix.LiveViewTest

  alias MishkaCmsCore.Accounts.{Permission, User, UserPermission}
  alias MishkaCmsCore.Install.Extensions
  alias MishkaCmsCore.Runtime.Component
  alias MishkaCmsCore.Runtime.Handlers.UiKitUpgrade
  alias MishkaCmsCore.Runtime.Page
  alias MishkaCmsCore.Runtime.PageDraft
  alias MishkaCmsCore.Runtime.ShareCard
  alias MishkaCmsCore.Runtime.States.SiteState
  alias MishkaCmsCore.Test.VersionHelpers
  alias MishkaDocument.Plugins.ShareCardTargets
  alias MishkaDocument.Provision
  alias MishkaInstaller.Event.{Event, EventHandler}

  require Ash.Query

  @password "Password123!"

  # HOW MANY THE BUNDLE SHIPS, read off the bundle rather than written here. The kit's components
  # are split and joined as the documentation grows; a number typed into an assertion turns every
  # one of those into a test failure that says nothing.
  @components length(MishkaDocument.Provision.component_names())
  @mine ~S(<div id={@id}>mine</div>)

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

    conn =
      conn
      |> Map.put(:host, "localhost")
      |> Map.update!(:req_headers, &[{"host", "localhost"} | List.keydelete(&1, "host", 0)])

    {:ok, conn: conn, site: site}
  end

  # THE SITE AS THE INSTALLER LEAVES IT: what the documentation ships, and the record core writes
  # once the run is over. That record is the whole answer to whether a site has the documentation
  # (`Extensions.installed?/2`) — a site holding every component and page and no record opens on the
  # installer, and the modal this suite is about is not on that screen.
  defp set_up!(site) do
    report = Provision.ensure!(site)

    :ok = Extensions.mark_installed!(site.id, :mishka_document, report.version)
  end

  defp components(site) do
    Component
    |> Ash.Query.for_read(:read_any, %{}, authorize?: false)
    |> Ash.Query.filter(site_id == ^site.id)
    |> Ash.read!(authorize?: false, page: [limit: 100])
    |> Map.fetch!(:results)
  end

  defp component!(site, name), do: Enum.find(components(site), &(&1.name == name))

  defp page!(site, path) do
    Page
    |> Ash.Query.for_read(:read_any, %{}, authorize?: false)
    |> Ash.Query.filter(site_id == ^site.id and path == ^path)
    |> Ash.read_one!(authorize?: false)
  end

  defp drafts(site, page) do
    PageDraft
    |> Ash.Query.for_read(:read_any, %{}, authorize?: false)
    |> Ash.Query.filter(site_id == ^site.id and source_page_id == ^page.id)
    |> Ash.read!(authorize?: false, page: [limit: 20])
    |> Map.fetch!(:results)
  end

  # The rows are put back to what an older bundle would have written AND stamped as though that
  # older bundle had written them, which is the state a site provisioned months ago is in: the kit
  # moved and nobody here touched the rows, so they are outdated AND safe — the case the first
  # button exists for. Aging the stamp alone would leave rows holding exactly what the bundle
  # ships, which is nothing to offer.
  defp age!(site) do
    for component <- components(site) do
      older = %{component | description: "as #{component.name} read at 0.0.1"}

      Ash.update!(
        component,
        %{
          description: older.description,
          extra:
            component.extra
            |> Map.put("ui_kit_version", "0.0.1")
            |> Map.put("ui_kit_digest", UiKitUpgrade.digest(older))
        },
        action: :master_update,
        authorize?: false,
        tenant: site.id
      )
    end
  end

  describe "a master who may edit the site's runtime" do
    setup %{conn: conn, site: site} do
      set_up!(site)

      {:ok, conn: log_in(conn, admin_with!("dockit@example.com", "*"))}
    end

    # THE ONE THING NO OTHER SUITE CAN SEE: this bundle's own components, through Ash's casting and
    # back out of the database, still answering to the fingerprint the install took of them. If they
    # did not, every row on every site would read as edited and the safe button would never appear.
    test "reports this bundle's components as outdated and untouched", %{conn: conn, site: site} do
      age!(site)

      {:ok, view, _html} = live(conn, "/admin/dashboard/document")

      view |> form("#document-kit-upgrade-form", %{"site_id" => site.id}) |> render_submit()

      assert has_element?(
               view,
               "#document-kit-upgrade-headline",
               "#{@components} components behind the bundle"
             )

      assert has_element?(
               view,
               "#document-kit-upgrade-ready-0",
               "installed from 0.0.1, untouched"
             )

      assert has_element?(view, "#document-kit-upgrade-safe", "Update #{@components} components")
      refute has_element?(view, "#document-kit-upgrade-choice")

      assert component!(site, "doc-section").extra["ui_kit_version"] == "0.0.1",
             "reading what is outdated wrote to the site"

      close(view)
    end

    test "updates them, and says everything is current when pressed again", %{
      conn: conn,
      site: site
    } do
      age!(site)

      {:ok, view, _html} = live(conn, "/admin/dashboard/document")

      view |> form("#document-kit-upgrade-form", %{"site_id" => site.id}) |> render_submit()
      html = view |> element("#document-kit-upgrade-safe") |> render_click()

      assert html =~ "Updated #{@components} components"

      for component <- components(site) do
        assert UiKitUpgrade.digest(component) == component.extra["ui_kit_digest"],
               "#{component.name} was not written as the bundle has it"
      end

      html =
        view |> form("#document-kit-upgrade-form", %{"site_id" => site.id}) |> render_submit()

      assert html =~ "up to date"
      refute has_element?(view, "#document-kit-upgrade-safe")

      close(view)
    end

    test "leaves a component the admin edited until they ask for it", %{conn: conn, site: site} do
      age!(site)

      edited =
        site
        |> component!("doc-sidebar")
        |> Ash.update!(%{template: @mine},
          action: :master_update,
          authorize?: false,
          tenant: site.id
        )

      {:ok, view, _html} = live(conn, "/admin/dashboard/document")

      view |> form("#document-kit-upgrade-form", %{"site_id" => site.id}) |> render_submit()

      assert has_element?(view, "#document-kit-upgrade-choice-0", "doc-sidebar")

      assert has_element?(
               view,
               "#document-kit-upgrade-safe",
               "Update #{@components - 1} components"
             )

      html = view |> element("#document-kit-upgrade-safe") |> render_click()

      assert html =~ "1 component left for you to decide on"
      assert component!(site, "doc-sidebar").template == @mine

      view |> element("#document-kit-upgrade-all") |> render_click()

      refute component!(site, "doc-sidebar").template == @mine

      assert VersionHelpers.version_with_changes(
               Component.Version,
               edited.id,
               %{template: @mine},
               tenant: site.id
             ),
             "the admin cannot restore what the update replaced"

      close(view)
    end

    # THE PAGES ARE WIRED TO THE SAME CHECK, and a page is the one thing this may not write: a site
    # serving `/:lang/docs` from before the pages were rewritten is offered a DRAFT of it, and the
    # row its readers are on stays exactly where it is.
    test "offers a page the site is behind on as a draft, and writes nothing live", %{
      conn: conn,
      site: site
    } do
      aged =
        site
        |> page!("/:lang/docs")
        |> Ash.update!(%{template: @mine},
          action: :master_update,
          authorize?: false,
          tenant: site.id
        )

      {:ok, view, _html} = live(conn, "/admin/dashboard/document")

      view |> form("#document-kit-upgrade-form", %{"site_id" => site.id}) |> render_submit()

      assert has_element?(view, "#document-kit-upgrade-pages-behind-0", "/:lang/docs")
      assert drafts(site, aged) == []

      html = view |> element("#document-kit-upgrade-pages-offer") |> render_click()

      assert html =~ "Created 1 draft"

      assert [draft] = drafts(site, aged)
      assert draft.label == "Documentation sample page"
      assert draft.source_page_id == aged.id

      assert page!(site, "/:lang/docs").template == @mine,
             "the admin's live page was written over"

      refute has_element?(view, "#document-kit-upgrade-pages-offer")
      assert [_one] = drafts(site, aged)

      close(view)
    end

    test "cannot be pointed at a site the page never offered", %{conn: conn, site: site} do
      age!(site)

      {:ok, view, _html} = live(conn, "/admin/dashboard/document")

      html = render_submit(view, "kit_check", %{"site_id" => Ash.UUID.generate()})

      assert html =~ "That is not a site this page can update."
      refute has_element?(view, "#document-kit-upgrade-report")

      close(view)
    end
  end

  describe "a writer who may not" do
    setup %{site: site} do
      set_up!(site)
      age!(site)

      :ok
    end

    test "is not offered the icon or the modal, and is refused every event anyway", %{
      conn: conn,
      site: site
    } do
      writer = create_user_with_permissions!(["admin:dashboard:document:workspace"])
      {:ok, view, _html} = live(log_in(conn, writer), "/admin/dashboard/document")

      refute has_element?(view, "#document-kit-upgrade-open")
      refute has_element?(view, "#document-kit-upgrade")

      assert render_submit(view, "kit_check", %{"site_id" => site.id}) =~ "not allowed"
      assert render_click(view, "kit_upgrade", %{"mode" => "all"}) =~ "not allowed"
      assert render_click(view, "page_drafts", %{}) =~ "not allowed"

      assert component!(site, "doc-section").extra["ui_kit_version"] == "0.0.1"

      close(view)
    end
  end

  # WHAT THE DASHBOARD NO LONGER CARRIES. Two cards sat under the tables of every site that was
  # already set up — one offering to install what was installed, one offering to compare — and a
  # dashboard is for the extension's own work. They are one modal now, behind one icon beside
  # Settings, and a set-up site's dashboard says nothing about either until it is asked.
  describe "the header icon" do
    setup %{conn: conn, site: site} do
      set_up!(site)

      {:ok, conn: log_in(conn, admin_with!("docicon@example.com", "*"))}
    end

    test "is the only way to either of them on a site that is set up", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/admin/dashboard/document")

      assert has_element?(view, "#document-kit-upgrade-open")

      refute has_element?(view, "#document-provision-badge"),
             "a site that is set up was warned that it was not"

      # NEITHER FORM IS ON THE PAGE ON ITS OWN. Both are inside the modal, which is the change:
      # a descendant selector is the only thing that can tell the two apart.
      assert has_element?(view, "#document-kit-upgrade-doctor #document-kit-upgrade-form")
      assert has_element?(view, "#document-kit-upgrade-doctor #document-provision-form")
      assert has_element?(view, "#document-provision-submit", "Repair")

      close(view)
    end

    # A TENANT ADMIN IS NOT OFFERED A CHOICE, and was shown nothing at all where the choice would
    # be — so the modal's buttons named no site. Their own is the only one this page will ever
    # write to, and now it says which one that is.
    test "shows a tenant admin their own site, and no picker", %{conn: conn, site: site} do
      tenant = create_user_with_permissions!(["admin:dashboard:*"], site_id: site.id)

      {:ok, view, _html} = live(log_in(conn, tenant, false), "/admin/dashboard/document")

      assert has_element?(view, "#document-kit-upgrade-site-fixed", site.name)

      refute has_element?(view, "#document-kit-upgrade-site"),
             "a tenant admin was offered a choice of sites"

      close(view)
    end

    # ONE PICKER FOR BOTH HALVES. The Repair button has no select of its own, so a master who reads
    # one site's standings and presses Repair must write to that site and not to the one the
    # dashboard opened on.
    test "hands Repair the site whose standings are on screen", %{conn: conn} do
      other = create_site!(name: "docsecond", host: "docsecond.test", active: true)

      {:ok, view, _html} = live(conn, "/admin/dashboard/document")

      view |> form("#document-kit-upgrade-form", %{"site_id" => other.id}) |> render_change()

      assert has_element?(
               view,
               ~s(#document-provision-form input[name="site_id"][value="#{other.id}"])
             )

      close(view)
    end

    # THE REDRAW BUTTON IS CORE'S, drawn once the documentation answers for its share cards on the
    # site. The plugin is written to the event's chain by hand, whatever another test left there,
    # and taken off when the test exits, since Mnesia is on disk.
    test "ends with the documentation's Redraw share cards button once it names its cards", %{
      conn: conn
    } do
      event = ShareCard.targets_event()

      {:ok, _} =
        Event.write(%{
          name: ShareCardTargets,
          event: event,
          extension: :mishka_installer,
          status: :started
        })

      :ok = EventHandler.do_compile(event, :start, false)

      on_exit(fn ->
        Event.unregister(:name, ShareCardTargets, false)
        EventHandler.do_compile(event, :start, false)
      end)

      {:ok, view, _html} = live(conn, "/admin/dashboard/document")

      assert has_element?(
               view,
               "#document-kit-upgrade-doctor #document-kit-upgrade-share-cards #document-kit-upgrade-share-cards-redraw"
             )

      close(view)
    end
  end

  describe "a site that has never been set up" do
    setup %{conn: conn} do
      {:ok, conn: log_in(conn, admin_with!("docnokit@example.com", "*"))}
    end

    test "has the badge in its header and no icon, because there is nothing to compare", %{
      conn: conn
    } do
      {:ok, view, _html} = live(conn, "/admin/dashboard/document")

      assert has_element?(view, "#document-provision-first-run")

      view |> element("#document-provision-skip") |> render_click()

      assert has_element?(view, "#document-provision-badge")
      refute has_element?(view, "#document-kit-upgrade-open")

      close(view)
    end

    # THE PRESS CARRIES THE SIGNED-IN ADMIN TO THE INSTALLER, so the installed CMS answers it. The
    # same install asked with nobody behind it is the install wizard's own, which an installed CMS
    # no longer answers: it is refused like an actor holding nothing, and writes nothing.
    test "is set up by the first-run button, and the same install with nobody behind it is refused",
         %{conn: conn, site: site} do
      other = create_site!(name: "wizardlessdocs", host: "wizardlessdocs.test", active: true)

      {:ok, view, _html} = live(conn, "/admin/dashboard/document")

      html = view |> form("#document-provision-form", %{"site_id" => site.id}) |> render_submit()

      assert html =~ "Added"
      assert length(components(site)) == @components
      assert Extensions.installed?(site.id, :mishka_document)

      assert {:error, {:extension_failed, message}} =
               Extensions.install(other.id, "mishka_document")

      assert message =~ "needs these permissions"
      assert components(other) == []

      close(view)
    end

    test "is set up by a site admin pressing it, for their own site whatever the event asks for",
         %{conn: conn, site: site} do
      other = create_site!(name: "otherdocs", host: "otherdocs.test", active: true)
      tenant = create_user_with_permissions!(["*"], site_id: site.id)

      {:ok, view, _html} = live(log_in(conn, tenant, false), "/admin/dashboard/document")

      html = render_submit(view, "extension_install", %{"site_id" => other.id})

      assert html =~ "Added"
      assert length(components(site)) == @components
      assert components(other) == []

      close(view)
    end
  end

  # WHO THE UPDATE IS AUTHORIZED AS. `Update components` wrote through `:master_update` with
  # `authorize?: false` whoever pressed it: the component resource's own policy never ran, and its
  # version history — `belongs_to_actor(:user, …)` — recorded nobody. The dashboard's own gate asks
  # for the areas the set-up writes; the component resource asks for its own. Those are different
  # questions, which is exactly why the resource has to be asked.
  describe "the actor behind the update" do
    setup %{conn: conn, site: site} do
      set_up!(site)
      age!(site)

      {:ok, conn: conn, admin: admin_with!("docactor@example.com", "*")}
    end

    test "is on every version the update writes", %{conn: conn, site: site, admin: admin} do
      {:ok, view, _html} = live(log_in(conn, admin), "/admin/dashboard/document")

      # WHAT THIS CLICK WROTE, and not what the fixture did. `set_up!/1` and `age!/1` both
      # ran with no actor — they are the system, as the seeds are — so their versions carry nobody
      # by design, and a test that swept them in would be asserting the opposite of the point.
      before = MapSet.new(component_versions(site), & &1.id)

      view |> form("#document-kit-upgrade-form", %{"site_id" => site.id}) |> render_submit()
      view |> element("#document-kit-upgrade-safe") |> render_click()

      written = Enum.reject(component_versions(site), &MapSet.member?(before, &1.id))

      refute written == [], "the update wrote no component versions at all"

      assert Enum.all?(written, &(&1.user_id == admin.id)),
             "a component this admin updated is attributed to nobody in its own history"

      close(view)
    end

    test "is refused before its first write when they hold none of what it writes", %{
      site: site
    } do
      weak = create_user_with_permissions!(["admin:dashboard:document:workspace"])

      assert_raise ArgumentError, ~r/setting up an extension needs/, fn ->
        Provision.ensure!(site.id, %{}, actor: weak)
      end
    end
  end

  # THE AUDIT TRAIL AS POSTGRES HOLDS IT. Read through the repo rather than back through Ash: what
  # is on trial here is what the WRITE recorded, and a read that went through the same framework
  # could answer with the same actor assumption the write is being asked about.
  # JOINED THROUGH THE COMPONENT, not filtered on the version's own `site_id`. A master action is
  # required to carry no tenant — `TenantContext` says so — and the version row takes its site from
  # the tenant, so a master's version has none. Which component it is about is never in doubt.
  defp component_versions(site) do
    %{rows: rows} =
      MishkaDocument.Repo.query!(
        """
        SELECT v.id::text, v.user_id::text
        FROM component_versions v
        JOIN components c ON c.id = v.version_source_id
        WHERE c.site_id = $1
        """,
        [Ecto.UUID.dump!(site.id)]
      )

    Enum.map(rows, fn [id, user_id] -> %{id: id, user_id: user_id} end)
  end

  defp admin_with!(email, permission) do
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
    |> Ash.Changeset.force_change_attribute(:permission_id, permission!(permission).id)
    |> Ash.create!(authorize?: false)

    user
  end

  defp permission!(name) do
    case Permission |> Ash.Query.filter(name == ^name) |> Ash.read_one(authorize?: false) do
      {:ok, nil} ->
        Permission
        |> Ash.Changeset.for_create(:create, %{name: name}, authorize?: false)
        |> Ash.create!()

      {:ok, found} ->
        found
    end
  end

  # Signs `user` in with the token it was issued. Who is a master is read from that token alone —
  # issued with no site, on the master site's address — so `master_mode` only stands for the choice
  # the sign-in page would have kept, and changes nothing once someone is signed in.
  defp log_in(conn, user, master_mode \\ true) do
    conn
    |> Plug.Test.init_test_session(%{})
    |> Plug.Conn.put_session(:master_mode, master_mode)
    |> AshAuthentication.Plug.Helpers.store_in_session(user)
  end

  # The dashboard's figures and its workspaces table load in `start_async/3`; a view stopped while
  # one is in flight raises on the way down once the test's sandbox owner is gone.
  defp close(view) do
    render_async(view, 5_000)
    ref = Process.monitor(view.pid)
    GenServer.stop(view.pid, :normal)
    assert_receive {:DOWN, ^ref, :process, _pid, _reason}
  end
end
