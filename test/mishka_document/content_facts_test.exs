defmodule MishkaDocument.Test.ContentFactsTest do
  @moduledoc """
  The components a page's or a note's text names, stored when it is written —
  `MishkaDocument.Resources.Changes.ContentFacts` — which
  `MishkaDocument.Plugins.ContentComponents` hands a site's stylesheet. Reading either works out
  nothing.
  """
  use MishkaDocument.DataCase, async: false

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
                 components: ["kept"]
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
                 %{site: ctx.site.name, site_id: ctx.site.id, components: []},
                 meta: %{site: ctx.site.name}
               )

      assert names == ["callout"]
    end

    test "come from a plugin this extension's supervisor starts" do
      assert ContentComponents in MishkaDocument.Application.plugins()
    end
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
  end
end
