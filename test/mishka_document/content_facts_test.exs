defmodule MishkaDocument.Test.ContentFactsTest do
  @moduledoc """
  The components, the icons and the classes a page's or a note's text names, stored when it is
  written —
  `MishkaDocument.Resources.Changes.ContentFacts` — which
  `MishkaDocument.Plugins.ContentComponents` hands a site's stylesheet. Reading either works out
  nothing.
  """
  use MishkaDocument.DataCase, async: false
  use Oban.Testing, repo: MishkaDocument.Repo

  alias MishkaCmsCore.Runtime.States.SiteState
  alias MishkaCmsCore.Runtime.Workers.RuntimeCompilerWorker
  alias MishkaDocument.{Note, Section}
  alias MishkaDocument.Plugins.ContentComponents
  alias MishkaDocument.Resources.Changes.ContentFacts

  @moduletag :integration

  @area "admin:dashboard:document:section"

  setup do
    site = create_site!(name: "facts#{System.unique_integer([:positive])}")
    workspace = create_workspace!(site_id: site.id)
    version = create_workspace_version!(workspace_id: workspace.id, site_id: site.id)

    %{
      site: site,
      version: version,
      editor: create_user_with_permissions!([@area], site_id: site.id)
    }
  end

  defp approved, do: [content_review_status: :approved, technical_review_status: :approved]

  defp page!(ctx, content, opts \\ []) do
    create_section!(
      [site_id: ctx.site.id, workspace_version_id: ctx.version.id, content: content] ++ opts
    )
  end

  defp write!(record, params, ctx) do
    record
    |> Ash.Changeset.for_update(:update, params, actor: ctx.editor, tenant: ctx.site.id)
    |> Ash.update!()
  end

  defp stored(%resource{id: id}), do: Ash.get!(resource, id, action: :read_any, authorize?: false)

  # THIS BUILD HAS NO `deps/heroicons`, so the stock Heroicons set ships nothing here. With no set
  # configured, the `hero-` glyphs the installed Chelekom kit bundles register themselves
  # (`MishkaCmsCore.Runtime.PageBuilder.Icons.Bundled`) — what a host without heroicons draws from.
  defp bundled_icons(_context) do
    original = Application.get_env(:mishka_cms_core, :icon_libraries)
    Application.put_env(:mishka_cms_core, :icon_libraries, [])

    on_exit(fn ->
      case original do
        nil -> Application.delete_env(:mishka_cms_core, :icon_libraries)
        libraries -> Application.put_env(:mishka_cms_core, :icon_libraries, libraries)
      end
    end)

    :ok
  end

  describe "content_components" do
    test "are the names a page's markers name, each once", ctx do
      page =
        page!(
          ctx,
          ~s(<p>[[component callout title="a"]]x[[/component]]</p>[[component badge /]]) <>
            "[[component callout /]]<code>[[component shown /]]</code>"
        )

      assert stored(page).content_components == ["callout", "badge"]
    end

    test "are nothing for text that names none", ctx do
      page = page!(ctx, "[[component callout /]]")

      assert stored(write!(page, %{content: "<p>plain</p>"}, ctx)).content_components == nil
      assert stored(page!(ctx, nil)).content_components == nil
    end

    test "are kept by a write that leaves the text alone", ctx do
      page = page!(ctx, "[[component callout /]]")

      assert stored(write!(page, %{title: "Renamed"}, ctx)).content_components == ["callout"]
    end

    test "are a note's too", ctx do
      page = page!(ctx, "<p>Body</p>")

      note =
        create_note!(
          site_id: ctx.site.id,
          section_id: page.id,
          content: "<p>[[component tip-box /]]</p>"
        )

      assert stored(note).content_components == ["tip-box"]
      assert stored(write!(note, %{content: "<p>none</p>"}, ctx)).content_components == nil
    end

    test "are an applied draft's, written onto its page", ctx do
      page = page!(ctx, "<p>Old</p>")

      MishkaDocument.SectionDraft
      |> Ash.Changeset.for_create(
        :create,
        %{
          workspace_version_id: ctx.version.id,
          source_section_id: page.id,
          title: page.title,
          slug: page.slug,
          content: "<p>[[component callout /]]</p>",
          language: "en",
          change_version: "0.0.2",
          version_increment_type: :patch
        },
        actor: ctx.editor,
        tenant: ctx.site.id
      )
      |> Ash.create!()
      |> Ash.Changeset.for_update(
        :update,
        %{content_review_status: :approved, technical_review_status: :approved},
        actor: ctx.editor,
        tenant: ctx.site.id
      )
      |> Ash.update!()

      assert stored(page).content_components == ["callout"]
    end
  end

  describe "content_icons" do
    setup :bundled_icons

    test "are the icons a page's markers and HTML name, each once", ctx do
      page =
        page!(
          ctx,
          ~s([[component breadcrumb]][[slot item icon="hero-cloud"]]Cloud[[/slot]]) <>
            ~s([[slot item icon="hero-circle-stack"]][[/slot]][[/component]]) <>
            ~s(<p><span class="hero-inbox size-4"></span> A hero-section, and hero-cloud again</p>)
        )

      assert stored(page).content_icons == ["hero-cloud", "hero-circle-stack", "hero-inbox"]
    end

    test "are nothing for text that names none, and follow the text it is written with", ctx do
      page = page!(ctx, ~s(<span class="hero-inbox"></span>))

      assert stored(write!(page, %{title: "Renamed"}, ctx)).content_icons == ["hero-inbox"]
      assert stored(write!(page, %{content: "<p>plain</p>"}, ctx)).content_icons == nil
      assert stored(page!(ctx, nil)).content_icons == nil
    end

    test "are a note's too", ctx do
      page = page!(ctx, "<p>Body</p>")

      note =
        create_note!(
          site_id: ctx.site.id,
          section_id: page.id,
          content: ~s(<p>[[component tip-box icon="hero-envelope" /]]</p>)
        )

      assert stored(note).content_icons == ["hero-envelope"]
    end
  end

  # A COMPONENT THAT TAKES A CLASS STRING in an attribute declares `examples` for it and no `values`.
  @open_attrs [
    %{
      "name" => "size",
      "type" => "string",
      "opts" => %{"default" => "small", "examples" => ["small", "large"]}
    },
    %{
      "name" => "color",
      "type" => "string",
      "opts" => %{"default" => "base", "values" => ["base", "dark"]}
    },
    %{"name" => "label", "type" => "string", "opts" => %{"default" => nil}}
  ]

  describe "content_classes" do
    test "are the classes a page's HTML, its markers' *_class and its components' open attributes write",
         ctx do
      create_component!(
        name: "open-badge",
        attrs: @open_attrs,
        active: true,
        precompile: false,
        site_id: ctx.site.id
      )

      page =
        page!(
          ctx,
          ~s(<div class="bg-[#282828] text-white">x</div>) <>
            ~s([[component doc-example title="Hidden block"]][[component slider track_class="h-1 bg-neutral-200" ) <>
            ~s(thumb_class="size-4" /]][[/component]]) <>
            ~s([[component open-badge size="leading-5 py-2" color="bg-red-500" label="flex" /]]) <>
            ~s(<pre><code>[[component slider track_class="in-code" /]]</code></pre>)
        )

      assert stored(page).content_classes == [
               "bg-[#282828]",
               "text-white",
               "size-4",
               "h-1",
               "bg-neutral-200",
               "leading-5",
               "py-2"
             ]
    end

    test "are nothing for text that writes none, and follow the text it is written with", ctx do
      page = page!(ctx, ~s(<p class="bg-[#282828]">x</p>))

      assert stored(write!(page, %{title: "Renamed"}, ctx)).content_classes == ["bg-[#282828]"]
      assert stored(write!(page, %{content: "<p>plain</p>"}, ctx)).content_classes == nil
      assert stored(page!(ctx, nil)).content_classes == nil
    end

    test "are a note's too", ctx do
      page = page!(ctx, "<p>Body</p>")

      note =
        create_note!(
          site_id: ctx.site.id,
          section_id: page.id,
          content: ~s(<p>[[component tip-box class="ring-2 ring-[#ff0]" /]]</p>)
        )

      assert stored(note).content_classes == ["ring-2", "ring-[#ff0]"]
    end
  end

  # A SITE'S STYLESHEET IS BUILT FROM WHAT IT REACHES, and a page's components are in no template.
  describe "the names a site's stylesheet hears" do
    test "are those its approved pages and notes name, each once", ctx do
      page = page!(ctx, "[[component callout /]][[component badge /]]", approved())
      page!(ctx, "[[component callout /]]", approved())
      page!(ctx, "[[component in-review /]]")

      create_note!(
        [site_id: ctx.site.id, section_id: page.id, content: "<p>[[component tip-box /]]</p>"] ++
          approved()
      )

      create_note!(
        site_id: ctx.site.id,
        section_id: page.id,
        content: "<p>[[component note-in-review /]]</p>"
      )

      elsewhere = create_site!()
      theirs = create_workspace!(site_id: elsewhere.id)
      their_version = create_workspace_version!(workspace_id: theirs.id, site_id: elsewhere.id)

      create_section!(
        [
          site_id: elsewhere.id,
          workspace_version_id: their_version.id,
          content: "[[component theirs /]]"
        ] ++ approved()
      )

      assert {:reply, %{components: names}} =
               ContentComponents.call(%{
                 site: ctx.site.name,
                 site_id: ctx.site.id,
                 components: ["kept"],
                 icons: []
               })

      assert Enum.sort(names) == ["badge", "callout", "kept", "tip-box"]
    end

    test "are asked of this extension by the site's stylesheet build", ctx do
      page!(ctx, "[[component callout /]]", approved())

      # THE APPLICATION'S PLUGIN PROCESSES ARE NOT RUNNING IN THIS SUITE: the plugin is registered
      # the way the CMS boot registers it, and unregistered when the test exits.
      MishkaCmsCore.PluginRegistrations.reconcile(false)
      {:ok, _registered} = ContentComponents.register()
      on_exit(fn -> MishkaInstaller.Event.Event.unregister(:name, ContentComponents, false) end)

      :ok =
        MishkaInstaller.Event.EventHandler.do_compile(
          ContentComponents.config(:__event__),
          :start,
          false
        )

      # THE EVENT `MishkaCmsCore.Runtime.Compilers.TailwindCompiler.content_components/1` FIRES,
      # with the map it hands the plugins.
      assert %{components: names} =
               MishkaInstaller.Event.Hook.call(
                 "runtime:compile:content_components",
                 %{site: ctx.site.name, site_id: ctx.site.id, components: [], icons: []},
                 meta: %{site: ctx.site.name}
               )

      assert names == ["callout"]
    end

    test "come from a plugin this extension's supervisor starts" do
      assert ContentComponents in MishkaDocument.Application.plugins()
    end
  end

  # AN ICON A PAGE NAMES IS IN NO TEMPLATE EITHER: a marker's `icon="hero-cloud"` reaches its
  # component as an expression, and a `<span class="hero-inbox">` in the text is never scanned.
  describe "the icons a site's stylesheet hears" do
    setup :bundled_icons

    test "are those its approved pages and notes name, each once", ctx do
      page =
        page!(
          ctx,
          ~s([[slot item icon="hero-cloud" /]]<span class="hero-inbox"></span>),
          approved()
        )

      page!(ctx, ~s(<span class="hero-cloud"></span>), approved())
      page!(ctx, ~s(<span class="hero-star"></span>))

      create_note!(
        [
          site_id: ctx.site.id,
          section_id: page.id,
          content: ~s(<p>[[component tip-box icon="hero-envelope" /]]</p>)
        ] ++
          approved()
      )

      create_note!(
        site_id: ctx.site.id,
        section_id: page.id,
        content: ~s(<p>[[component tip-box icon="hero-moon" /]]</p>)
      )

      assert {:reply, %{icons: icons}} =
               ContentComponents.call(%{
                 site: ctx.site.name,
                 site_id: ctx.site.id,
                 components: [],
                 icons: ["hero-bell"]
               })

      assert Enum.sort(icons) == ["hero-bell", "hero-cloud", "hero-envelope", "hero-inbox"]
    end
  end

  # A CLASS A PAGE WRITES IS IN NO TEMPLATE EITHER: a marker's `track_class="h-1"` reaches its
  # component as an expression, and a page's HTML is never scanned.
  describe "the classes a site's stylesheet hears" do
    test "are those its approved pages and notes write, each once", ctx do
      page = page!(ctx, ~s(<p class="bg-[#282828] p-2">x</p>), approved())
      page!(ctx, ~s(<p class="p-2">x</p>), approved())
      page!(ctx, ~s(<p class="in-review">x</p>))

      create_note!(
        [
          site_id: ctx.site.id,
          section_id: page.id,
          content: ~s(<p>[[component tip-box thumb_class="size-4" /]]</p>)
        ] ++ approved()
      )

      assert {:reply, %{classes: classes, components: components}} =
               ContentComponents.call(%{
                 site: ctx.site.name,
                 site_id: ctx.site.id,
                 components: [],
                 icons: [],
                 classes: ["kept"]
               })

      assert Enum.sort(classes) == ["bg-[#282828]", "kept", "p-2", "size-4"]
      assert components == ["tip-box"]
    end

    test "are not asked of a build that asks for none, which still hears the names", ctx do
      page!(ctx, ~s(<p class="p-2">[[component callout /]]</p>), approved())

      assert {:reply, answer} =
               ContentComponents.call(%{
                 site: ctx.site.name,
                 site_id: ctx.site.id,
                 components: [],
                 icons: []
               })

      assert answer.components == ["callout"]
      refute Map.has_key?(answer, :classes)
    end
  end

  describe "a write that changes the classes an approved page writes" do
    setup :open_site

    test "rebuilds the site's stylesheet when it writes one no approved page did", ctx do
      write!(ctx.page, %{content: ~s(<p class="p-2 bg-[#282828]">x</p>)}, ctx)

      assert [_job] = css_jobs(ctx.site)
    end

    test "rebuilds nothing when its classes stay as they were", ctx do
      write!(ctx.page, %{content: ~s(<p>New text</p><i class="p-2"></i>)}, ctx)

      assert stored(ctx.page).content_classes == ["p-2"]
      assert css_jobs(ctx.site) == []
    end

    test "rebuilds nothing for classes other approved pages already write", ctx do
      write!(ctx.page, %{content: ~s(<p class="p-2 m-4 text-sm">x</p>)}, ctx)

      assert css_jobs(ctx.site) == []
    end
  end

  # A WRITE THAT MAKES AN ICON LIVE asks for the site's stylesheet again, as one that makes a
  # component name live does. `TailwindCompiler.schedule/1` enqueues nothing under the `:env_test?`
  # flag, so it is switched off once the pages a test starts from exist.
  describe "a write that changes the icons an approved page names" do
    setup [:bundled_icons, :open_site]

    test "rebuilds the site's stylesheet when it names one no approved page did", ctx do
      write!(ctx.page, %{content: ~s(<span class="hero-cloud hero-inbox"></span>)}, ctx)

      assert [_job] = css_jobs(ctx.site)
    end

    test "rebuilds nothing when its icons stay as they were", ctx do
      write!(ctx.page, %{content: ~s(<p>New text</p><i class="hero-cloud p-2"></i>)}, ctx)

      assert stored(ctx.page).content_icons == ["hero-cloud"]
      assert css_jobs(ctx.site) == []
    end

    test "rebuilds nothing for an icon another approved page already names", ctx do
      write!(ctx.page, %{content: ~s(<span class="hero-cloud hero-star p-2"></span>)}, ctx)

      assert css_jobs(ctx.site) == []
    end
  end

  # A NAME AND HOST OF ITS OWN, active, so its create caches it in `SiteState` — a stylesheet job is
  # enqueued only for such a site.
  defp open_site(_context) do
    name = "iconsite#{System.unique_integer([:positive])}"
    site = create_site!(name: name, host: "#{name}.test", active: true)
    on_exit(fn -> SiteState.delete(site.id) end)

    workspace = create_workspace!(site_id: site.id)
    version = create_workspace_version!(workspace_id: workspace.id, site_id: site.id)
    ctx = %{site: site, version: version}

    page = page!(ctx, ~s(<span class="hero-cloud p-2"></span>), approved())
    page!(ctx, ~s(<span class="hero-star m-4"></span>), approved())
    page!(ctx, ~s(<span class="text-sm"></span>), approved())

    Application.put_env(:mishka_cms_core, :env_test?, false)
    on_exit(fn -> Application.put_env(:mishka_cms_core, :env_test?, true) end)

    {:ok,
     site: site,
     version: version,
     page: page,
     editor: create_user_with_permissions!([@area], site_id: site.id)}
  end

  defp css_jobs(site) do
    all_enqueued(worker: RuntimeCompilerWorker)
    |> Enum.filter(fn job ->
      get_in(job.args, ["data", "type"]) == "css" and
        get_in(job.args, ["data", "site_id"]) == site.id
    end)
  end

  # WHEN A WRITE ASKS FOR THE STYLESHEET AGAIN: a name an approved page or note makes live.
  describe "newly_live/2" do
    test "is what an approved page names now and did not before" do
      was = %{
        content_review_status: :approved,
        technical_review_status: :approved,
        content_components: ["a"]
      }

      assert ContentFacts.newly_live(was, %{was | content_components: ["a", "b"]}) == ["b"]
      assert ContentFacts.newly_live(was, %{was | content_components: ["a"]}) == []
      assert ContentFacts.newly_live(was, %{was | content_components: nil}) == []
    end

    test "is everything a page names once both reviews approve it, and nothing before" do
      pending = %{
        content_review_status: :approved,
        technical_review_status: :pending,
        content_components: ["a"]
      }

      approved = %{pending | technical_review_status: :approved}

      assert ContentFacts.newly_live(pending, approved) == ["a"]
      assert ContentFacts.newly_live(approved, pending) == []
      assert ContentFacts.newly_live(%Section{}, pending) == []
      assert ContentFacts.newly_live(%Note{}, approved) == ["a"]
    end

    test "is the same question of the classes a page writes" do
      was = %{
        content_review_status: :approved,
        technical_review_status: :approved,
        content_classes: ["p-2"]
      }

      now = %{was | content_classes: ["p-2", "bg-[#282828]"]}

      assert ContentFacts.newly_live(was, now, :content_classes) == ["bg-[#282828]"]
      assert ContentFacts.newly_live(now, was, :content_classes) == []
    end

    test "is the same question of the icons a page names" do
      was = %{
        content_review_status: :approved,
        technical_review_status: :approved,
        content_components: ["a"],
        content_icons: ["hero-cloud"]
      }

      now = %{was | content_icons: ["hero-cloud", "hero-inbox"]}

      assert ContentFacts.newly_live(was, now, :content_icons) == ["hero-inbox"]
      assert ContentFacts.newly_live(was, now) == []
      assert ContentFacts.newly_live(now, was, :content_icons) == []

      assert ContentFacts.newly_live(
               %{now | technical_review_status: :pending},
               now,
               :content_icons
             ) ==
               ["hero-cloud", "hero-inbox"]
    end
  end
end
