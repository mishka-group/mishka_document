# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_document/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaDocument.Agent.OperationsTest do
  @moduledoc """
  Receipts for the document extension's writes (`MishkaDocument.Plugins.AgentOperations`): a
  version's publish, and a draft's approval, which writes its page or note in the same action. The
  page or note is read back from the table; a draft not approved yet says so and claims nothing.
  """
  use MishkaDocument.DataCase, async: false

  alias MishkaCmsCore.Agent.{Operation, Receipts}
  alias MishkaDocument.{NoteDraft, SectionDraft, WorkspaceVersion}

  setup do
    Receipts.switch(true)
    on_exit(fn -> Receipts.switch(false) end)

    site = create_site!(active: true)

    admin =
      create_user_with_permissions!(
        [
          "admin:dashboard:document:section",
          "admin:dashboard:document:workspace",
          "admin:dashboard:agent:receipts"
        ],
        site_id: site.id
      )

    document = create_workspace!(site_id: site.id, skip_version: true, status: :active)

    version =
      create_workspace_version!(
        site_id: site.id,
        workspace_id: document.id,
        status: :stable,
        published_at: ~U[2026-03-01 00:00:00Z]
      )

    page =
      create_section!(
        site_id: site.id,
        workspace_version_id: version.id,
        title: "Salaries",
        slug: "salaries",
        content_review_status: :approved,
        technical_review_status: :approved
      )

    {:ok, site: site, admin: admin, document: document, version: version, page: page}
  end

  defp stage(receipt, name), do: Enum.find(receipt.stages, &(&1.name == name))

  defp draft!(ctx, attrs) do
    SectionDraft
    |> Ash.Changeset.for_create(
      :create,
      Map.merge(
        %{
          workspace_version_id: ctx.version.id,
          source_section_id: ctx.page.id,
          title: "Salaries and bonuses",
          slug: "salaries",
          language: "en",
          change_version: "1.1.0",
          version_increment_type: :minor,
          order_position: 0,
          permissions: [],
          seo_tags: [],
          schema: []
        },
        attrs
      ),
      tenant: ctx.site.id,
      actor: ctx.admin
    )
    |> Ash.create!()
  end

  defp review(draft, ctx, attrs) do
    draft
    |> Ash.Changeset.for_update(:update, attrs, tenant: ctx.site.id, actor: ctx.admin)
    |> then(&Receipts.run("document:section_draft:update", &1, source: :agent))
  end

  @approved %{content_review_status: :approved, technical_review_status: :approved}

  test "the publish, the drafts and the rows are declared" do
    for name <-
          ~w(document:workspace_version:publish document:section_draft:update document:note_draft:update
                   document:section:create document:note:update document:workspace:permanent_destroy),
        do: assert(%Operation{} = Operation.lookup(name))
  end

  test "a version's publish is read back as stable with a publication time", ctx do
    draft_version =
      create_workspace_version!(
        site_id: ctx.site.id,
        workspace_id: ctx.document.id,
        status: :draft
      )

    assert {:ok, %WorkspaceVersion{status: :stable}, receipt} =
             draft_version
             |> Ash.Changeset.for_update(:publish, %{}, tenant: ctx.site.id, actor: ctx.admin)
             |> then(&Receipts.run("document:workspace_version:publish", &1))

    assert receipt.status == :verified
    assert %{observed: %{source: :notifier}} = stage(receipt, :action_committed)

    assert %{status: :verified, observed: %{status: :stable, published_at: :present}} =
             stage(receipt, :db_read_back)

    assert %{status: :verified, observed: %{correlated: :receipt}} =
             stage(receipt, :broadcast_published)

    assert %{status: :skipped, reason: :off} = stage(receipt, :sitemap_job)
    assert {:ok, _} = Receipts.get(receipt.id, ctx.admin)
  end

  test "a page draft approved twice is verified by the page it wrote", ctx do
    draft = draft!(ctx, %{})

    assert {:ok, applied, receipt} = review(draft, ctx, @approved)
    assert %DateTime{} = applied.applied_at

    assert receipt.status == :verified

    assert %{status: :verified, observed: %{applied_at: :matches}} =
             stage(receipt, :db_read_back)

    assert %{status: :verified, layer: :db, observed: %{present: true}} =
             stage(receipt, :page_written)

    refute inspect(receipt) =~ "bonuses"
  end

  test "a draft adding a page is verified by the new page's row", ctx do
    draft = draft!(ctx, %{source_section_id: nil, slug: "bonuses", title: "Bonuses"})

    assert {:ok, _applied, receipt} = review(draft, ctx, @approved)
    assert %{status: :verified} = stage(receipt, :page_written)
  end

  test "a draft with one review is not applied, and the receipt claims no page", ctx do
    draft = draft!(ctx, %{})

    assert {:ok, %{applied_at: nil}, receipt} =
             review(draft, ctx, %{content_review_status: :approved})

    assert receipt.status == :verified
    assert %{status: :skipped, reason: :not_approved} = stage(receipt, :page_written)
  end

  test "a page the approval did not write fails the stage, whatever the draft says", ctx do
    draft = draft!(ctx, %{})

    changeset =
      draft
      |> Ash.Changeset.for_update(:update, @approved, tenant: ctx.site.id, actor: ctx.admin)
      |> Ash.Changeset.after_action(fn _changeset, record ->
        {:ok, id} = Ecto.UUID.dump(ctx.page.id)

        MishkaDocument.Repo.query!(
          "UPDATE mishka_document_sections SET title = 'Salaries' WHERE id = $1",
          [id]
        )

        {:ok, record}
      end)

    assert {:ok, _draft, receipt} = Receipts.run("document:section_draft:update", changeset)

    assert %{status: :failed, reason: :mismatch, observed: %{title: :present}} =
             stage(receipt, :page_written)

    assert receipt.status == :failed
  end

  test "a note draft approved twice is verified by the note it wrote", ctx do
    note = create_note!(site_id: ctx.site.id, section_id: ctx.page.id, title: "Tip")

    draft =
      NoteDraft
      |> Ash.Changeset.for_create(
        :create,
        %{
          workspace_version_id: ctx.version.id,
          section_id: ctx.page.id,
          source_note_id: note.id,
          title: "Pay day",
          content: "<p>Body</p>",
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

    assert {:ok, _applied, receipt} =
             draft
             |> Ash.Changeset.for_update(:update, @approved,
               tenant: ctx.site.id,
               actor: ctx.admin
             )
             |> then(&Receipts.run("document:note_draft:update", &1))

    assert receipt.status == :verified
    assert %{status: :verified, layer: :db} = stage(receipt, :note_written)
  end
end
