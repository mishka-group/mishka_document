# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_document/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaDocument.DraftApplyTest do
  @moduledoc """
  Applying a draft of a page or a note — both its reviews approved — writes the fields the draft
  changes, and no other (`MishkaDocument.Resources.Changes.StartFromSource`): a field its editor
  left empty when adding it, or never touched after, keeps what the page or note holds, also when
  that changed after the draft was written. A draft adding a page writes all of itself.
  """
  use MishkaDocument.DataCase, async: false

  require Ash.Query

  alias MishkaDocument.{EventLog, Note, NoteDraft, Section, SectionDraft}

  @robots [%{"tag" => "meta", "attrs" => %{"name" => "robots"}, "content" => "noindex, follow"}]
  @schema [%{"@type" => "TechArticle", "name" => "Salaries"}]

  setup do
    site = create_site!(active: true)
    admin = create_user_with_permissions!(["admin:dashboard:document:section"], site_id: site.id)
    document = create_workspace!(site_id: site.id, skip_version: true, status: :active)

    version =
      create_workspace_version!(
        site_id: site.id,
        workspace_id: document.id,
        status: :stable,
        published_at: ~U[2026-03-01 00:00:00Z]
      )

    parent = create_section!(site_id: site.id, workspace_version_id: version.id, slug: "people")

    translated =
      create_section!(
        site_id: site.id,
        workspace_version_id: version.id,
        slug: "translated",
        language: "fa"
      )

    page =
      create_section!(
        site_id: site.id,
        workspace_version_id: version.id,
        parent_section_id: parent.id,
        language_group_id: translated.id,
        title: "Salaries",
        slug: "salaries",
        content: ~s(<p dir="auto">How salaries are paid.</p>),
        order_position: 3,
        change_version: "1.0.0",
        content_review_status: :approved,
        technical_review_status: :approved,
        permissions: ["members:read"],
        seo_tags: @robots,
        schema: @schema
      )

    %{site: site, admin: admin, version: version, parent: parent, page: page}
  end

  # What the draft form sends for an edit of a page when only its title and version are typed: every
  # other field it shows, left empty.
  defp edit_draft!(ctx, attrs \\ %{}) do
    params =
      Map.merge(
        %{
          workspace_version_id: ctx.version.id,
          source_section_id: ctx.page.id,
          title: "Salaries and bonuses",
          slug: "salaries",
          language: "en",
          change_version: "1.1.0",
          version_increment_type: :minor,
          parent_section_id: nil,
          language_group_id: nil,
          order_position: 0,
          content: nil,
          permissions: [],
          seo_tags: [],
          schema: []
        },
        attrs
      )

    SectionDraft
    |> Ash.Changeset.for_create(:create, params, tenant: ctx.site.id, actor: ctx.admin)
    |> Ash.create!()
  end

  defp update!(draft, ctx, attrs) do
    draft
    |> Ash.Changeset.for_update(:update, attrs, tenant: ctx.site.id, actor: ctx.admin)
    |> Ash.update!()
  end

  defp approve!(draft, ctx),
    do:
      update!(draft, ctx, %{content_review_status: :approved, technical_review_status: :approved})

  defp page(ctx), do: Ash.get!(Section, ctx.page.id, tenant: ctx.site.id, actor: ctx.admin)

  # The page's update events, oldest first.
  defp page_updates(ctx) do
    EventLog
    |> Ash.Query.filter(resource == ^Section and record_id == ^ctx.page.id and action == :update)
    |> Ash.Query.sort(occurred_at: :asc)
    |> Ash.read!(actor: ctx.admin, page: false)
  end

  describe "a draft of a page" do
    test "starts with what the page holds for every field it is added without", ctx do
      draft = edit_draft!(ctx)

      assert draft.parent_section_id == ctx.parent.id
      assert draft.language_group_id == ctx.page.language_group_id
      assert draft.order_position == 3
      assert draft.content == ctx.page.content
      assert draft.permissions == ["members:read"]
      assert length(draft.seo_tags) == 1
      assert length(draft.schema) == 1
      assert Enum.sort(draft.changed_fields) == [:change_version, :title]
    end

    test "changes only the fields it changes once applied", ctx do
      ctx |> edit_draft!() |> approve!(ctx)

      page = page(ctx)
      assert page.title == "Salaries and bonuses"
      assert page.change_version == "1.1.0"
      assert page.parent_section_id == ctx.parent.id
      assert page.language_group_id == ctx.page.language_group_id
      assert page.order_position == 3
      assert page.content == ctx.page.content
      assert page.permissions == ["members:read"]
      assert length(page.seo_tags) == 1
      assert length(page.schema) == 1
    end

    test "keeps what the page was given after the draft was written", ctx do
      draft = edit_draft!(ctx)

      ctx.page
      |> Ash.Changeset.for_update(
        :update,
        %{permissions: ["staff:read"], content: "<p>Rewritten since.</p>", order_position: 7},
        tenant: ctx.site.id,
        actor: ctx.admin
      )
      |> Ash.update!()

      approve!(draft, ctx)

      page = page(ctx)
      assert page.title == "Salaries and bonuses"
      assert page.permissions == ["staff:read"]
      assert page.content == "<p>Rewritten since.</p>"
      assert page.order_position == 7
    end

    test "edited to clear a field clears it, and set back to the page's own leaves it", ctx do
      draft = edit_draft!(ctx)
      draft = update!(draft, ctx, %{permissions: [], parent_section_id: nil})

      assert Enum.sort(draft.changed_fields) == [
               :change_version,
               :parent_section_id,
               :permissions,
               :title
             ]

      draft = update!(draft, ctx, %{title: "Salaries", parent_section_id: ctx.parent.id})
      assert Enum.sort(draft.changed_fields) == [:change_version, :permissions]

      ctx.page
      |> Ash.Changeset.for_update(:update, %{title: "Pay"}, tenant: ctx.site.id, actor: ctx.admin)
      |> Ash.update!()

      approve!(draft, ctx)

      page = page(ctx)
      assert page.permissions == []
      assert page.parent_section_id == ctx.parent.id
      assert page.title == "Pay"
    end

    test "moves the page to its version and leaves its place in the document's history", ctx do
      before = page_updates(ctx)
      draft = ctx |> edit_draft!(%{content: "<p>Paid monthly.</p>"}) |> approve!(ctx)

      page = page(ctx)
      assert page.change_version == "1.1.0"
      assert page.content == "<p>Paid monthly.</p>"
      assert page.workspace_version_id == ctx.page.workspace_version_id
      assert page.section_lineage_id == ctx.page.section_lineage_id

      assert %DateTime{} =
               Ash.get!(SectionDraft, draft.id, tenant: ctx.site.id, actor: ctx.admin).applied_at

      assert [applied] = page_updates(ctx) -- before
      assert applied.metadata["title"] == "Salaries and bonuses"
    end

    test "that changes nothing is applied without writing the page", ctx do
      before = page_updates(ctx)

      draft = edit_draft!(ctx, %{title: "Salaries", change_version: "1.0.0"})
      assert draft.changed_fields == []

      draft = approve!(draft, ctx)

      assert %DateTime{} = draft.applied_at
      assert page_updates(ctx) == before
      assert page(ctx).updated_at == ctx.page.updated_at
    end
  end

  test "a draft adding a page writes all of itself", ctx do
    draft =
      ctx
      |> edit_draft!(%{
        source_section_id: nil,
        slug: "bonuses",
        title: "Bonuses",
        order_position: 4
      })
      |> approve!(ctx)

    assert draft.changed_fields == []

    [page] =
      Section
      |> Ash.Query.filter(slug == "bonuses")
      |> Ash.read!(tenant: ctx.site.id, actor: ctx.admin)

    assert page.order_position == 4
    assert page.change_version == "1.1.0"
  end

  test "a draft of a note changes only the fields it changes once applied", ctx do
    note =
      create_note!(
        site_id: ctx.site.id,
        section_id: ctx.page.id,
        title: "Tip",
        content: "<p>Pay day is the last Friday.</p>",
        order_position: 2,
        seo_tags: @robots,
        schema: @schema
      )

    draft =
      NoteDraft
      |> Ash.Changeset.for_create(
        :create,
        %{
          workspace_version_id: ctx.version.id,
          section_id: ctx.page.id,
          source_note_id: note.id,
          title: "Pay day",
          content: note.content,
          order_position: 0,
          change_version: "1.1.0",
          version_increment_type: :minor,
          seo_tags: [],
          schema: []
        },
        tenant: ctx.site.id,
        actor: ctx.admin
      )
      |> Ash.create!()

    assert Enum.sort(draft.changed_fields) == [:change_version, :title]

    draft
    |> Ash.Changeset.for_update(
      :update,
      %{content_review_status: :approved, technical_review_status: :approved},
      tenant: ctx.site.id,
      actor: ctx.admin
    )
    |> Ash.update!()

    note = Ash.get!(Note, note.id, tenant: ctx.site.id, actor: ctx.admin)
    assert note.title == "Pay day"
    assert note.content == "<p>Pay day is the last Friday.</p>"
    assert note.order_position == 2
    assert length(note.seo_tags) == 1
    assert length(note.schema) == 1
  end
end
