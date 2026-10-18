# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_document/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaDocument.SectionPathCalculationsTest do
  @moduledoc """
  A section's `breadcrumb_path` and `section_versions_count`, which the database works out: the path
  is the parents above the section in one recursive query, the count is the sections of one lineage
  in the section's own site.

  Both sit behind the page's field policy, so a reader who may not see them is never asked for
  them, and the database is not asked either.
  """
  use MishkaDocument.DataCase, async: false

  import MishkaDocument.Test.Factory

  alias MishkaDocument.Section

  require Ash.Query

  setup do
    site = create_site!()
    workspace = create_workspace!(site_id: site.id, status: :active, skip_version: true)

    version =
      create_workspace_version!(workspace_id: workspace.id, site_id: site.id, status: :beta)

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
      parent_section_id: parent && parent.id,
      content_review_status: :approved,
      technical_review_status: :approved
    )
  end

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

    test "is worked out for every section of a batch in one query", ctx do
      root = page!(ctx, "Guides")
      leaves = for n <- 1..5, do: page!(ctx, "Leaf #{n}", root)

      {loaded, queries} =
        with_queries(fn ->
          Ash.load!(leaves, [:breadcrumb_path], actor: ctx.admin, tenant: ctx.site.id)
        end)

      assert Enum.all?(loaded, &(titles(&1.breadcrumb_path) == ["Guides"]))
      assert Enum.count(queries, &String.contains?(&1, "WITH RECURSIVE")) == 1
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

    test "stops at 20 levels when the parents loop back on themselves", ctx do
      first = page!(ctx, "First")
      second = page!(ctx, "Second", first)
      first = point!(first, :parent_section_id, second.id)

      [first, second] =
        Ash.load!([first, second], [:breadcrumb_path], actor: ctx.admin, tenant: ctx.site.id)

      assert length(first.breadcrumb_path) == 20
      assert length(second.breadcrumb_path) == 20

      assert first.breadcrumb_path |> titles() |> Enum.uniq() |> Enum.sort() == [
               "First",
               "Second"
             ]
    end
  end

  describe "section_versions_count" do
    test "counts the sections of one lineage in the site, the section included", ctx do
      first = page!(ctx, "Guides")

      other_version =
        create_workspace_version!(
          workspace_id: ctx.version.workspace_id,
          site_id: ctx.site.id,
          status: :alpha
        )

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

    test "is worked out for every section of a batch in one query", ctx do
      pages = for n <- 1..5, do: page!(ctx, "Page #{n}")

      {loaded, queries} =
        with_queries(fn ->
          Ash.load!(pages, [:section_versions_count], actor: ctx.admin, tenant: ctx.site.id)
        end)

      assert Enum.all?(loaded, &(&1.section_versions_count == 1))
      assert Enum.count(queries, &String.contains?(&1, "GROUP BY section_lineage_id")) == 1
    end
  end

  describe "on a read that selects only some of the section's fields" do
    test "all three are still worked out", ctx do
      root = page!(ctx, "Guides")
      leaf = page!(ctx, "Install", root)

      {:ok, [selected]} =
        Section
        |> Ash.Query.filter(id == ^leaf.id)
        |> Ash.Query.select([:id, :title])
        |> Ash.Query.load([:breadcrumb_path, :section_versions_count, :contributors_count])
        |> Ash.read(actor: ctx.admin, tenant: ctx.site.id)

      assert titles(selected.breadcrumb_path) == ["Guides"]
      assert selected.section_versions_count == 1
      assert selected.contributors_count == 0
    end
  end

  describe "a reader who may not see them" do
    test "cannot read the section they belong to", ctx do
      root = page!(ctx, "Guides")
      leaf = page!(ctx, "Install", root)

      assert {:error, _refused} =
               Ash.get(Section, leaf.id, actor: ctx.nobody, tenant: ctx.site.id)
    end

    test "gets them forbidden on a public section, and the database is not asked", ctx do
      root = page!(ctx, "Guides")
      leaf = page!(ctx, "Install", root)

      for actor <- [nil, ctx.nobody] do
        {fetched, queries} =
          with_queries(fn ->
            Ash.get!(Section, leaf.id,
              action: :public_get,
              actor: actor,
              tenant: ctx.site.id,
              load: [:breadcrumb_path, :section_versions_count]
            )
          end)

        assert %Ash.ForbiddenField{} = fetched.breadcrumb_path
        assert %Ash.ForbiddenField{} = fetched.section_versions_count
        refute Enum.any?(queries, &String.contains?(&1, "WITH RECURSIVE"))
        refute Enum.any?(queries, &String.contains?(&1, "GROUP BY section_lineage_id"))
      end
    end

    test "is shown them on that section when it holds the section area", ctx do
      root = page!(ctx, "Guides")
      leaf = page!(ctx, "Install", root)

      fetched =
        Ash.get!(Section, leaf.id,
          action: :public_get,
          actor: ctx.admin,
          tenant: ctx.site.id,
          load: [:breadcrumb_path, :section_versions_count]
        )

      assert titles(fetched.breadcrumb_path) == ["Guides"]
      assert fetched.section_versions_count == 1
    end
  end
end
