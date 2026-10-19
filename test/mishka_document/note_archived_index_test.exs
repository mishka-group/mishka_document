# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_document/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaDocument.NoteArchivedIndexTest do
  @moduledoc """
  The index `Section.latest_note_archived_at` reads archived notes through. The notes table has
  the base filter `archived_at IS NULL`, so every other index of it is partial on that and cannot
  answer a read of archived rows: without this one the aggregate scans the whole table once per
  section.
  """
  use MishkaDocument.DataCase, async: false

  alias MishkaDocument.Section

  @index "mishka_document_notes_site_id_section_id_archived_at_index"
  @january ~U[2026-01-01 00:00:00.000000Z]
  @archived_at ~U[2026-04-01 00:00:00.000000Z]

  test "the notes table has an index on its archived notes alone" do
    %{rows: [[definition]]} =
      Repo.query!(
        "SELECT indexdef FROM pg_indexes WHERE tablename = 'mishka_document_notes' AND indexname = $1",
        [@index]
      )

    assert definition =~ "(site_id, section_id, archived_at)"
    assert definition =~ "WHERE (archived_at IS NOT NULL)"
  end

  test "the aggregate's read of a section can use it" do
    site = create_site!()
    workspace = create_workspace!(site_id: site.id, status: :active, skip_version: true)

    version =
      create_workspace_version!(workspace_id: workspace.id, site_id: site.id, status: :beta)

    section =
      create_section!(
        site_id: site.id,
        workspace_version_id: version.id,
        content_review_status: :approved,
        technical_review_status: :approved
      )
      |> Ash.Seed.update!(%{updated_at: @january})

    section |> create_shown_note!(@january) |> archive_note_at!(@archived_at)

    {section_read, reads} =
      with_statements(fn ->
        Ash.get!(Section, section.id, load: :last_modified_at, tenant: site.id, authorize?: false)
      end)

    assert section_read.last_modified_at == @archived_at

    {sql, params} = Enum.find(reads, fn {sql, _} -> sql =~ "latest_note_archived_at" end)

    Repo.query!("SET LOCAL enable_seqscan = off")
    %{rows: plan} = Repo.query!("EXPLAIN " <> sql, params)

    assert plan |> List.flatten() |> Enum.join("\n") =~ @index
  end

  defp with_statements(fun) do
    owner = self()
    handler = {__MODULE__, make_ref()}
    event = Repo.config() |> Keyword.fetch!(:telemetry_prefix) |> Kernel.++([:query])

    :telemetry.attach(
      handler,
      event,
      fn _event, _measurements, %{query: query, params: params}, owner ->
        send(owner, {:statement, query, params})
      end,
      owner
    )

    try do
      {fun.(), drain_statements([])}
    after
      :telemetry.detach(handler)
    end
  end

  defp drain_statements(acc) do
    receive do
      {:statement, query, params} -> drain_statements([{query, params} | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end
end
