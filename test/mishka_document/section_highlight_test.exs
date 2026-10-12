defmodule MishkaDocument.Test.SectionHighlightTest do
  @moduledoc """
  A page's text is a whole documentation page — kilobytes of it, code blocks and all — and its code
  blocks are highlighted with Makeup when it is written, and stored that way
  (`MishkaDocument.Resources.Changes.HighlightCode`).

  The shape is `pre.highlight > code.language-x > span.<token>`. Every write here goes through the
  action an admin's form, the JSON:API or an approved draft calls, as an admin holding the section
  area.
  """
  use MishkaDocument.DataCase, async: false

  alias MishkaDocument.{Section, SectionDraft}

  require Ash.Query

  @moduletag :integration

  @area "admin:dashboard:document:section"

  setup do
    site = create_site!()
    workspace = create_workspace!(site_id: site.id)
    version = create_workspace_version!(workspace_id: workspace.id, site_id: site.id)

    %{
      site: site,
      version: version,
      editor: create_user_with_permissions!([@area], site_id: site.id)
    }
  end

  defp attrs(ctx, content) do
    unique = System.unique_integer([:positive])

    %{
      title: "Page #{unique}",
      slug: "page-#{unique}",
      content: content,
      language: "en",
      workspace_version_id: ctx.version.id
    }
  end

  defp create!(ctx, content) do
    Section
    |> Ash.Changeset.for_create(:create, attrs(ctx, content),
      actor: ctx.editor,
      tenant: ctx.site.id
    )
    |> Ash.create!()
  end

  defp block(language, code), do: ~s(<pre><code class="language-#{language}">#{code}</code></pre>)

  defp query(content, selector),
    do: content |> LazyHTML.from_fragment() |> LazyHTML.query(selector)

  defp count(content, selector), do: content |> query(selector) |> Enum.count()

  defp code_text(content, language),
    do: content |> query("pre > code.language-#{language}") |> LazyHTML.text()

  # A page the size of a real one: an introduction, a dozen sections of prose, and code in four
  # languages between them.
  defp long_page do
    prose = String.duplicate("Each step is explained in full before the code that does it. ", 12)

    Enum.map_join(1..12, fn index ->
      "<h2>Step #{index}</h2><p>#{prose}</p>" <>
        case rem(index, 4) do
          0 -> block("elixir", "def step_#{index}(conn), do: conn")
          1 -> block("heex", "&lt;.button phx-click=&quot;go&quot;&gt;Go&lt;/.button&gt;")
          2 -> block("js", "const step = #{index};")
          3 -> block("css", ".step-#{index} { color: #333; }")
        end
    end)
  end

  describe "a whole page" do
    test "is saved as it was written, whatever its length", ctx do
      content = long_page()
      assert byte_size(content) > 9_000

      page = create!(ctx, content)

      assert count(page.content, "h2") == 12
      assert count(page.content, "pre.highlight") == 12
      assert count(page.content, "pre:not(.highlight)") == 0
    end

    test "comes back with its code highlighted, under its language", ctx do
      page = create!(ctx, block("elixir", "def hello, do: :world"))

      assert count(page.content, "pre.highlight > code.language-elixir > span.kd") == 1
      assert count(page.content, "pre.highlight > code.language-elixir > span.nf") == 1
      assert code_text(page.content, "elixir") == "def hello, do: :world"

      read =
        Section
        |> Ash.Query.for_read(:read, %{}, actor: ctx.editor, tenant: ctx.site.id)
        |> Ash.Query.filter(id == ^page.id)
        |> Ash.read_one!()

      assert read.content == page.content
    end

    test "keeps a code block's language when no lexer answers to it", ctx do
      content = block("bash", "mix deps.get")

      assert create!(ctx, content).content == content
    end

    test "and keeps the markup a page is made of, scripts aside", ctx do
      page =
        create!(
          ctx,
          ~s(<h2 class="lead">Intro</h2><table><tr><td>One</td></tr></table>) <>
            "<script>alert(1)</script>"
        )

      assert count(page.content, "h2.lead") == 1
      assert count(page.content, "table td") == 1
      refute page.content =~ "<script"
    end

    test "may still be no text at all, a heading over the pages filed under it", ctx do
      assert create!(ctx, nil).content == nil
    end
  end

  describe "an update" do
    test "highlights the code it was handed, and leaves a highlighted page as it is", ctx do
      page = create!(ctx, block("elixir", "def old, do: 1"))

      updated =
        page
        |> Ash.Changeset.for_update(:update, %{content: block("erlang", "ok.")},
          actor: ctx.editor,
          tenant: ctx.site.id
        )
        |> Ash.update!()

      assert count(updated.content, "pre.highlight > code.language-erlang > span") > 0

      same =
        updated
        |> Ash.Changeset.for_update(:update, %{title: "Renamed", content: updated.content},
          actor: ctx.editor,
          tenant: ctx.site.id
        )
        |> Ash.update!()

      assert same.content == updated.content
    end

    test "and a master's create and update highlight the same way", ctx do
      master = create_user_with_permissions!([@area])

      page =
        Section
        |> Ash.Changeset.for_create(
          :master_create,
          Map.put(attrs(ctx, block("elixir", "def a, do: 1")), :site_id, ctx.site.id),
          actor: master
        )
        |> Ash.create!()

      assert count(page.content, "pre.highlight > code.language-elixir > span.kd") == 1

      updated =
        Section
        |> Ash.get!(page.id, action: :master_get, actor: master)
        |> Ash.Changeset.for_update(:master_update, %{content: block("json", ~s({"a": 1}))},
          actor: master
        )
        |> Ash.update!()

      assert count(updated.content, "pre.highlight > code.language-json > span") > 0
    end
  end

  describe "a draft" do
    test "is stored highlighted, and the page it is applied to holds the same text", ctx do
      page = create!(ctx, "<p>Old</p>")

      draft =
        SectionDraft
        |> Ash.Changeset.for_create(
          :create,
          %{
            workspace_version_id: ctx.version.id,
            source_section_id: page.id,
            title: page.title,
            slug: page.slug,
            content: long_page(),
            language: "en",
            change_version: "0.0.2",
            version_increment_type: :patch
          },
          actor: ctx.editor,
          tenant: ctx.site.id
        )
        |> Ash.create!()

      assert count(draft.content, "pre.highlight") == 12

      draft
      |> Ash.Changeset.for_update(
        :update,
        %{content_review_status: :approved, technical_review_status: :approved},
        actor: ctx.editor,
        tenant: ctx.site.id
      )
      |> Ash.update!()

      applied =
        Section
        |> Ash.Query.for_read(:read, %{}, actor: ctx.editor, tenant: ctx.site.id)
        |> Ash.Query.filter(id == ^page.id)
        |> Ash.read_one!()

      assert applied.content == draft.content
      assert count(applied.content, "pre.highlight > code.language-elixir > span.nf") == 3
    end

    test "that adds a page writes it highlighted", ctx do
      draft =
        SectionDraft
        |> Ash.Changeset.for_create(
          :create,
          %{
            workspace_version_id: ctx.version.id,
            title: "New page",
            slug: "new-page",
            content: block("elixir", "def a, do: 1"),
            language: "en",
            change_version: "0.0.1",
            version_increment_type: :none
          },
          actor: ctx.editor,
          tenant: ctx.site.id
        )
        |> Ash.create!()

      draft
      |> Ash.Changeset.for_update(
        :update,
        %{content_review_status: :approved, technical_review_status: :approved},
        actor: ctx.editor,
        tenant: ctx.site.id
      )
      |> Ash.update!()

      written =
        Section
        |> Ash.Query.for_read(:read, %{}, actor: ctx.editor, tenant: ctx.site.id)
        |> Ash.Query.filter(slug == "new-page")
        |> Ash.read_one!()

      assert count(written.content, "pre.highlight > code.language-elixir > span.kd") == 1
    end
  end
end
