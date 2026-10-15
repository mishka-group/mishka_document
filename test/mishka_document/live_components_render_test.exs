defmodule MishkaDocument.LiveComponentsRenderTest do
  @moduledoc """
  The document's live components, compiled by the real runtime and driven on a real page.

  The component goes through `MishkaCmsCore.Runtime.Compilers.ComponentCompiler`, is reached the way
  a page reaches it — `LiveViewHelpers.component/1`, off the stored `<.component component_name="…"/>`
  rather than a `<.live_component>` a test wrote — and is then read the way a visitor would read it.

  ## What these five have to agree about

  A documentation page is four of them side by side, and they agree on nothing by sharing code: a
  stored component has nothing to share it through. So the agreements are pinned here instead —
  `doc-toc`'s anchors against the ids `doc-section` writes, every one of them against the same
  version when `?v=` names one, and every one of them refusing the same draft.
  """
  use MishkaDocument.ConnCase, async: false

  import Phoenix.LiveViewTest
  import MishkaDocument.Test.Factory
  import Phoenix.Component, only: [sigil_H: 2]

  alias MishkaCmsCore.Runtime.Compilers.Helpers, as: CompilerHelpers
  alias MishkaCmsCore.Runtime.Handlers.ModuleCompilerHandler
  alias MishkaCmsCore.Runtime.LiveViewHelpers
  alias MishkaCmsCore.Runtime.States.{SettingsState, SiteState}
  alias MishkaCmsCore.Runtime.Translations
  alias MishkaDocument.Test.Plugins.PageExtras
  alias MishkaInstaller.Event.{Event, EventHandler, ModuleStateCompiler}

  require Ash.Query

  @moduletag :integration

  @extras_event "document:page:extras"

  # A UNIQUE SITE NAME PER TEST, and it is not tidiness. A component's runtime module is named from
  # a hash of (component name, SITE NAME) and is cached in the VM's code table for the rest of the
  # run — while the module carries the site's ID, read from the row it was compiled against. Reuse
  # one name across tests and the second test renders the FIRST test's module, which points at a
  # site id that test rolled back: every list comes back empty with nothing to say why.
  #
  # Production never meets this — a site's name is stable and its id does not change under it — but
  # a suite that rolls back between tests does.
  setup do
    SiteState.clear()
    name = "docville#{System.unique_integer([:positive])}"
    site = create_site!(name: name, host: "#{name}.test", active: true)

    SiteState.save(%{
      id: site.id,
      name: site.name,
      host: site.host,
      priority: site.priority,
      active: site.active,
      master: site.master
    })

    on_exit(fn -> SiteState.clear() end)

    {:ok, _installed} = MishkaDocument.Kit.install!(site.id)

    # The test process renders for this site, as a page on it would — `cold/2` draws in it. A site's
    # component is drawn only where that site is the one being rendered: see
    # `LiveViewHelpers.component/1`.
    :ok = Translations.put_site(site.id)

    {:ok, site: site}
  end

  # THE WAY A PAGE REACHES IT. A page's stored template says `<.component component_name="…"/>` and
  # `LiveViewHelpers.component/1` is what forks on the compiled shape and builds the
  # `%Phoenix.LiveView.Component{}`. Calling `<.live_component>` here would skip that fork, which is
  # the half of the feature most likely to break and the half this test exists for.
  defmodule Host do
    use Phoenix.LiveView

    # IT RENDERS FOR THE SITE, as `MishkaCmsWeb.RuntimeLive` does, once for the dead render and again
    # in the socket's own process.
    def mount(_params, session, socket) do
      :ok = Translations.put_site(session["site_id"])

      {:ok,
       Phoenix.Component.assign(socket,
         blocks: session["blocks"] || [],
         site: session["site"],
         missing: false
       )}
    end

    # WHAT `MishkaCmsWeb.RuntimeLive` IS TOLD when a block finds nothing at the address it was
    # handed, once the socket is connected; it answers with the site's 404.
    def handle_info(:mishka_runtime_not_found, socket),
      do: {:noreply, Phoenix.Component.assign(socket, :missing, true)}

    # THE PAGE AROUND A BLOCK CHANGING UNDER IT, which is what a patch to another URL is. A live
    # component is redrawn when the assigns its parent hands it change, and nothing else redraws it:
    # this is the moment `update_many/1` puts those assigns back on the socket and `update/2` runs
    # over them again, on top of whatever the reader has done to the block since it mounted.
    def handle_info({:params, params}, socket) do
      blocks =
        Enum.map(socket.assigns.blocks, fn block ->
          Map.put(block, "attrs", Map.put(block["attrs"], :params, params))
        end)

      {:noreply, Phoenix.Component.assign(socket, :blocks, blocks)}
    end

    # AND THE SAME FOR A SETTING RATHER THAN A URL, which is what an author changing one in the
    # Inspector does to the block under it.
    def handle_info({:attrs, id, attrs}, socket) do
      blocks =
        Enum.map(socket.assigns.blocks, fn block ->
          (block["id"] == id && Map.put(block, "attrs", Map.merge(block["attrs"], attrs))) ||
            block
        end)

      {:noreply, Phoenix.Component.assign(socket, :blocks, blocks)}
    end

    def render(assigns) do
      ~H"""
      <div id="host">
        <p :if={@missing} id="runtime-not-found"></p>
        <div :for={block <- @blocks}>
          {LiveViewHelpers.component(
            Map.merge(block["attrs"], %{
              component_name: block["name"],
              site: @site,
              id: block["id"]
            })
          )}
        </div>
      </div>
      """
    end
  end

  # EVERY READ OF A MOUNTED PAGE WAITS FOR THE BLOCKS ON IT, because four of the five now read in
  # the background: a connected socket takes the `start_async/3` branch, so the first render is the
  # skeleton and the rows arrive in the message after it. `render_async/2` waits on the tasks
  # themselves — it is not a sleep, and a block that never starts one is answered immediately.
  @async 5_000

  defp mount_page(site, name, attrs \\ %{}),
    do: mount_blocks(site, [%{"name" => name, "id" => "one", "attrs" => attrs}])

  defp mount_blocks(site, blocks) do
    {:ok, view, _first_paint} =
      live_isolated(Phoenix.ConnTest.build_conn(), Host,
        session: %{"blocks" => blocks, "site" => site.name, "site_id" => site.id}
      )

    {:ok, view, render_async(view, @async)}
  end

  # THE FIRST PAINT AS WELL AS WHAT ARRIVES AFTER IT, for the cases that are about the difference.
  defp mount_raw(site, blocks) do
    {:ok, view, first_paint} =
      live_isolated(Phoenix.ConnTest.build_conn(), Host,
        session: %{"blocks" => blocks, "site" => site.name, "site_id" => site.id}
      )

    {view, first_paint}
  end

  defp roles(html, role),
    do:
      html
      |> LazyHTML.from_fragment()
      |> LazyHTML.query(~s([data-role="#{role}"]))
      |> Enum.count()

  defp cold(site, name, attrs \\ %{}) do
    attrs
    |> Map.merge(%{component_name: name, site: site.name, id: "cold"})
    |> LiveViewHelpers.static_component()
    |> Phoenix.HTML.Safe.to_iodata()
    |> IO.iodata_to_binary()
  end

  # A READ THAT ANSWERS WITH AN ERROR, which is what a read the database refuses looks like. A
  # block's FIRST read is in step with the page, so this is how a first read fails.
  defp refuse!(site, name) do
    kept = site |> component_row(name) |> Map.fetch!(:helpers) |> Enum.map(&helper_map/1)

    refused =
      Enum.map(kept, fn helper ->
        case helper.name do
          "fetch" -> %{helper | args: "_asked", code: "{:error, :refused}"}
          _left_alone -> helper
        end
      end)

    refute refused == kept, "#{name} has no fetch/1, so nothing was refused"

    write_helpers!(site, name, refused)

    kept
  end

  # A READ THAT FAILS WITHOUT RAISING: a component that names no site asks for documents of no
  # tenant, which Ash refuses with `{:error, _}`.
  defp unsited!(site, name) do
    helpers =
      site
      |> component_row(name)
      |> Map.fetch!(:helpers)
      |> Enum.map(&helper_map/1)
      |> Enum.map(fn
        %{name: "site_id"} = helper -> %{helper | code: "nil"}
        helper -> helper
      end)

    write_helpers!(site, name, helpers)
    recompile!(site, name)
  end

  defp helper_map(helper),
    do: Map.take(helper, [:name, :args, :code, :attrs, :slots, :discriminators])

  defp component_row(site, name) do
    MishkaCmsCore.Runtime.Component
    |> Ash.Query.for_read(:read_any, %{}, authorize?: false)
    |> Ash.Query.filter(name == ^name and site_id == ^site.id)
    |> Ash.read_one!()
  end

  # `page_code: :package` FOR THE REASON `Validations.CodeChange` GIVES: helpers are author-written
  # Elixir, and writing them needs `admin:dashboard:runtime:component` or `admin:dashboard:code` —
  # unless what is writing is a package, which is how `UiKitHandler.install_kit!/2` puts these very
  # helpers there in the first place. This writes the kit's own code back in the kit's own shape, so
  # it announces itself the same way.
  defp write_helpers!(site, name, helpers) do
    site
    |> component_row(name)
    |> Ash.update!(%{helpers: helpers},
      action: :master_update,
      authorize?: false,
      tenant: site.id,
      context: %{page_code: :package}
    )
  end

  # THE ROW IS NOT THE MODULE. A component is compiled once per (name, site) and kept in the VM's
  # code table, so editing the row changes nothing until something rebuilds it — which is what the
  # admin's own save does through `MishkaCmsCore.Runtime.Workers.RuntimeCompilerWorker`.
  defp recompile!(site, name) do
    {:ok, _module} =
      ModuleCompilerHandler.compile_or_return_module(
        CompilerHelpers.module_name(name, site.name, "Component"),
        name,
        site.name,
        site.id,
        :update
      )

    :ok
  end

  defp text_of(view, selector) do
    view
    |> render_async(@async)
    |> LazyHTML.from_fragment()
    |> LazyHTML.query(selector)
    |> Enum.map(&(&1 |> LazyHTML.text() |> String.trim()))
  end

  defp drawn(view, selector) do
    view
    |> render_async(@async)
    |> LazyHTML.from_fragment()
    |> LazyHTML.query(selector)
  end

  defp hrefs(view, selector) do
    view
    |> render_async(@async)
    |> LazyHTML.from_fragment()
    |> LazyHTML.query(selector)
    |> Enum.map(&LazyHTML.attribute(&1, "href"))
    |> List.flatten()
  end

  defp ids_of(view, selector) do
    view
    |> render_async(@async)
    |> LazyHTML.from_fragment()
    |> LazyHTML.query(selector)
    |> Enum.map(&LazyHTML.attribute(&1, "id"))
    |> List.flatten()
  end

  defp bundle_components,
    do:
      MishkaDocument.Kit.bundle_path()
      |> File.read!()
      |> Jason.decode!()
      |> Map.fetch!("components")

  # WHAT IT ASKED THE DATABASE FOR, off the repo's own telemetry — the only place a read whose
  # answer nothing renders leaves a mark.
  defp queries_while(fun) do
    handler = "queries-#{System.unique_integer([:positive])}"
    listener = self()

    :telemetry.attach(
      handler,
      [:mishka_document, :repo, :query],
      fn _event, _measurements, metadata, _config ->
        send(listener, {handler, metadata.query})
      end,
      nil
    )

    try do
      fun.()
      drain(handler, [])
    after
      :telemetry.detach(handler)
    end
  end

  defp drain(handler, gathered) do
    receive do
      {^handler, query} -> drain(handler, [query | gathered])
    after
      0 -> gathered
    end
  end

  # ---- fixtures -------------------------------------------------------------------------------

  defp document!(site, opts) do
    create_workspace!(
      Keyword.merge(
        [site_id: site.id, status: :active, language: "en", skip_version: true],
        opts
      )
    )
  end

  defp version!(site, document, opts) do
    create_workspace_version!(
      Keyword.merge(
        [
          site_id: site.id,
          workspace_id: document.id,
          status: :stable,
          is_latest_for_version: false,
          published_at: ~U[2026-01-01 00:00:00Z]
        ],
        opts
      )
    )
  end

  defp page!(site, version, opts) do
    create_section!(
      Keyword.merge(
        [
          site_id: site.id,
          workspace_version_id: version.id,
          content_review_status: :approved,
          technical_review_status: :approved,
          language: "en",
          content: "<p>Body</p>"
        ],
        opts
      )
    )
  end

  defp note!(site, page, opts) do
    create_note!(
      Keyword.merge(
        [
          site_id: site.id,
          section_id: page.id,
          content_review_status: :approved,
          technical_review_status: :approved,
          content: "<p>Note body</p>"
        ],
        opts
      )
    )
  end

  # One document, one published version, four pages in order — what nearly every case below wants.
  #
  # "Appendix" is last and sorts first, on purpose: every other title here happens to be in
  # alphabetical order, so without one page whose place and whose name disagree, a component that
  # ignored `order_position` altogether would pass every ordering assertion in this file.
  defp manual!(site) do
    document = document!(site, name: "Mishka CMS", slug: "mishka-cms", description: "The manual.")
    version = version!(site, document, version_number: "1.0.0", is_latest_for_version: true)

    pages =
      for {title, slug, order} <- [
            {"Getting started", "getting-started", 0},
            {"Installation", "installation", 1},
            {"Upgrading", "upgrading", 2},
            {"Appendix", "appendix", 3}
          ] do
        page!(site, version,
          title: title,
          slug: slug,
          order_position: order,
          content: "<h2>#{title}</h2><p>Body of #{title}.</p>"
        )
      end

    %{document: document, version: version, pages: pages}
  end

  # A DOCUMENT WITH AN ADDRESS OF ITS OWN is read there by every block a page at that address holds,
  # and nowhere else: its slug under /docs names nothing. Every link written to it or to a page of it
  # is under that address — never /docs/<slug> — with no ?lang=, since the address is one edition's. A page's address holds the pages it is filed
  # under (`MishkaDocument.Address`).
  describe "a document with an address of its own" do
    test "is read at it, and every link to a page of it is under it", %{site: site} do
      addressed!(site)

      {:ok, view, _html} =
        mount_page(site, "doc-section", %{
          path: "/mishka/docs",
          lang_param: "",
          params: %{"section" => "installation/from-source"}
        })

      assert text_of(view, ~s([data-role="doc-section-title"])) == ["From source"]
      assert hrefs(view, ~s([data-role="doc-section-crumb"])) == ["/mishka/docs/installation"]
      assert hrefs(view, ~s([data-role="doc-section-prev"])) == ["/mishka/docs/installation"]
      assert hrefs(view, ~s([data-role="doc-section-next"])) == ["/mishka/docs/upgrading"]
    end

    test "draws its front page at the address, its pages under it", %{site: site} do
      addressed!(site)

      {:ok, view, _html} =
        mount_page(site, "doc-section", %{path: "/mishka/docs", lang_param: "", params: %{}})

      assert text_of(view, ~s([data-role="doc-landing-title"])) == ["Mishka CMS"]

      assert hrefs(view, ~s([data-role="doc-landing-link"])) == [
               "/mishka/docs/installation",
               "/mishka/docs/upgrading"
             ]
    end

    test "is listed and linked at its address, with no language written onto it",
         %{site: site} do
      addressed!(site)

      {:ok, list, _html} = mount_page(site, "doc-workspace-list", %{per_page: 10})
      assert hrefs(list, ~s([data-role="doc-list-title"])) == ["/mishka/docs"]

      {:ok, contents, _html} =
        mount_page(site, "doc-sidebar", %{path: "/mishka/docs", lang_param: "", expand_all: true})

      assert hrefs(contents, ~s([data-role="doc-sidebar-link"])) == [
               "/mishka/docs/installation",
               "/mishka/docs/installation/from-source",
               "/mishka/docs/upgrading"
             ]
    end

    test "keeps a page filed under another inside its parent's address, in every block",
         %{site: site} do
      addressed!(site)

      attrs = %{
        path: "/mishka/docs",
        lang_param: "",
        params: %{"section" => "installation/from-source"}
      }

      {:ok, contents, _html} = mount_page(site, "doc-sidebar", attrs)

      assert hrefs(contents, ~s([data-role="doc-sidebar-link"][aria-current="page"])) == [
               "/mishka/docs/installation/from-source"
             ]

      {:ok, toc, _html} = mount_page(site, "doc-toc", attrs)
      assert text_of(toc, ~s([data-role="doc-toc-link"])) == ["Clone", "Build"]

      {:ok, switch, _html} = mount_page(site, "doc-switcher", Map.put(attrs, :show, "version"))

      # The older version has no "From source", so its entry leads to its front page.
      assert hrefs(switch, ~s([data-role="doc-switcher-version"])) == [
               "/mishka/docs/installation/from-source",
               "/mishka/docs?v=0.9.0"
             ]
    end

    test "answers a page filed under another only at its whole address", %{site: site} do
      addressed!(site)

      assert_raise MishkaCmsCore.ErrorsExceptions.NotFoundError, fn ->
        mount_page(site, "doc-section", %{
          path: "/mishka/docs",
          lang_param: "",
          params: %{"section" => "from-source"}
        })
      end
    end

    test "and an address no document is read at is a missing page", %{site: site} do
      addressed!(site)

      assert_raise MishkaCmsCore.ErrorsExceptions.NotFoundError, fn ->
        mount_page(site, "doc-section", %{path: "/nothing/here", lang_param: "", params: %{}})
      end
    end

    test "but a document an author pinned wins over the address", %{site: site} do
      addressed!(site)
      document!(site, name: "Other", slug: "other")

      {:ok, view, _html} =
        mount_page(site, "doc-section", %{
          workspace: "mishka-cms",
          path: "/nothing/here",
          params: %{}
        })

      assert text_of(view, ~s([data-role="doc-landing-title"])) == ["Mishka CMS"]
    end

    test "is a missing page at /docs/<its slug>, and the blocks beside it draw none of it",
         %{site: site} do
      addressed!(site)

      under_base = %{
        workspace_param: "workspace",
        section_param: "section",
        lang_param: "",
        doc_base: "/docs",
        params: %{"workspace" => "mishka-cms", "section" => "installation"}
      }

      assert_raise MishkaCmsCore.ErrorsExceptions.NotFoundError, fn ->
        mount_page(site, "doc-section", under_base)
      end

      {:ok, contents, _html} = mount_page(site, "doc-sidebar", under_base)
      assert hrefs(contents, ~s([data-role="doc-sidebar-link"])) == []

      {:ok, toc, _html} = mount_page(site, "doc-toc", under_base)
      assert text_of(toc, ~s([data-role="doc-toc-link"])) == []

      {:ok, switch, _html} =
        mount_page(site, "doc-switcher", Map.put(under_base, :show, "version"))

      assert hrefs(switch, ~s([data-role="doc-switcher-version"])) == []
    end

    test "tells apart two pages of the same name under two parents", %{site: site} do
      %{version: version} = addressed!(site)
      page!(site, version, title: "Tabs", slug: "tabs", order_position: 2)
      headless = page!(site, version, title: "Headless", slug: "headless", order_position: 3)

      page!(site, version,
        title: "Headless tabs",
        slug: "tabs",
        order_position: 0,
        parent_section_id: headless.id
      )

      for {address, title} <- [{"tabs", "Tabs"}, {"headless/tabs", "Headless tabs"}] do
        {:ok, view, _html} =
          mount_page(site, "doc-section", %{
            path: "/mishka/docs",
            lang_param: "",
            params: %{"section" => address}
          })

        assert text_of(view, ~s([data-role="doc-section-title"])) == [title]
      end
    end
  end

  # A VERSION'S FRONT PAGE IS DRAWN AT ITS DOCUMENT'S OWN ADDRESS, in place of the landing: every
  # block reads it there, every link to it is that address with no trailing slash, the pages filed
  # under it sit directly under the address, and the address with its slug after it is a missing
  # page (`MishkaDocument.Address`).
  describe "a document with a front page" do
    test "draws it at the document's own address, in place of the landing", %{site: site} do
      fronted!(site, path: "/mishka/docs")

      {:ok, view, _html} =
        mount_page(site, "doc-section", %{path: "/mishka/docs", lang_param: "", params: %{}})

      assert text_of(view, ~s([data-role="doc-section-title"])) == ["Get started"]
      assert text_of(view, ~s([data-role="doc-section-landing"])) == []
      assert [body] = text_of(view, ~s([data-role="doc-section-body"]))
      assert body =~ "Welcome."
      assert hrefs(view, ~s([data-role="doc-section-next"])) == ["/mishka/docs/install"]
    end

    test "marks it as the page being read in the contents, linked at the address", %{site: site} do
      fronted!(site, path: "/mishka/docs")
      attrs = %{path: "/mishka/docs", lang_param: "", params: %{}}

      {:ok, contents, _html} = mount_page(site, "doc-sidebar", Map.put(attrs, :expand_all, true))

      assert hrefs(contents, ~s([data-role="doc-sidebar-link"])) == [
               "/mishka/docs",
               "/mishka/docs/install",
               "/mishka/docs/upgrading"
             ]

      assert hrefs(contents, ~s([data-role="doc-sidebar-link"][aria-current="page"])) == [
               "/mishka/docs"
             ]

      {:ok, toc, _html} = mount_page(site, "doc-toc", attrs)
      assert text_of(toc, ~s([data-role="doc-toc-link"])) == ["Why", "How"]

      {:ok, switch, _html} = mount_page(site, "doc-switcher", Map.put(attrs, :show, "version"))

      assert hrefs(switch, ~s([data-role="doc-switcher-version"])) == [
               "/mishka/docs",
               "/mishka/docs?v=0.9.0"
             ]
    end

    test "files the pages under it directly under the address, and leads back to it",
         %{site: site} do
      fronted!(site, path: "/mishka/docs")

      {:ok, view, _html} =
        mount_page(site, "doc-section", %{
          path: "/mishka/docs",
          lang_param: "",
          params: %{"section" => "install"}
        })

      assert text_of(view, ~s([data-role="doc-section-title"])) == ["Install"]
      assert hrefs(view, ~s([data-role="doc-section-crumb"])) == ["/mishka/docs"]
      assert hrefs(view, ~s([data-role="doc-section-prev"])) == ["/mishka/docs"]
      assert hrefs(view, ~s([data-role="doc-section-next"])) == ["/mishka/docs/upgrading"]
    end

    test "has no address of its own under the document's", %{site: site} do
      fronted!(site, path: "/mishka/docs")

      for section <- ["get-started", "get-started/install"] do
        assert_raise MishkaCmsCore.ErrorsExceptions.NotFoundError, fn ->
          mount_page(site, "doc-section", %{
            path: "/mishka/docs",
            lang_param: "",
            params: %{"section" => section}
          })
        end
      end

      {:ok, toc, _html} =
        mount_page(site, "doc-toc", %{
          path: "/mishka/docs",
          lang_param: "",
          params: %{"section" => "get-started"}
        })

      assert text_of(toc, ~s([data-role="doc-toc-link"])) == []
    end

    test "is linked at /docs/<slug> for a document with no address", %{site: site} do
      fronted!(site, [])

      attrs = %{
        doc_base: "/docs",
        lang_param: "",
        params: %{"workspace" => "fronted"}
      }

      {:ok, view, _html} = mount_page(site, "doc-section", attrs)
      assert text_of(view, ~s([data-role="doc-section-title"])) == ["Get started"]

      {:ok, contents, _html} = mount_page(site, "doc-sidebar", Map.put(attrs, :expand_all, true))

      assert hrefs(contents, ~s([data-role="doc-sidebar-link"])) == [
               "/docs/fronted",
               "/docs/fronted/install",
               "/docs/fronted/upgrading"
             ]

      {:ok, child, _html} =
        mount_page(site, "doc-section", put_in(attrs, [:params, "section"], "install"))

      assert hrefs(child, ~s([data-role="doc-section-crumb"])) == ["/docs/fronted"]
    end

    test "and a version with none keeps the landing", %{site: site} do
      %{front: front} = fronted!(site, path: "/mishka/docs")

      front
      |> Ash.Changeset.for_update(:update, %{front_page: false},
        tenant: site.id,
        authorize?: false
      )
      |> Ash.update!()

      {:ok, view, _html} =
        mount_page(site, "doc-section", %{path: "/mishka/docs", lang_param: "", params: %{}})

      assert text_of(view, ~s([data-role="doc-landing-title"])) == ["Fronted"]
      assert text_of(view, ~s([data-role="doc-section-title"])) == []
    end
  end

  # A CALLOUT IS PLACED INSIDE A PAGE'S TEXT, as the content editor stores it: a marker inside a
  # paragraph around a line, or a marker on its own around paragraphs and lists. `rich_content`
  # draws it as `doc-callout`, in the tone the marker names.
  describe "doc-callout in a page's text" do
    # THE RUNTIME DRAWS A MARKER'S COMPONENT ONLY BY A NAME `SiteState` KNOWS for the site, which a
    # booted site holds for every component it has and this suite's hand-saved one does not.
    defp callout_page!(site, content) do
      :ok = SiteState.put_component(site.id, "doc-callout")
      on_exit(fn -> SiteState.delete_component(site.id, "doc-callout") end)

      %{version: version} = manual!(site)

      page!(site, version,
        title: "Callouts",
        slug: "callouts",
        order_position: 9,
        content: content
      )

      {:ok, view, _html} =
        mount_page(site, "doc-section", %{
          workspace: "mishka-cms",
          params: %{"section" => "callouts"}
        })

      view
      |> render_async(@async)
      |> LazyHTML.from_fragment()
      |> LazyHTML.query(~s([data-role="doc-section-body"]))
    end

    test "draws a marker inside a paragraph as the callout, around its line", %{site: site} do
      body =
        callout_page!(
          site,
          ~s(<p>Before.</p><p>[[component doc-callout tone="tip"]]Use <code>mix</code>[[/component]]</p>)
        )

      assert [callout] = Enum.to_list(LazyHTML.query(body, ~s([data-role="doc-callout"])))
      assert LazyHTML.attribute(callout, "data-tone") == ["tip"]
      assert LazyHTML.query(callout, ~s([data-role="doc-callout-title"])) |> Enum.count() == 0

      assert callout
             |> LazyHTML.query(~s([data-role="doc-callout-body"] > code))
             |> LazyHTML.text() == "mix"

      assert LazyHTML.query(body, ~s(p [data-role="doc-callout"])) |> Enum.count() == 0
    end

    test "draws a marker on its own around paragraphs and a list", %{site: site} do
      body =
        callout_page!(
          site,
          ~s([[component doc-callout tone="warning" title="Heads up"]]) <>
            "<p>One.</p><ul><li>Two.</li><li>Three.</li></ul>[[/component]]"
        )

      assert [callout] = Enum.to_list(LazyHTML.query(body, ~s([data-role="doc-callout"])))
      assert LazyHTML.attribute(callout, "data-tone") == ["warning"]

      assert callout
             |> LazyHTML.query(~s([data-role="doc-callout-title"]))
             |> LazyHTML.text()
             |> String.trim() == "Heads up"

      inner = LazyHTML.query(callout, ~s([data-role="doc-callout-body"]))
      assert inner |> LazyHTML.query("p") |> LazyHTML.text() == "One."
      assert inner |> LazyHTML.query("ul > li") |> Enum.count() == 2
    end

    test "is a note when the marker names no tone", %{site: site} do
      body = callout_page!(site, "<p>[[component doc-callout]]Plain.[[/component]]</p>")

      assert body
             |> LazyHTML.query(~s([data-role="doc-callout"]))
             |> LazyHTML.attribute("data-tone") == ["note"]
    end
  end

  # AN EXAMPLE IS PLACED INSIDE A PAGE'S TEXT around the markers of the components it shows, and
  # drawn on the page itself, where its components' scripts run: a toolbar over it turns its
  # direction and opens a still preview of it, a frame the hook fills with a copy of the example
  # under the site's stylesheet when it opens. Nothing of the preview's page is drawn with the page.
  describe "doc-example in a page's text" do
    # THE RUNTIME DRAWS A MARKER'S COMPONENT ONLY BY A NAME `SiteState` KNOWS for the site, which a
    # booted site holds for every component it has and this suite's hand-saved one does not.
    defp example_page!(site, content, inside \\ ["doc-callout"]) do
      {_page, article} = example_page_of!(site, content, inside)
      LazyHTML.query(article, ~s([data-role="doc-section-body"]))
    end

    defp example_page_of!(site, content, inside, notes \\ []) do
      for name <- ["doc-example" | inside] do
        :ok = SiteState.put_component(site.id, name)
        on_exit(fn -> SiteState.delete_component(site.id, name) end)
      end

      %{version: version} = manual!(site)

      page =
        page!(site, version,
          title: "Examples",
          slug: "examples",
          order_position: 9,
          content: content
        )

      for {note, place} <- Enum.with_index(notes) do
        note!(site, page, title: "Note #{place}", order_position: place, content: note)
      end

      {:ok, view, _html} =
        mount_page(site, "doc-section", %{
          workspace: "mishka-cms",
          params: %{"section" => "examples"},
          show_notes: true
        })

      {page,
       view
       |> render_async(@async)
       |> LazyHTML.from_fragment()
       |> LazyHTML.query(~s([data-role="doc-section-article"]))}
    end

    # The element the hook builds the preview in, as drawn: empty, carrying the preview's words.
    defp holder(example),
      do: LazyHTML.query(example, ~s([data-role="doc-example-preview-holder"]))

    defp pressed(example) do
      example
      |> LazyHTML.query(~s([data-role="doc-example-option"]))
      |> Enum.map(fn option ->
        [action] = LazyHTML.attribute(option, "data-action")
        [value] = LazyHTML.attribute(option, "data-value")
        [pressed] = LazyHTML.attribute(option, "aria-pressed")
        {action, value, pressed}
      end)
    end

    defp texts(node, selector) do
      node |> LazyHTML.query(selector) |> Enum.map(&(&1 |> LazyHTML.text() |> String.trim()))
    end

    test "draws the example on the page, and an empty holder its preview is built in when it opens",
         %{site: site} do
      {page, body} =
        example_page_of!(
          site,
          ~s(<p>Before.</p>[[component doc-example title="A tip"]]) <>
            ~s([[component doc-callout tone="tip"]]Use <code>mix</code>[[/component]]) <>
            "[[/component]]",
          ["doc-callout"]
        )

      assert [example] = Enum.to_list(LazyHTML.query(body, ~s([data-role="doc-example"])))
      assert [id] = LazyHTML.attribute(example, "id")
      assert id =~ ~r/\Aone-body-\d+\z/
      assert LazyHTML.attribute(example, "data-frame-theme") == ["dark"]
      assert LazyHTML.attribute(example, "data-frame-device") == ["desktop"]
      assert LazyHTML.attribute(example, "data-frame-dir") == ["ltr"]
      assert texts(example, ~s([data-role="doc-example-title"])) == ["A tip"]

      # On the page: the callout is drawn in the example's body, in the page's own DOM.
      stage = LazyHTML.query(example, ~s([data-role="doc-example-stage"]))
      assert LazyHTML.attribute(stage, "id") == ["#{id}-stage"]
      assert LazyHTML.attribute(stage, "dir") == ["ltr"]

      callout =
        LazyHTML.query(
          stage,
          ~s([data-role="doc-example-body"] > [data-role="doc-callout"])
        )

      assert LazyHTML.attribute(callout, "data-tone") == ["tip"]
      assert texts(callout, ~s([data-role="doc-callout-body"] > code)) == ["mix"]
      assert body |> LazyHTML.query(~s([data-role="doc-callout"])) |> Enum.count() == 1

      assert body
             |> LazyHTML.query(~s|[data-role="doc-section-body"] > p:not([data-role])|)
             |> LazyHTML.text() == "Before."

      # The preview: a dialog the open button names, which the hook builds the first time it opens
      # in an element LiveView leaves to the browser.
      [open] = example |> LazyHTML.query(~s([data-role="doc-example-open"])) |> Enum.to_list()
      assert LazyHTML.attribute(open, "aria-controls") == ["#{id}-preview"]
      assert LazyHTML.attribute(open, "aria-haspopup") == ["dialog"]
      assert texts(open, ~s([data-role="doc-example-open-text"])) == ["Preview"]

      holder = holder(example)
      assert LazyHTML.attribute(holder, "phx-update") == ["ignore"]
      assert [holder_id] = LazyHTML.attribute(holder, "id")
      assert holder_id =~ ~r/\A#{id}-preview-[0-9a-z]+\z/
      assert holder |> LazyHTML.child_nodes() |> Enum.count() == 0

      # It names the page that draws the example alone, which the frame the hook builds is handed
      # as its `src` only when the preview opens, and the words the preview says.
      assert LazyHTML.attribute(holder, "data-src") == [
               "/_preview/doc-example/section/#{page.id}/0"
             ]

      assert LazyHTML.attribute(holder, "data-label") == ["A tip"]
      assert LazyHTML.attribute(holder, "data-toolbar-label") == ["Preview"]
      assert LazyHTML.attribute(holder, "data-frame-label") == ["A tip"]
      assert LazyHTML.attribute(holder, "data-close-text") == ["Close"]

      for drawn <- ~w(dialog iframe) ++ [~s([data-role="doc-example-preview"])] do
        assert body |> LazyHTML.query(drawn) |> Enum.count() == 0
      end

      refute LazyHTML.to_html(body) =~ ~s( src="/_preview/)
    end

    # THE PREVIEW IS THE BROWSER'S ONCE DRAWN, under an id named after the words it is drawn with and
    # the place of its example: drawn again, each keeps its id; another example, or another place,
    # draws another one.
    test "names its preview after the words it is drawn with and its place", %{site: site} do
      content =
        "[[component doc-example]][[component doc-callout]]Same.[[/component]][[/component]]" <>
          "[[component doc-example]][[component doc-callout]]Same.[[/component]][[/component]]" <>
          ~s([[component doc-example title="Named"]][[component doc-callout]]Same.[[/component]]) <>
          "[[/component]]"

      keys = fn body ->
        body
        |> LazyHTML.query(~s([data-role="doc-example"]))
        |> Enum.map(fn example ->
          [id] = LazyHTML.attribute(example, "id")

          [holder] =
            example
            |> LazyHTML.query(~s([data-role="doc-example-preview-holder"]))
            |> LazyHTML.attribute("id")

          String.replace_prefix(holder, "#{id}-preview-", "")
        end)
      end

      drawn = keys.(example_page!(site, content))

      assert [_first, _second, _third] = drawn
      assert drawn |> Enum.uniq() |> length() == 3

      {:ok, view, _html} =
        mount_page(site, "doc-section", %{
          workspace: "mishka-cms",
          params: %{"section" => "examples"}
        })

      again =
        view
        |> render_async(@async)
        |> LazyHTML.from_fragment()
        |> LazyHTML.query(~s([data-role="doc-section-body"]))
        |> keys.()

      assert again == drawn
    end

    # A TALL EXAMPLE IS CUT, but the browser is what knows how tall it is: the root says the height,
    # and the hook marks it collapsible once it has measured the example. The foot's button shows all
    # of it.
    test "carries the height a tall example is cut at, and the button that shows all of it",
         %{site: site} do
      body =
        example_page!(
          site,
          ~s([[component doc-example collapse_height="480" expand_text="All of it"]]) <>
            "[[component doc-callout]]Tall.[[/component]][[/component]]" <>
            ~s([[component doc-example collapse_height="7"]]) <>
            "[[component doc-callout]]Odd.[[/component]][[/component]]"
        )

      examples = LazyHTML.query(body, ~s([data-role="doc-example"]))
      assert LazyHTML.attribute(examples, "data-collapse-height") == ["480", "320"]
      assert LazyHTML.attribute(examples, "data-collapsible") == []

      [first | _second] = Enum.to_list(examples)
      [id] = LazyHTML.attribute(first, "id")

      stage = LazyHTML.query(first, ~s([data-role="doc-example-stage"]))
      assert LazyHTML.attribute(stage, "id") == ["#{id}-stage"]

      button = LazyHTML.query(first, ~s([data-role="doc-example-foot"] > button[type="button"]))
      assert LazyHTML.attribute(button, "data-role") == ["doc-example-expand"]
      assert LazyHTML.attribute(button, "aria-expanded") == ["false"]
      assert LazyHTML.attribute(button, "aria-controls") == ["#{id}-stage"]

      assert texts(first, ~s([data-role="doc-example-expand-text"])) == ["All of it"]
      assert texts(first, ~s([data-role="doc-example-collapse-text"])) == ["Show less"]
    end

    # ON THE PAGE THE TOOLBAR TURNS THE EXAMPLE'S DIRECTION AND OPENS ITS PREVIEW; the preview's own
    # toolbar, which the hook builds, switches its colours, its width and its direction, and says
    # what the holder carries.
    test "draws its toolbar with the choice it was set with pressed, and the preview's words",
         %{site: site} do
      body =
        example_page!(
          site,
          "[[component doc-example]][[component doc-callout]]Plain.[[/component]][[/component]]"
        )

      example = LazyHTML.query(body, ~s([data-role="doc-example"]))

      assert pressed(example) == [{"dir", "ltr", "true"}, {"dir", "rtl", "false"}]

      toolbar = LazyHTML.query(example, ~s([data-role="doc-example-toolbar"][role="toolbar"]))
      assert LazyHTML.attribute(toolbar, "aria-label") == ["Example options"]
      assert texts(toolbar, ~s([data-role="doc-example-option-text"])) == ~w(LTR RTL)
      assert toolbar |> LazyHTML.query(~s(button[type="button"])) |> Enum.count() == 3

      assert example |> LazyHTML.query(~s([data-role="doc-example-title"])) |> Enum.count() == 0

      holder = holder(example)

      assert for(
               name <-
                 ~w(label toolbar-label frame-label light-text dark-text desktop-text tablet-text
                    mobile-text ltr-text rtl-text close-text),
               do: holder |> LazyHTML.attribute("data-#{name}") |> List.first()
             ) == ~w(Preview Preview Example Light Dark Desktop Tablet Mobile LTR RTL Close)
    end

    # AN EXAMPLE'S FRAME IS ITS MARKUP AND THE FEW ELEMENTS AROUND IT, whatever the page holds of
    # them: no preview is drawn with it, nothing but its body carries a class — the kit's stylesheet
    # draws the rest by `data-role` — and no button carries a command of its own, since the hook
    # answers them all.
    test "costs a page little more than its own markup", %{site: site} do
      count = 20

      body =
        example_page!(
          site,
          Enum.map_join(1..count, fn n ->
            ~s([[component doc-example title="Example #{n}"]]) <>
              "[[component doc-callout]]Example #{n}.[[/component]][[/component]]"
          end)
        )

      examples = body |> LazyHTML.query(~s([data-role="doc-example"])) |> Enum.to_list()
      assert length(examples) == count

      frame =
        examples
        |> Enum.map(fn example ->
          inner = LazyHTML.query(example, ~s([data-role="doc-example-body"]))
          byte_size(LazyHTML.to_html(example)) - byte_size(LazyHTML.to_html(inner))
        end)
        |> Enum.sum()

      assert div(frame, count) < 3_000,
             "an example's frame costs #{div(frame, count)} bytes of the page, past its bound of 3000"

      for example <- examples do
        classed = example |> LazyHTML.query("[class]") |> Enum.count()

        in_body =
          example |> LazyHTML.query(~s([data-role="doc-example-body"] [class])) |> Enum.count()

        assert LazyHTML.attribute(example, "class") == []
        assert classed - in_body == 1, "an element of the example's frame carries a class"
      end

      buttons = body |> LazyHTML.query(~s(button[data-role^="doc-example-"])) |> Enum.to_list()
      assert length(buttons) == count * 4

      for button <- buttons do
        names = button |> LazyHTML.attributes() |> List.first() |> Enum.map(&elem(&1, 0))
        assert Enum.filter(names, &String.starts_with?(&1, "phx-")) == []
      end
    end

    test "takes the colours, width and direction the marker sets, and only the declared ones",
         %{site: site} do
      body =
        example_page!(
          site,
          ~s([[component doc-example theme="light" device="mobile" dir="rtl"]]) <>
            "[[component doc-callout]]One.[[/component]][[/component]]" <>
            ~s([[component doc-example theme="purple" device="watch" dir="up"]]) <>
            "[[component doc-callout]]Two.[[/component]][[/component]]"
        )

      assert [set, refused] = Enum.to_list(LazyHTML.query(body, ~s([data-role="doc-example"])))

      assert LazyHTML.attribute(set, "data-frame-theme") == ["light"]
      assert LazyHTML.attribute(set, "data-frame-device") == ["mobile"]
      assert LazyHTML.attribute(set, "data-frame-dir") == ["rtl"]

      assert set
             |> LazyHTML.query(~s([data-role="doc-example-stage"]))
             |> LazyHTML.attribute("dir") ==
               ["rtl"]

      assert for({action, value, "true"} <- pressed(set), do: {action, value}) == [{"dir", "rtl"}]

      assert LazyHTML.attribute(refused, "data-frame-theme") == ["dark"]
      assert LazyHTML.attribute(refused, "data-frame-device") == ["desktop"]
      assert LazyHTML.attribute(refused, "data-frame-dir") == ["ltr"]
    end

    # THE EXAMPLE'S TEXT IS THE PAGE'S, as written, and nothing of it is drawn a second time for the
    # preview: the hook copies it from the page when the preview opens.
    test "carries the example's text onto the page exactly as it was written, and only once",
         %{site: site} do
      body =
        example_page!(
          site,
          ~s([[component doc-example]]<p>Tom &amp; "Jerry" &lt;b&gt;</p>[[/component]]),
          []
        )

      assert [example] = Enum.to_list(LazyHTML.query(body, ~s([data-role="doc-example"])))

      assert example
             |> LazyHTML.query(~s([data-role="doc-example-body"] > p))
             |> LazyHTML.text() == ~s(Tom & "Jerry" <b>)

      assert example
             |> LazyHTML.query("p")
             |> Enum.count(&(LazyHTML.text(&1) =~ "Jerry")) == 1

      assert body |> LazyHTML.query("b") |> Enum.count() == 0
    end

    # THE HOLDER NAMES THE PAGE THAT DRAWS ITS EXAMPLE ALONE, by the example's place among the
    # examples of the page's text or of a note's — none counted inside code — and that page draws
    # exactly that example. Nothing is loaded for it until the preview opens: no frame is drawn.
    test "names for each preview the page that draws its own example alone", %{
      conn: conn,
      site: site
    } do
      example = fn text ->
        "[[component doc-example]][[component doc-callout]]#{text}[[/component]][[/component]]"
      end

      {page, body} =
        example_page_of!(
          site,
          ~s(<pre><code>[[component doc-example]]Code[[/component]]</code></pre>) <>
            example.("First") <>
            "<p>Between.</p>" <>
            "[[component doc-callout]]" <> example.("Inside") <> "[[/component]]",
          ["doc-callout"],
          ["<p>Note.</p>" <> example.("In the note")]
        )

      [note] =
        MishkaDocument.Note
        |> Ash.Query.filter(section_id == ^page.id)
        |> Ash.read!(tenant: site.id, authorize?: false)

      holders = LazyHTML.query(body, ~s([data-role="doc-example-preview-holder"]))

      assert LazyHTML.attribute(holders, "data-src") == [
               "/_preview/doc-example/section/#{page.id}/0",
               "/_preview/doc-example/section/#{page.id}/1",
               "/_preview/doc-example/note/#{note.id}/0"
             ]

      assert body |> LazyHTML.query("iframe") |> Enum.count() == 0
      refute LazyHTML.to_html(body) =~ ~s( src="/_preview/)

      conn =
        conn
        |> Map.put(:host, site.host)
        |> Map.update!(:req_headers, &[{"host", site.host} | List.keydelete(&1, "host", 0)])

      drawn =
        for [src] <- Enum.map(holders, &LazyHTML.attribute(&1, "data-src")) do
          conn
          |> get(src)
          |> html_response(200)
          |> LazyHTML.from_document()
          |> LazyHTML.query(~s([data-role="doc-example-live"] [data-role="doc-callout-body"]))
          |> Enum.map(&(&1 |> LazyHTML.text() |> String.trim()))
        end

      assert drawn == [["First"], ["Inside"], ["In the note"]]
    end

    # A COMPONENT THAT KEEPS STATE IS DRAWN BY LIVEVIEW, ON THE PAGE: the example draws it on the
    # page like any other, and its preview is built like any other's, of the page that draws the
    # example alone.
    test "draws an example that keeps state on the page, and a holder for its preview",
         %{site: site} do
      body =
        example_page!(
          site,
          ~s(<p>Before.</p>[[component doc-example title="Contents"]][[component doc-toc /]][[/component]]),
          ["doc-toc"]
        )

      assert [example] = Enum.to_list(LazyHTML.query(body, ~s([data-role="doc-example"])))

      assert texts(example, ~s([data-role="doc-example-title"])) == ["Contents"]
      assert example |> holder() |> Enum.count() == 1

      assert example
             |> LazyHTML.query(~s([data-role="doc-example-unavailable"]))
             |> Enum.count() == 0

      assert example |> LazyHTML.query(~s([data-role="doc-example-toolbar"])) |> Enum.count() == 1

      assert example
             |> LazyHTML.query(~s([data-role="doc-example-body"] [data-role="doc-toc"]))
             |> Enum.count() == 1

      assert body |> LazyHTML.query("p:not([data-role])") |> LazyHTML.text() == "Before."
    end

    # THE TOOLBAR IS ANSWERED BY THE KIT'S OWN HOOK, mounted on the example's root, under the name
    # the site's JavaScript registers the installed row by.
    test "mounts the kit's example hook on its root", %{site: site} do
      hook =
        MishkaCmsCore.Runtime.JsHook
        |> Ash.Query.for_read(:read_any, %{}, authorize?: false)
        |> Ash.Query.filter(name == "doc-example" and site_id == ^site.id)
        |> Ash.Query.load([:is_global])
        |> Ash.read_one!()

      assert hook, "installing the kit wrote no doc-example hook for the site"
      assert hook.active

      body =
        example_page!(
          site,
          "[[component doc-example]][[component doc-callout]]Hooked.[[/component]][[/component]]"
        )

      registered =
        MishkaCmsCore.Runtime.Compilers.JavaScriptCompiler.browser_name(hook, site.name)

      assert registered == String.capitalize(site.name) <> "DocExample"

      assert body
             |> LazyHTML.query(~s([data-role="doc-example"]))
             |> LazyHTML.attribute("phx-hook") ==
               [registered]
    end

    # A PREVIEW RENDERS CONTENT TO A STRING, with no LiveView to draw on: the example is drawn there
    # as on a page, with no preview of its own.
    test "draws the same example, with no preview, where content is rendered to a string",
         %{site: site} do
      for name <- ["doc-example", "doc-callout"] do
        :ok = SiteState.put_component(site.id, name)
        on_exit(fn -> SiteState.delete_component(site.id, name) end)
      end

      html =
        %{
          html:
            ~s([[component doc-example dir="rtl"]][[component doc-callout tone="info"]]Hi[[/component]][[/component]]),
          site: site.name,
          id: "preview"
        }
        |> MishkaCmsCore.Runtime.ContentComponents.draw(:static)
        |> Phoenix.HTML.Safe.to_iodata()
        |> IO.iodata_to_binary()
        |> LazyHTML.from_fragment()

      example = LazyHTML.query(html, ~s([data-role="doc-example"]))
      assert LazyHTML.attribute(example, "id") == ["preview-0"]

      assert example
             |> LazyHTML.query(~s([data-role="doc-example-body"] > [data-role="doc-callout"]))
             |> LazyHTML.attribute("data-tone") == ["info"]

      assert LazyHTML.attribute(example, "data-frame-dir") == ["rtl"]

      # Content drawn anywhere but a page of a document says nowhere the example is written, so it
      # has no preview: the toolbar turns its direction and offers nothing more.
      assert example |> holder() |> Enum.count() == 0

      assert example |> LazyHTML.query(~s([data-role="doc-example-open"])) |> Enum.count() ==
               0

      assert texts(
               example,
               ~s([data-role="doc-example-toolbar"] [data-role="doc-example-option-text"])
             ) ==
               ~w(LTR RTL)
    end
  end

  # A GROUP IS ONLY A HEADING IN THE CONTENTS, like a sidebar's NAVIGATION over its pages: it has no
  # page and no address, nothing links to it, and the pages under it are addressed as if it were not
  # there (`MishkaDocument.Address`).
  describe "a document with a group" do
    test "draws it in the contents as a heading over its pages, always open", %{site: site} do
      grouped!(site)

      {:ok, contents, _html} =
        mount_page(site, "doc-sidebar", %{
          path: "/mishka/docs",
          lang_param: "",
          params: %{"section" => "upgrading"}
        })

      assert text_of(contents, ~s([data-role="doc-sidebar-group"])) == ["Navigation"]

      assert hrefs(contents, ~s([data-role="doc-sidebar-link"])) == [
               "/mishka/docs/getting-started",
               "/mishka/docs/breadcrumb",
               "/mishka/docs/menu",
               "/mishka/docs/upgrading"
             ]

      refute "/mishka/docs/navigation" in hrefs(contents, "a")
    end

    test "keeps it in a filtered list while one of its pages matches", %{site: site} do
      grouped!(site)

      {:ok, view, _html} =
        mount_page(site, "doc-sidebar", %{path: "/mishka/docs", lang_param: "", show_filter: true})

      view |> form(~s(#one form), %{"q" => "crumb"}) |> render_change()
      assert text_of(view, ~s([data-role="doc-sidebar-group"])) == ["Navigation"]
      assert text_of(view, ~s([data-role="doc-sidebar-link"])) == ["Breadcrumb"]

      view |> form(~s(#one form), %{"q" => "upgr"}) |> render_change()
      assert text_of(view, ~s([data-role="doc-sidebar-group"])) == []
      assert text_of(view, ~s([data-role="doc-sidebar-link"])) == ["Upgrading"]

      view |> form(~s(#one form), %{"q" => "navigation"}) |> render_change()
      assert text_of(view, ~s([data-role="doc-sidebar-group"])) == []
    end

    test "lists it on the landing as a heading over its pages", %{site: site} do
      grouped!(site)

      {:ok, view, _html} =
        mount_page(site, "doc-section", %{path: "/mishka/docs", lang_param: "", params: %{}})

      assert text_of(view, ~s([data-role="doc-landing-items"] [data-role="doc-landing-link"])) ==
               ["Getting started", "Upgrading"]

      assert text_of(view, ~s([data-role="doc-landing-group-title"])) == ["Navigation"]

      assert hrefs(view, ~s([data-role="doc-landing-group"] [data-role="doc-landing-link"])) == [
               "/mishka/docs/breadcrumb",
               "/mishka/docs/menu"
             ]
    end

    test "steps over it from page to page, and names it in the trail as a word", %{site: site} do
      grouped!(site)
      attrs = %{path: "/mishka/docs", lang_param: ""}

      {:ok, first, _html} =
        mount_page(
          site,
          "doc-section",
          Map.put(attrs, :params, %{"section" => "getting-started"})
        )

      assert hrefs(first, ~s([data-role="doc-section-next"])) == ["/mishka/docs/breadcrumb"]

      {:ok, crumb, _html} =
        mount_page(site, "doc-section", Map.put(attrs, :params, %{"section" => "breadcrumb"}))

      assert text_of(crumb, ~s([data-role="doc-section-title"])) == ["Breadcrumb"]
      assert hrefs(crumb, ~s([data-role="doc-section-prev"])) == ["/mishka/docs/getting-started"]
      assert text_of(crumb, ~s([data-role="doc-section-crumb"])) == ["Navigation"]
      assert hrefs(crumb, ~s([data-role="doc-section-crumb"])) == []
    end

    test "has no address: its would-be one is a missing page, and no block takes it for a page",
         %{site: site} do
      grouped!(site)

      for section <- ["navigation", "navigation/breadcrumb"] do
        assert_raise MishkaCmsCore.ErrorsExceptions.NotFoundError, fn ->
          mount_page(site, "doc-section", %{
            path: "/mishka/docs",
            lang_param: "",
            params: %{"section" => section}
          })
        end
      end

      attrs = %{path: "/mishka/docs", lang_param: "", params: %{"section" => "navigation"}}

      {:ok, toc, _html} = mount_page(site, "doc-toc", attrs)
      assert text_of(toc, ~s([data-role="doc-toc-link"])) == []

      {:ok, contents, _html} = mount_page(site, "doc-sidebar", attrs)
      assert hrefs(contents, ~s([data-role="doc-sidebar-link"][aria-current="page"])) == []

      {:ok, switch, _html} = mount_page(site, "doc-switcher", Map.put(attrs, :show, "version"))
      assert hrefs(switch, ~s([data-role="doc-switcher-version"])) == ["/mishka/docs"]
    end
  end

  # A GROUP WITH A PAGE OF ITS OWN is read at its slug like any page, while the pages under it keep
  # their address as if it were not there; every block links to it, and a lock or a review keeps it
  # from a visitor as it keeps any page.
  describe "a group with a page of its own" do
    test "is read at its slug, while its pages keep their address", %{site: site} do
      paged_group!(site)
      attrs = %{path: "/mishka/docs", lang_param: ""}

      {:ok, group, _html} =
        mount_page(site, "doc-section", Map.put(attrs, :params, %{"section" => "navigation"}))

      assert text_of(group, ~s([data-role="doc-section-title"])) == ["Navigation"]
      assert [body] = text_of(group, ~s([data-role="doc-section-body"]))
      assert body =~ "Ways to move around a site."

      {:ok, crumb, _html} =
        mount_page(site, "doc-section", Map.put(attrs, :params, %{"section" => "breadcrumb"}))

      assert text_of(crumb, ~s([data-role="doc-section-title"])) == ["Breadcrumb"]

      assert_raise MishkaCmsCore.ErrorsExceptions.NotFoundError, fn ->
        mount_page(
          site,
          "doc-section",
          Map.put(attrs, :params, %{"section" => "navigation/breadcrumb"})
        )
      end
    end

    test "is a heading in the contents that links to it, current while it is read",
         %{site: site} do
      paged_group!(site)
      attrs = %{path: "/mishka/docs", lang_param: ""}

      {:ok, on_group, _html} =
        mount_page(site, "doc-sidebar", Map.put(attrs, :params, %{"section" => "navigation"}))

      assert text_of(on_group, ~s([data-role="doc-sidebar-group"])) == ["Navigation", "Feedback"]
      assert hrefs(on_group, ~s([data-role="doc-sidebar-group"])) == ["/mishka/docs/navigation"]

      assert hrefs(on_group, ~s([data-role="doc-sidebar-group"][aria-current="page"])) ==
               ["/mishka/docs/navigation"]

      assert hrefs(on_group, ~s([data-role="doc-sidebar-link"])) == [
               "/mishka/docs/getting-started",
               "/mishka/docs/breadcrumb",
               "/mishka/docs/menu",
               "/mishka/docs/alert",
               "/mishka/docs/upgrading"
             ]

      {:ok, elsewhere, _html} =
        mount_page(site, "doc-sidebar", Map.put(attrs, :params, %{"section" => "upgrading"}))

      assert hrefs(elsewhere, ~s([data-role="doc-sidebar-group"])) == ["/mishka/docs/navigation"]
      assert hrefs(elsewhere, ~s([data-role="doc-sidebar-group"][aria-current="page"])) == []
    end

    test "is linked from the landing and the trail, and Previous and Next stop on it",
         %{site: site} do
      paged_group!(site)
      attrs = %{path: "/mishka/docs", lang_param: ""}

      {:ok, landing, _html} = mount_page(site, "doc-section", Map.put(attrs, :params, %{}))

      assert hrefs(landing, ~s([data-role="doc-landing-group-link"])) == [
               "/mishka/docs/navigation"
             ]

      assert text_of(landing, ~s([data-role="doc-landing-group-title"])) ==
               ["Navigation", "Feedback"]

      {:ok, first, _html} =
        mount_page(
          site,
          "doc-section",
          Map.put(attrs, :params, %{"section" => "getting-started"})
        )

      assert hrefs(first, ~s([data-role="doc-section-next"])) == ["/mishka/docs/navigation"]

      {:ok, group, _html} =
        mount_page(site, "doc-section", Map.put(attrs, :params, %{"section" => "navigation"}))

      assert hrefs(group, ~s([data-role="doc-section-prev"])) == ["/mishka/docs/getting-started"]
      assert hrefs(group, ~s([data-role="doc-section-next"])) == ["/mishka/docs/breadcrumb"]

      {:ok, crumb, _html} =
        mount_page(site, "doc-section", Map.put(attrs, :params, %{"section" => "breadcrumb"}))

      assert hrefs(crumb, ~s([data-role="doc-section-crumb"])) == ["/mishka/docs/navigation"]
      assert hrefs(crumb, ~s([data-role="doc-section-prev"])) == ["/mishka/docs/navigation"]
    end

    test "is what the table of contents and the switch read there", %{site: site} do
      paged_group!(site)
      attrs = %{path: "/mishka/docs", lang_param: "", params: %{"section" => "navigation"}}

      {:ok, toc, _html} = mount_page(site, "doc-toc", attrs)

      assert text_of(toc, ~s([data-role="doc-toc-link"])) == [
               "Where to start",
               "Where to go next"
             ]

      {:ok, switch, _html} = mount_page(site, "doc-switcher", Map.put(attrs, :show, "version"))
      assert hrefs(switch, ~s([data-role="doc-switcher-version"])) == ["/mishka/docs/navigation"]
    end

    test "is a missing page to a visitor it is locked to, and while it waits for review",
         %{site: site} do
      %{version: version} = paged_group!(site)
      member = create_user_with_permissions!(["members:read"], site_id: site.id)

      page!(site, version,
        title: "Members",
        slug: "members",
        order_position: 5,
        group_heading: true,
        group_page: true,
        permissions: ["members:read"]
      )

      page!(site, version,
        title: "Overlays",
        slug: "overlays",
        order_position: 6,
        group_heading: true,
        group_page: true,
        content_review_status: :pending
      )

      attrs = %{path: "/mishka/docs", lang_param: ""}

      for section <- ["members", "overlays"] do
        assert_raise MishkaCmsCore.ErrorsExceptions.NotFoundError, fn ->
          mount_page(site, "doc-section", Map.put(attrs, :params, %{"section" => section}))
        end
      end

      {:ok, shown, _html} =
        mount_page(
          site,
          "doc-section",
          Map.merge(attrs, %{params: %{"section" => "members"}, current_user: member})
        )

      assert text_of(shown, ~s([data-role="doc-section-title"])) == ["Members"]
    end
  end

  # THE PAGES UNDER A PAGE, AS CARDS, placed in its text as `[[component doc-section-cards /]]`:
  # `doc-section` tells the block which page it is in, and the block reads that page's published
  # pages itself, as the contents read them for the same visitor.
  describe "doc-section-cards" do
    test "lists the published pages under the page it is placed in, in order, as cards",
         %{site: site} do
      paged_group!(site)

      view = navigation_page(site)

      assert text_of(view, ~s([data-role="doc-cards-title"])) == ["Breadcrumb", "Menu"]

      assert hrefs(view, ~s([data-role="doc-cards-link"])) == [
               "/mishka/docs/breadcrumb",
               "/mishka/docs/menu"
             ]

      assert text_of(view, ~s([data-role="doc-cards-description"])) == [
               "A trail of links back up the site.",
               "A list of links that opens from a button."
             ]

      [grid] = Enum.to_list(drawn(view, ~s([data-role="doc-cards-items"])))
      [classes] = LazyHTML.attribute(grid, "class")
      assert "grid-cols-1" in String.split(classes)
      assert "sm:grid-cols-2" in String.split(classes)

      assert [body] = text_of(view, ~s([data-role="doc-section-body"]))
      assert body =~ "Ways to move around a site."
    end

    test "leaves out a page locked to the visitor, and shows it to one who holds it",
         %{site: site} do
      paged_group!(site)
      member = create_user_with_permissions!(["members:read"], site_id: site.id)

      assert text_of(navigation_page(site), ~s([data-role="doc-cards-title"])) ==
               ["Breadcrumb", "Menu"]

      assert text_of(navigation_page(site, member), ~s([data-role="doc-cards-title"])) ==
               ["Breadcrumb", "Menu", "Mega menu"]
    end

    test "says so when no page is filed under the page", %{site: site} do
      %{version: version} = paged_group!(site)

      page!(site, version,
        title: "Lonely",
        slug: "lonely",
        order_position: 7,
        content: "<p>[[component doc-section-cards /]]</p>"
      )

      {:ok, view, _html} =
        mount_page(site, "doc-section", %{
          path: "/mishka/docs",
          lang_param: "",
          params: %{"section" => "lonely"}
        })

      assert text_of(view, ~s([data-role="doc-cards-empty"])) == [
               "No pages are filed under this one yet."
             ]

      assert text_of(view, ~s([data-role="doc-cards-item"])) == []
    end

    test "lists the pages under the page its parent names, a group with no page by its slug",
         %{site: site} do
      %{version: version} = paged_group!(site)

      page!(site, version,
        title: "Overview",
        slug: "overview",
        order_position: 8,
        content:
          ~s(<p>[[component doc-section-cards parent="navigation" /]]</p>) <>
            ~s(<p>[[component doc-section-cards parent="feedback" show_description=false /]]</p>)
      )

      {:ok, view, _html} =
        mount_page(site, "doc-section", %{
          path: "/mishka/docs",
          lang_param: "",
          params: %{"section" => "overview"}
        })

      assert text_of(view, ~s([data-role="doc-cards-title"])) == ["Breadcrumb", "Menu", "Alert"]
      assert hrefs(view, ~s([data-role="doc-cards-link"])) |> List.last() == "/mishka/docs/alert"
      assert length(text_of(view, ~s([data-role="doc-cards-description"]))) == 2
    end

    test "leaves a marker in code as it was written", %{site: site} do
      %{version: version} = paged_group!(site)

      page!(site, version,
        title: "Syntax",
        slug: "syntax",
        order_position: 9,
        content: "<p>Write <code>[[component doc-section-cards /]]</code> on a page.</p>"
      )

      {:ok, view, _html} =
        mount_page(site, "doc-section", %{
          path: "/mishka/docs",
          lang_param: "",
          params: %{"section" => "syntax"}
        })

      assert text_of(view, ~s([data-role="doc-cards"])) == []

      assert text_of(view, ~s([data-role="doc-section-body"] code)) == [
               "[[component doc-section-cards /]]"
             ]
    end

    test "reads on its own, handed the page it is in", %{site: site} do
      %{group: group} = paged_group!(site)

      {:ok, view, _html} =
        mount_page(site, "doc-section-cards", %{placed_in: group.id, lang_param: ""})

      assert hrefs(view, ~s([data-role="doc-cards-link"])) == [
               "/mishka/docs/breadcrumb",
               "/mishka/docs/menu"
             ]

      {:ok, nowhere, _html} = mount_page(site, "doc-section-cards", %{placed_in: "not-a-page"})
      assert text_of(nowhere, ~s([data-role="doc-cards-empty"])) != []
    end

    test "is recorded among the components the page's text names", %{site: site} do
      %{group: group} = paged_group!(site)

      assert document_page(site, group.slug).content_components == ["doc-section-cards"]
    end
  end

  # WHAT A PLUGIN PUTS ON A PAGE'S CARD: the badges of the header it answers for that page, asked
  # with `card: true` so it answers from what it holds.
  describe "doc-section-cards's badges" do
    setup do
      Process.register(self(), :__page_extras_probe__)

      {:ok, _} =
        Event.write(%{
          name: PageExtras,
          event: @extras_event,
          extension: :mishka_installer,
          status: :started
        })

      :ok = EventHandler.do_compile(@extras_event, :start, false)

      on_exit(fn ->
        PageExtras.forget!()
        Event.unregister(:name, PageExtras, false)
        EventHandler.do_compile(@extras_event, :start, false)
      end)

      :ok
    end

    test "draws the badges a plugin answers for each page, and nothing else of its header",
         %{site: site} do
      paged_group!(site)

      PageExtras.answer!(fn
        %{card: true, page: %{slug: slug}} = state ->
          %{
            state
            | header: [
                %{kind: :badges, items: [%{text: "Component", tone: :secondary}, %{text: slug}]},
                %{kind: :command, label: "Install", value: "mix x"}
              ],
              tabs: [%{id: "props", label: "Props", kind: :list, items: []}]
          }

        state ->
          state
      end)

      view = navigation_page(site)

      assert text_of(view, ~s([data-role="doc-cards-badge"])) ==
               ["Component", "breadcrumb", "Component", "menu"]

      assert view
             |> drawn(~s([data-role="doc-cards-badge"]))
             |> LazyHTML.attribute("data-tone")
             |> Enum.take(2) == ["secondary", "neutral"]

      assert text_of(view, ~s([data-role="doc-cards"] [data-role="doc-extra-command"])) == []

      site_id = site.id

      assert_received {:page_extras_asked,
                       %{
                         site_id: ^site_id,
                         card: true,
                         document: %{slug: "paged", path: "/mishka/docs"},
                         version: "1.0.0",
                         page: %{
                           slug: "breadcrumb",
                           path: "breadcrumb",
                           parents: [%{slug: "navigation", group: true}]
                         }
                       }}
    end

    test "asks nothing with show_badges off", %{site: site} do
      %{version: version} = paged_group!(site)

      page!(site, version,
        title: "Plain",
        slug: "plain",
        order_position: 9,
        content:
          ~s(<p>[[component doc-section-cards parent="navigation" show_badges=false /]]</p>)
      )

      PageExtras.answer!(fn state ->
        %{state | header: [%{kind: :badges, items: [%{text: "Never"}]}]}
      end)

      {:ok, view, _html} =
        mount_page(site, "doc-section", %{
          path: "/mishka/docs",
          lang_param: "",
          params: %{"section" => "plain"}
        })

      assert text_of(view, ~s([data-role="doc-cards-title"])) == ["Breadcrumb", "Menu"]
      assert text_of(view, ~s([data-role="doc-cards-badge"])) == []
      refute_received {:page_extras_asked, %{card: true}}
    end
  end

  # THE PAGE'S OWN TEXT IS STYLED, AND NOTHING A COMPONENT IN IT DRAWS. The body's and a note's
  # rules reach an element with no class and nothing with a class between it and the body: what the
  # editor writes carries no class, and a component's markup does — so a component drawn at the top,
  # one whose own root is a heading or a list, and one placed inside a list item keep their own look.
  # Each rule is read off the markup and run as the selector it compiles to.
  describe "the text of a page" do
    # A COMPONENT'S MARKUP AS CHELEKOM WRITES IT: every element carries classes of its own. Each is
    # marked `data-part="component"` too, so a test can tell it from the page's own HTML.
    defp marked!(site, name, template) do
      :ok = SiteState.put_component(site.id, name)
      on_exit(fn -> SiteState.delete_component(site.id, name) end)
      create_component!(name: name, site_id: site.id, active: true, template: template)
    end

    defp crumbs!(site),
      do:
        marked!(
          site,
          "content-crumbs",
          ~S|<nav data-role="content-crumbs" data-part="component" class="text-sm"><ol data-part="component" class="flex items-center gap-2"><li data-part="component" class="flex items-center"><a data-part="component" href="https://example.com/home" class="text-[#5b57d6]">Home</a></li><li data-part="component" class="flex items-center">Here</li></ol></nav>|
        )

    defp heading!(site),
      do:
        marked!(
          site,
          "content-heading",
          ~S|<h2 data-role="content-heading" data-part="component" class="text-3xl font-black">Drawn heading</h2>|
        )

    defp listed!(site),
      do:
        marked!(
          site,
          "content-list",
          ~S|<ul data-role="content-list" data-part="component" class="m-0"><li data-part="component" class="p-1"><a data-part="component" class="no-underline" href="https://example.com/x">Listed</a></li></ul>|
        )

    defp linked!(site),
      do:
        marked!(
          site,
          "content-link",
          ~S|<a data-role="content-link" data-part="component" class="font-bold" href="https://example.com/drawn">Drawn link</a>|
        )

    defp text_page!(site, content, note \\ nil) do
      %{version: version} = manual!(site)

      page =
        page!(site, version, title: "Text", slug: "text", order_position: 9, content: content)

      if note, do: note!(site, page, title: "Aside", content: note)

      {:ok, view, _html} =
        mount_page(site, "doc-section", %{workspace: "mishka-cms", params: %{"section" => "text"}})

      {view, page}
    end

    # WHAT EACH CONTENT STYLE ON `role` REACHES: every `[selector]:utility` class of it, read as the
    # rule Tailwind writes for it — `&` the element, `_` a space — and run over the drawn page. One
    # `{utility, elements}` per class.
    defp styled(view, role) do
      page = view |> render_async(@async) |> LazyHTML.from_fragment()
      scope = ~s([data-role="#{role}"])
      [classes | _] = page |> LazyHTML.query(scope) |> LazyHTML.attribute("class")

      for class <- String.split(classes),
          [_class, selector, utility] <- [Regex.run(~r/\A\[(.+)\]:([^\]]+)\z/, class)] do
        rule = selector |> String.replace("_", " ") |> String.replace("&", scope)
        {utility, page |> LazyHTML.query(rule) |> Enum.to_list()}
      end
    end

    defp reached(styled, utility),
      do: for({^utility, elements} <- styled, element <- elements, do: element)

    defp reached_component(styled),
      do:
        for(
          {_utility, elements} <- styled,
          element <- elements,
          LazyHTML.attribute(element, "data-part") == ["component"],
          do: element
        )

    test "its own list and link take its styles, and a component's list and link do not",
         %{site: site} do
      crumbs!(site)
      listed!(site)

      content =
        ~s(<p>Read <a href="https://example.com/guide">the guide</a> first.</p>) <>
          "<ul><li><p>Own item</p></li></ul><ol><li><p>First step</p></li></ol>" <>
          "<p>[[component content-crumbs /]]</p>[[component content-list /]]"

      {view, _page} = text_page!(site, content, content)

      assert view |> render_async(@async) |> roles("content-crumbs") == 2

      for role <- ["doc-section-body", "doc-note-body"] do
        styles = styled(view, role)

        assert styles |> reached("list-disc") |> Enum.map(&LazyHTML.text/1) == ["Own item"]
        assert styles |> reached("list-decimal") |> Enum.map(&LazyHTML.text/1) == ["First step"]

        assert styles |> reached("ml-5") |> Enum.map(&LazyHTML.text/1) == [
                 "Own item",
                 "First step"
               ]

        assert styles |> reached("underline") |> Enum.flat_map(&LazyHTML.attribute(&1, "href")) ==
                 ["https://example.com/guide"]

        assert reached_component(styles) == [], "#{role} reaches a component's markup"
      end
    end

    # A COMPONENT IS NOT TEXT WHEREVER IT IS DRAWN: one whose own root is a heading, a list or a link,
    # and one placed inside a list item, keep the classes they were drawn with.
    test "a component drawn as a heading, or inside a list item, is left to its own classes",
         %{site: site} do
      heading!(site)
      crumbs!(site)
      listed!(site)
      linked!(site)

      {view, _page} =
        text_page!(
          site,
          "<h2>Own heading</h2><p>[[component content-heading /]]</p>" <>
            "<ul><li><p>Own item</p><p>[[component content-crumbs /]]</p>" <>
            "<p>[[component content-list /]]</p><p>[[component content-link /]]</p></li></ul>" <>
            ~s(<blockquote><p>Quoted <a href="https://example.com/source">source</a></p></blockquote>)
        )

      html = render_async(view, @async)
      assert roles(html, "content-heading") == 1

      for role <- ["content-crumbs", "content-list", "content-link"] do
        assert html
               |> LazyHTML.from_fragment()
               |> LazyHTML.query(~s(li > [data-role="#{role}"]))
               |> Enum.count() == 1,
               "#{role} is not drawn inside the list item"
      end

      styles = styled(view, "doc-section-body")

      assert styles |> reached("text-lg") |> Enum.map(&LazyHTML.text/1) == ["Own heading"]
      assert styles |> reached("list-disc") |> Enum.count() == 1

      assert styles |> reached("underline") |> Enum.flat_map(&LazyHTML.attribute(&1, "href")) ==
               ["https://example.com/source"]

      assert reached_component(styles) == []
    end

    test "and a callout's own text is styled the same way", %{site: site} do
      :ok = SiteState.put_component(site.id, "doc-callout")
      on_exit(fn -> SiteState.delete_component(site.id, "doc-callout") end)
      crumbs!(site)

      {view, _page} =
        text_page!(
          site,
          ~s([[component doc-callout tone="tip"]]<ul><li><p>Inside</p></li></ul>) <>
            "<p>[[component content-crumbs /]]</p>[[/component]]"
        )

      body = styled(view, "doc-section-body")
      assert reached(body, "list-disc") == []

      callout = styled(view, "doc-callout-body")
      assert callout |> reached("list-disc") |> Enum.map(&LazyHTML.text/1) == ["Inside"]
      assert reached_component(callout) == []
    end
  end

  # `{{doc.version}}` IN A PAGE'S TEXT IS THE VERSION BEING READ. The page stores the placeholder, so
  # the same text drawn from two versions draws two numbers.
  describe "{{doc.version}} in a page's text" do
    defp versioned_manual!(site) do
      %{document: document, version: latest} = manual!(site)

      older =
        version!(site, document, version_number: "0.9.0", published_at: ~U[2025-01-01 00:00:00Z])

      editor =
        create_user_with_permissions!(["admin:dashboard:document:section"], site_id: site.id)

      content =
        "<h2>Install {{doc.version}}</h2>" <>
          "<p>This is {{ doc.version }}.</p>" <>
          ~s(<p><a href="https://example.com/lib/blob/v{{doc.version}}/README.md">Source</a></p>) <>
          ~S(<p>Write \{{doc.version}} for the version.</p>) <>
          ~S(<pre><code class="language-elixir">{:lib, "~> {{doc.version}}", only: :dev}</code></pre>)

      pages =
        for version <- [latest, older] do
          page =
            MishkaDocument.Section
            |> Ash.Changeset.for_create(
              :create,
              %{
                workspace_version_id: version.id,
                title: "Install",
                slug: "install",
                order_position: 9,
                language: "en",
                content: content,
                content_review_status: :approved,
                technical_review_status: :approved
              },
              actor: editor,
              tenant: site.id
            )
            |> Ash.create!()

          note!(site, page, title: "Aside", content: "<p>Notes of {{doc.version}}.</p>")
          page
        end

      %{pages: pages}
    end

    test "draws the number of the version read, in its text, code, links and notes",
         %{site: site} do
      %{pages: pages} = versioned_manual!(site)

      for {params, number} <- [
            {%{"section" => "install"}, "1.0.0"},
            {%{"section" => "install", "v" => "0.9.0"}, "0.9.0"}
          ] do
        {:ok, view, _html} =
          mount_page(site, "doc-section", %{workspace: "mishka-cms", params: params})

        assert [body] = text_of(view, ~s([data-role="doc-section-body"]))
        assert body =~ "Install #{number}"
        assert body =~ "This is #{number}."
        assert body =~ "Write {{doc.version}} for the version."
        refute body =~ "\\{{"

        assert hrefs(view, ~s([data-role="doc-section-body"] a[href^="https://example.com"])) ==
                 ["https://example.com/lib/blob/v#{number}/README.md"]

        assert [code] = text_of(view, ~s([data-role="doc-section-body"] pre.highlight code))
        assert code =~ ~s({:lib, "~> #{number}", only: :dev})

        assert text_of(view, ~s([data-role="doc-note-body"])) == ["Notes of #{number}."]
      end

      for page <- pages do
        stored =
          MishkaDocument.Section
          |> Ash.Query.for_read(:public_list, %{}, authorize?: false)
          |> Ash.Query.filter(id == ^page.id)
          |> Ash.read_one!(tenant: site.id)

        assert stored.content =~ "{{doc.version}}"
        assert stored.content =~ "{{ doc.version }}"
      end
    end

    test "and doc-toc lists its headings with the same number, at the ids doc-section wrote",
         %{site: site} do
      versioned_manual!(site)
      attrs = %{workspace: "mishka-cms", params: %{"section" => "install", "v" => "0.9.0"}}

      {:ok, view, _html} =
        mount_blocks(site, [
          %{"name" => "doc-section", "id" => "one", "attrs" => attrs},
          %{"name" => "doc-toc", "id" => "two", "attrs" => attrs}
        ])

      assert text_of(view, ~s([data-role="doc-toc-link"])) == ["Install 0.9.0", "Aside"]
      assert ["#" <> id, _note] = hrefs(view, ~s([data-role="doc-toc-link"]))
      assert ids_of(view, ~s([data-role="doc-section-body"] h2)) == [id]
    end

    test "and a card's summary is the start of its page's text with the number filled",
         %{site: site} do
      %{version: version, group: group} = paged_group!(site)

      page!(site, version,
        title: "Versioned",
        slug: "versioned",
        order_position: 4,
        parent_section_id: group.id,
        content: "<p>For {{doc.version}} only.</p>"
      )

      descriptions = text_of(navigation_page(site), ~s([data-role="doc-cards-description"]))

      assert "For 1.0.0 only." in descriptions
      refute Enum.any?(descriptions, &(&1 =~ "{{"))
    end
  end

  # THE TRAIL CAN END WITH THE PAGE ITSELF, as a word marked as the current page — and then a page
  # at the top of its document has a trail too. Left off, the trail is the pages above it alone.
  describe "doc-section's crumb_current" do
    test "ends the trail with the page being read", %{site: site} do
      addressed!(site)

      base = %{path: "/mishka/docs", lang_param: "", crumb_current: true}

      {:ok, nested, _html} =
        mount_page(
          site,
          "doc-section",
          Map.put(base, :params, %{"section" => "installation/from-source"})
        )

      assert text_of(nested, ~s([data-role="doc-section-crumb"])) == [
               "Installation",
               "From source"
             ]

      assert hrefs(nested, ~s([data-role="doc-section-crumb"])) == ["/mishka/docs/installation"]

      assert text_of(nested, ~s([data-role="doc-section-crumb"][aria-current="page"])) == [
               "From source"
             ]

      {:ok, top, _html} =
        mount_page(site, "doc-section", Map.put(base, :params, %{"section" => "upgrading"}))

      assert text_of(top, ~s([data-role="doc-section-breadcrumb"])) == ["Upgrading"]

      assert text_of(top, ~s([data-role="doc-section-crumb"][aria-current="page"])) == [
               "Upgrading"
             ]
    end

    test "is the front page alone on the front page, and no trail on the landing", %{site: site} do
      %{front: front} = fronted!(site, path: "/mishka/docs")
      attrs = %{path: "/mishka/docs", lang_param: "", crumb_current: true, params: %{}}

      {:ok, view, _html} = mount_page(site, "doc-section", attrs)

      assert text_of(view, ~s([data-role="doc-section-crumb"][aria-current="page"])) == [
               "Get started"
             ]

      assert hrefs(view, ~s([data-role="doc-section-crumb"])) == []

      front
      |> Ash.Changeset.for_update(:update, %{front_page: false},
        tenant: site.id,
        authorize?: false
      )
      |> Ash.update!()

      {:ok, landing, _html} = mount_page(site, "doc-section", attrs)
      assert text_of(landing, ~s([data-role="doc-section-breadcrumb"])) == []
    end

    test "left off, a page at the top has no trail and a nested one ends above it", %{site: site} do
      addressed!(site)
      base = %{path: "/mishka/docs", lang_param: ""}

      {:ok, top, _html} =
        mount_page(site, "doc-section", Map.put(base, :params, %{"section" => "upgrading"}))

      assert text_of(top, ~s([data-role="doc-section-breadcrumb"])) == []

      {:ok, nested, _html} =
        mount_page(
          site,
          "doc-section",
          Map.put(base, :params, %{"section" => "installation/from-source"})
        )

      assert text_of(nested, ~s([data-role="doc-section-crumb"])) == ["Installation"]
      assert text_of(nested, ~s([aria-current="page"])) == []
    end
  end

  # WHEN A PAGE LAST CHANGED, under its title, with the version being read: the date its head gives
  # as `dateModified` — the page's own, and its document's at the document's own address.
  describe "doc-section's updated line" do
    defp updated(view) do
      line = drawn(view, ~s([data-role="doc-section-updated"]))
      time = LazyHTML.query(line, "time")

      %{
        lines: Enum.count(line),
        datetime: LazyHTML.attribute(time, "datetime"),
        date: Enum.map(time, &String.trim(LazyHTML.text(&1))),
        version:
          line
          |> LazyHTML.query(~s([data-role="doc-section-updated-version"]))
          |> Enum.map(&String.trim(LazyHTML.text(&1)))
      }
    end

    test "says when the page last changed and the version being read", %{site: site} do
      %{pages: pages} = manual!(site)
      page = Enum.find(pages, &(&1.slug == "installation"))
      Ash.Seed.update!(page, %{updated_at: ~U[2026-03-04 05:06:07.891234Z]})

      {:ok, view, _html} =
        mount_page(site, "doc-section", %{
          workspace: "mishka-cms",
          params: %{"section" => "installation"}
        })

      assert %{datetime: ["2026-03-04T05:06:07Z"], date: [date], version: ["v1.0.0"]} =
               updated(view)

      assert date == "Updated " <> MishkaCmsCore.Localized.date(~U[2026-03-04 05:06:07Z])
    end

    test "is the document's change on its front page", %{site: site} do
      %{document: document, front: front} = fronted!(site, path: "/mishka/docs")
      Ash.Seed.update!(document, %{updated_at: ~U[2026-02-01 00:00:00Z]})
      Ash.Seed.update!(front, %{updated_at: ~U[2026-05-01 00:00:00Z]})

      {:ok, view, _html} =
        mount_page(site, "doc-section", %{path: "/mishka/docs", lang_param: "", params: %{}})

      assert %{datetime: ["2026-02-01T00:00:00Z"], version: ["v1.0.0"]} = updated(view)
    end

    test "says the version ?v= names, in its own words, and is left out when asked", %{
      site: site
    } do
      addressed!(site)

      attrs = %{
        path: "/mishka/docs",
        lang_param: "",
        updated_text: "Changed %{date}",
        params: %{"section" => "installation", "v" => "0.9.0"}
      }

      {:ok, older, _html} = mount_page(site, "doc-section", attrs)

      assert %{version: ["v0.9.0"], date: ["Changed " <> _date]} = updated(older)

      {:ok, hidden, _html} = mount_page(site, "doc-section", Map.put(attrs, :show_updated, false))

      assert %{lines: 0} = updated(hidden)
      assert text_of(hidden, ~s([data-role="doc-section-title"])) == ["Installation"]
    end
  end

  describe "doc-switcher's version_text" do
    test "names the version switch, and left empty leaves the number alone", %{site: site} do
      addressed!(site)
      attrs = %{path: "/mishka/docs", lang_param: "", show: "version"}

      {:ok, named, _html} = mount_page(site, "doc-switcher", attrs)

      assert text_of(named, ~s([data-role="doc-switcher-versions-summary"])) == [
               "Version: 1.0.0"
             ]

      {:ok, bare, _html} = mount_page(site, "doc-switcher", Map.put(attrs, :version_text, ""))
      assert text_of(bare, ~s([data-role="doc-switcher-versions-summary"])) == ["1.0.0"]
    end
  end

  describe "they compile" do
    # WHICH KIND EACH ONE IS COMES OUT OF THE BUNDLE, not out of a list here. The kit holds both
    # now — blocks that read and hold what they read, and the function components they draw their
    # rows and their states with — and the two get different module shapes from
    # `MishkaCmsCore.Runtime.Compilers.ComponentCompiler`. A function component given the live shape
    # would be handed a socket it cannot use, and a live one given the stateless shape loses
    # `update_many/1` and with it every assign its parent sends.
    test "and each takes the shape its own row asks for", %{site: site} do
      for component <- bundle_components() do
        name = component["name"]

        assert LiveViewHelpers.ensure_component_loaded(name, site.name), "#{name} did not compile"

        module = CompilerHelpers.module_name(name, site.name, "Component")
        assert module.__component_information__([:private, :stateful]) == component["stateful"]

        assert function_exported?(module, :update_many, 1) == component["stateful"],
               "#{name} got the other shape"
      end
    end

    # WHICH ONES ANSWER IS READ OUT OF THE BUNDLE. Three of the five draw themselves from the URL
    # alone and declare no handler, so demanding one of all five would only keep the list short.
    test "and every declared handler reaches the compiled module", %{site: site} do
      answering =
        for component <- bundle_components(),
            Enum.any?(component["helpers"], &(&1["name"] == "handle_event")),
            do: component["name"]

      refute answering == [], "no component declares a handler, so this asserts nothing"

      for name <- answering do
        assert LiveViewHelpers.ensure_component_loaded(name, site.name), "#{name} did not compile"

        module = CompilerHelpers.module_name(name, site.name, "Component")
        assert function_exported?(module, :handle_event, 3), "#{name} answers nothing"
      end
    end

    # LIKE ANY OTHER COMPONENT. `precompile: false` means nothing builds this module at boot: the
    # first call finds no module, compiles the row, and renders.
    test "a stateful row with no module yet compiles when it is first called", %{site: site} do
      manual!(site)

      module = CompilerHelpers.module_name("doc-workspace-list", site.name, "Component")

      refute Code.ensure_loaded?(module),
             "the module was already built, so this proves nothing about lazy compilation"

      {:ok, view, _html} = mount_page(site, "doc-workspace-list")

      assert Code.ensure_loaded?(module), "the first call did not compile it"
      assert text_of(view, ~s([data-role="doc-list-title"])) == ["Mishka CMS"]
    end
  end

  # A DOCUMENTATION PAGE IS FOUR OF THESE SIDE BY SIDE, and the attributes that say which page it is
  # are written once and handed to all four. Every one of them declares `rest` as a global, so an
  # attribute one of them does not declare is not ignored — it is printed onto that block's root as
  # an HTML attribute. `doc-toc` builds no links out of `doc_base` and declares it for this reason.
  describe "the four blocks of a documentation page" do
    test "take one set of attributes between them", %{site: site} do
      manual!(site)

      attrs = %{
        workspace: "mishka-cms",
        workspace_param: "workspace",
        section_param: "section",
        version_param: "v",
        lang: "",
        lang_param: "",
        doc_base: "/docs",
        params: %{"section" => "installation"}
      }

      names = ~w(doc-section doc-sidebar doc-toc doc-switcher)

      {:ok, view, _html} =
        mount_blocks(
          site,
          for(name <- names, do: %{"name" => name, "id" => name, "attrs" => attrs})
        )

      document = view |> render() |> LazyHTML.from_fragment()

      for name <- names do
        [opening | _rest] =
          document
          |> LazyHTML.query("##{name}")
          |> Enum.map(&LazyHTML.to_html/1)
          |> Enum.map(&(&1 |> String.split(">") |> List.first()))

        printed =
          ~r/\s([a-zA-Z_][-\w]*)=/
          |> Regex.scan(opening)
          |> Enum.map(fn [_whole, attribute] -> attribute end)
          |> Enum.filter(&String.contains?(&1, "_"))

        assert printed == [],
               "#{name} printed #{inspect(printed)} as HTML, so it declares none of it"
      end
    end
  end

  # WHAT A READER SEES WHILE A BLOCK IS READING, AND IF IT CANNOT. A documentation page is four
  # blocks side by side, each with reads of its own; before the split the page waited for all four
  # and showed nothing until the slowest of them was done.
  describe "a block that reads" do
    # ITS FIRST PAINT HOLDS ITS ROWS, because what a crawler and a reader without JavaScript are
    # served is the first paint.
    test "draws its rows in its first paint, with no skeleton", %{site: site} do
      manual!(site)

      {view, first_paint} =
        mount_raw(site, [%{"name" => "doc-workspace-list", "id" => "one", "attrs" => %{}}])

      assert roles(first_paint, "doc-list-loading") == 0,
             "the first paint held a skeleton, so a crawler was served no documents"

      assert roles(first_paint, "doc-list-item") == 1
      assert roles(render_async(view, @async), "doc-list-item") == 1
    end

    # ONE READ PER RENDER OF THE VISIT, AND NONE IN A TASK. A visit renders the page twice — the GET
    # and the connected mount — and each reads its first answer in step: the GET so its HTML holds
    # the rows, the connected mount so they are drawn at once rather than behind a skeleton. Counted
    # off the repo's telemetry: `live_isolated/3` is the whole visit, its dead render and its mount.
    test "and one visit reads once per render, and starts no background read", %{site: site} do
      manual!(site)

      asked =
        queries_while(fn ->
          {view, _first_paint} =
            mount_raw(site, [%{"name" => "doc-workspace-list", "id" => "one", "attrs" => %{}}])

          render_async(view, @async)
        end)

      # One load reads the documents that name a lock of their own — what the list is kept to for its
      # visitor — then the page of rows and its count: three per render, two renders.
      assert Enum.count(asked, &String.contains?(&1, "mishka_document_workspaces")) == 6,
             "a load is the locked documents, the page of rows and its count, once for each render"
    end

    # AND A CHANGE TO WHAT THE ROWS ARE DRAWN FROM RE-STREAMS THEM. A streamed row is rendered once
    # and never again — LiveView prunes `stream.inserts` after each render, so `@streams.documents`
    # is empty on every render that is not a fresh load — so the words inside a card and the base
    # its link is built from cannot reach the cards already on the page by re-rendering. Turning
    # the descriptions off left every card exactly as it was.
    test "and a change to what the rows are drawn from re-streams them", %{site: site} do
      manual!(site)

      {view, _first_paint} =
        mount_raw(site, [%{"name" => "doc-workspace-list", "id" => "one", "attrs" => %{}}])

      assert roles(render_async(view, @async), "doc-list-description") == 1

      send(view.pid, {:attrs, "one", %{show_description: false}})

      assert roles(render_async(view, @async), "doc-list-description") == 0,
             "the cards were never drawn again for the setting they were asked for"

      assert roles(render(view), "doc-list-item") == 1, "the cards were lost instead of redrawn"
    end

    test "beside the other blocks of a documentation page, each with its rows in the first paint",
         %{
           site: site
         } do
      manual!(site)

      attrs = %{
        workspace: "mishka-cms",
        doc_base: "/docs",
        params: %{"section" => "installation"}
      }

      {_view, first_paint} =
        mount_raw(site, [
          %{"name" => "doc-sidebar", "id" => "sidebar", "attrs" => attrs},
          %{"name" => "doc-toc", "id" => "toc", "attrs" => attrs},
          %{"name" => "doc-switcher", "id" => "switcher", "attrs" => attrs}
        ])

      for role <- ~w(doc-sidebar-loading doc-toc-loading doc-switcher-loading) do
        assert roles(first_paint, role) == 0, "#{role} was drawn in the first paint"
      end

      assert roles(first_paint, "doc-sidebar-item") > 0
    end

    # ONE BLOCK FAILING IS ONE BLOCK'S PROBLEM. The read answers with an error, so the block draws
    # its own error and the page around it, blocks and all, is still standing.
    test "and a block whose read fails takes nothing else down with it", %{site: site} do
      manual!(site)
      refuse!(site, "doc-sidebar")

      attrs = %{
        workspace: "mishka-cms",
        doc_base: "/docs",
        params: %{"section" => "installation"}
      }

      {view, _first_paint} =
        mount_raw(site, [
          %{"name" => "doc-sidebar", "id" => "sidebar", "attrs" => attrs},
          %{"name" => "doc-section", "id" => "section", "attrs" => attrs}
        ])

      arrived = render_async(view, @async)

      assert roles(arrived, "doc-sidebar-error") == 1, "the block that failed drew no error"
      assert roles(arrived, "doc-section-title") == 1, "the block beside it lost its page"
      assert roles(arrived, "doc-notice-retry") == 1, "the error offers no way to ask again"
    end

    # AND THE WAY OUT WORKS. The signature that stops a re-render from re-reading is the one thing
    # that has to be cleared for this, which is what the button's own handler does.
    test "and asking again reads again", %{site: site} do
      manual!(site)
      kept = refuse!(site, "doc-workspace-list")

      {view, _first_paint} =
        mount_raw(site, [%{"name" => "doc-workspace-list", "id" => "list", "attrs" => %{}}])

      assert roles(render_async(view, @async), "doc-list-error") == 1

      write_helpers!(site, "doc-workspace-list", kept)
      recompile!(site, "doc-workspace-list")

      view |> element(~s(#list [data-role="doc-notice-retry"])) |> render_click()

      assert roles(render_async(view, @async), "doc-list-item") == 1,
             "asking again did not read again"
    end
  end

  # THE BUILDER'S PREVIEW AND ITS CANVAS RENDER A COMPONENT WITH NO PROCESS AT ALL —
  # `MishkaCmsCore.Runtime.LiveViewHelpers.cold/2` — where `Phoenix.LiveView.Async` starts no task
  # at all, so a block that only ever read in one would draw an author its skeleton and never
  # anything else. Every block is rendered that way here.
  describe "with no socket at all" do
    test "every block still draws what it holds", %{site: site} do
      manual!(site)

      for component <- bundle_components(), component["stateful"] do
        html = cold(site, component["name"])

        refute html =~ ~s(data-tone="loading"),
               "#{component["name"]} drew its skeleton where nothing will ever finish loading"

        refute html =~ "failed to render", "#{component["name"]} did not render at all"
      end
    end

    test "and the list draws its documents", %{site: site} do
      manual!(site)

      html = cold(site, "doc-workspace-list")

      assert roles(html, "doc-list-item") == 1
      assert html =~ "Mishka CMS"
    end

    # A READ THAT FAILS IS THE BLOCK'S ERROR HERE TOO, reached through the read's own
    # `{:error, _}` and nothing that catches.
    test "and a read that fails draws the block's error", %{site: site} do
      %{pages: [placed | _rest]} = manual!(site)

      asked = %{
        "workspace" => "mishka-cms",
        "params" => %{"section" => "installation"},
        "placed_in" => placed.id
      }

      failing =
        for component <- bundle_components(),
            component["stateful"],
            [_whole, role] <- Regex.scan(~r/role="(doc-[a-z-]+-error)"/, component["template"]) do
          name = component["name"]
          unsited!(site, name)

          attrs =
            for %{"name" => attr} <- component["attrs"],
                Map.has_key?(asked, attr),
                into: %{},
                do: {String.to_existing_atom(attr), asked[attr]}

          assert roles(cold(site, name, attrs), role) == 1,
                 "#{name} drew no error for a read that failed"

          name
        end

      assert Enum.sort(failing) ==
               ~w(doc-section-cards doc-sidebar doc-switcher doc-toc doc-workspace-list)
    end
  end

  # A DOCUMENT OR A PAGE OF ONE LOCKED TO PERMISSIONS IS LEFT OUT OF EVERY LIST ITS VISITOR MAY NOT
  # OPEN IT FROM, and shown to one who may. The page hands the block its visitor as `current_user`;
  # a block handed none reads for a visitor who is not signed in.
  describe "a locked document or page in a list" do
    setup %{site: site} do
      %{version: version} = manual!(site)

      page!(site, version,
        title: "Salaries",
        slug: "salaries",
        order_position: 4,
        content: "<h2>Pay</h2><p>Monthly.</p><h2>Leave</h2><p>Yearly.</p>",
        permissions: ["members:read"]
      )

      handbook =
        document!(site, name: "Handbook", slug: "handbook", permissions: ["members:read"])

      handbook_version =
        version!(site, handbook, version_number: "1.0.0", is_latest_for_version: true)

      page!(site, handbook_version,
        title: "Desk",
        slug: "desk",
        order_position: 0,
        content: "<h2>Chairs</h2><p>Four.</p><h2>Lamps</h2><p>Two.</p>",
        permissions: ["desk:read"]
      )

      %{member: create_user_with_permissions!(["members:read"], site_id: site.id)}
    end

    test "is left out of the documents", %{site: site, member: member} do
      {:ok, guest, _html} = mount_page(site, "doc-workspace-list", %{per_page: 10})
      assert text_of(guest, ~s([data-role="doc-list-title"])) == ["Mishka CMS"]

      {:ok, shown, _html} =
        mount_page(site, "doc-workspace-list", %{per_page: 10, current_user: member})

      assert Enum.sort(text_of(shown, ~s([data-role="doc-list-title"]))) == [
               "Handbook",
               "Mishka CMS"
             ]
    end

    test "is left out of the contents", %{site: site, member: member} do
      attrs = %{workspace: "mishka-cms", lang_param: ""}

      {:ok, guest, _html} = mount_page(site, "doc-sidebar", attrs)
      refute "Salaries" in text_of(guest, ~s([data-role="doc-sidebar-link"]))

      {:ok, shown, _html} = mount_page(site, "doc-sidebar", Map.put(attrs, :current_user, member))
      assert "Salaries" in text_of(shown, ~s([data-role="doc-sidebar-link"]))
    end

    test "draws neither its text nor its headings", %{site: site, member: member} do
      attrs = %{workspace: "mishka-cms", lang_param: "", params: %{"section" => "salaries"}}

      {:ok, guest, _html} = mount_page(site, "doc-toc", attrs)
      assert text_of(guest, ~s([data-role="doc-toc-link"])) == []

      {:ok, guest, _html} = mount_page(site, "doc-section", attrs)
      assert text_of(guest, ~s([data-role="doc-section-body"])) == []

      {:ok, shown, _html} = mount_page(site, "doc-toc", Map.put(attrs, :current_user, member))
      assert text_of(shown, ~s([data-role="doc-toc-link"])) == ["Pay", "Leave"]

      {:ok, shown, _html} = mount_page(site, "doc-section", Map.put(attrs, :current_user, member))
      assert [body] = text_of(shown, ~s([data-role="doc-section-body"]))
      assert body =~ "Monthly."
    end

    # A PAGE'S OWN LOCK WINS OVER ITS DOCUMENT'S, so a reader holding only the page's reaches it
    # inside a document closed to them.
    test "whose own lock opens for the reader is drawn inside a document that does not",
         %{site: site, member: member} do
      desk = create_user_with_permissions!(["desk:read"], site_id: site.id)
      attrs = %{workspace: "handbook", lang_param: "", params: %{"section" => "desk"}}

      {:ok, shown, _html} = mount_page(site, "doc-toc", Map.put(attrs, :current_user, desk))
      assert text_of(shown, ~s([data-role="doc-toc-link"])) == ["Chairs", "Lamps"]

      {:ok, shown, _html} = mount_page(site, "doc-section", Map.put(attrs, :current_user, desk))
      assert [body] = text_of(shown, ~s([data-role="doc-section-body"]))
      assert body =~ "Four."

      {:ok, closed, _html} = mount_page(site, "doc-toc", Map.put(attrs, :current_user, member))
      assert text_of(closed, ~s([data-role="doc-toc-link"])) == []
    end
  end

  describe "doc-workspace-list" do
    test "lists the site's active documents", %{site: site} do
      manual!(site)
      document!(site, name: "Unfinished", slug: "unfinished", status: :draft)

      {:ok, view, _html} = mount_page(site, "doc-workspace-list", %{per_page: 10})

      assert text_of(view, ~s([data-role="doc-list-title"])) == ["Mishka CMS"]
    end

    test "says so when nothing is published", %{site: site} do
      {:ok, view, _html} = mount_page(site, "doc-workspace-list")

      assert text_of(view, ~s([data-role="doc-list-empty"])) == ["Nothing published yet."]
    end

    # ANOTHER SITE'S DOCUMENTS ARE NOT THIS SITE'S. The tenant comes from the component's own
    # compiled metadata, so it is not something a stored template could be edited into changing.
    test "reads only its own site's documents", %{site: site} do
      manual!(site)
      elsewhere = create_site!(name: "elsewhere#{System.unique_integer([:positive])}")
      document!(elsewhere, name: "Theirs", slug: "theirs")

      {:ok, view, _html} = mount_page(site, "doc-workspace-list", %{per_page: 10})

      assert text_of(view, ~s([data-role="doc-list-title"])) == ["Mishka CMS"]
    end

    test "follows the order an editor gave them, and the other orders an author can ask for", %{
      site: site
    } do
      # Three of them, written in the order an editor also gave them, and the middle one touched
      # afterwards — so the three answers below are three different lists and none of them can be
      # right by accident.
      document!(site, name: "First", slug: "first", display_order: 1)
      middle = document!(site, name: "Second", slug: "second", display_order: 2)
      document!(site, name: "Third", slug: "third", display_order: 3)

      {:ok, ordered, _html} = mount_page(site, "doc-workspace-list", %{per_page: 10})

      assert text_of(ordered, ~s([data-role="doc-list-title"])) == ["First", "Second", "Third"]

      {:ok, newest, _html} =
        mount_page(site, "doc-workspace-list", %{per_page: 10, sort: "newest"})

      assert text_of(newest, ~s([data-role="doc-list-title"])) == ["Third", "Second", "First"],
             "newest is the order they were started in, the most recent first"

      # Touching one is what makes it the most recently changed, which is the whole of what
      # `updated` orders by — and it is the order that puts the document somebody is working on in
      # front of the one nobody has opened in a year.
      middle
      |> Ash.Changeset.for_update(:master_update, %{description: "Changed."}, authorize?: false)
      |> Ash.update!(authorize?: false)

      {:ok, updated, _html} =
        mount_page(site, "doc-workspace-list", %{per_page: 10, sort: "updated"})

      assert text_of(updated, ~s([data-role="doc-list-title"])) == ["Second", "Third", "First"]
    end

    test "keeps only the documents an editor flagged when asked", %{site: site} do
      document!(site, name: "Ordinary", slug: "ordinary")
      document!(site, name: "Picked", slug: "picked", featured: true)

      {:ok, view, _html} =
        mount_page(site, "doc-workspace-list", %{per_page: 10, featured_only: true})

      assert text_of(view, ~s([data-role="doc-list-title"])) == ["Picked"]
      assert text_of(view, ~s([data-role="doc-list-featured"])) == ["Featured"]
    end

    # THE POINT OF THE WHOLE FEATURE. The page number lives on the component, a click reaches the
    # component's own handler through `@myself`, and the list moves.
    test "pages forward and back", %{site: site} do
      for {name, order} <- Enum.with_index(~w(A B C D E)) do
        document!(site, name: name, slug: String.downcase(name), display_order: order)
      end

      {:ok, view, _html} = mount_page(site, "doc-workspace-list", %{per_page: 2})

      assert text_of(view, ~s([data-role="doc-list-position"])) == ["1 / 3"]

      view |> element(~s(#one [data-role="doc-list-next"])) |> render_click()
      assert text_of(view, ~s([data-role="doc-list-title"])) == ["C", "D"]

      view |> element(~s(#one [data-role="doc-list-prev"])) |> render_click()
      assert text_of(view, ~s([data-role="doc-list-title"])) == ["A", "B"]
    end

    test "reads its page out of the URL when the page gave it one", %{site: site} do
      for {name, order} <- Enum.with_index(~w(A B C D)) do
        document!(site, name: name, slug: String.downcase(name), display_order: order)
      end

      {:ok, view, _html} =
        mount_page(site, "doc-workspace-list", %{
          per_page: 2,
          base: "/docs",
          params: %{"page" => "2"}
        })

      assert text_of(view, ~s([data-role="doc-list-title"])) == ["C", "D"]
      assert hrefs(view, ~s([data-role="doc-list-prev"])) == ["/docs?page=1"]
    end

    # A PAGE THE ADDRESS NAMES PAST THE LAST ONE IS MISSING, so `?page=999` is not one more address
    # of the last page: the HTTP render raises, and a connected one asks the page for its 404.
    test "is missing at a page the URL names past the last one", %{site: site} do
      for {name, order} <- Enum.with_index(~w(A B C)) do
        document!(site, name: name, slug: String.downcase(name), display_order: order)
      end

      for page <- ["3", "999"] do
        assert_raise MishkaCmsCore.ErrorsExceptions.NotFoundError, fn ->
          mount_page(site, "doc-workspace-list", %{per_page: 2, params: %{"page" => page}})
        end
      end

      for {page, titles} <- [{"1", ["A", "B"]}, {"2", ["C"]}] do
        {:ok, view, _html} =
          mount_page(site, "doc-workspace-list", %{per_page: 2, params: %{"page" => page}})

        assert text_of(view, ~s([data-role="doc-list-title"])) == titles
        refute has_element?(view, "#runtime-not-found")
      end

      {:ok, view, _html} = mount_page(site, "doc-workspace-list", %{per_page: 2})
      send(view.pid, {:params, %{"page" => "9"}})
      render_async(view, @async)

      assert has_element?(view, "#runtime-not-found")
    end

    test "but a page the pager asks for past the last one is the last one", %{site: site} do
      for {name, order} <- Enum.with_index(~w(A B C)) do
        document!(site, name: name, slug: String.downcase(name), display_order: order)
      end

      {:ok, view, _html} = mount_page(site, "doc-workspace-list", %{per_page: 2})

      view |> with_target("#one") |> render_click("page", %{"to" => "9"})

      assert text_of(view, ~s([data-role="doc-list-title"])) == ["C"]
      refute has_element?(view, "#runtime-not-found")
    end

    test "links each document where the page said documents live", %{site: site} do
      manual!(site)

      {:ok, view, _html} = mount_page(site, "doc-workspace-list", %{doc_base: "/docs"})

      assert hrefs(view, ~s([data-role="doc-list-title"])) == ["/docs/mishka-cms?lang=en"]
    end

    # AT THE ADDRESS THE SITE'S URL MODE GIVES THE LANGUAGE: English, the first, unprefixed while
    # the site leaves it so.
    for mode <- ~w(prefix_others prefix_all) do
      test "and leaves the language alone when the path already carries it, in #{mode}", %{
        site: site
      } do
        url_mode!(site, unquote(mode))
        manual!(site)

        {:ok, view, _html} = mount_page(site, "doc-workspace-list", %{doc_base: "/:lang/docs"})

        assert hrefs(view, ~s([data-role="doc-list-title"])) == [
                 english(unquote(mode), "/docs/mishka-cms")
               ]
      end
    end

    # `:lang` IS NOT THE FIRST SEGMENT BY DECREE. A page may be stored at /docs/:lang and the link
    # has to be built by replacing that segment wherever it sits.
    test "and fills the language segment wherever the page put it", %{site: site} do
      manual!(site)

      {:ok, view, _html} = mount_page(site, "doc-workspace-list", %{doc_base: "/docs/:lang"})

      assert hrefs(view, ~s([data-role="doc-list-title"])) == ["/docs/en/mishka-cms"]
    end

    test "draws the author's own card when they named one", %{site: site} do
      manual!(site)

      create_component!(
        site_id: site.id,
        name: "my-doc-card",
        template: ~s(<div data-role="mine">{@doc.name} at {@href}</div>),
        attrs: [
          %{name: "doc", type: "any", opts: %{"default" => nil}},
          %{name: "href", type: "any", opts: %{"default" => nil}}
        ],
        active: true
      )

      {:ok, view, _html} =
        mount_page(site, "doc-workspace-list", %{card: "my-doc-card", doc_base: "/docs"})

      assert text_of(view, ~s([data-role="mine"])) == ["Mishka CMS at /docs/mishka-cms?lang=en"]
      assert text_of(view, ~s([data-role="doc-list-title"])) == [], "it drew both cards"
    end
  end

  describe "doc-workspace-list with details" do
    test "draws none unless asked", %{site: site} do
      manual!(site)

      {:ok, view, _html} = mount_page(site, "doc-workspace-list", %{per_page: 10})

      assert Enum.empty?(drawn(view, ~s([data-role="doc-list-meta"])))
    end

    test "draws each document's version, pages, language and last change", %{site: site} do
      %{document: document, pages: pages} = manual!(site)

      {:ok, view, _html} =
        mount_page(site, "doc-workspace-list", %{per_page: 10, show_details: true})

      assert text_of(view, ~s([data-role="doc-list-version"])) == ["v1.0.0"]
      assert text_of(view, ~s([data-role="doc-list-pages"])) == ["4 pages"]
      assert text_of(view, ~s([data-role="doc-list-language-codes"])) == ["en"]

      document =
        Ash.get!(MishkaDocument.Workspace, document.id, action: :master_get, authorize?: false)

      newest = Enum.max([document.updated_at | Enum.map(pages, & &1.updated_at)], DateTime)

      assert [datetime] =
               view
               |> drawn(~s([data-role="doc-list-updated"] time))
               |> Enum.map(&LazyHTML.attribute(&1, "datetime"))
               |> List.flatten()

      assert {:ok, ^newest, 0} = DateTime.from_iso8601(datetime)
    end

    test "counts the pages of the version a reader lands on, as the visitor may read them", %{
      site: site
    } do
      %{document: document, version: version} = manual!(site)

      page!(site, version,
        title: "Locked",
        slug: "locked",
        order_position: 4,
        permissions: ["members:read"]
      )

      page!(site, version,
        title: "Waiting",
        slug: "waiting",
        order_position: 5,
        content_review_status: :pending
      )

      page!(site, version, title: "Group", slug: "group", order_position: 6, group_heading: true)

      newer =
        version!(site, document,
          version_number: "2.0.0-beta",
          status: :beta,
          published_at: ~U[2026-02-01 00:00:00Z]
        )

      page!(site, newer, title: "Only in the beta", slug: "beta", order_position: 0)

      member = create_user_with_permissions!(["members:read"], site_id: site.id)

      {:ok, guest, _html} =
        mount_page(site, "doc-workspace-list", %{per_page: 10, show_details: true})

      assert text_of(guest, ~s([data-role="doc-list-version"])) == ["v1.0.0"]
      assert text_of(guest, ~s([data-role="doc-list-pages"])) == ["4 pages"]

      {:ok, shown, _html} =
        mount_page(site, "doc-workspace-list", %{
          per_page: 10,
          show_details: true,
          current_user: member
        })

      assert text_of(shown, ~s([data-role="doc-list-pages"])) == ["5 pages"]
    end

    test "says one page as one, in the words the page gave it", %{site: site} do
      document = document!(site, name: "Leaflet", slug: "leaflet")
      version = version!(site, document, version_number: "0.1.0", is_latest_for_version: true)
      page!(site, version, title: "Only", slug: "only", order_position: 0)

      {:ok, view, _html} =
        mount_page(site, "doc-workspace-list", %{
          per_page: 10,
          show_details: true,
          one_page_text: "%{count} Seite",
          version_text: "Version %{version}"
        })

      assert text_of(view, ~s([data-role="doc-list-pages"])) == ["1 Seite"]
      assert text_of(view, ~s([data-role="doc-list-version"])) == ["Version 0.1.0"]
    end

    test "names every language a document is published in", %{site: site} do
      {:ok, _} = MishkaCmsCore.Settings.put("site.languages", ["en", "fa"], site_id: site.id)
      %{document: document} = manual!(site)

      document!(site,
        name: "میشکا",
        slug: "mishka-cms-fa",
        language: "fa",
        language_group_id: document.language_group_id
      )

      create_component!(
        site_id: site.id,
        name: "my-languages-card",
        template: ~S|<div data-role="languages">{Enum.join(@details.languages, " ")}</div>|,
        attrs: [
          %{name: "doc", type: "any", opts: %{"default" => nil}},
          %{name: "href", type: "any", opts: %{"default" => nil}},
          %{name: "details", type: "any", opts: %{"default" => nil}}
        ],
        active: true
      )

      {:ok, custom, _html} =
        mount_page(site, "doc-workspace-list", %{
          per_page: 10,
          show_details: true,
          card: "my-languages-card"
        })

      assert text_of(custom, ~s([data-role="languages"])) == ["en fa"]

      # The chips already name them, so the card does not say them twice.
      {:ok, chips, _html} =
        mount_page(site, "doc-workspace-list", %{
          per_page: 10,
          show_details: true,
          show_languages: true
        })

      assert Enum.empty?(drawn(chips, ~s([data-role="doc-list-language-codes"])))
      assert Enum.sort(text_of(chips, ~s([data-role="doc-list-language"]))) == ["en", "fa"]
    end

    test "hands them to the author's own card", %{site: site} do
      manual!(site)

      create_component!(
        site_id: site.id,
        name: "my-detailed-card",
        template:
          ~s(<div data-role="mine">{@doc.name}: v{@details.version}, {@details.pages}</div>),
        attrs: [
          %{name: "doc", type: "any", opts: %{"default" => nil}},
          %{name: "href", type: "any", opts: %{"default" => nil}},
          %{name: "details", type: "any", opts: %{"default" => nil}}
        ],
        active: true
      )

      {:ok, view, _html} =
        mount_page(site, "doc-workspace-list", %{
          per_page: 10,
          show_details: true,
          card: "my-detailed-card"
        })

      assert text_of(view, ~s([data-role="mine"])) == ["Mishka CMS: v1.0.0, 4"]
    end

    test "has nothing to say about a version when none is published", %{site: site} do
      document!(site, name: "Unwritten", slug: "unwritten")

      {:ok, view, _html} =
        mount_page(site, "doc-workspace-list", %{per_page: 10, show_details: true})

      assert Enum.empty?(drawn(view, ~s([data-role="doc-list-version"])))
      assert text_of(view, ~s([data-role="doc-list-pages"])) == ["0 pages"]
    end
  end

  # ONE DOCUMENT, ONCE. A manual written in four languages is four rows sharing a group, and a
  # listing that showed all four showed the same manual four times over.
  describe "doc-workspace-list in one language" do
    setup %{site: site} do
      # THE SITE HAS TO PUBLISH PERSIAN for its Persian edition to have a URL at all: `:lang` only
      # answers `site.languages`, so a chip leading to `/fa/docs/...` on a site that does not list
      # `fa` would lead to a 404 — see "says so as a word".
      {:ok, _} = MishkaCmsCore.Settings.put("site.languages", ["en", "fa"], site_id: site.id)
      master = document!(site, name: "Mishka CMS", slug: "mishka-cms")

      persian =
        document!(site,
          name: "میشکا",
          slug: "mishka-cms-fa",
          language: "fa",
          language_group_id: master.language_group_id
        )

      {:ok, master: master, persian: persian}
    end

    test "shows one edition of each document by default", %{site: site} do
      {:ok, view, _html} = mount_page(site, "doc-workspace-list", %{per_page: 10})

      assert text_of(view, ~s([data-role="doc-list-title"])) == ["Mishka CMS"]
    end

    test "shows one language when the page names one", %{site: site} do
      {:ok, view, _html} = mount_page(site, "doc-workspace-list", %{per_page: 10, lang: "fa"})

      assert text_of(view, ~s([data-role="doc-list-title"])) == ["میشکا"]
    end

    test "and every edition when the page asks for all of them", %{site: site} do
      {:ok, view, _html} = mount_page(site, "doc-workspace-list", %{per_page: 10, lang: "all"})

      assert Enum.sort(text_of(view, ~s([data-role="doc-list-title"]))) == ["Mishka CMS", "میشکا"]
    end

    test "a reader may ask for another language through the URL", %{site: site} do
      {:ok, view, _html} =
        mount_page(site, "doc-workspace-list", %{per_page: 10, params: %{"lang" => "fa"}})

      assert text_of(view, ~s([data-role="doc-list-title"])) == ["میشکا"]
    end

    # AND AN AUTHOR MAY REFUSE THEM. A page built as the Persian index is not something a query
    # string turns into the English one.
    test "unless the author emptied the key it travels under", %{site: site} do
      {:ok, view, _html} =
        mount_page(site, "doc-workspace-list", %{
          per_page: 10,
          lang: "fa",
          lang_param: "",
          params: %{"lang" => "en"}
        })

      assert text_of(view, ~s([data-role="doc-list-title"])) == ["میشکا"]
    end

    test "a right-to-left edition says so on the element around it", %{site: site} do
      {:ok, view, _html} = mount_page(site, "doc-workspace-list", %{per_page: 10, lang: "fa"})

      directions =
        view
        |> render_async(@async)
        |> LazyHTML.from_fragment()
        |> LazyHTML.query(~s([data-role="doc-workspace-list"]))
        |> Enum.map(&LazyHTML.attribute(&1, "dir"))
        |> List.flatten()

      assert directions == ["rtl"]
    end

    for mode <- ~w(prefix_others prefix_all) do
      test "and the chips lead to the other editions, in #{mode}", %{site: site} do
        url_mode!(site, unquote(mode))

        {:ok, view, _html} =
          mount_page(site, "doc-workspace-list", %{
            per_page: 10,
            show_languages: true,
            doc_base: "/:lang/docs"
          })

        assert Enum.sort(hrefs(view, ~s([data-role="doc-list-language"]))) ==
                 Enum.sort([english(unquote(mode), "/docs/mishka-cms"), "/fa/docs/mishka-cms-fa"])
      end
    end

    # AND SAYS SO AS A WORD where the site cannot serve that language. The translation was written
    # and the chip row is what says so; a link to a URL the site does not answer would not.
    test "and says so as a word where the site does not publish that language", %{site: site} do
      {:ok, _} = MishkaCmsCore.Settings.put("site.languages", ["en"], site_id: site.id)

      {:ok, view, _html} =
        mount_page(site, "doc-workspace-list", %{
          per_page: 10,
          show_languages: true,
          doc_base: "/:lang/docs"
        })

      assert hrefs(view, ~s([data-role="doc-list-language"])) == ["/docs/mishka-cms"]
      assert Enum.sort(text_of(view, ~s([data-role="doc-list-language"]))) == ["en", "fa"]
    end

    # AND NO CHIPS AT ALL UNDER A DOCUMENT NOBODY TRANSLATED. Every document written through the CMS
    # is the master of a group holding itself — `SetLanguageGroupId` fills the group with the row's
    # own id — so a chip row drawn from the group puts a lone "en" under every card on a site that
    # publishes in one language.
    test "and a document with one edition gets none", %{site: site} do
      alone = document!(site, name: "Alone", slug: "alone")

      {:ok, view, _html} =
        mount_page(site, "doc-workspace-list", %{
          per_page: 10,
          show_languages: true,
          doc_base: "/:lang/docs"
        })

      assert text_of(view, ~s([data-role="doc-list-title"])) == ["Alone", "Mishka CMS"]

      assert text_of(view, ~s(#one-doc-#{alone.id} [data-role="doc-list-language"])) == [],
             "a document with one edition offered the language it is already written in"

      assert text_of(view, ~s([data-role="doc-list-language"])) == ["en", "fa"],
             "the document that does have two editions lost its chips"
    end
  end

  describe "doc-section" do
    test "says nothing is chosen when the URL names no document", %{site: site} do
      {:ok, view, _html} = mount_page(site, "doc-section")

      assert text_of(view, ~s([data-role="doc-section-idle"])) == ["Choose a document."]
      assert text_of(view, ~s([data-role="doc-section-article"])) == []
    end

    test "draws the document's front page when no page is named", %{site: site} do
      manual!(site)

      {:ok, view, _html} = mount_page(site, "doc-section", %{workspace: "mishka-cms"})

      assert text_of(view, ~s([data-role="doc-landing-title"])) == ["Mishka CMS"]
      assert text_of(view, ~s([data-role="doc-landing-description"])) == ["The manual."]

      assert text_of(view, ~s([data-role="doc-landing-link"])) ==
               ["Getting started", "Installation", "Upgrading", "Appendix"]
    end

    test "and the page the URL names", %{site: site} do
      manual!(site)

      {:ok, view, _html} =
        mount_page(site, "doc-section", %{
          workspace: "mishka-cms",
          params: %{"section" => "installation"}
        })

      assert text_of(view, ~s([data-role="doc-section-title"])) == ["Installation"]

      assert [body] = text_of(view, ~s([data-role="doc-section-body"]))
      assert body =~ "Body of Installation."
    end

    # A PAGE'S CODE IS STORED HIGHLIGHTED, and the body is scrubbed again on its way to the page.
    # The token classes and the block's language have to come through that, or the kit's stylesheet
    # has nothing to colour.
    test "draws a whole page with its code highlighted as it was stored", %{site: site} do
      %{version: version} = manual!(site)

      editor =
        create_user_with_permissions!(["admin:dashboard:document:section"], site_id: site.id)

      prose = "<p>#{String.duplicate("Words about it. ", 60)}</p>"

      content =
        Enum.map_join(1..6, fn index ->
          "<h2>Step #{index}</h2>" <>
            prose <>
            ~S|<pre><code class="language-elixir">def hello(name), do: "Hi #{name}"</code></pre>|
        end)

      assert byte_size(content) > 6_000

      page =
        MishkaDocument.Section
        |> Ash.Changeset.for_create(
          :create,
          %{
            workspace_version_id: version.id,
            title: "Long page",
            slug: "long-page",
            order_position: 9,
            language: "en",
            content: content,
            content_review_status: :approved,
            technical_review_status: :approved
          },
          actor: editor,
          tenant: site.id
        )
        |> Ash.create!()

      attrs = %{workspace: "mishka-cms", params: %{"section" => "long-page"}}
      {:ok, view, _html} = mount_page(site, "doc-section", attrs)

      token_classes = fn html, scope ->
        html
        |> LazyHTML.from_fragment()
        |> LazyHTML.query(scope <> " pre.highlight > code.language-elixir > span")
        |> LazyHTML.attribute("class")
      end

      stored = token_classes.(page.content, "")
      drawn = token_classes.(render_async(view, @async), ~s([data-role="doc-section-body"]))

      assert "kd" in stored and "nf" in stored and "s" in stored
      assert drawn == stored

      {:ok, toc, _html} = mount_page(site, "doc-toc", attrs)

      assert text_of(toc, ~s([data-role="doc-toc-link"])) ==
               Enum.map(1..6, &"Step #{&1}")
    end

    # A CODE BLOCK IS READ IN A WINDOW THE BLOCK DRAWS, not one the page stores: a head with the
    # language the block was stored with and a button that copies it, over the block as it was. The
    # stored text keeps only its code.
    test "draws each code block in a window with its language and a copy button", %{site: site} do
      %{version: version} = manual!(site)

      content =
        ~S|<h2>Install</h2><p>Add it.</p>| <>
          ~S|<pre><code class="language-elixir">def deps, do: []</code></pre>| <>
          ~S|<p>Then run it.</p><pre><code>mix deps.get</code></pre>|

      page =
        page!(site, version, title: "Code", slug: "code", order_position: 9, content: content)

      {:ok, view, _html} =
        mount_page(site, "doc-section", %{workspace: "mishka-cms", params: %{"section" => "code"}})

      body = drawn(view, ~s([data-role="doc-section-body"]))
      windows = LazyHTML.query(body, ~s([data-role="doc-code"]))

      assert Enum.count(windows) == 2
      assert LazyHTML.attribute(windows, "data-language") == ["elixir", ""]
      assert text_of(view, ~s([data-role="doc-code-lang"])) == ["elixir", ""]

      assert text_of(view, ~s([data-role="doc-code"] > pre > code)) ==
               ["def deps, do: []", "mix deps.get"]

      assert body |> LazyHTML.query("pre.highlight > code.language-elixir > span") |> Enum.count() >
               0

      buttons =
        LazyHTML.query(
          body,
          ~s([data-role="doc-code"] > [data-role="doc-code-head"] > button[type="button"][data-role="doc-code-copy"])
        )

      assert Enum.count(buttons) == 2
      assert LazyHTML.attribute(buttons, "aria-label") == ["Copy code", "Copy code"]
      assert LazyHTML.attribute(buttons, "data-copied-text") == ["Copied", "Copied"]
      assert text_of(view, ~s([data-role="doc-code-copy-text"])) == ["Copy", "Copy"]
      assert text_of(view, ~s([data-role="doc-code-copied-text"])) == ["✓Copied", "✓Copied"]

      statuses =
        LazyHTML.query(body, ~s([data-role="doc-code-head"] > [data-role="doc-code-status"]))

      assert LazyHTML.attribute(statuses, "aria-live") == ["polite", "polite"]
      assert text_of(view, ~s([data-role="doc-code-status"])) == ["", ""]

      stored = Ash.get!(MishkaDocument.Section, page.id, authorize?: false, tenant: site.id)

      refute stored.content =~ "doc-code"
      assert stored.content =~ ~S|<p>Then run it.</p><pre><code>mix deps.get</code></pre>|
    end

    test "and its button says what an author tells it to, as text", %{site: site} do
      %{version: version} = manual!(site)

      page!(site, version,
        title: "Code",
        slug: "code",
        order_position: 9,
        content: ~S|<pre><code class="language-heex">&lt;.button /&gt;</code></pre>|
      )

      {:ok, view, _html} =
        mount_page(site, "doc-section", %{
          workspace: "mishka-cms",
          params: %{"section" => "code"},
          copy_text: "Kopieren",
          copied_text: ~S|Kopiert <b>"ok"</b>|,
          copy_label: "Code kopieren"
        })

      button = drawn(view, ~s([data-role="doc-code-copy"]))

      assert LazyHTML.attribute(button, "aria-label") == ["Code kopieren"]
      assert LazyHTML.attribute(button, "data-copied-text") == [~S|Kopiert <b>"ok"</b>|]
      assert text_of(view, ~s([data-role="doc-code-copy-text"])) == ["Kopieren"]
      assert text_of(view, ~s([data-role="doc-code-copied-text"])) == [~S|✓Kopiert <b>"ok"</b>|]
      assert button |> LazyHTML.query("b") |> Enum.count() == 0
      assert text_of(view, ~s([data-role="doc-code-lang"])) == ["heex"]
      assert text_of(view, ~s([data-role="doc-code"] code)) == ["<.button />"]
    end

    test "and leaves a page with no code block as it was", %{site: site} do
      manual!(site)

      {:ok, view, _html} =
        mount_page(site, "doc-section", %{
          workspace: "mishka-cms",
          params: %{"section" => "installation"}
        })

      body = drawn(view, ~s([data-role="doc-section-body"]))

      assert body |> LazyHTML.query(~s([data-role^="doc-code"])) |> Enum.count() == 0
      assert text_of(view, ~s([data-role="doc-section-body"] > p)) == ["Body of Installation."]
    end

    # A LONG BLOCK IS CUT AT `code_lines`, with a button under it that shows all of it and says how
    # many lines that is; a short one is drawn as it always was.
    test "cuts a code block of more lines than code_lines, with the button that shows all of it",
         %{site: site} do
      %{version: version} = manual!(site)
      long = Enum.map_join(1..20, "\n", &"line #{&1}")

      page!(site, version,
        title: "Code",
        slug: "code",
        order_position: 9,
        content:
          ~s|<pre><code class="language-elixir">#{long}\n</code></pre>| <>
            ~S|<pre><code>mix deps.get</code></pre>|
      )

      {:ok, view, _html} =
        mount_page(site, "doc-section", %{workspace: "mishka-cms", params: %{"section" => "code"}})

      windows = drawn(view, ~s([data-role="doc-section-body"] [data-role="doc-code"]))
      assert LazyHTML.attribute(windows, "data-collapsible") == ["true"]
      assert LazyHTML.attribute(windows, "data-collapse-lines") == ["16"]

      [long_window, short_window] = Enum.to_list(windows)

      assert long_window |> LazyHTML.query("pre") |> LazyHTML.attribute("id") == [
               "one-body-code-0"
             ]

      button = LazyHTML.query(long_window, ~s(pre + [data-role="doc-code-foot"] > button))
      assert LazyHTML.attribute(button, "type") == ["button"]
      assert LazyHTML.attribute(button, "data-role") == ["doc-code-expand"]
      assert LazyHTML.attribute(button, "aria-expanded") == ["false"]
      assert LazyHTML.attribute(button, "aria-controls") == ["one-body-code-0"]

      assert text_of(view, ~s([data-role="doc-code-expand-text"])) == ["Show all 20 lines"]
      assert text_of(view, ~s([data-role="doc-code-collapse-text"])) == ["Show less"]
      assert text_of(view, ~s([data-role="doc-code"] > pre > code)) == [long, "mix deps.get"]

      assert short_window |> LazyHTML.query("pre") |> LazyHTML.attribute("id") == []
      assert short_window |> LazyHTML.query(~s([data-role="doc-code-foot"])) |> Enum.count() == 0
    end

    test "and cuts none at code_lines 0, its button saying what an author tells it to",
         %{site: site} do
      %{version: version} = manual!(site)
      long = Enum.map_join(1..20, "\n", &"line #{&1}")

      page!(site, version,
        title: "Code",
        slug: "code",
        order_position: 9,
        content: ~s|<pre><code>#{long}</code></pre>|
      )

      {:ok, whole, _html} =
        mount_page(site, "doc-section", %{
          workspace: "mishka-cms",
          params: %{"section" => "code"},
          code_lines: 0
        })

      assert text_of(whole, ~s([data-role="doc-code-foot"])) == []
      assert whole |> drawn("[data-collapsible]") |> Enum.count() == 0

      {:ok, cut, _html} =
        mount_page(site, "doc-section", %{
          workspace: "mishka-cms",
          params: %{"section" => "code"},
          code_lines: 8,
          expand_text: ~S|Alle %{count} <b>Zeilen</b>|,
          collapse_text: "Weniger"
        })

      assert cut |> drawn("[data-collapse-lines]") |> LazyHTML.attribute("data-collapse-lines") ==
               ["8"]

      assert text_of(cut, ~s([data-role="doc-code-expand-text"])) == [~S|Alle 20 <b>Zeilen</b>|]
      assert text_of(cut, ~s([data-role="doc-code-collapse-text"])) == ["Weniger"]
      assert cut |> drawn(~s([data-role="doc-code-foot"] b)) |> Enum.count() == 0
    end

    # A NOTE IS STORED AS A PAGE'S TEXT IS, so its code block keeps its language, and its window
    # carries the button.
    test "and draws a note's code blocks in windows as well", %{site: site} do
      %{pages: [_first, installation | _rest]} = manual!(site)

      note!(site, installation,
        title: "On Windows",
        content: ~S|<p>Use PowerShell.</p><pre><code class="language-bash">mix setup</code></pre>|
      )

      {:ok, view, _html} =
        mount_page(site, "doc-section", %{
          workspace: "mishka-cms",
          params: %{"section" => "installation"}
        })

      assert text_of(view, ~s([data-role="doc-note-body"] [data-role="doc-code-lang"])) == [
               "bash"
             ]

      assert text_of(view, ~s([data-role="doc-note-body"] [data-role="doc-code"] > pre > code)) ==
               ["mix setup"]

      assert view
             |> drawn(~s([data-role="doc-note-body"] [data-role="doc-code-copy"]))
             |> Enum.count() == 1
    end

    # THE BUTTONS ARE ANSWERED BY THE KIT'S OWN HOOK, mounted on the block's root and not inside its
    # text, under the name the site's JavaScript registers the installed row by.
    test "mounts the kit's copy hook on its root", %{site: site} do
      hook =
        MishkaCmsCore.Runtime.JsHook
        |> Ash.Query.for_read(:read_any, %{}, authorize?: false)
        |> Ash.Query.filter(name == "doc-code-copy" and site_id == ^site.id)
        |> Ash.Query.load([:is_global])
        |> Ash.read_one!()

      assert hook, "installing the kit wrote no doc-code-copy hook for the site"
      assert hook.active

      manual!(site)

      {:ok, view, _html} =
        mount_page(site, "doc-section", %{
          workspace: "mishka-cms",
          params: %{"section" => "installation"}
        })

      root = drawn(view, ~s(#one[data-role="doc-section"]))

      registered =
        MishkaCmsCore.Runtime.Compilers.JavaScriptCompiler.browser_name(hook, site.name)

      assert registered == String.capitalize(site.name) <> "DocCodeCopy"
      assert LazyHTML.attribute(root, "phx-hook") == [registered]
      assert view |> drawn(~s([data-role="doc-section-body"] [phx-hook])) |> Enum.count() == 0
    end

    # A SLUG THAT NAMES NOTHING IS A DIFFERENT SENTENCE from no slug at all — one is "pick a
    # document", the other is "that page is gone", and a reader who followed a stale link deserves
    # the second.
    test "and says so when the slug names nothing published", %{site: site} do
      manual!(site)

      {:ok, gone_page, _html} =
        mount_page(site, "doc-section", %{
          workspace: "mishka-cms",
          params: %{"section" => "no-such-page"}
        })

      assert text_of(gone_page, ~s([data-role="doc-section-missing"])) != []

      {:ok, gone_doc, _html} = mount_page(site, "doc-section", %{workspace: "no-such-document"})

      assert text_of(gone_doc, ~s([data-role="doc-section-missing"])) != []
      assert text_of(gone_doc, ~s([data-role="doc-section-idle"])) == []
    end

    # AND WHEN THE URL NAMES ONE THAT IS NOT THERE, the page is missing rather than a page with a
    # notice on it — the answer a reader who followed a stale link needs and the one a crawler reads.
    # `MishkaCmsWeb.Live.RuntimeLive` turns the same raise into the 404 page on a live render.
    test "raises when the URL names a document that is not there", %{site: site} do
      manual!(site)

      assert_raise MishkaCmsCore.ErrorsExceptions.NotFoundError, fn ->
        mount_page(site, "doc-section", %{params: %{"workspace" => "no-such-document"}})
      end
    end

    test "raises when the URL names a section that is not there", %{site: site} do
      manual!(site)

      assert_raise MishkaCmsCore.ErrorsExceptions.NotFoundError, fn ->
        mount_page(site, "doc-section", %{
          params: %{"workspace" => "mishka-cms", "section" => "no-such-page"}
        })
      end
    end

    # THE OTHER HALF OF THE SAME LINE, kept honest: the two above are the page's own subject, and a
    # document an author PINNED is not. A stray `?section=` on their page draws the notice and the
    # page stands — which is what the five tests above this one assert from the other direction.
    test "but a pinned document keeps its page standing", %{site: site} do
      manual!(site)

      {:ok, view, _html} =
        mount_page(site, "doc-section", %{
          workspace: "mishka-cms",
          params: %{"section" => "no-such-page"}
        })

      assert text_of(view, ~s([data-role="doc-section-missing"])) != []
    end

    test "reads the document out of the URL when the page did not pin one", %{site: site} do
      manual!(site)

      {:ok, view, _html} =
        mount_page(site, "doc-section", %{
          params: %{"workspace" => "mishka-cms", "section" => "upgrading"}
        })

      assert text_of(view, ~s([data-role="doc-section-title"])) == ["Upgrading"]
    end

    # THE AUTHOR'S CHOICE WINS. A block pinned to one document sits on a page about that document.
    test "and a pinned document is not changed by the URL", %{site: site} do
      manual!(site)
      other = document!(site, name: "Other", slug: "other")
      version!(site, other, version_number: "1.0.0", is_latest_for_version: true)

      {:ok, view, _html} =
        mount_page(site, "doc-section", %{
          workspace: "mishka-cms",
          params: %{"workspace" => "other"}
        })

      assert text_of(view, ~s([data-role="doc-landing-title"])) == ["Mishka CMS"]
    end

    # A PAGE STILL IN REVIEW IS NOT A PAGE. Its slug still resolves in the URL, and a component that
    # read it would publish, through the back door, work its author has not finished.
    test "never draws a page that is not approved", %{site: site} do
      %{version: version} = manual!(site)

      page!(site, version,
        title: "Secret",
        slug: "secret",
        order_position: 9,
        content_review_status: :pending
      )

      {:ok, landing, _html} = mount_page(site, "doc-section", %{workspace: "mishka-cms"})
      refute "Secret" in text_of(landing, ~s([data-role="doc-landing-link"]))

      {:ok, asked, _html} =
        mount_page(site, "doc-section", %{
          workspace: "mishka-cms",
          params: %{"section" => "secret"}
        })

      assert text_of(asked, ~s([data-role="doc-section-missing"])) != []
    end

    test "nor a page of a document nobody activated", %{site: site} do
      draft = document!(site, name: "Draft", slug: "draft-doc", status: :draft)
      version = version!(site, draft, version_number: "1.0.0", is_latest_for_version: true)
      page!(site, version, title: "Hidden", slug: "hidden", order_position: 0)

      {:ok, view, _html} =
        mount_page(site, "doc-section", %{
          workspace: "draft-doc",
          params: %{"section" => "hidden"}
        })

      assert text_of(view, ~s([data-role="doc-section-missing"])) != []
    end

    # THE GAP THE RESOURCE LEAVES OPEN, CLOSED HERE. `Section.public_list_at_workspace_version`
    # checks the page and not the version it belongs to, so a component resolving a version by id
    # would serve a draft version's approved pages to anyone who typed the number. Every version is
    # resolved through `WorkspaceVersion.public_list` instead, and a number that read does not
    # answer with is a number nobody can reach.
    test "nor a page of a version nobody published, whoever types the number", %{site: site} do
      %{document: document} = manual!(site)
      draft = version!(site, document, version_number: "9.9.9", status: :draft)
      page!(site, draft, title: "Unreleased", slug: "unreleased", order_position: 0)

      {:ok, view, _html} =
        mount_page(site, "doc-section", %{
          workspace: "mishka-cms",
          params: %{"section" => "unreleased", "v" => "9.9.9"}
        })

      assert text_of(view, ~s([data-role="doc-section-missing"])) != []
      assert text_of(view, ~s([data-role="doc-section-title"])) == []
    end

    test "reads only its own site's documents", %{site: site} do
      elsewhere = create_site!(name: "elsewhere#{System.unique_integer([:positive])}")
      theirs = document!(elsewhere, name: "Theirs", slug: "theirs")
      version!(elsewhere, theirs, version_number: "1.0.0", is_latest_for_version: true)

      {:ok, view, _html} = mount_page(site, "doc-section", %{workspace: "theirs"})

      assert text_of(view, ~s([data-role="doc-section-missing"])) != []
    end

    # NOR A DOCUMENT IN A LANGUAGE IT IS NOT WRITTEN IN. A slug names one document per site whatever
    # language that document is in, so narrowing the lookup by the language the URL asks for is what
    # stops /fa/docs/<an English slug> answering with the English document inside a Persian page.
    # The same rule refuses a stray ?lang= on a path that names no language, rather than serving the
    # wrong edition — and an author whose paths carry no language empties the key it travels under,
    # after which nothing in a URL can narrow it.
    test "nor one in a language it is not written in, unless the author closed the key", %{
      site: site
    } do
      manual!(site)

      asked = %{workspace: "mishka-cms", params: %{"section" => "installation", "lang" => "fa"}}

      {:ok, narrowed, _html} = mount_page(site, "doc-section", asked)

      assert text_of(narrowed, ~s([data-role="doc-section-missing"])) != []
      assert text_of(narrowed, ~s([data-role="doc-section-title"])) == []

      {:ok, pinned, _html} = mount_page(site, "doc-section", Map.put(asked, :lang_param, ""))

      assert text_of(pinned, ~s([data-role="doc-section-title"])) == ["Installation"]
    end

    test "draws the notes filed under a page, in order, each one an anchor", %{site: site} do
      %{pages: pages} = manual!(site)
      page = Enum.find(pages, &(&1.slug == "installation"))

      # The titles are in the opposite order to their places on purpose: a component that ordered
      # these by name would draw them in the same order as one that read `order_position`.
      note!(site, page, title: "Apple note", order_position: 1)
      note!(site, page, title: "Zebra note", order_position: 0)

      _draft =
        note!(site, page, title: "In review", order_position: 2, content_review_status: :pending)

      {:ok, view, _html} =
        mount_page(site, "doc-section", %{
          workspace: "mishka-cms",
          params: %{"section" => "installation"}
        })

      assert text_of(view, ~s([data-role="doc-note-title"])) == ["Zebra note", "Apple note"]

      assert ids_of(view, ~s([data-role="doc-section-note"])) == ["zebra-note", "apple-note"]
    end

    # WHAT THE CONTENT EDITOR STORES: a placed component's marker in a paragraph of its own. The page
    # draws it as the component, in the body and in a note, and the marker itself never shows.
    test "draws a component placed in the page's body or in a note as that component", %{
      site: site
    } do
      callout =
        create_component!(
          name: "doc-callout-#{System.unique_integer([:positive])}",
          site_id: site.id,
          active: true,
          precompile: false,
          template:
            ~S|<aside data-role="probe-callout" data-title={@title}>{render_slot(@inner_block)}</aside>|,
          attrs: [
            %{"name" => "title", "type" => "string", "opts" => %{"default" => nil}},
            %{"name" => "rest", "type" => "global", "opts" => %{}}
          ],
          slots: [%{"name" => "inner_block", "opts" => %{}}]
        )

      :ok = SiteState.put_component(site.id, callout.name)

      %{version: version} = manual!(site)

      page =
        page!(site, version,
          title: "Widgets",
          slug: "widgets",
          order_position: 4,
          content:
            ~s(<h2>Widgets</h2><p>[[component #{callout.name} title="In the body"]]Body inner[[/component]]</p>)
        )

      note!(site, page,
        title: "A note",
        content:
          ~s(<p>Before</p><p>[[component #{callout.name} title="In a note"]]Note inner[[/component]]</p>)
      )

      {:ok, view, html} =
        mount_page(site, "doc-section", %{
          workspace: "mishka-cms",
          params: %{"section" => "widgets"}
        })

      assert text_of(view, ~s([data-role="doc-section-body"] [data-role="probe-callout"])) ==
               ["Body inner"]

      assert text_of(view, ~s([data-role="doc-note-body"] [data-role="probe-callout"])) ==
               ["Note inner"]

      assert text_of(view, ~s([data-role="doc-note-body"] p)) == ["Before"]
      refute html =~ "[[component"
    end

    test "and leaves them out when the author turned them off", %{site: site} do
      %{pages: pages} = manual!(site)
      note!(site, Enum.find(pages, &(&1.slug == "installation")), title: "A note")

      {:ok, view, _html} =
        mount_page(site, "doc-section", %{
          workspace: "mishka-cms",
          show_notes: false,
          params: %{"section" => "installation"}
        })

      assert text_of(view, ~s([data-role="doc-note-title"])) == []
    end

    # THE BODY IS MARKUP, AND IT IS SCRUBBED. It has to render as HTML or the reader sees `&lt;p&gt;`
    # down the page; it is stored data rather than reviewed code, so `raw/1` is applied to the
    # scrubber's output and to nothing else.
    test "renders the body as markup with the executable parts removed", %{site: site} do
      %{version: version} = manual!(site)

      page!(site, version,
        title: "Scripted",
        slug: "scripted",
        order_position: 5,
        content: "<h2>Heading</h2><p>Body</p><script>steal()</script>"
      )

      {:ok, view, _html} =
        mount_page(site, "doc-section", %{
          workspace: "mishka-cms",
          params: %{"section" => "scripted"}
        })

      body =
        view
        |> render_async(@async)
        |> LazyHTML.from_fragment()
        |> LazyHTML.query(~s([data-role="doc-section-body"]))
        |> Enum.map(&LazyHTML.to_html/1)
        |> List.first()

      assert body =~ "<p>Body</p>", "the author's markup was escaped instead of rendered"
      refute body =~ "<script", "a script tag survived into the page"
    end

    test "walks the trail up to a page filed under another", %{site: site} do
      %{version: version, pages: pages} = manual!(site)
      parent = Enum.find(pages, &(&1.slug == "installation"))

      page!(site, version,
        title: "From source",
        slug: "from-source",
        order_position: 3,
        parent_section_id: parent.id
      )

      {:ok, view, _html} =
        mount_page(site, "doc-section", %{
          workspace: "mishka-cms",
          doc_base: "/docs",
          lang_param: "",
          params: %{"section" => "installation/from-source"}
        })

      assert text_of(view, ~s([data-role="doc-section-crumb"])) == ["Installation"]
      assert hrefs(view, ~s([data-role="doc-section-crumb"])) == ["/docs/mishka-cms/installation"]
    end

    test "offers the pages either side of the one being read", %{site: site} do
      manual!(site)

      {:ok, view, _html} =
        mount_page(site, "doc-section", %{
          workspace: "mishka-cms",
          doc_base: "/docs",
          lang_param: "",
          params: %{"section" => "installation"}
        })

      assert hrefs(view, ~s([data-role="doc-section-prev"])) ==
               ["/docs/mishka-cms/getting-started"]

      assert hrefs(view, ~s([data-role="doc-section-next"])) == ["/docs/mishka-cms/upgrading"]

      {:ok, first, _html} =
        mount_page(site, "doc-section", %{
          workspace: "mishka-cms",
          doc_base: "/docs",
          lang_param: "",
          params: %{"section" => "getting-started"}
        })

      assert hrefs(first, ~s([data-role="doc-section-prev"])) == []

      {:ok, last, _html} =
        mount_page(site, "doc-section", %{
          workspace: "mishka-cms",
          doc_base: "/docs",
          lang_param: "",
          params: %{"section" => "appendix"}
        })

      assert hrefs(last, ~s([data-role="doc-section-next"])) == []

      assert hrefs(last, ~s([data-role="doc-section-prev"])) == ["/docs/mishka-cms/upgrading"]
    end

    # AND IN THE ORDER THE CONTENTS BESIDE IT DRAW. A page's position is counted among its siblings,
    # so a flat sort puts the first chapter's child between two chapters — and Next then leaves the
    # chapter the reader is in while the sidebar still says they are inside it.
    test "and does it in the order doc-sidebar lists them", %{site: site} do
      %{version: version, pages: pages} = manual!(site)
      parent = Enum.find(pages, &(&1.slug == "installation"))

      page!(site, version,
        title: "From source",
        slug: "from-source",
        order_position: 0,
        parent_section_id: parent.id
      )

      attrs = %{workspace: "mishka-cms", doc_base: "/docs", lang_param: ""}

      {:ok, contents, _html} =
        mount_page(site, "doc-sidebar", Map.put(attrs, :expand_all, true))

      assert text_of(contents, ~s([data-role="doc-sidebar-link"])) ==
               ["Getting started", "Installation", "From source", "Upgrading", "Appendix"]

      # Walking Next from the first page has to visit the same titles in the same order. Sorted
      # flat, "From source" would sit at the top of the document and "Installation" would lead
      # straight to "Upgrading", past the page filed under it.
      walked =
        for address <- ~w(getting-started installation installation/from-source upgrading) do
          {:ok, view, _html} =
            mount_page(site, "doc-section", Map.put(attrs, :params, %{"section" => address}))

          assert [text] = text_of(view, ~s([data-role="doc-section-next"]))
          text |> String.split("\n") |> List.last() |> String.trim()
        end

      assert walked == ["Installation", "From source", "Upgrading", "Appendix"]
    end

    # A LINK OUT OF AN OLDER VERSION STAYS IN IT. A reader following Next inside 0.0.4 who landed on
    # the latest version's page would not be told they had moved.
    test "and every link it writes keeps the version the reader is on", %{site: site} do
      %{document: document} = manual!(site)

      older =
        version!(site, document, version_number: "0.9.0", published_at: ~U[2025-01-01 00:00:00Z])

      for {title, slug, order} <- [{"Old one", "old-one", 0}, {"Old two", "old-two", 1}] do
        page!(site, older, title: title, slug: slug, order_position: order)
      end

      {:ok, view, _html} =
        mount_page(site, "doc-section", %{
          workspace: "mishka-cms",
          doc_base: "/docs",
          lang_param: "",
          params: %{"section" => "old-one", "v" => "0.9.0"}
        })

      assert text_of(view, ~s([data-role="doc-section-title"])) == ["Old one"]

      assert hrefs(view, ~s([data-role="doc-section-next"])) == [
               "/docs/mishka-cms/old-two?v=0.9.0"
             ]
    end

    test "and drops it again on the latest one", %{site: site} do
      manual!(site)

      {:ok, view, _html} =
        mount_page(site, "doc-section", %{
          workspace: "mishka-cms",
          doc_base: "/docs",
          lang_param: "",
          params: %{"section" => "getting-started", "v" => "1.0.0"}
        })

      assert hrefs(view, ~s([data-role="doc-section-next"])) == ["/docs/mishka-cms/installation"]
    end

    # A PAGE WHOSE PARENT IS STILL IN REVIEW IS A PAGE OF ITS OWN. Hanging it off a page nobody can
    # see would drop it out of the document altogether.
    test "a page whose parent is not published stands at the top", %{site: site} do
      %{version: version} = manual!(site)

      hidden =
        page!(site, version,
          title: "Hidden parent",
          slug: "hidden-parent",
          order_position: 8,
          content_review_status: :pending
        )

      page!(site, version,
        title: "Orphan",
        slug: "orphan",
        order_position: 9,
        parent_section_id: hidden.id
      )

      {:ok, view, _html} = mount_page(site, "doc-section", %{workspace: "mishka-cms"})

      assert "Orphan" in text_of(view, ~s([data-role="doc-landing-link"]))
    end
  end

  # WHAT A PLUGIN ADDS TO A PAGE on `document:page:extras`: facts under its title and tabs beside its
  # text, every word of them escaped, the tab shown the one the URL names; a page no plugin adds to
  # is drawn as it always was.
  describe "doc-section's page extras" do
    setup do
      Process.register(self(), :__page_extras_probe__)

      {:ok, _} =
        Event.write(%{
          name: PageExtras,
          event: @extras_event,
          extension: :mishka_installer,
          status: :started
        })

      :ok = EventHandler.do_compile(@extras_event, :start, false)

      on_exit(fn ->
        PageExtras.forget!()
        Event.unregister(:name, PageExtras, false)
        EventHandler.do_compile(@extras_event, :start, false)
      end)

      :ok
    end

    test "tells the plugin the page it draws", %{site: site} do
      grouped!(site)

      {:ok, _view, _html} = mount_breadcrumb(site)

      site_id = site.id

      assert_received {:page_extras_asked,
                       %{
                         site_id: ^site_id,
                         document: %{slug: "grouped", path: "/mishka/docs", language: "en"},
                         version: "1.0.0",
                         page: %{
                           slug: "breadcrumb",
                           title: "Breadcrumb",
                           path: "breadcrumb",
                           parents: [%{slug: "navigation", title: "Navigation", group: true}]
                         },
                         header: [],
                         tabs: []
                       }}
    end

    test "draws the facts it puts under the title, as text", %{site: site} do
      grouped!(site)

      PageExtras.answer!(fn state ->
        %{
          state
          | header: [
              %{
                kind: :badges,
                items: [
                  %{text: "v1.0.0", tone: :primary},
                  %{text: "Stable", tone: "success"},
                  %{text: "Odd", tone: "Not A Tone"},
                  %{tone: "success"}
                ]
              },
              %{kind: :command, label: "Installation", value: "mix gen breadcrumb"},
              %{
                kind: :link,
                label: "Source",
                href: "https://github.com/x/y",
                text: "View Source"
              },
              %{kind: :link, label: "Docs", href: "/mishka/docs", text: "Contents"},
              %{kind: :text, label: "Package", value: ~S|<b>"Kit"</b>|},
              %{kind: :link, label: "Bad", href: "javascript:alert(1)", text: "Run"},
              %{kind: :link, label: "Away", href: "//elsewhere.test/x", text: "Away"},
              %{kind: :command, label: "Empty", value: "  "},
              %{kind: :script, value: "nothing"},
              "not a fact"
            ]
        }
      end)

      {:ok, view, _html} = mount_breadcrumb(site)

      extras = drawn(view, ~s([data-role="doc-section-article"] > [data-role="doc-extras"]))
      assert Enum.count(extras) == 1

      badges = LazyHTML.query(extras, ~s([data-role="doc-extra-badge"]))
      assert Enum.map(badges, &LazyHTML.text/1) == ["v1.0.0", "Stable", "Odd"]
      assert LazyHTML.attribute(badges, "data-tone") == ["primary", "success", "neutral"]

      assert text_of(view, ~s([data-role="doc-extras"] [data-role="doc-extra-label"])) ==
               ["Installation", "Source", "Docs", "Package"]

      command = LazyHTML.query(extras, ~s([data-role="doc-extra-command"]))
      assert command |> LazyHTML.query("code") |> LazyHTML.attribute("dir") == ["ltr"]
      assert text_of(view, ~s([data-role="doc-extra-command"] code)) == ["mix gen breadcrumb"]

      button = LazyHTML.query(command, ~s(button[type="button"][data-role="doc-code-copy"]))
      assert LazyHTML.attribute(button, "aria-label") == ["Copy code"]
      assert LazyHTML.attribute(button, "data-copied-text") == ["Copied"]
      assert command |> LazyHTML.query(~s([data-role="doc-code-status"])) |> Enum.count() == 1

      links = LazyHTML.query(extras, ~s([data-role="doc-extra-link"] a))
      assert LazyHTML.attribute(links, "href") == ["https://github.com/x/y", "/mishka/docs"]
      assert LazyHTML.attribute(links, "target") == ["_blank"]
      assert LazyHTML.attribute(links, "rel") == ["noopener noreferrer"]

      assert text_of(view, ~s([data-role="doc-extra-text"] [data-role="doc-extra-value"])) ==
               [~S|<b>"Kit"</b>|]

      assert extras |> LazyHTML.query("b") |> Enum.count() == 0
      assert view |> drawn(~s([data-role="doc-tabs"])) |> Enum.count() == 0
    end

    test "draws a link fact with the rel it was given, and the default for one without", %{
      site: site
    } do
      grouped!(site)

      PageExtras.answer!(fn state ->
        %{
          state
          | header: [
              %{kind: :link, href: "https://github.com/a", text: "Plain"},
              %{
                kind: :link,
                href: "https://github.com/b",
                text: "Given",
                rel: "nofollow noopener noreferrer"
              },
              %{
                kind: :link,
                href: "https://github.com/c",
                text: "Cased",
                rel: "  NoFollow  sponsored nofollow "
              },
              %{
                kind: :link,
                href: "https://github.com/d",
                text: "Strange",
                rel: "bad_word <b> x:y"
              },
              %{kind: :link, href: "https://github.com/e", text: "Listed", rel: ["nofollow"]},
              %{kind: :link, href: "https://github.com/f", text: "Blank", rel: "   "},
              %{kind: :link, href: "/mishka/docs", text: "Inside"},
              %{kind: :link, href: "/mishka/docs/breadcrumb", text: "Marked", rel: "nofollow"}
            ],
            tabs: [
              %{
                id: "links",
                label: "Links",
                kind: :list,
                items: [
                  %{kind: :link, href: "https://github.com/g", text: "Tabbed", rel: "sponsored"}
                ]
              }
            ]
        }
      end)

      {:ok, view, _html} = mount_breadcrumb(site)

      links =
        view
        |> drawn(~s([data-role="doc-section-article"] > [data-role="doc-extras"] a))
        |> Enum.map(fn link ->
          {LazyHTML.text(link), LazyHTML.attribute(link, "target"),
           LazyHTML.attribute(link, "rel")}
        end)

      assert links == [
               {"Plain", ["_blank"], ["noopener noreferrer"]},
               {"Given", ["_blank"], ["nofollow noopener noreferrer"]},
               {"Cased", ["_blank"], ["nofollow sponsored"]},
               {"Strange", ["_blank"], ["noopener noreferrer"]},
               {"Listed", ["_blank"], ["noopener noreferrer"]},
               {"Blank", ["_blank"], ["noopener noreferrer"]},
               {"Inside", [], []},
               {"Marked", [], ["nofollow"]}
             ]

      assert view
             |> drawn(~s([data-role="doc-tab-panel"] [data-role="doc-extra-link"] a))
             |> Enum.map(&LazyHTML.attribute(&1, "rel")) == [["sponsored"]]
    end

    test "adds its tabs after the text's own, which is shown", %{site: site} do
      grouped!(site)
      PageExtras.answer!(&with_tabs/1)

      {:ok, view, _html} = mount_breadcrumb(site)

      assert text_of(view, ~s([data-role="doc-tabs"] [data-role="doc-tab"])) ==
               ["Documentation", "Props", "CLI", "Pending"]

      assert hrefs(view, ~s([data-role="doc-tab"])) == [
               "/mishka/docs/breadcrumb",
               "/mishka/docs/breadcrumb?tab=props",
               "/mishka/docs/breadcrumb?tab=cli",
               "/mishka/docs/breadcrumb?tab=pending"
             ]

      assert shown_tab(view) == ["documentation"]

      assert view |> drawn(~s([data-role="doc-section-body"])) |> LazyHTML.attribute("hidden") ==
               []

      panels = drawn(view, ~s([data-role="doc-section-article"] > [data-role="doc-tab-panel"]))
      assert LazyHTML.attribute(panels, "data-tab") == ["props", "cli", "pending"]
      assert LazyHTML.attribute(panels, "hidden") == ["", "", ""]

      assert LazyHTML.attribute(panels, "aria-labelledby") ==
               ["one-tab-props", "one-tab-cli", "one-tab-pending"]

      # The Props tab: one table, every cell as text.
      assert text_of(view, panel("props", ~s([data-role="doc-extra-title"]))) == ["Attributes"]
      assert text_of(view, panel("props", "th")) == ["Name", "Values", "Required", "Description"]

      assert text_of(view, panel("props", ~s(td[data-column="name"] code))) == [
               "color",
               "<script>"
             ]

      assert text_of(view, panel("props", ~s([data-role="doc-extra-item"]))) == [
               "base",
               "primary"
             ]

      assert view
             |> drawn(
               panel("props", ~s(td[data-column="required"] [data-role="doc-extra-badge"]))
             )
             |> LazyHTML.attribute("data-tone") == ["secondary", "neutral"]

      assert text_of(view, panel("props", ~s([data-role="doc-extra-blank"]))) == ["—", "—"]
      assert view |> drawn(panel("props", "script")) |> Enum.count() == 0

      # The CLI tab: a list of facts, its command copied by the same button, and an empty table.
      assert text_of(
               view,
               panel("cli", ~s([data-role="doc-extra-list"] [data-role="doc-extra-label"]))
             ) ==
               ["Command", "Needs"]

      assert view
             |> drawn(
               panel("cli", ~s([data-role="doc-extra-command"] [data-role="doc-code-copy"]))
             )
             |> Enum.count() == 1

      assert text_of(view, panel("cli", ~s([data-role="doc-extra-rows-empty"]))) == [
               "No options."
             ]

      # A tab whose data is being fetched says so.
      assert text_of(view, panel("pending", ~s([data-role="doc-tab-pending"]))) ==
               ["Still fetching."]
    end

    test "opens the tab the URL names, keeps the page's other keys, and reads nothing for it",
         %{site: site} do
      grouped!(site)
      PageExtras.answer!(&with_tabs/1)

      {:ok, view, _html} = mount_breadcrumb(site, %{"tab" => "props", "utm" => "feed"})

      assert shown_tab(view) == ["props"]

      assert view |> drawn(~s([data-role="doc-section-body"])) |> LazyHTML.attribute("hidden") ==
               [""]

      assert open_panels(view) == ["props"]

      assert hrefs(view, ~s([data-role="doc-tab"])) == [
               "/mishka/docs/breadcrumb?utm=feed",
               "/mishka/docs/breadcrumb?tab=props&utm=feed",
               "/mishka/docs/breadcrumb?tab=cli&utm=feed",
               "/mishka/docs/breadcrumb?tab=pending&utm=feed"
             ]

      flush_asks()
      send(view.pid, {:params, %{"section" => "breadcrumb", "tab" => "cli", "utm" => "feed"}})

      assert open_panels(view) == ["cli"]
      assert shown_tab(view) == ["cli"]
      refute_received {:page_extras_asked, _again}

      send(view.pid, {:params, %{"section" => "breadcrumb", "tab" => "nothing", "utm" => "feed"}})

      assert open_panels(view) == []
      assert shown_tab(view) == ["documentation"]

      assert view |> drawn(~s([data-role="doc-section-body"])) |> LazyHTML.attribute("hidden") ==
               []

      send(view.pid, {:params, %{"section" => "menu", "tab" => "nothing"}})

      assert text_of(view, ~s([data-role="doc-section-title"])) == ["Menu"]
      assert_received {:page_extras_asked, %{page: %{slug: "menu"}}}
    end

    test "on a document's landing, tells the plugin there is no page and hides the contents under a tab",
         %{site: site} do
      grouped!(site)
      PageExtras.answer!(&with_tabs/1)

      {:ok, view, _html} =
        mount_page(site, "doc-section", %{
          path: "/mishka/docs",
          lang_param: "",
          params: %{"tab" => "cli"}
        })

      assert_received {:page_extras_asked, %{page: nil, version: "1.0.0"}}

      assert view
             |> drawn(~s([data-role="doc-section-landing"] > [data-role="doc-tabs"]))
             |> Enum.count() == 1

      assert hrefs(view, ~s([data-role="doc-tab"])) == [
               "/mishka/docs",
               "/mishka/docs?tab=props",
               "/mishka/docs?tab=cli",
               "/mishka/docs?tab=pending"
             ]

      for hidden <- ~w(doc-landing-items doc-landing-group) do
        assert view |> drawn(~s([data-role="#{hidden}"])) |> LazyHTML.attribute("hidden") == [""]
      end

      assert view
             |> drawn(
               ~s|[data-role="doc-section-landing"] > [data-role="doc-tab-panel"]:not([hidden])|
             )
             |> LazyHTML.attribute("data-tab") == ["cli"]
    end

    # WHAT A PLUGIN IS STILL FETCHING is a skeleton until the fetch is announced on the topic the
    # plugin names, and then the page asks once more and draws it, with no reload and no polling.
    test "draws a skeleton while its data is fetched, and the rows once the fetch is announced",
         %{site: site} do
      grouped!(site)
      topic = "test:page_extras:#{System.unique_integer([:positive])}"
      fetched = :atomics.new(1, [])

      PageExtras.answer!(fn state ->
        case :atomics.get(fetched, 1) do
          1 -> with_tabs(state)
          0 -> fetching(state, topic)
        end
      end)

      {view, _first_paint} = mount_raw(site, [breadcrumb_block(%{})])
      view_pid = view.pid
      test_pid = self()

      # The task that waits has subscribed once it asks for itself.
      assert_receive {:page_extras_asker, asker} when asker not in [view_pid, test_pid], @async

      waiting = LazyHTML.from_fragment(render(view))

      assert waiting
             |> LazyHTML.query(~s([data-role="doc-extras"] [data-role="doc-extra-pending"]))
             |> Enum.count() == 1

      assert waiting
             |> LazyHTML.query(
               ~s([data-role="doc-tab-panel"] [data-role="doc-tab-pending"][data-tone="loading"])
             )
             |> Enum.count() == 2

      :atomics.put(fetched, 1, 1)
      :ok = Phoenix.PubSub.broadcast(MishkaCmsCore.PubSub, topic, {:fetched, "1.0.0"})

      assert text_of(view, panel("props", ~s(td[data-column="name"] code))) == [
               "color",
               "<script>"
             ]

      assert view |> drawn(~s([data-role="doc-extra-pending"])) |> Enum.count() == 0
      assert view |> drawn(~s([data-role="doc-tab"])) |> Enum.count() == 4

      assert hrefs(view, ~s([data-role="doc-tab"][data-tab="cli"])) == [
               "/mishka/docs/breadcrumb?tab=cli"
             ]
    end

    test "says what it could not fetch once the wait is over, and a tab the plugin says failed",
         %{site: site} do
      grouped!(site)
      topic = "test:page_extras:#{System.unique_integer([:positive])}"

      PageExtras.answer!(fn state ->
        failed = %{id: "gone", label: "Gone", state: :failed, text: "Not here."}
        fetching = fetching(state, topic)
        %{fetching | tabs: fetching.tabs ++ [failed]}
      end)

      {view, _first_paint} = mount_raw(site, [breadcrumb_block(%{pending_wait: 50})])

      assert text_of(view, panel("props", ~s([data-role="doc-tab-failed"]))) == [
               "Could not fetch."
             ]

      assert text_of(view, panel("cli", ~s([data-role="doc-tab-failed"]))) == ["Could not fetch."]
      assert text_of(view, panel("gone", ~s([data-role="doc-tab-failed"]))) == ["Not here."]
      assert view |> drawn(~s([data-role="doc-tab-pending"])) |> Enum.count() == 0
      assert view |> drawn(~s([data-role="doc-extra-pending"])) |> Enum.count() == 0
    end

    test "draws a page no plugin adds to as it always was", %{site: site} do
      grouped!(site)

      {:ok, asked_nothing, _html} = mount_breadcrumb(site)

      PageExtras.answer!(&%{&1 | header: "not a list", tabs: nil})
      {:ok, nonsense, _html} = mount_breadcrumb(site, %{"tab" => "props"})

      for view <- [asked_nothing, nonsense] do
        assert view |> drawn(~s([data-role^="doc-extra"], [data-role^="doc-tab"])) |> Enum.count() ==
                 0

        assert view |> drawn("[hidden]") |> Enum.count() == 0
        assert text_of(view, ~s([data-role="doc-section-body"] > p)) == ["Body"]
      end

      assert article(nonsense) == article(asked_nothing)
    end

    test "draws the page as it always was when the event cannot run", %{site: site} do
      grouped!(site)
      PageExtras.answer!(&with_tabs/1)

      :ok = ModuleStateCompiler.purge_create([], @extras_event, [__MODULE__.NotLoadedPlugin])

      {:ok, view, _html} = mount_breadcrumb(site, %{"tab" => "props"})

      refute_received {:page_extras_asked, _state}

      assert view |> drawn(~s([data-role^="doc-extra"], [data-role^="doc-tab"])) |> Enum.count() ==
               0

      assert view |> drawn("[hidden]") |> Enum.count() == 0
      assert text_of(view, ~s([data-role="doc-section-title"])) == ["Breadcrumb"]
    end
  end

  defp mount_breadcrumb(site, params \\ %{}) do
    mount_page(site, "doc-section", %{
      path: "/mishka/docs",
      lang_param: "",
      params: Map.put(params, "section", "breadcrumb")
    })
  end

  defp breadcrumb_block(attrs) do
    %{
      "name" => "doc-section",
      "id" => "one",
      "attrs" =>
        Map.merge(
          %{path: "/mishka/docs", lang_param: "", params: %{"section" => "breadcrumb"}},
          attrs
        )
    }
  end

  # The skeleton of the facts and two tabs still being fetched, announced on `topic`.
  defp fetching(state, topic) do
    pending = fn id, label ->
      %{
        id: id,
        label: label,
        state: :not_ready,
        text: "Fetching.",
        failed_text: "Could not fetch.",
        pending: %{topic: topic}
      }
    end

    %{
      state
      | header: [%{kind: :pending, text: "Fetching."}],
        tabs: [pending.("props", "Props"), pending.("cli", "CLI")]
    }
  end

  defp panel(id, selector), do: ~s([data-role="doc-tab-panel"][data-tab="#{id}"] #{selector})

  defp shown_tab(view) do
    view
    |> drawn(~s([data-role="doc-tab"][aria-current="page"]))
    |> LazyHTML.attribute("data-tab")
  end

  defp open_panels(view) do
    view
    |> drawn(~s|[data-role="doc-tab-panel"]:not([hidden])|)
    |> LazyHTML.attribute("data-tab")
  end

  defp article(view) do
    view
    |> drawn(~s([data-role="doc-section-article"]))
    |> LazyHTML.to_html()
  end

  defp flush_asks do
    receive do
      {:page_extras_asked, _state} -> flush_asks()
    after
      0 -> :ok
    end
  end

  # Three tabs, and the four a plugin should not have added: the text's own id, an id no URL
  # carries, one with no label and a second Props.
  defp with_tabs(state) do
    %{
      state
      | tabs: [
          %{
            id: "props",
            label: "Props",
            kind: :table,
            title: "Attributes",
            columns: [
              %{key: :name, label: "Name", code: true},
              %{key: :values, label: "Values"},
              %{key: :required, label: "Required"},
              %{key: "doc", label: "Description"},
              %{label: "No key"}
            ],
            rows: [
              %{
                :name => "color",
                :values => ["base", :primary],
                :required => %{text: "Yes", tone: :secondary},
                "doc" => "The colour."
              },
              %{name: "<script>", values: [], required: %{text: "No"}},
              "not a row"
            ],
            empty_text: "No attributes."
          },
          %{
            id: "cli",
            label: "CLI",
            blocks: [
              %{
                kind: :list,
                items: [
                  %{kind: :command, label: "Command", value: "mix gen breadcrumb"},
                  %{kind: :badges, label: "Needs", items: [%{text: "icon"}]}
                ]
              },
              %{
                kind: :table,
                columns: [%{key: :flag, label: "Option"}],
                rows: [],
                empty_text: "No options."
              }
            ]
          },
          %{id: "pending", label: "Pending", state: :not_ready, text: "Still fetching."},
          %{id: "documentation", label: "Mine", kind: :list, items: []},
          %{id: "Not An Id", label: "Odd", kind: :list, items: []},
          %{id: "nolabel", kind: :list, items: []},
          %{id: "props", label: "Props again", kind: :list, items: []}
        ]
    }
  end

  describe "doc-sidebar" do
    test "lists every published page of the version, in order", %{site: site} do
      manual!(site)

      {:ok, view, _html} =
        mount_page(site, "doc-sidebar", %{workspace: "mishka-cms", lang_param: ""})

      assert text_of(view, ~s([data-role="doc-sidebar-link"])) ==
               ["Getting started", "Installation", "Upgrading", "Appendix"]

      assert hrefs(view, ~s([data-role="doc-sidebar-link"])) == [
               "/docs/mishka-cms/getting-started",
               "/docs/mishka-cms/installation",
               "/docs/mishka-cms/upgrading",
               "/docs/mishka-cms/appendix"
             ]
    end

    test "says so when the version has nothing approved in it", %{site: site} do
      document = document!(site, name: "Empty", slug: "empty-doc")
      version!(site, document, version_number: "1.0.0", is_latest_for_version: true)

      {:ok, view, _html} = mount_page(site, "doc-sidebar", %{workspace: "empty-doc"})

      assert text_of(view, ~s([data-role="doc-sidebar-empty"])) == ["No published pages."]
    end

    test "marks the page the reader is on", %{site: site} do
      manual!(site)

      {:ok, view, _html} =
        mount_page(site, "doc-sidebar", %{
          workspace: "mishka-cms",
          params: %{"section" => "installation"}
        })

      marked =
        view
        |> render_async(@async)
        |> LazyHTML.from_fragment()
        |> LazyHTML.query(~s([data-role="doc-sidebar-item"][data-active="true"]))
        |> Enum.map(&(&1 |> LazyHTML.text() |> String.trim()))

      assert marked == ["Installation"]
    end

    # THE CONTENTS KEEP THEIR PLACE ACROSS PAGES through the kit's own hook, mounted on the block's
    # root under the name the site's JavaScript registers the installed row by, and keyed on the
    # document the root names.
    test "mounts the kit's scroll hook on its root, naming its document", %{site: site} do
      hook =
        MishkaCmsCore.Runtime.JsHook
        |> Ash.Query.for_read(:read_any, %{}, authorize?: false)
        |> Ash.Query.filter(name == "doc-sidebar-scroll" and site_id == ^site.id)
        |> Ash.Query.load([:is_global])
        |> Ash.read_one!()

      assert hook, "installing the kit wrote no doc-sidebar-scroll hook for the site"
      assert hook.active

      %{document: document} = manual!(site)

      {:ok, view, _html} =
        mount_page(site, "doc-sidebar", %{
          workspace: "mishka-cms",
          params: %{"section" => "installation"}
        })

      root = drawn(view, ~s(#one[data-role="doc-sidebar"]))

      registered =
        MishkaCmsCore.Runtime.Compilers.JavaScriptCompiler.browser_name(hook, site.name)

      assert registered == String.capitalize(site.name) <> "DocSidebarScroll"
      assert LazyHTML.attribute(root, "phx-hook") == [registered]
      assert LazyHTML.attribute(root, "data-document") == [document.id]
    end

    # NESTING IS THE WHOLE POINT OF A SIDEBAR. A child sits under its parent and is drawn only while
    # that branch is the one the reader is in.
    test "nests a page under its parent and opens the branch the reader is in", %{site: site} do
      %{version: version, pages: pages} = manual!(site)
      parent = Enum.find(pages, &(&1.slug == "installation"))

      page!(site, version,
        title: "From source",
        slug: "from-source",
        order_position: 0,
        parent_section_id: parent.id
      )

      {:ok, closed, _html} = mount_page(site, "doc-sidebar", %{workspace: "mishka-cms"})

      refute "From source" in text_of(closed, ~s([data-role="doc-sidebar-link"])),
             "a branch nobody is in was drawn open"

      {:ok, open, _html} =
        mount_page(site, "doc-sidebar", %{
          workspace: "mishka-cms",
          params: %{"section" => "installation/from-source"}
        })

      assert text_of(open, ~s([data-role="doc-sidebar-link"])) ==
               ["Getting started", "Installation", "From source", "Upgrading", "Appendix"]

      depths =
        open
        |> render()
        |> LazyHTML.from_fragment()
        |> LazyHTML.query(~s([data-role="doc-sidebar-item"]))
        |> Enum.map(&LazyHTML.attribute(&1, "data-depth"))
        |> List.flatten()

      assert depths == ["0", "0", "1", "0", "0"]
    end

    test "and draws every branch when the author asked for that", %{site: site} do
      %{version: version, pages: pages} = manual!(site)
      parent = Enum.find(pages, &(&1.slug == "installation"))

      page!(site, version,
        title: "From source",
        slug: "from-source",
        order_position: 0,
        parent_section_id: parent.id
      )

      {:ok, view, _html} =
        mount_page(site, "doc-sidebar", %{workspace: "mishka-cms", expand_all: true})

      assert "From source" in text_of(view, ~s([data-role="doc-sidebar-link"]))
    end

    test "a page whose parent is not published stands at the top", %{site: site} do
      %{version: version} = manual!(site)

      hidden =
        page!(site, version,
          title: "Hidden parent",
          slug: "hidden-parent",
          order_position: 8,
          content_review_status: :pending
        )

      page!(site, version,
        title: "Orphan",
        slug: "orphan",
        order_position: 9,
        parent_section_id: hidden.id
      )

      {:ok, view, _html} = mount_page(site, "doc-sidebar", %{workspace: "mishka-cms"})

      assert "Orphan" in text_of(view, ~s([data-role="doc-sidebar-link"]))
    end

    test "the filter narrows the list as the reader types", %{site: site} do
      %{version: version} = manual!(site)

      for {title, slug, order} <- [
            {"Authentication", "authentication", 5},
            {"Authorization", "authorization", 6}
          ] do
        page!(site, version, title: title, slug: slug, order_position: order)
      end

      {:ok, view, _html} =
        mount_page(site, "doc-sidebar", %{workspace: "mishka-cms", show_filter: true})

      view |> form(~s(#one form), %{"q" => "auth"}) |> render_change()

      assert text_of(view, ~s([data-role="doc-sidebar-link"])) ==
               ["Authentication", "Authorization"]

      view |> form(~s(#one form), %{"q" => "nothing here"}) |> render_change()
      assert text_of(view, ~s([data-role="doc-sidebar-none"])) == ["Nothing matches."]

      view |> form(~s(#one form), %{"q" => ""}) |> render_change()
      assert length(text_of(view, ~s([data-role="doc-sidebar-link"]))) == 6
    end

    test "and a query that is not text is not a query", %{site: site} do
      manual!(site)

      {:ok, view, _html} =
        mount_page(site, "doc-sidebar", %{workspace: "mishka-cms", show_filter: true})

      view |> element(~s(#one form)) |> render_change(%{"q" => ["auth"]})

      assert length(text_of(view, ~s([data-role="doc-sidebar-link"]))) == 4
    end

    test "keeps the version on its links only while it is not the latest", %{site: site} do
      %{document: document} = manual!(site)

      older =
        version!(site, document, version_number: "0.9.0", published_at: ~U[2025-01-01 00:00:00Z])

      page!(site, older, title: "Old one", slug: "old-one", order_position: 0)

      {:ok, older_view, _html} =
        mount_page(site, "doc-sidebar", %{
          workspace: "mishka-cms",
          lang_param: "",
          params: %{"v" => "0.9.0"}
        })

      assert hrefs(older_view, ~s([data-role="doc-sidebar-link"])) ==
               ["/docs/mishka-cms/old-one?v=0.9.0"]

      {:ok, latest_view, _html} =
        mount_page(site, "doc-sidebar", %{workspace: "mishka-cms", lang_param: ""})

      assert hrefs(latest_view, ~s([data-role="doc-sidebar-link"]))
             |> Enum.all?(&(not (&1 =~ "v=")))
    end
  end

  describe "doc-toc" do
    test "lists the headings of the page and the notes under it", %{site: site} do
      %{version: version} = manual!(site)

      page =
        page!(site, version,
          title: "Long one",
          slug: "long-one",
          order_position: 4,
          content: "<h2>Why</h2><p>Because.</p><h3>How</h3><p>Like this.</p>"
        )

      note!(site, page, title: "A note", order_position: 0)

      {:ok, view, _html} =
        mount_page(site, "doc-toc", %{
          workspace: "mishka-cms",
          params: %{"section" => "long-one"}
        })

      assert text_of(view, ~s([data-role="doc-toc-link"])) == ["Why", "How", "A note"]
    end

    # THE ONE AGREEMENT TWO COMPONENTS CANNOT SHARE CODE FOR. `doc-toc` computes the anchors and
    # `doc-section` writes them, out of copies of the same helper, so every link here has to be
    # checked against the markup that component actually rendered.
    test "and every anchor it writes exists in the page doc-section drew", %{site: site} do
      %{version: version} = manual!(site)

      page =
        page!(site, version,
          title: "Long one",
          slug: "long-one",
          order_position: 4,
          content:
            "<h2>Why</h2><p>Because.</p><h3>How &amp; when</h3><p>Like this.</p><h2>Why</h2>"
        )

      note!(site, page, title: "A note", order_position: 0)

      attrs = %{workspace: "mishka-cms", params: %{"section" => "long-one"}}

      {:ok, view, _html} =
        mount_blocks(site, [
          %{"name" => "doc-section", "id" => "one", "attrs" => attrs},
          %{"name" => "doc-toc", "id" => "two", "attrs" => attrs}
        ])

      document = view |> render() |> LazyHTML.from_fragment()

      anchors =
        document
        |> LazyHTML.query(~s([data-role="doc-toc-link"]))
        |> Enum.map(&LazyHTML.attribute(&1, "href"))
        |> List.flatten()
        |> Enum.map(&String.trim_leading(&1, "#"))

      assert length(anchors) == 4, "the table of contents lost an entry"

      for anchor <- anchors do
        assert LazyHTML.query(document, "##{anchor}") |> Enum.to_list() != [],
               "the table of contents points at ##{anchor} and nothing on the page answers to it"
      end
    end

    # A NOTE IS LINKED BY ITS TITLE: `#color-palette`. A later note of a slug already taken gets the
    # first free `-2`, `-3`, a title with no letter or digit is the note's place, a Persian title stays
    # Persian, and a heading with a note's title is named clear of it — the same in both blocks,
    # whatever either one shows.
    test "links each note by the slug of its title, as doc-section draws it", %{site: site} do
      %{version: version} = manual!(site)

      page =
        page!(site, version,
          title: "Palette",
          slug: "palette",
          order_position: 4,
          content: "<h2>Why</h2><p>Because.</p><h2>Color palette</h2><p>Body.</p>"
        )

      note!(site, page, title: "Color palette", order_position: 0)
      note!(site, page, title: "Color palette 2", order_position: 1)
      note!(site, page, title: "Color  Palette!", order_position: 2)
      note!(site, page, title: "— ? —", order_position: 3)
      note!(site, page, title: "پالت رنگ", order_position: 4)

      attrs = %{workspace: "mishka-cms", params: %{"section" => "palette"}}

      {:ok, view, _html} =
        mount_blocks(site, [
          %{"name" => "doc-section", "id" => "one", "attrs" => attrs},
          %{"name" => "doc-toc", "id" => "two", "attrs" => attrs},
          %{"name" => "doc-toc", "id" => "three", "attrs" => Map.put(attrs, :show_notes, false)}
        ])

      notes = ["color-palette", "color-palette-2", "color-palette-3", "note-4", "پالت-رنگ"]
      headings = ["why", "color-palette-4"]

      assert ids_of(view, ~s([data-role="doc-section-note"])) == notes

      assert ids_of(view, ~s([data-role="doc-section-body"] h2)) == headings

      assert hrefs(view, ~s(#two [data-role="doc-toc-link"])) ==
               Enum.map(headings ++ notes, &("#" <> &1))

      assert hrefs(view, ~s(#three [data-role="doc-toc-link"])) ==
               Enum.map(headings, &("#" <> &1))
    end

    test "draws nothing when there is not enough to list", %{site: site} do
      %{version: version} = manual!(site)

      page!(site, version,
        title: "Short one",
        slug: "short-one",
        order_position: 4,
        content: "<p>No headings at all.</p>"
      )

      {:ok, view, _html} =
        mount_page(site, "doc-toc", %{
          workspace: "mishka-cms",
          params: %{"section" => "short-one"}
        })

      assert text_of(view, ~s([data-role="doc-toc-link"])) == []
      assert text_of(view, ~s([data-role="doc-toc-heading"])) == []
    end

    # AND "NOT ENOUGH" IS ONE, which is the case the rule exists for: a column headed On this page
    # with a single link to the top of what the reader is already looking at. How many it takes is
    # an attribute, so an author who wants that column anyway can have it.
    test "and one entry is not enough, until an author says it is", %{site: site} do
      %{version: version} = manual!(site)

      page!(site, version,
        title: "Single",
        slug: "single",
        order_position: 4,
        content: "<h2>Just one</h2><p>Body.</p>"
      )

      asked = %{workspace: "mishka-cms", params: %{"section" => "single"}}

      {:ok, hidden, _html} = mount_page(site, "doc-toc", asked)

      assert text_of(hidden, ~s([data-role="doc-toc-link"])) == []
      assert text_of(hidden, ~s([data-role="doc-toc-heading"])) == []

      {:ok, lowered, _html} = mount_page(site, "doc-toc", Map.put(asked, :min_entries, 1))

      assert text_of(lowered, ~s([data-role="doc-toc-link"])) == ["Just one"]
      assert text_of(lowered, ~s([data-role="doc-toc-heading"])) == ["On this page"]
    end

    test "and nothing at all when the URL names no page", %{site: site} do
      manual!(site)

      {:ok, view, _html} = mount_page(site, "doc-toc", %{workspace: "mishka-cms"})

      assert text_of(view, ~s([data-role="doc-toc-link"])) == []
    end

    test "leaves out the halves an author turned off", %{site: site} do
      %{version: version} = manual!(site)

      page =
        page!(site, version,
          title: "Long one",
          slug: "long-one",
          order_position: 4,
          content: "<h2>Why</h2><p>Because.</p><h3>How</h3>"
        )

      note!(site, page, title: "Zebra note", order_position: 0)
      note!(site, page, title: "Apple note", order_position: 1)

      {:ok, headings_only, _html} =
        mount_page(site, "doc-toc", %{
          workspace: "mishka-cms",
          show_notes: false,
          params: %{"section" => "long-one"}
        })

      assert text_of(headings_only, ~s([data-role="doc-toc-link"])) == ["Why", "How"]

      {:ok, notes_only, _html} =
        mount_page(site, "doc-toc", %{
          workspace: "mishka-cms",
          show_headings: false,
          params: %{"section" => "long-one"}
        })

      assert text_of(notes_only, ~s([data-role="doc-toc-link"])) == ["Zebra note", "Apple note"]
    end
  end

  describe "doc-switcher" do
    setup %{site: site} do
      %{document: document, version: latest} = manual!(site)

      older =
        version!(site, document, version_number: "0.9.0", published_at: ~U[2025-01-01 00:00:00Z])

      _draft = version!(site, document, version_number: "9.9.9", status: :draft)
      _archived = version!(site, document, version_number: "0.1.0", status: :archived)

      {:ok, document: document, latest: latest, older: older}
    end

    test "offers the versions this document publishes and no others", %{site: site} do
      {:ok, view, _html} = mount_page(site, "doc-switcher", %{workspace: "mishka-cms"})

      assert text_of(view, ~s([data-role="doc-switcher-version"] span:first-child)) ==
               ["1.0.0", "0.9.0"]
    end

    # A MENU CLOSES WHEN THE READER LEAVES IT: a click outside it or Escape presses its summary while
    # it is open, in the browser, and a patch keeps the `open` the reader left it with.
    test "closes its version menu on a click outside it and on Escape", %{site: site} do
      {:ok, view, _html} = mount_page(site, "doc-switcher", %{workspace: "mishka-cms"})

      menu = drawn(view, ~s(details[data-role="doc-switcher-versions"]))

      closes =
        Jason.encode!(
          Phoenix.LiveView.JS.dispatch("click", to: {:inner, ":scope[open] summary"}).ops
        )

      assert LazyHTML.attribute(menu, "phx-click-away") == [closes]
      assert LazyHTML.attribute(menu, "phx-window-keydown") == [closes]
      assert LazyHTML.attribute(menu, "phx-key") == ["Escape"]

      assert LazyHTML.attribute(menu, "phx-mounted") ==
               [Jason.encode!(Phoenix.LiveView.JS.ignore_attributes(["open"]).ops)]
    end

    test "marks the one being read and the latest one", %{site: site} do
      {:ok, view, _html} =
        mount_page(site, "doc-switcher", %{workspace: "mishka-cms", params: %{"v" => "0.9.0"}})

      selected =
        view
        |> render_async(@async)
        |> LazyHTML.from_fragment()
        |> LazyHTML.query(~s([data-role="doc-switcher-version"][data-selected="true"]))
        |> Enum.map(&LazyHTML.attribute(&1, "data-version"))
        |> List.flatten()

      assert selected == ["0.9.0"]
      assert text_of(view, ~s([data-role="doc-switcher-latest-badge"])) == ["latest"]
    end

    # THE SAME PAGE IN THE OTHER VERSION, found through the lineage a clone carries rather than
    # through a slug that may have been renamed.
    test "each version leads to the same page in it", %{site: site, older: older} do
      current = document_page(site, "installation")

      page!(site, older,
        title: "Installation (old)",
        slug: "installation-old",
        order_position: 0,
        section_lineage_id: current.section_lineage_id
      )

      {:ok, view, _html} =
        mount_page(site, "doc-switcher", %{
          workspace: "mishka-cms",
          doc_base: "/docs",
          lang_param: "",
          params: %{"section" => "installation"}
        })

      assert "/docs/mishka-cms/installation-old?v=0.9.0" in hrefs(
               view,
               ~s([data-role="doc-switcher-version"])
             )
    end

    # AND THE DOCUMENT'S FRONT PAGE WHERE THERE IS NO SUCH PAGE. A page written after an older
    # version was cut does not exist in it, and a link to a slug that version never had is a link to
    # nothing.
    test "and to the document's front page where it has no such page", %{site: site} do
      {:ok, view, _html} =
        mount_page(site, "doc-switcher", %{
          workspace: "mishka-cms",
          doc_base: "/docs",
          lang_param: "",
          params: %{"section" => "installation"}
        })

      assert "/docs/mishka-cms?v=0.9.0" in hrefs(view, ~s([data-role="doc-switcher-version"]))
    end

    test "says so, and offers the way back, when an older version is being read", %{site: site} do
      {:ok, older_view, _html} =
        mount_page(site, "doc-switcher", %{
          workspace: "mishka-cms",
          doc_base: "/docs",
          lang_param: "",
          params: %{"v" => "0.9.0"}
        })

      assert text_of(older_view, ~s([data-role="doc-switcher-banner-text"])) != []
      assert hrefs(older_view, ~s([data-role="doc-switcher-latest"])) == ["/docs/mishka-cms"]

      {:ok, latest_view, _html} = mount_page(site, "doc-switcher", %{workspace: "mishka-cms"})

      assert text_of(latest_view, ~s([data-role="doc-switcher-banner-text"])) == []
    end

    # A NUMBER THIS DOCUMENT DOES NOT PUBLISH IS NOT A VERSION. An archived one is not either, and
    # both fall back to the latest rather than to an empty page.
    test "an archived or unknown version falls back to the latest", %{site: site} do
      for asked <- ["0.1.0", "no-such-version"] do
        {:ok, view, _html} =
          mount_page(site, "doc-switcher", %{workspace: "mishka-cms", params: %{"v" => asked}})

        assert text_of(view, ~s([data-role="doc-switcher-banner-text"])) == [],
               "#{asked} was treated as a version of its own"

        selected =
          view
          |> render()
          |> LazyHTML.from_fragment()
          |> LazyHTML.query(~s([data-role="doc-switcher-version"][data-selected="true"]))
          |> Enum.map(&LazyHTML.attribute(&1, "data-version"))
          |> List.flatten()

        assert selected == ["1.0.0"]
      end
    end

    test "draws only the half the author asked for", %{site: site} do
      {:ok, versions_only, _html} =
        mount_page(site, "doc-switcher", %{workspace: "mishka-cms", show: "version"})

      assert text_of(versions_only, ~s([data-role="doc-switcher-language"])) == []
      assert text_of(versions_only, ~s([data-role="doc-switcher-version"])) != []
    end

    # AND A SWITCH WITH ONE OPTION IS NOT A SWITCH. This document has one edition and was written
    # the way every document here is written, which is to say `SetLanguageGroupId` gave it a group
    # holding itself: a language half built from that group offers the language the reader is
    # already in, on every document on a site that publishes in one.
    test "and says nothing about languages for a document nobody translated", %{site: site} do
      {:ok, view, _html} = mount_page(site, "doc-switcher", %{workspace: "mishka-cms"})

      assert text_of(view, ~s([data-role="doc-switcher-language"])) == []
      assert text_of(view, ~s([data-role="doc-switcher-languages"])) == []

      assert text_of(view, ~s([data-role="doc-switcher-version"])) != [],
             "the version half went with it"
    end
  end

  # A PAGE WITH NO ADDRESS IS A WORD, NOT A LINK TO NOTHING. A document in a language the site does
  # not publish has no address under a base carrying `:lang`, and `<.link navigate={nil}>` draws
  # `href="#"` — a link that scrolls the reader to the top of the page they are on. Every title,
  # crumb, page and neighbour is drawn as the word it names instead; a control that only leads
  # somewhere — a card's read link, a version menu — is not drawn at all.
  describe "a document with no address on this site" do
    setup %{site: site} do
      {:ok, _} = MishkaCmsCore.Settings.put("site.languages", ["fa"], site_id: site.id)
      %{version: version, pages: pages} = manual!(site)
      parent = Enum.find(pages, &(&1.slug == "installation"))

      page!(site, version,
        title: "From source",
        slug: "from-source",
        order_position: 0,
        parent_section_id: parent.id
      )

      :ok
    end

    test "is drawn in words, with no link to nothing", %{site: site} do
      attrs = %{workspace: "mishka-cms", doc_base: "/:lang/docs", lang_param: ""}

      for {name, given, roles} <- [
            {"doc-workspace-list", %{per_page: 10, doc_base: "/:lang/docs", lang_param: ""},
             ["doc-list-title"]},
            {"doc-section", attrs, ["doc-landing-link"]},
            {"doc-section", Map.put(attrs, :params, %{"section" => "installation/from-source"}),
             ["doc-section-crumb", "doc-section-prev", "doc-section-next"]},
            {"doc-sidebar", Map.put(attrs, :expand_all, true), ["doc-sidebar-link"]},
            {"doc-switcher", Map.put(attrs, :show, "version"), []}
          ] do
        {:ok, view, _html} = mount_page(site, name, given)

        for role <- roles do
          assert text_of(view, ~s([data-role="#{role}"])) != [], "#{name} drew no #{role}"

          assert hrefs(view, ~s([data-role="#{role}"])) == [],
                 "#{name} linked a #{role} to nothing"
        end

        assert hrefs(view, "a") |> Enum.filter(&(&1 == "#")) == [],
               "#{name} drew a link to nothing"

        assert text_of(view, "a:not([href])") == [], "#{name} drew a link with no address"
      end
    end

    test "draws no read link on a card and no version menu", %{site: site} do
      {:ok, list, _html} =
        mount_page(site, "doc-workspace-list", %{
          per_page: 10,
          doc_base: "/:lang/docs",
          lang_param: ""
        })

      assert text_of(list, ~s([data-role="doc-list-title"])) == ["Mishka CMS"]
      assert text_of(list, ~s([data-role="doc-list-read"])) == []

      {:ok, switcher, _html} =
        mount_page(site, "doc-switcher", %{
          workspace: "mishka-cms",
          doc_base: "/:lang/docs",
          lang_param: "",
          show: "version"
        })

      assert text_of(switcher, ~s([data-role="doc-switcher-version"])) == []
    end
  end

  describe "doc-switcher across languages" do
    setup %{site: site} do
      # See the note in "doc-workspace-list in one language": a switch can only offer a language the
      # site publishes, because that is the only one its `:lang` pages answer.
      {:ok, _} = MishkaCmsCore.Settings.put("site.languages", ["en", "fa"], site_id: site.id)
      %{document: master, pages: pages} = manual!(site)
      english = Enum.find(pages, &(&1.slug == "installation"))

      persian =
        document!(site,
          name: "میشکا",
          slug: "mishka-cms-fa",
          language: "fa",
          language_group_id: master.language_group_id
        )

      persian_version =
        version!(site, persian, version_number: "0.3.0", is_latest_for_version: true)

      translated =
        page!(site, persian_version,
          title: "نصب",
          slug: "nasb",
          order_position: 0,
          language: "fa",
          language_group_id: english.language_group_id
        )

      {:ok, master: master, english: english, persian: persian, translated: translated}
    end

    test "offers every edition of the document", %{site: site} do
      {:ok, view, _html} =
        mount_page(site, "doc-switcher", %{workspace: "mishka-cms", show: "language"})

      assert text_of(view, ~s([data-role="doc-switcher-language"])) == ["en", "fa"]
    end

    # THE TRANSLATION OF THE PAGE, not the front page of the other edition. Translations of one page
    # share a `language_group_id`, which is what makes the two the same page — and the Persian one is
    # filed under a different slug on purpose, so nothing here can be right by having the same name.
    #
    # Read in the background, in the task `MishkaGervaz.Messages.start_async/4` hands the page's
    # site: each link is the address this site's URL mode gives its language, built by
    # `site_path/2` there as in the template.
    for mode <- ~w(prefix_others prefix_all) do
      test "and each leads to the same page in that language, in #{mode}", %{site: site} do
        url_mode!(site, unquote(mode))

        {:ok, view, _html} =
          mount_page(site, "doc-switcher", %{
            workspace: "mishka-cms",
            show: "language",
            doc_base: "/:lang/docs",
            params: %{"section" => "installation"}
          })

        assert Enum.sort(hrefs(view, ~s([data-role="doc-switcher-language"]))) ==
                 Enum.sort([
                   english(unquote(mode), "/docs/mishka-cms/installation"),
                   "/fa/docs/mishka-cms-fa/nasb"
                 ])
      end
    end

    # AND THE SLUG IS THE FALLBACK WHERE NOBODY LINKED THEM. An admin can write a translation without
    # joining it to the page it translates, and a Persian page called `upgrading` is still the
    # Persian `upgrading`.
    test "and falls back to the same slug when the two were never linked", %{
      site: site,
      persian: persian
    } do
      [version] = public_versions(site, persian)

      page!(site, version,
        title: "ارتقا",
        slug: "upgrading",
        order_position: 1,
        language: "fa"
      )

      {:ok, view, _html} =
        mount_page(site, "doc-switcher", %{
          workspace: "mishka-cms",
          show: "language",
          doc_base: "/:lang/docs",
          params: %{"section" => "upgrading"}
        })

      assert "/fa/docs/mishka-cms-fa/upgrading" in hrefs(
               view,
               ~s([data-role="doc-switcher-language"])
             )
    end

    # EDITIONS NUMBER THEIR VERSIONS ON THEIR OWN. Persian is on 0.3.0 while English is on 1.0.0, so
    # a `?v=` must never survive a language switch.
    test "and no version number crosses the switch", %{site: site} do
      {:ok, view, _html} =
        mount_page(site, "doc-switcher", %{
          workspace: "mishka-cms",
          show: "language",
          doc_base: "/:lang/docs",
          params: %{"section" => "installation", "v" => "1.0.0"}
        })

      for href <- hrefs(view, ~s([data-role="doc-switcher-language"])) do
        refute href =~ "v=", "#{href} carried a version into another edition"
      end
    end

    test "an edition nobody linked into the group offers no switch at all", %{site: site} do
      document = document!(site, name: "Alone", slug: "alone")
      version!(site, document, version_number: "1.0.0", is_latest_for_version: true)

      Ash.update!(
        Ash.Changeset.for_update(document, :master_update, %{language_group_id: nil},
          authorize?: false
        ),
        authorize?: false
      )

      {:ok, view, _html} =
        mount_page(site, "doc-switcher", %{workspace: "alone", show: "language"})

      assert text_of(view, ~s([data-role="doc-switcher-language"])) == []
    end

    # AND THE CHIP FOR THE EDITION BEING READ IS A NO-OP, which is the one link in this switch
    # allowed to keep a `?v=`: built like the others it would take a reader on an older version to
    # the latest one, and to whatever page that version files under the lineage — from the chip
    # marked as the language they are already reading in.
    test "and the chip for the edition being read keeps the page and version the reader is on", %{
      site: site,
      master: master,
      english: english
    } do
      older =
        version!(site, master, version_number: "0.9.0", published_at: ~U[2025-01-01 00:00:00Z])

      page!(site, older,
        title: "Installation (old)",
        slug: "installation-old",
        order_position: 0,
        section_lineage_id: english.section_lineage_id
      )

      {:ok, view, _html} =
        mount_page(site, "doc-switcher", %{
          workspace: "mishka-cms",
          show: "language",
          doc_base: "/docs",
          lang_param: "",
          params: %{"section" => "installation-old", "v" => "0.9.0"}
        })

      current =
        view
        |> render_async(@async)
        |> LazyHTML.from_fragment()
        |> LazyHTML.query(~s([data-role="doc-switcher-language"][data-selected="true"]))
        |> Enum.map(&LazyHTML.attribute(&1, "href"))
        |> List.flatten()

      assert current == ["/docs/mishka-cms/installation-old?v=0.9.0"]
    end
  end

  # WHAT THE READER DID TO A BLOCK OUTLIVES THE PAGE MOVING UNDER IT. `update_many/1` puts the
  # parent's assigns back on the socket and `update/2` runs `load/1` over them again every time
  # those assigns change — a patch to another URL, a parent event — and not only when the block
  # itself was clicked. Anything the reader has since put on that socket has to come through: the
  # first thing they would notice otherwise is the list jumping back to its first page, or their
  # filter emptying, because something elsewhere on the page moved.
  #
  # Each case below changes what the page hands the block, so the new assigns are visible in what it
  # draws — which is also what proves the block was redrawn at all rather than left alone.
  describe "the page around them changing" do
    test "leaves doc-workspace-list on the page the reader turned to", %{site: site} do
      documents =
        for {name, order} <- Enum.with_index(~w(A B C D E)) do
          document!(site, name: name, slug: String.downcase(name), display_order: order)
        end

      document!(site,
        name: "B fa",
        slug: "b-fa",
        display_order: 1,
        language: "fa",
        language_group_id: Enum.at(documents, 1).language_group_id
      )

      {:ok, view, _html} = mount_page(site, "doc-workspace-list", %{per_page: 2})

      view |> element(~s(#one [data-role="doc-list-next"])) |> render_click()

      assert text_of(view, ~s([data-role="doc-list-position"])) == ["2 / 3"]
      assert text_of(view, ~s([data-role="doc-list-title"])) == ["C", "D"]

      send(view.pid, {:params, %{"lang" => "all"}})

      assert text_of(view, ~s([data-role="doc-list-position"])) == ["2 / 3"]

      assert text_of(view, ~s([data-role="doc-list-title"])) == ["B fa", "C"],
             "the block was not redrawn, so the line above asserts nothing about what survived"
    end

    test "and doc-sidebar narrowed to what the reader typed", %{site: site} do
      manual!(site)

      {:ok, view, _html} =
        mount_page(site, "doc-sidebar", %{workspace: "mishka-cms", show_filter: true})

      view |> form(~s(#one form), %{"q" => "stall"}) |> render_change()
      assert text_of(view, ~s([data-role="doc-sidebar-link"])) == ["Installation"]

      send(view.pid, {:params, %{"section" => "installation"}})

      assert text_of(view, ~s([data-role="doc-sidebar-link"])) == ["Installation"]

      marked =
        view
        |> render_async(@async)
        |> LazyHTML.from_fragment()
        |> LazyHTML.query(~s([data-role="doc-sidebar-item"][data-active="true"]))
        |> Enum.map(&(&1 |> LazyHTML.text() |> String.trim()))

      assert marked == ["Installation"],
             "the block was not redrawn, so the line above asserts nothing about what survived"
    end
  end

  # One manual read at /mishka/docs, with "From source" filed under "Installation", and an older
  # version holding "Installation" too.
  defp addressed!(site) do
    document = document!(site, name: "Mishka CMS", slug: "mishka-cms", path: "/mishka/docs")
    version = version!(site, document, version_number: "1.0.0", is_latest_for_version: true)

    install =
      page!(site, version,
        title: "Installation",
        slug: "installation",
        order_position: 0,
        content: "<h2>Steps</h2><p>One.</p><h2>Checks</h2><p>Two.</p>"
      )

    page!(site, version,
      title: "From source",
      slug: "from-source",
      order_position: 0,
      parent_section_id: install.id,
      content: "<h2>Clone</h2><p>One.</p><h2>Build</h2><p>Two.</p>"
    )

    page!(site, version, title: "Upgrading", slug: "upgrading", order_position: 1)

    older =
      version!(site, document, version_number: "0.9.0", published_at: ~U[2025-01-01 00:00:00Z])

    page!(site, older, title: "Installation", slug: "installation", order_position: 0)

    %{document: document, version: version}
  end

  # One manual whose latest version marks "Get started" as its front page, with "Install" filed under
  # it, and an older version with no front page.
  defp fronted!(site, opts) do
    document = document!(site, Keyword.merge([name: "Fronted", slug: "fronted"], opts))
    version = version!(site, document, version_number: "1.0.0", is_latest_for_version: true)

    front =
      page!(site, version,
        title: "Get started",
        slug: "get-started",
        order_position: 0,
        front_page: true,
        content: "<p>Welcome.</p><h2>Why</h2><p>One.</p><h2>How</h2><p>Two.</p>"
      )

    page!(site, version,
      title: "Install",
      slug: "install",
      order_position: 0,
      parent_section_id: front.id
    )

    page!(site, version, title: "Upgrading", slug: "upgrading", order_position: 1)

    older =
      version!(site, document, version_number: "0.9.0", published_at: ~U[2025-01-01 00:00:00Z])

    page!(site, older, title: "Get started", slug: "get-started", order_position: 0)

    %{document: document, version: version, front: front}
  end

  # One manual at /mishka/docs whose contents hold the group "Navigation" between two pages, with
  # "Breadcrumb" and "Menu" under it.
  defp grouped!(site) do
    document = document!(site, name: "Grouped", slug: "grouped", path: "/mishka/docs")
    version = version!(site, document, version_number: "1.0.0", is_latest_for_version: true)

    page!(site, version, title: "Getting started", slug: "getting-started", order_position: 0)

    group =
      page!(site, version,
        title: "Navigation",
        slug: "navigation",
        order_position: 1,
        group_heading: true,
        content: nil
      )

    page!(site, version,
      title: "Breadcrumb",
      slug: "breadcrumb",
      order_position: 0,
      parent_section_id: group.id
    )

    page!(site, version,
      title: "Menu",
      slug: "menu",
      order_position: 1,
      parent_section_id: group.id
    )

    page!(site, version, title: "Upgrading", slug: "upgrading", order_position: 2)

    %{document: document, version: version, group: group}
  end

  # One manual at /mishka/docs: "Getting started", the group "Navigation" with a page of its own —
  # its intro, a heading, and the cards of its pages — over "Breadcrumb" (an SEO description),
  # "Menu" (a summary from its text), "Drafts" (waiting for review) and "Mega menu" (locked to
  # members:read); the group "Feedback" with no page, over "Alert"; then "Upgrading".
  defp paged_group!(site) do
    :ok = SiteState.put_component(site.id, "doc-section-cards")
    on_exit(fn -> SiteState.delete_component(site.id, "doc-section-cards") end)

    document = document!(site, name: "Paged", slug: "paged", path: "/mishka/docs")
    version = version!(site, document, version_number: "1.0.0", is_latest_for_version: true)

    page!(site, version, title: "Getting started", slug: "getting-started", order_position: 0)

    group =
      page!(site, version,
        title: "Navigation",
        slug: "navigation",
        order_position: 1,
        group_heading: true,
        group_page: true,
        content:
          "<p>Ways to move around a site.</p><h2>Where to start</h2>" <>
            "<p>[[component doc-section-cards /]]</p><h2>Where to go next</h2><p>Forms.</p>"
      )

    page!(site, version,
      title: "Breadcrumb",
      slug: "breadcrumb",
      order_position: 0,
      parent_section_id: group.id,
      seo_tags: [
        %{
          tag: "meta",
          attrs: %{"name" => "description"},
          content: "A trail of links back up the site."
        }
      ]
    )

    page!(site, version,
      title: "Menu",
      slug: "menu",
      order_position: 1,
      parent_section_id: group.id,
      content: "<p>A list of links that <b>opens</b> from a button.</p>"
    )

    page!(site, version,
      title: "Drafts",
      slug: "drafts",
      order_position: 2,
      parent_section_id: group.id,
      content_review_status: :pending
    )

    page!(site, version,
      title: "Mega menu",
      slug: "mega-menu",
      order_position: 3,
      parent_section_id: group.id,
      permissions: ["members:read"]
    )

    feedback =
      page!(site, version,
        title: "Feedback",
        slug: "feedback",
        order_position: 2,
        group_heading: true,
        content: nil
      )

    page!(site, version,
      title: "Alert",
      slug: "alert",
      order_position: 0,
      parent_section_id: feedback.id,
      content: "<p>A message that asks for attention.</p>"
    )

    page!(site, version, title: "Upgrading", slug: "upgrading", order_position: 3)

    %{document: document, version: version, group: group}
  end

  # The group's own page of `paged_group!/1`, read by `visitor`.
  defp navigation_page(site, visitor \\ nil) do
    {:ok, view, _html} =
      mount_page(site, "doc-section", %{
        path: "/mishka/docs",
        lang_param: "",
        params: %{"section" => "navigation"},
        current_user: visitor
      })

    view
  end

  defp public_versions(site, document) do
    MishkaDocument.WorkspaceVersion
    |> Ash.Query.for_read(:public_list, %{}, authorize?: false)
    |> Ash.Query.filter(workspace_id == ^document.id)
    |> Ash.read!(tenant: site.id)
  end

  # The one page of the fixture manual a test needs by row rather than by name.
  defp document_page(site, slug) do
    MishkaDocument.Section
    |> Ash.Query.for_read(:public_list, %{}, authorize?: false)
    |> Ash.Query.filter(slug == ^slug)
    |> Ash.read!(tenant: site.id)
    |> List.first()
  end

  # `site`'s addresses named in `mode`.
  defp url_mode!(site, mode) do
    on_exit(fn -> SettingsState.delete(site.id, "site.language_urls") end)
    {:ok, _} = MishkaCmsCore.Settings.put("site.language_urls", mode, site_id: site.id)
  end

  # Where English, the site's first language, puts `path` in `mode`.
  defp english("prefix_others", path), do: path
  defp english("prefix_all", path), do: "/en" <> path
end
