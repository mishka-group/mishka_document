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

  require Ash.Query

  @moduletag :integration

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
         site: session["site"]
       )}
    end

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
      manual!(site)

      asked = %{"workspace" => "mishka-cms", "params" => %{"section" => "installation"}}

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

      assert Enum.sort(failing) == ~w(doc-sidebar doc-switcher doc-toc doc-workspace-list)
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
      second = note!(site, page, title: "Apple note", order_position: 1)
      first = note!(site, page, title: "Zebra note", order_position: 0)

      _draft =
        note!(site, page, title: "In review", order_position: 2, content_review_status: :pending)

      {:ok, view, _html} =
        mount_page(site, "doc-section", %{
          workspace: "mishka-cms",
          params: %{"section" => "installation"}
        })

      assert text_of(view, ~s([data-role="doc-note-title"])) == ["Zebra note", "Apple note"]

      assert ids_of(view, ~s([data-role="doc-section-note"])) ==
               ["note-#{first.id}", "note-#{second.id}"]
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
