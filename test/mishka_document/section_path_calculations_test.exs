# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_document/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaDocument.SectionPathCalculationsTest do
  @moduledoc """
  A section's `breadcrumb_path` and `section_versions_count`, which read the sections around it as
  whoever asked: the path walks the parents level by level, the count gathers the sections of one
  lineage, and a reader who may not read sections is shown neither.
  """
  use MishkaDocument.DataCase, async: false

  import MishkaDocument.Test.Factory

  alias MishkaDocument.Resources.Calculations.{BreadcrumbPath, SectionVersionsCount}
  alias MishkaDocument.Section

  setup do
    site = create_site!()
    workspace = create_workspace!(site_id: site.id, skip_version: true)
    version = create_workspace_version!(workspace_id: workspace.id, site_id: site.id)

    {:ok,
     site: site,
     version: version,
     admin: create_user_with_permissions!(["admin:dashboard:*"], site_id: site.id),
     nobody: create_user_with_permissions!(["admin:dashboard:runtime:page"], site_id: site.id)}
  end

  defp page!(ctx, title, parent \\ nil) do
    create_section!(
      site_id: ctx.site.id,
      workspace_version_id: ctx.version.id,
      title: title,
      slug: String.downcase(String.replace(title, " ", "-")),
      parent_section_id: parent && parent.id
    )
  end

  defp context(ctx, actor, authorize? \\ true),
    do: %Ash.Resource.Calculation.Context{
      actor: actor,
      tenant: ctx.site.id,
      authorize?: authorize?
    }

  defp titles(path), do: Enum.map(path, & &1["title"])

  defp point!(section, field, id) do
    Ecto.Adapters.SQL.query!(
      MishkaDocument.Repo,
      "UPDATE mishka_document_sections SET #{field} = $1 WHERE id = $2",
      [Ecto.UUID.dump!(id), Ecto.UUID.dump!(section.id)]
    )

    Ash.get!(Section, section.id, tenant: section.site_id, authorize?: false)
  end

  defp archive!(section),
    do: Ash.destroy!(section, action: :destroy, tenant: section.site_id, authorize?: false)

  describe "breadcrumb_path" do
    test "runs from the root heading down to the immediate parent", ctx do
      root = page!(ctx, "Guides")
      middle = page!(ctx, "Install", root)
      leaf = page!(ctx, "Linux", middle)
      lone = page!(ctx, "Alone")

      [leaf, middle, lone] =
        Ash.load!([leaf, middle, lone], [:breadcrumb_path], actor: ctx.admin, tenant: ctx.site.id)

      assert titles(leaf.breadcrumb_path) == ["Guides", "Install"]
      assert titles(middle.breadcrumb_path) == ["Guides"]
      assert lone.breadcrumb_path == []

      assert [%{"id" => id, "slug" => "guides"}] = middle.breadcrumb_path
      assert id == root.id
    end

    test "ends where an archived ancestor stands, and is empty under an archived parent", ctx do
      root = page!(ctx, "Guides")
      middle = page!(ctx, "Install", root)
      leaf = page!(ctx, "Linux", middle)

      archive!(root)
      leaf = Ash.load!(leaf, [:breadcrumb_path], actor: ctx.admin, tenant: ctx.site.id)
      assert titles(leaf.breadcrumb_path) == ["Install"]

      archive!(middle)
      leaf = Ash.load!(leaf, [:breadcrumb_path], actor: ctx.admin, tenant: ctx.site.id)
      assert leaf.breadcrumb_path == []
    end

    test "ends where the parents loop back on themselves", ctx do
      first = page!(ctx, "First")
      second = page!(ctx, "Second", first)
      first = point!(first, :parent_section_id, second.id)

      [first, second] =
        Ash.load!([first, second], [:breadcrumb_path], actor: ctx.admin, tenant: ctx.site.id)

      assert titles(first.breadcrumb_path) == ["First", "Second"]
      assert titles(second.breadcrumb_path) == ["Second", "First"]
    end

    test "is read as the reader: one who may not read sections is shown no ancestor", ctx do
      root = page!(ctx, "Guides")
      leaf = page!(ctx, "Install", root)

      assert [[%{"title" => "Guides"}]] =
               BreadcrumbPath.calculate([leaf], [], context(ctx, ctx.admin))

      assert [[]] = BreadcrumbPath.calculate([leaf], [], context(ctx, ctx.nobody))

      assert [[%{"title" => "Guides"}]] =
               BreadcrumbPath.calculate([leaf], [], context(ctx, nil, false))
    end
  end

  describe "section_versions_count" do
    test "counts the sections of one lineage in the site, the section included", ctx do
      first = page!(ctx, "Guides")

      other_version =
        create_workspace_version!(workspace_id: ctx.version.workspace_id, site_id: ctx.site.id)

      clone =
        create_section!(
          site_id: ctx.site.id,
          workspace_version_id: other_version.id,
          source_section_id: first.id,
          title: "Guides",
          slug: "guides"
        )

      unrelated = page!(ctx, "Unrelated")

      [first, clone, unrelated] =
        Ash.load!([first, clone, unrelated], [:section_versions_count],
          actor: ctx.admin,
          tenant: ctx.site.id
        )

      assert first.section_versions_count == 2
      assert clone.section_versions_count == 2
      assert unrelated.section_versions_count == 1

      archive!(clone)
      first = Ash.load!(first, [:section_versions_count], actor: ctx.admin, tenant: ctx.site.id)
      assert first.section_versions_count == 1
    end

    test "is read as the reader: one who may not read sections counts the section alone", ctx do
      first = page!(ctx, "Guides")

      other_version =
        create_workspace_version!(workspace_id: ctx.version.workspace_id, site_id: ctx.site.id)

      create_section!(
        site_id: ctx.site.id,
        workspace_version_id: other_version.id,
        source_section_id: first.id
      )

      assert [2] = SectionVersionsCount.calculate([first], [], context(ctx, ctx.admin))
      assert [1] = SectionVersionsCount.calculate([first], [], context(ctx, ctx.nobody))
      assert [2] = SectionVersionsCount.calculate([first], [], context(ctx, nil, false))
    end
  end
end
