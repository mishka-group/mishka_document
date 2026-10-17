# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_document/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaDocument.ContributorsTest do
  @moduledoc """
  `MishkaDocument.Resources.Helpers.Contributors`: who wrote the pages and notes of a version, read
  from the event log as the actor asking, so the log's own policy decides what each can see.
  """
  use MishkaDocument.DataCase, async: false

  alias MishkaDocument.{Note, Section}
  alias MishkaDocument.Resources.Helpers.Contributors

  setup do
    site = create_site!()
    workspace = create_workspace!(site_id: site.id)
    version = create_workspace_version!(workspace_id: workspace.id, site_id: site.id)

    first = create_user!(site_id: site.id, email: "first-writer@test.com")
    second = create_user!(site_id: site.id, email: "second-writer@test.com")
    master_writer = create_user!(email: "master-writer@test.com")

    section =
      Section
      |> Ash.Changeset.for_create(
        :create,
        %{workspace_version_id: version.id, title: "Guide", slug: "guide"},
        actor: first,
        tenant: site.id,
        authorize?: false
      )
      |> Ash.create!()

    Note
    |> Ash.Changeset.for_create(
      :create,
      %{section_id: section.id, title: "Aside", content: "A note"},
      actor: second,
      tenant: site.id,
      authorize?: false
    )
    |> Ash.create!()

    other_section =
      Section
      |> Ash.Changeset.for_create(
        :create,
        %{workspace_version_id: version.id, title: "Other", slug: "other"},
        actor: master_writer,
        tenant: site.id,
        authorize?: false
      )
      |> Ash.create!()

    %{
      site: site,
      version: version,
      section: section,
      other_section: other_section,
      first: first,
      second: second,
      master_writer: master_writer,
      admin: create_user_with_permissions!(["admin:dashboard:*"], site_id: site.id),
      master: create_user_with_permissions!(["admin:dashboard:*"]),
      outsider: create_user_with_permissions!(["admin:dashboard:*"], site_id: create_site!().id),
      nobody: create_user_with_permissions!(["admin:dashboard:runtime:page"], site_id: site.id)
    }
  end

  describe "writers_in_version/2" do
    test "names everybody who created or updated a page or a note of the version", ctx do
      expected = Enum.sort([ctx.first.id, ctx.second.id, ctx.master_writer.id])

      assert ctx.version.id |> Contributors.writers_in_version(actor: ctx.master) |> Enum.sort() ==
               expected

      assert ctx.version.id |> Contributors.writers_in_version(actor: ctx.admin) |> Enum.sort() ==
               expected
    end

    test "names nobody to a viewer of another site, or one holding no document area", ctx do
      assert Contributors.writers_in_version(ctx.version.id, actor: ctx.outsider) == []
      assert Contributors.writers_in_version(ctx.version.id, actor: ctx.nobody) == []
      assert Contributors.writers_in_version(ctx.version.id, actor: nil) == []
    end

    test "names nobody for a version nothing was written in", ctx do
      assert Contributors.writers_in_version(Ecto.UUID.generate(), actor: ctx.master) == []
    end
  end

  describe "sections_written_by/2" do
    test "gives the pages the accounts wrote", ctx do
      assert Contributors.sections_written_by([ctx.first.id], actor: ctx.master) ==
               [ctx.section.id]

      assert Contributors.sections_written_by([ctx.master_writer.id], actor: ctx.master) ==
               [ctx.other_section.id]

      assert Contributors.sections_written_by([ctx.second.id], actor: ctx.master) == []
    end

    test "gives a site admin only what accounts of its own site wrote", ctx do
      assert Contributors.sections_written_by([ctx.first.id], actor: ctx.admin) ==
               [ctx.section.id]

      assert Contributors.sections_written_by([ctx.master_writer.id], actor: ctx.admin) == []
    end

    test "gives a viewer without the area, or another site's, nothing", ctx do
      assert Contributors.sections_written_by([ctx.first.id], actor: ctx.outsider) == []
      assert Contributors.sections_written_by([ctx.first.id], actor: ctx.nobody) == []
    end
  end

  describe "writer_counts/2" do
    test "counts the accounts that wrote each page or its notes", ctx do
      ids = [ctx.section.id, ctx.other_section.id]

      assert Contributors.writer_counts(ids, actor: ctx.master) ==
               %{ctx.section.id => 2, ctx.other_section.id => 1}
    end

    test "counts only what the viewer may read, and nothing for a page nobody wrote", ctx do
      assert Contributors.writer_counts([Ecto.UUID.generate()], actor: ctx.master) == %{}
      assert Contributors.writer_counts([ctx.section.id], actor: ctx.outsider) == %{}
      assert Contributors.writer_counts([ctx.section.id], actor: ctx.nobody) == %{}
      assert Contributors.writer_counts([], actor: ctx.master) == %{}
    end

    test "reads without checks when the caller does", ctx do
      assert Contributors.writer_counts([ctx.section.id], authorize?: false) ==
               %{ctx.section.id => 2}
    end
  end
end
