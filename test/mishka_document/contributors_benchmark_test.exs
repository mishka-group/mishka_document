# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_document/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaDocument.ContributorsBenchmarkTest do
  @moduledoc """
  How long the Sections page's contributor figure takes on a busy event log: `contributors_count`
  over 50 pages with `EVENTS` rows (5,000 by default) in `mishka_document_event_logs`. The first 5,000
  are the 50 pages' own events (about 100 each); any more are other records' events, which the
  figure has to read past. The 50 pages are one batch, counted by one statement.

  Left out of `mix test`; run it on its own:

      mix test --include benchmark test/mishka_document/contributors_benchmark_test.exs
      EVENTS=200000 mix test --include benchmark test/mishka_document/contributors_benchmark_test.exs

  It prints how many statements the load ran, how long it took, and the plan of the statement.
  """
  use MishkaDocument.DataCase, async: false

  @moduletag :benchmark
  @moduletag timeout: 600_000

  alias MishkaDocument.Section

  @pages 50
  @page_events 5_000
  @writers 20

  setup do
    site = create_site!()
    workspace = create_workspace!(site_id: site.id, status: :active, skip_version: true)

    version =
      create_workspace_version!(workspace_id: workspace.id, site_id: site.id, status: :beta)

    writers =
      for n <- 1..@writers, do: create_user!(site_id: site.id, email: "writer-#{n}@test.com")

    admin = create_user_with_permissions!(["admin:dashboard:*"], site_id: site.id)

    sections =
      for n <- 1..@pages do
        create_section!(
          site_id: site.id,
          workspace_version_id: version.id,
          title: "Page #{n}",
          slug: "page-#{n}"
        )
      end

    %{site: site, version: version, writers: writers, admin: admin, sections: sections}
  end

  defp events, do: "EVENTS" |> System.get_env("5000") |> String.to_integer()

  defp seed_events!(ctx, total) do
    writer_ids = Enum.map(ctx.writers, &Ecto.UUID.dump!(&1.id))
    section_ids = Enum.map(ctx.sections, &Ecto.UUID.dump!(&1.id))
    section_texts = Enum.map(ctx.sections, & &1.id)

    Ecto.Adapters.SQL.query!(
      MishkaDocument.Repo,
      """
      INSERT INTO mishka_document_event_logs
        (id, record_id, metadata, data, changed_attributes, occurred_at, resource, action, action_type, actor_id)
      SELECT
        uuid_generate_v7(),
        CASE WHEN n % 3 = 0 OR n > $9 THEN gen_random_uuid() ELSE ($1::uuid[])[1 + n % $5] END,
        CASE
          WHEN n > $9 THEN
            jsonb_build_object('site_id', gen_random_uuid()::text,
                               'workspace_version_id', gen_random_uuid()::text,
                               'section_id', gen_random_uuid()::text)
          WHEN n % 3 = 0 THEN
            jsonb_build_object('site_id', $2::text, 'workspace_version_id', $3::text,
                               'section_id', ($4::text[])[1 + n % $5])
          ELSE
            jsonb_build_object('site_id', $2::text, 'workspace_version_id', $3::text)
        END,
        '{}'::jsonb,
        '{}'::jsonb,
        now() - (n || ' seconds')::interval,
        CASE WHEN n % 3 = 0 THEN 'Elixir.MishkaDocument.Note' ELSE 'Elixir.MishkaDocument.Section' END,
        CASE WHEN n % 7 = 0 THEN 'destroy' WHEN n % 2 = 0 THEN 'update' ELSE 'create' END,
        CASE WHEN n % 7 = 0 THEN 'destroy' WHEN n % 2 = 0 THEN 'update' ELSE 'create' END,
        ($6::uuid[])[1 + n % $7]
      FROM generate_series(1, $8) AS n
      """,
      [
        section_ids,
        ctx.site.id,
        ctx.version.id,
        section_texts,
        @pages,
        writer_ids,
        @writers,
        total,
        @page_events
      ],
      timeout: :infinity
    )
  end

  test "contributors_count over 50 pages", ctx do
    total = events()
    seed_events!(ctx, total)
    Ecto.Adapters.SQL.query!(MishkaDocument.Repo, "ANALYZE mishka_document_event_logs")

    {loaded, statements} =
      with_queries(fn ->
        Ash.load!(ctx.sections, [:contributors_count], actor: ctx.admin, tenant: ctx.site.id)
      end)

    log_reads = Enum.count(statements, &String.contains?(&1, "mishka_document_event_logs"))

    micros =
      for _round <- 1..5 do
        {micros, _} =
          :timer.tc(fn ->
            Ash.load!(ctx.sections, [:contributors_count], actor: ctx.admin, tenant: ctx.site.id)
          end)

        micros
      end

    statement = Enum.find(statements, &String.contains?(&1, "mishka_document_event_logs"))
    section_ids = Enum.map(ctx.sections, & &1.id)
    site_ids = Enum.map(ctx.sections, fn _ -> ctx.site.id end)

    %{rows: plan} =
      Ecto.Adapters.SQL.query!(
        MishkaDocument.Repo,
        "EXPLAIN (ANALYZE, COSTS OFF, TIMING OFF, SUMMARY ON) " <> statement,
        [section_ids, site_ids]
      )

    IO.puts("""

    contributors_count over #{@pages} pages, #{total} events in the log
      statements on the event log per load: #{log_reads}
      load times (ms, 5 rounds): #{Enum.map_join(micros, ", ", &Float.round(&1 / 1000, 1))}
      median: #{micros |> Enum.sort() |> Enum.at(2) |> Kernel./(1000) |> Float.round(1)} ms
      plan of the statement:
    #{Enum.map_join(plan, "\n", fn [line] -> "        " <> line end)}
    """)

    assert log_reads == 1
    assert Enum.all?(loaded, &is_integer(&1.contributors_count))
    assert Enum.any?(loaded, &(&1.contributors_count > 0))
    assert %Section{} = hd(loaded)
  end
end
