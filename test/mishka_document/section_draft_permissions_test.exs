# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_document/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaDocument.SectionDraftPermissionsTest do
  @moduledoc """
  A draft carries the permissions its page opens with, as it carries its SEO Tags and structured
  data: a draft of an existing page starts with that page's
  (`MishkaDocument.Resources.Changes.StartFromSource`), and applying the draft — both reviews
  approved — writes what the draft holds onto the page
  (`MishkaDocument.Resources.Changes.AutoApplySectionDraft`).
  """
  use MishkaDocument.DataCase, async: false

  require Ash.Query

  alias MishkaDocument.{Section, SectionDraft}

  @robots [%{"tag" => "meta", "attrs" => %{"name" => "robots"}, "content" => "noindex, follow"}]

  setup do
    site = create_site!(active: true)
    document = create_workspace!(site_id: site.id, skip_version: true, status: :active)

    version =
      create_workspace_version!(
        site_id: site.id,
        workspace_id: document.id,
        status: :stable,
        published_at: ~U[2026-03-01 00:00:00Z]
      )

    section =
      create_section!(
        site_id: site.id,
        workspace_version_id: version.id,
        title: "Salaries",
        slug: "salaries",
        content_review_status: :approved,
        technical_review_status: :approved,
        permissions: ["members:read"],
        seo_tags: @robots
      )

    %{site: site, version: version, section: section}
  end

  defp draft!(ctx, overrides) do
    create_section_draft!(
      [site_id: ctx.site.id, workspace_version_id: ctx.version.id, title: "Salaries"] ++ overrides
    )
  end

  defp update!(draft, site, attrs) do
    draft
    |> Ash.Changeset.for_update(:update, attrs, tenant: site.id, authorize?: false)
    |> Ash.update!()
  end

  defp apply!(draft, site),
    do:
      update!(draft, site, %{content_review_status: :approved, technical_review_status: :approved})

  defp section(site, id), do: Ash.get!(Section, id, tenant: site.id, authorize?: false)

  test "a draft of a page starts with its permissions and SEO Tags, and applying it keeps them",
       ctx do
    draft = draft!(ctx, source_section_id: ctx.section.id, slug: "salaries")

    assert draft.permissions == ["members:read"]
    assert [%{"tag" => "meta"} | _] = Enum.map(draft.seo_tags, &stringify/1)

    apply!(draft, ctx.site)

    page = section(ctx.site, ctx.section.id)
    assert page.permissions == ["members:read"]
    assert length(page.seo_tags) == 1
  end

  test "a draft that names other permissions gives them to the page once applied", ctx do
    draft =
      draft!(ctx,
        source_section_id: ctx.section.id,
        slug: "salaries",
        permissions: ["staff:read"]
      )

    assert draft.permissions == ["staff:read"]

    apply!(draft, ctx.site)

    assert section(ctx.site, ctx.section.id).permissions == ["staff:read"]
  end

  test "a draft edited to name none opens the page once applied", ctx do
    draft =
      ctx
      |> draft!(source_section_id: ctx.section.id, slug: "salaries")
      |> update!(ctx.site, %{permissions: []})

    apply!(draft, ctx.site)

    assert section(ctx.site, ctx.section.id).permissions == []
  end

  test "a draft of a new page gives it the permissions it names", ctx do
    draft = draft!(ctx, slug: "bonuses", title: "Bonuses", permissions: ["members:read"])

    apply!(draft, ctx.site)

    [page] =
      Section
      |> Ash.Query.filter(slug == "bonuses")
      |> Ash.read!(tenant: ctx.site.id, authorize?: false)

    assert page.permissions == ["members:read"]

    assert %SectionDraft{applied_at: %DateTime{}} =
             Ash.get!(SectionDraft, draft.id, tenant: ctx.site.id, authorize?: false)
  end

  defp stringify(%{} = tag), do: Map.new(tag, fn {key, value} -> {to_string(key), value} end)
end
