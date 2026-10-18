# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_document/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaDocument.ContributorsTest do
  @moduledoc """
  A page's `contributors_count`: how many accounts created or updated the page, or a note of it,
  counted from the event log by the database, one statement for the whole batch of pages asked about.

  The count is gated upstream, by the page's field policy: a reader who may not see it is never
  asked for it, and the database is not asked either.
  """
  use MishkaDocument.DataCase, async: false

  alias MishkaDocument.{Note, Section}
  alias MishkaDocument.Resources.Calculations.SectionMaintainers

  setup do
    site = create_site!()
    workspace = create_workspace!(site_id: site.id, status: :active, skip_version: true)

    version =
      create_workspace_version!(workspace_id: workspace.id, site_id: site.id, status: :beta)

    %{
      site: site,
      version: version,
      first: create_user!(site_id: site.id, email: "first-writer@test.com"),
      second: create_user!(site_id: site.id, email: "second-writer@test.com"),
      master_writer: create_user!(email: "master-writer@test.com"),
      admin: create_user_with_permissions!(["admin:dashboard:*"], site_id: site.id),
      nobody: create_user_with_permissions!(["admin:dashboard:runtime:page"], site_id: site.id)
    }
  end

  defp write_section!(ctx, actor, title) do
    Section
    |> Ash.Changeset.for_create(
      :create,
      %{workspace_version_id: ctx.version.id, title: title, slug: String.downcase(title)},
      actor: actor,
      tenant: ctx.site.id,
      authorize?: false
    )
    |> Ash.create!()
  end

  defp write_note!(ctx, section, actor) do
    Note
    |> Ash.Changeset.for_create(
      :create,
      %{section_id: section.id, title: "Aside", content: "A note"},
      actor: actor,
      tenant: ctx.site.id,
      authorize?: false
    )
    |> Ash.create!()
  end

  defp rewrite!(ctx, section, actor) do
    section
    |> Ash.Changeset.for_update(:update, %{title: "Rewritten"},
      actor: actor,
      tenant: ctx.site.id,
      authorize?: false
    )
    |> Ash.update!()
  end

  defp counts(ctx, sections, opts) do
    sections
    |> Ash.load!([:contributors_count], [tenant: ctx.site.id] ++ opts)
    |> Map.new(&{&1.id, &1.contributors_count})
  end

  test "counts each account once however often it wrote, and the accounts that wrote notes",
       ctx do
    guide = write_section!(ctx, ctx.first, "Guide")
    rewrite!(ctx, guide, ctx.first)
    write_note!(ctx, guide, ctx.second)
    write_note!(ctx, guide, ctx.second)
    rewrite!(ctx, guide, ctx.master_writer)

    assert counts(ctx, [guide], actor: ctx.admin) == %{guide.id => 3}
  end

  test "counts every page of a batch for itself", ctx do
    guide = write_section!(ctx, ctx.first, "Guide")
    write_note!(ctx, guide, ctx.second)
    other = write_section!(ctx, ctx.master_writer, "Other")
    alone = write_section!(ctx, ctx.first, "Alone")
    unwritten = create_section!(site_id: ctx.site.id, workspace_version_id: ctx.version.id)

    assert counts(ctx, [guide, other, alone, unwritten], actor: ctx.admin) == %{
             guide.id => 2,
             other.id => 1,
             alone.id => 1,
             unwritten.id => 0
           }
  end

  test "does not count what was written to another page", ctx do
    guide = write_section!(ctx, ctx.first, "Guide")
    other = write_section!(ctx, ctx.second, "Other")
    write_note!(ctx, other, ctx.master_writer)

    assert counts(ctx, [guide], actor: ctx.admin) == %{guide.id => 1}
  end

  describe "who is let reach the count" do
    defp public_count(ctx, section, actor) do
      with_queries(fn ->
        Ash.get!(Section, section.id,
          action: :public_get,
          actor: actor,
          tenant: ctx.site.id,
          load: [:contributors_count]
        )
      end)
    end

    defp log_reads(queries),
      do: Enum.count(queries, &String.contains?(&1, "mishka_document_event_logs"))

    test "a reader of the section area has it counted by one query on the log", ctx do
      guide =
        create_section!(
          site_id: ctx.site.id,
          workspace_version_id: ctx.version.id,
          content_review_status: :approved,
          technical_review_status: :approved
        )

      {fetched, queries} = public_count(ctx, guide, ctx.admin)

      assert fetched.contributors_count == 0
      assert log_reads(queries) == 1
    end

    test "a reader without the section area cannot read the page itself", ctx do
      guide = write_section!(ctx, ctx.first, "Guide")

      assert {:error, _refused} =
               Ash.get(Section, guide.id, actor: ctx.nobody, tenant: ctx.site.id)
    end

    test "a visitor, or a reader without the section area, gets it forbidden and the log is not read",
         ctx do
      guide =
        create_section!(
          site_id: ctx.site.id,
          workspace_version_id: ctx.version.id,
          content_review_status: :approved,
          technical_review_status: :approved
        )

      for actor <- [nil, ctx.nobody] do
        {fetched, queries} = public_count(ctx, guide, actor)

        assert %Ash.ForbiddenField{} = fetched.contributors_count
        assert log_reads(queries) == 0
      end
    end
  end

  describe "a batch of pages" do
    setup ctx do
      site = create_site!()
      workspace = create_workspace!(site_id: site.id, status: :active, skip_version: true)

      version =
        create_workspace_version!(workspace_id: workspace.id, site_id: site.id, status: :beta)

      %{
        other: %{
          ctx
          | site: site,
            version: version,
            first: create_user!(site_id: site.id, email: "other-site-first@test.com"),
            second: create_user!(site_id: site.id, email: "other-site-second@test.com")
        }
      }
    end

    defp calculated(records), do: SectionMaintainers.calculate(records, [], %{})

    test "mixing two sites and a page with no site counts each page as asked alone", ctx do
      guide = write_section!(ctx, ctx.first, "Guide")
      write_note!(ctx, guide, ctx.second)
      notes = write_section!(ctx, ctx.first, "Notes")
      unwritten = create_section!(site_id: ctx.site.id, workspace_version_id: ctx.version.id)

      abroad = write_section!(ctx.other, ctx.other.first, "Abroad")
      write_note!(ctx.other, abroad, ctx.other.second)
      write_note!(ctx.other, abroad, ctx.other.second)
      memo = write_section!(ctx.other, ctx.other.first, "Memo")
      shared = write_section!(ctx.other, ctx.other.first, "Shared")
      write_note!(ctx.other, shared, ctx.other.second)

      assert calculated([guide, notes, abroad, memo, shared, unwritten]) == [2, 1, 2, 1, 2, 0]

      batch = [
        guide,
        abroad,
        unwritten,
        %{id: notes.id, site_id: ctx.other.site.id},
        %{id: memo.id, site_id: ctx.site.id},
        %{id: shared.id, site_id: nil},
        %{id: Ecto.UUID.generate(), site_id: nil}
      ]

      assert calculated(batch) == [2, 2, 0, 0, 0, 2, 0]
      assert calculated(batch) == Enum.flat_map(batch, &calculated([&1]))
    end

    test "a batch with no page asks the database nothing" do
      {counts, queries} = with_queries(fn -> calculated([]) end)

      assert counts == []
      assert log_reads(queries) == 0
    end

    test "fifty pages are counted by one statement on the log", ctx do
      written = for n <- 1..3, do: write_section!(ctx, ctx.first, "Written #{n}")
      write_note!(ctx, hd(written), ctx.second)

      unwritten =
        for _n <- 1..47,
            do: create_section!(site_id: ctx.site.id, workspace_version_id: ctx.version.id)

      batch = written ++ unwritten

      {loaded, queries} =
        with_queries(fn ->
          Ash.load!(batch, [:contributors_count], actor: ctx.admin, tenant: ctx.site.id)
        end)

      assert length(loaded) == 50
      assert log_reads(queries) == 1

      assert loaded |> Enum.map(& &1.contributors_count) |> Enum.frequencies() ==
               %{0 => 47, 1 => 2, 2 => 1}

      assert Enum.map(loaded, & &1.id) == Enum.map(batch, & &1.id)
    end
  end
end
