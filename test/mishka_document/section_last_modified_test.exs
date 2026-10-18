# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_document/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaDocument.SectionLastModifiedTest do
  @moduledoc """
  A section's `last_modified_at`: the newest of its own `updated_at`, the `updated_at` of the
  approved notes its page shows and the time a note of it was archived. The notes are read in the
  section's own query, so a batch of sections is one read whatever notes they hold.

  Times are pinned with `Ash.Seed`, so each test names the moment it expects.
  """
  use MishkaDocument.DataCase, async: false

  alias MishkaDocument.Section

  @january ~U[2026-01-01 00:00:00.000000Z]
  @february ~U[2026-02-01 00:00:00.000000Z]
  @march ~U[2026-03-01 00:00:00.000000Z]
  @april ~U[2026-04-01 00:00:00.000000Z]

  setup do
    site = create_site!()
    workspace = create_workspace!(site_id: site.id, status: :active, skip_version: true)

    version =
      create_workspace_version!(workspace_id: workspace.id, site_id: site.id, status: :beta)

    {:ok, site: site, version: version}
  end

  defp page!(ctx, slug, at \\ @february) do
    section =
      create_section!(
        site_id: ctx.site.id,
        workspace_version_id: ctx.version.id,
        slug: slug,
        content_review_status: :approved,
        technical_review_status: :approved
      )

    Ash.Seed.update!(section, %{updated_at: at})
  end

  defp last_modified(ctx, section) do
    Section
    |> Ash.get!(section.id, load: :last_modified_at, tenant: ctx.site.id, authorize?: false)
    |> Map.fetch!(:last_modified_at)
  end

  test "is the section's own time while it has no notes", ctx do
    assert last_modified(ctx, page!(ctx, "alone")) == @february
  end

  test "moves to a note edited after the section", ctx do
    section = page!(ctx, "guide")
    create_shown_note!(section, @january)
    create_shown_note!(section, @march)

    assert last_modified(ctx, section) == @march
  end

  test "keeps the section's own time while its notes are older", ctx do
    section = page!(ctx, "guide")
    create_shown_note!(section, @january)

    assert last_modified(ctx, section) == @february
  end

  test "moves to the section when it is newer than its notes", ctx do
    section = page!(ctx, "guide", @april)
    create_shown_note!(section, @march)

    assert last_modified(ctx, section) == @april
  end

  test "ignores a note the page does not show", ctx do
    section = page!(ctx, "guide")
    create_shown_note!(section, @march, content_review_status: :pending)
    create_shown_note!(section, @april, technical_review_status: :rejected)

    assert last_modified(ctx, section) == @february
  end

  test "ignores the notes of another section", ctx do
    section = page!(ctx, "guide")
    create_shown_note!(page!(ctx, "other"), @march)

    assert last_modified(ctx, section) == @february
  end

  test "moves to the time a note was archived", ctx do
    section = page!(ctx, "guide")
    section |> create_shown_note!(@january) |> archive_note_at!(@april)

    assert last_modified(ctx, section) == @april
  end

  test "is one read for a batch of sections, whatever notes they hold", ctx do
    [edited, archived, untouched] = sections = for slug <- ~w(a b c), do: page!(ctx, slug)

    read = fn ->
      Section
      |> Ash.Query.for_read(:read, %{}, tenant: ctx.site.id, authorize?: false)
      |> Ash.Query.load(:last_modified_at)
      |> Ash.read!(tenant: ctx.site.id, authorize?: false, page: false)
      |> Map.new(&{&1.id, &1.last_modified_at})
    end

    {bare, bare_reads} = with_queries(read)

    create_shown_note!(edited, @march)
    create_shown_note!(edited, @january)
    archived |> create_shown_note!(@january) |> archive_note_at!(@april)

    {noted, noted_reads} = with_queries(read)

    assert length(noted_reads) == length(bare_reads)
    assert Map.new(sections, &{&1.id, @february}) == bare

    assert noted == %{edited.id => @march, archived.id => @april, untouched.id => @february}
  end
end
