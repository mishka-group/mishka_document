defmodule MishkaDocument.Test.NoteHighlightTest do
  @moduledoc """
  A note's text is stored the way a page's is: scrubbed by the same `html5` sanitizer, so a code
  block keeps its `language-` class, and highlighted with Makeup when it is written
  (`MishkaDocument.Resources.Changes.HighlightCode`). The components and icons it names are worked
  out from what is stored (`MishkaDocument.Resources.Changes.ContentFacts`). A note draft is stored
  the same way, and the note it is applied to holds the same text.
  """
  use MishkaDocument.DataCase, async: false

  alias MishkaDocument.{Note, NoteDraft}

  @moduletag :integration

  @area "admin:dashboard:document:section"

  setup do
    site = create_site!()
    workspace = create_workspace!(site_id: site.id)
    version = create_workspace_version!(workspace_id: workspace.id, site_id: site.id)

    page =
      create_section!(site_id: site.id, workspace_version_id: version.id, content: "<p>Page</p>")

    %{
      site: site,
      version: version,
      page: page,
      editor: create_user_with_permissions!([@area], site_id: site.id)
    }
  end

  defp block(language, code), do: ~s(<pre><code class="language-#{language}">#{code}</code></pre>)

  defp count(content, selector),
    do: content |> LazyHTML.from_fragment() |> LazyHTML.query(selector) |> Enum.count()

  defp code_text(content, language),
    do:
      content
      |> LazyHTML.from_fragment()
      |> LazyHTML.query("pre > code.language-#{language}")
      |> LazyHTML.text()

  defp create!(ctx, content) do
    Note
    |> Ash.Changeset.for_create(
      :create,
      %{
        section_id: ctx.page.id,
        title: "Part #{System.unique_integer([:positive])}",
        content: content
      },
      actor: ctx.editor,
      tenant: ctx.site.id
    )
    |> Ash.create!()
  end

  defp stored(%Note{id: id}), do: Ash.get!(Note, id, action: :read_any, authorize?: false)

  describe "a note's code" do
    test "keeps its language and is highlighted under it", ctx do
      note = create!(ctx, "<p>Add it:</p>" <> block("elixir", "def hello, do: :world"))

      assert count(note.content, "pre.highlight > code.language-elixir > span.kd") == 1
      assert count(note.content, "pre.highlight > code.language-elixir > span.nf") == 1
      assert code_text(note.content, "elixir") == "def hello, do: :world"
      assert stored(note).content == note.content
    end

    test "keeps a language no lexer answers to, as written", ctx do
      content = block("bash", "mix deps.get")

      assert create!(ctx, content).content == content
    end

    test "keeps the classes of the markup around it, scripts aside", ctx do
      note =
        create!(ctx, ~s(<h3 class="lead">Setup</h3><p>Text</p>) <> "<script>alert(1)</script>")

      assert count(note.content, "h3.lead") == 1
      refute note.content =~ "<script"
    end

    test "is highlighted by an update, and a highlighted note saved again is left as it is",
         ctx do
      note = create!(ctx, "<p>Old</p>")

      updated =
        note
        |> Ash.Changeset.for_update(
          :update,
          %{content: block("heex", "&lt;.button&gt;Go&lt;/.button&gt;")},
          actor: ctx.editor,
          tenant: ctx.site.id
        )
        |> Ash.update!()

      assert count(updated.content, "pre.highlight > code.language-heex > span") > 0

      same =
        updated
        |> Ash.Changeset.for_update(:update, %{title: "Renamed", content: updated.content},
          actor: ctx.editor,
          tenant: ctx.site.id
        )
        |> Ash.update!()

      assert same.content == updated.content
    end

    test "is highlighted by a master's create and update the same way", ctx do
      master = create_user_with_permissions!([@area])

      note =
        Note
        |> Ash.Changeset.for_create(
          :master_create,
          %{
            section_id: ctx.page.id,
            site_id: ctx.site.id,
            title: "Master part",
            content: block("elixir", "def a, do: 1")
          },
          actor: master
        )
        |> Ash.create!()

      assert count(note.content, "pre.highlight > code.language-elixir > span.kd") == 1

      updated =
        Note
        |> Ash.get!(note.id, action: :master_get, actor: master)
        |> Ash.Changeset.for_update(:master_update, %{content: block("json", ~s({"a": 1}))},
          actor: master
        )
        |> Ash.update!()

      assert count(updated.content, "pre.highlight > code.language-json > span") > 0
    end
  end

  # THIS BUILD HAS NO `deps/heroicons`: with no icon set configured, the `hero-` glyphs the
  # installed Chelekom kit bundles register themselves, as `MishkaDocument.Test.ContentFactsTest`
  # sets up.
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

  describe "what a note names" do
    setup :bundled_icons

    test "its components and icons, from its markers and its classes, are recorded", ctx do
      note =
        create!(
          ctx,
          ~s([[component doc-example title="Icons"]][[component chelekom-breadcrumb]]) <>
            ~s([[slot item icon="hero-cloud"]]Cloud[[/slot]][[/component]][[/component]]) <>
            ~s(<p><span class="hero-inbox size-4"></span> Inbox</p>) <>
            block("heex", "&lt;.breadcrumb /&gt;")
        )

      facts = stored(note)

      assert facts.content_components == ["doc-example", "chelekom-breadcrumb"]
      assert facts.content_icons == ["hero-cloud", "hero-inbox"]
    end
  end

  describe "a note draft" do
    test "is stored highlighted, and the note it is applied to holds the same text", ctx do
      note = create!(ctx, "<p>Old</p>")

      draft =
        NoteDraft
        |> Ash.Changeset.for_create(
          :create,
          %{
            workspace_version_id: ctx.version.id,
            section_id: ctx.page.id,
            source_note_id: note.id,
            title: note.title,
            content: "<p>New</p>" <> block("elixir", "def b, do: 2"),
            change_version: "0.0.2",
            version_increment_type: :patch
          },
          actor: ctx.editor,
          tenant: ctx.site.id
        )
        |> Ash.create!()

      assert count(draft.content, "pre.highlight > code.language-elixir > span.kd") == 1

      draft
      |> Ash.Changeset.for_update(
        :update,
        %{content_review_status: :approved, technical_review_status: :approved},
        actor: ctx.editor,
        tenant: ctx.site.id
      )
      |> Ash.update!()

      assert stored(note).content == draft.content
    end
  end
end
