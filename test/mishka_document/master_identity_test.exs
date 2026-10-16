# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_document/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaDocument.MasterIdentityTest do
  @moduledoc """
  A master is a user whose `site_id` is nil, and nothing else makes one: not the `"*"` permission,
  not a missing actor, not a missing tenant. These pin that rule across the document resources — a
  site user holding every permission still acts on its own site only, and a call with no actor is
  never served as a master. System calls made with `authorize?: false` stay exempt.
  """
  use MishkaDocument.DataCase, async: false

  require Ash.Query

  alias MishkaDocument.{
    Issue,
    IssueComment,
    Note,
    NoteDraft,
    Section,
    SectionDraft,
    Tag,
    Workspace,
    WorkspaceVersion
  }

  defp star(site), do: create_user_with_permissions!(["*"], site_id: site.id)
  defp master, do: create_user_with_permissions!(["*"])

  defp ids(rows), do: rows |> Enum.map(& &1.id) |> MapSet.new()

  # A section copied from `source`: another version of the source's workspace.
  defp copy_of!(source, overrides \\ []) do
    %{workspace_id: workspace_id} =
      Ash.get!(WorkspaceVersion, source.workspace_version_id,
        action: :read_any,
        authorize?: false
      )

    version = create_workspace_version!(workspace_id: workspace_id, site_id: source.site_id)

    create_section!(
      [site_id: source.site_id, workspace_version_id: version.id, source_section_id: source.id] ++
        overrides
    )
  end

  # A section pointer written before sections were held to their own site, past every check.
  defp point!(section, field, id) do
    Ecto.Adapters.SQL.query!(
      MishkaDocument.Repo,
      "UPDATE mishka_document_sections SET #{field} = $1 WHERE id = $2",
      [Ecto.UUID.dump!(id), Ecto.UUID.dump!(section.id)]
    )

    Ash.get!(MishkaDocument.Section, section.id, tenant: section.site_id, authorize?: false)
  end

  defp read_any(resource, opts) do
    page =
      if Ash.Resource.Info.action(resource, :read_any).pagination, do: [limit: 100], else: nil

    resource
    |> Ash.Query.for_read(:read_any, %{}, opts)
    |> Ash.read(page: page)
    |> case do
      {:ok, %{results: results}} -> {:ok, results}
      other -> other
    end
  end

  describe "the read_any bypass reads" do
    setup do
      site_a = create_site!()
      site_b = create_site!()
      section_b = create_section!(site_id: site_b.id)

      %{
        site_a: site_a,
        rows: %{
          Note => create_note!(site_id: site_b.id, section_id: section_b.id),
          Section => section_b,
          SectionDraft => create_section_draft!(site_id: site_b.id),
          Tag => create_document_tag!(site_id: site_b.id),
          Workspace => create_workspace!(site_id: site_b.id),
          WorkspaceVersion => create_workspace_version!(site_id: site_b.id)
        }
      }
    end

    test "serve a site user holding every permission no row at all", %{
      site_a: site_a,
      rows: rows
    } do
      actor = star(site_a)
      create_workspace!(site_id: site_a.id)

      for {resource, _row} <- rows do
        assert {:ok, []} = read_any(resource, actor: actor),
               "#{inspect(resource)} :read_any served a site user"
      end
    end

    test "refuse a call with no actor", %{rows: rows} do
      for {resource, _row} <- rows do
        assert {:error, %Ash.Error.Forbidden{}} = read_any(resource, actor: nil),
               "#{inspect(resource)} :read_any served a missing actor"
      end
    end

    test "serve a master every site's rows", %{rows: rows} do
      actor = master()

      for {resource, row} <- rows do
        assert {:ok, results} = read_any(resource, actor: actor)
        assert row.id in ids(results), "#{inspect(resource)} :read_any hid a row from a master"
      end
    end

    test "still serve a system read made with authorize?: false", %{rows: rows} do
      for {resource, row} <- rows do
        assert {:ok, results} = read_any(resource, authorize?: false)

        assert row.id in ids(results)
      end
    end
  end

  describe "archived workspaces" do
    test "have no generic action that picks the master read from a missing tenant" do
      refute Ash.Resource.Info.action(Workspace, :read_archived_api)
    end
  end

  describe "the master_* relationships" do
    setup do
      site_b = create_site!()
      workspace = create_workspace!(site_id: site_b.id, skip_version: true)

      translation =
        create_workspace!(
          site_id: site_b.id,
          skip_version: true,
          language: "fa",
          language_group_id: workspace.id
        )

      v1 = create_workspace_version!(workspace_id: workspace.id, site_id: site_b.id)

      v2 =
        create_workspace_version!(
          workspace_id: workspace.id,
          site_id: site_b.id,
          source_version_id: v1.id
        )

      section = create_section!(site_id: site_b.id, workspace_version_id: v2.id)
      copied = create_section!(site_id: site_b.id, workspace_version_id: v1.id)

      child =
        create_section!(
          site_id: site_b.id,
          workspace_version_id: v2.id,
          parent_section_id: section.id,
          language_group_id: section.id,
          source_section_id: copied.id,
          language: "fa"
        )

      note = create_note!(site_id: site_b.id, section_id: section.id)
      tag = create_document_tag!(site_id: site_b.id)

      tag_translation =
        create_document_tag!(site_id: site_b.id, language: "fa", language_group_id: tag.id)

      create_section_tag!(section_id: section.id, tag_id: tag.id)

      draft =
        create_section_draft!(
          site_id: site_b.id,
          workspace_version_id: v2.id,
          source_section_id: section.id,
          parent_section_id: section.id,
          language_group_id: section.id
        )

      note_draft =
        create_note_draft!(
          site_id: site_b.id,
          section_id: section.id,
          workspace_version_id: v2.id,
          source_note_id: note.id
        )

      draft_note_draft =
        [
          section_draft_id: draft.id,
          workspace_version_id: v2.id,
          site_id: site_b.id
        ]
        |> MishkaDocument.Dev.Generator.master_note_draft()
        |> Ash.Generator.generate()

      issue = create_issue!(site_id: site_b.id, section_id: section.id, note_id: note.id)
      comment = create_issue_comment!(site_id: site_b.id, issue_id: issue.id)

      %{
        site_b: site_b,
        records: [
          issue,
          comment,
          note,
          note_draft,
          draft_note_draft,
          section,
          child,
          draft,
          tag,
          tag_translation,
          workspace,
          translation,
          v2
        ]
      }
    end

    defp master_relationships(resource) do
      resource
      |> Ash.Resource.Info.relationships()
      |> Enum.map(&Atom.to_string(&1.name))
      |> Enum.filter(
        &(String.starts_with?(&1, "master_") and not String.ends_with?(&1, "_join_assoc"))
      )
      |> Enum.map(&String.to_existing_atom/1)
    end

    defp loaded(record, relationship, opts) do
      record.__struct__
      |> Ash.Query.for_read(:master_get, %{}, opts)
      |> Ash.Query.filter(id == ^record.id)
      |> Ash.Query.load([relationship])
      |> Ash.read_one!()
      |> Map.get(relationship)
    end

    defp present?(nil), do: false
    defp present?([]), do: false
    defp present?(%{results: results}), do: results != []
    defp present?(_record), do: true

    defp every_master_relationship(records) do
      for record <- records,
          relationship <- master_relationships(record.__struct__),
          do: {record, relationship}
    end

    test "load nothing for a call with no actor, even one made with authorize?: false", %{
      records: records
    } do
      for {record, relationship} <- every_master_relationship(records) do
        refute present?(loaded(record, relationship, authorize?: false)),
               "#{inspect(record.__struct__)}.#{relationship} served a missing actor"
      end
    end

    test "load nothing for a user of the row's own site holding every permission", %{
      site_b: site_b,
      records: records
    } do
      actor = star(site_b)

      for {record, relationship} <- every_master_relationship(records) do
        refute present?(loaded(record, relationship, actor: actor, authorize?: false)),
               "#{inspect(record.__struct__)}.#{relationship} served a site user"
      end
    end

    test "load every one of them for a master", %{records: records} do
      actor = master()

      found =
        for {record, relationship} <- every_master_relationship(records),
            present?(loaded(record, relationship, actor: actor)),
            into: MapSet.new(),
            do: {record.__struct__, relationship}

      expected =
        for resource <- [
              Issue,
              IssueComment,
              Note,
              NoteDraft,
              Section,
              SectionDraft,
              Tag,
              Workspace,
              WorkspaceVersion
            ],
            relationship <- master_relationships(resource),
            into: MapSet.new(),
            do: {resource, relationship}

      assert MapSet.difference(expected, found) == MapSet.new()
    end
  end

  describe "a section's source section" do
    setup do
      site_b = create_site!()
      own = create_section!(site_id: site_b.id)
      foreign = create_section!(site_id: create_site!().id)

      %{
        site_b: site_b,
        own: own,
        same_site: copy_of!(own),
        crossed: point!(create_section!(site_id: site_b.id), :source_section_id, foreign.id)
      }
    end

    test "loads for a site admin of the section's own site", ctx do
      source = fn record ->
        record
        |> Ash.load!([:source_section], actor: star(ctx.site_b), tenant: ctx.site_b.id)
        |> Map.get(:source_section)
      end

      assert %{id: id} = source.(ctx.same_site)
      assert id == ctx.own.id
      refute source.(ctx.crossed)
    end

    test "loads for a master through master_source_section, from the section's own site only",
         ctx do
      assert %{id: id} = loaded(ctx.same_site, :master_source_section, actor: master())
      assert id == ctx.own.id
      refute loaded(ctx.crossed, :master_source_section, actor: master())
      refute loaded(ctx.crossed, :master_source_section, authorize?: false)
    end
  end

  describe "the event log's own site scoping" do
    alias MishkaDocument.EventLog
    alias MishkaDocument.Resources.Helpers.SiteNames

    setup do
      site = create_site!()
      section = create_section!(site_id: site.id)
      author = create_user!(site_id: site.id)

      event =
        EventLog
        |> Ash.Changeset.for_create(
          :create,
          %{
            record_id: section.id,
            resource: MishkaDocument.Section,
            action: :create,
            action_type: :create,
            actor_id: author.id,
            metadata: %{
              "site_id" => site.id,
              "workspace_version_id" => section.workspace_version_id
            },
            data: %{},
            occurred_at: DateTime.utc_now()
          },
          authorize?: false
        )
        |> Ash.create!()

      %{site: site, section: section, author: author, event: event}
    end

    defp table(action, actor) do
      page = if Ash.Resource.Info.action(EventLog, action).pagination, do: [limit: 1000]

      EventLog
      |> Ash.Query.for_read(action, %{}, actor: actor, authorize?: false)
      |> Ash.read!(page: page)
      |> case do
        %{results: results} -> results
        results -> results
      end
    end

    test "gives a call with no actor no row", %{event: event} do
      refute event.id in ids(table(:table_read, nil))
      refute event.id in ids(table(:table_get, nil))
    end

    test "gives a master every site and a site user its own", %{site: site, event: event} do
      assert event.id in ids(table(:table_read, master()))
      assert event.id in ids(table(:table_read, star(site)))
      refute event.id in ids(table(:table_read, star(create_site!())))
    end

    test "names the site only for a master", %{site: site} do
      stamped = fn actor ->
        EventLog
        |> Ash.Query.for_read(:read, %{}, authorize?: false)
        |> SiteNames.prepare([], %{actor: actor})
        |> Ash.read!()
        |> Enum.map(& &1.__metadata__[:site_name])
        |> Enum.reject(&is_nil/1)
      end

      assert site.name in stamped.(master())
      assert stamped.(nil) == []
      assert stamped.(star(site)) == []
    end

    test "a live event reaches a master and its own site's users, never a viewer who is not a user",
         %{site: site, event: event} do
      visible = MishkaGervaz.Resource.Info.Table.config(EventLog)[:realtime][:visible]

      assert visible.(event, master())
      assert visible.(event, star(site))
      refute visible.(event, star(create_site!()))
      refute visible.(event, %{site_id: nil})
      refute visible.(event, nil)
    end

    test "the section table's contributor filter gives a viewer who is not a user nothing", %{
      site: site,
      section: section,
      author: author
    } do
      filter = MishkaGervaz.Resource.Info.Table.filter(Section, :contributor)
      state = %{path_params: %{workspace_version_id: section.workspace_version_id}}

      contributors = fn user ->
        MishkaCmsCore.Accounts.User
        |> Ash.Query.new()
        |> filter.load.(Map.put(state, :current_user, user))
        |> Ash.read!(authorize?: false)
        |> ids()
      end

      sections = fn user ->
        Section
        |> Ash.Query.for_read(:read_any, %{}, authorize?: false)
        |> filter.apply.([author.id], %{current_user: user})
        |> Ash.read!(page: [limit: 100])
        |> Map.get(:results)
        |> ids()
      end

      assert author.id in contributors.(master())
      assert author.id in contributors.(star(site))
      refute author.id in contributors.(nil)

      assert section.id in sections.(master())
      assert section.id in sections.(star(site))
      refute section.id in sections.(nil)
    end

    test "the section table's contributor options with no version stay on the viewer's own site",
         %{site: site, author: author} do
      filter = MishkaGervaz.Resource.Info.Table.filter(Section, :contributor)
      stranger = create_user!(site_id: create_site!().id)

      options = fn user ->
        MishkaCmsCore.Accounts.User
        |> Ash.Query.new()
        |> filter.load.(%{path_params: %{}, current_user: user})
        |> Ash.read!(authorize?: false)
        |> ids()
      end

      assert author.id in options.(master())
      assert stranger.id in options.(master())

      assert author.id in options.(star(site))
      refute stranger.id in options.(star(site))

      assert options.(nil) == MapSet.new()
    end
  end

  describe "the event log's reads" do
    alias MishkaDocument.EventLog

    setup do
      site_a = create_site!()
      site_b = create_site!()

      event = fn site ->
        EventLog
        |> Ash.Changeset.for_create(
          :create,
          %{
            record_id: Ash.UUIDv7.generate(),
            resource: MishkaDocument.Workspace,
            action: :create,
            action_type: :create,
            metadata: %{"site_id" => site.id, "title" => "Event"},
            data: %{},
            occurred_at: DateTime.utc_now()
          },
          authorize?: false
        )
        |> Ash.create!()
      end

      %{site_a: site_a, site_b: site_b, event_a: event.(site_a), event_b: event.(site_b)}
    end

    defp log(action, args, opts) do
      page = if Ash.Resource.Info.action(EventLog, action).pagination, do: [limit: 1000]

      EventLog
      |> Ash.Query.for_read(action, args, opts)
      |> Ash.read(page: page)
      |> case do
        {:ok, %{results: results}} -> {:ok, ids(results)}
        {:ok, results} -> {:ok, ids(results)}
        error -> error
      end
    end

    test "tenant_read never serves a site user another site's events", ctx do
      assert {:ok, rows} = log(:tenant_read, %{site_id: ctx.site_b.id}, actor: star(ctx.site_a))
      refute ctx.event_b.id in rows

      assert {:ok, own} = log(:tenant_read, %{site_id: ctx.site_a.id}, actor: star(ctx.site_a))
      assert ctx.event_a.id in own
    end

    test "no read serves a call with no actor", ctx do
      for {action, args} <- [
            master_read: %{},
            tenant_read: %{site_id: ctx.site_b.id},
            read: %{},
            table_read: %{},
            table_get: %{}
          ] do
        assert {:error, %Ash.Error.Forbidden{}} = log(action, args, actor: nil),
               "#{action} served a missing actor"
      end
    end

    test "no read serves a user without the admin permission", ctx do
      nobody = create_user!()

      for {action, args} <- [master_read: %{}, read: %{}, table_read: %{}] do
        assert {:error, %Ash.Error.Forbidden{}} = log(action, args, actor: nobody),
               "#{action} served a user without the admin permission"
      end

      assert {:error, %Ash.Error.Forbidden{}} =
               log(:tenant_read, %{site_id: ctx.site_b.id},
                 actor: create_user!(site_id: ctx.site_b.id)
               )
    end

    test "the plain read gives a master every site and a site admin its own site", ctx do
      assert {:ok, all} = log(:read, %{}, actor: master())
      assert ctx.event_a.id in all
      assert ctx.event_b.id in all

      assert {:ok, own} = log(:read, %{}, actor: star(ctx.site_a))
      assert ctx.event_a.id in own
      refute ctx.event_b.id in own
    end

    test "a master reads another site's events through tenant_read and master_read", ctx do
      assert {:ok, rows} = log(:tenant_read, %{site_id: ctx.site_b.id}, actor: master())
      assert ctx.event_b.id in rows

      assert {:ok, all} = log(:master_read, %{}, actor: master())
      assert ctx.event_b.id in all
    end

    test "a system read made with authorize?: false still reads every site", ctx do
      assert {:ok, all} = log(:read, %{}, authorize?: false)
      assert ctx.event_a.id in all
      assert ctx.event_b.id in all
    end

    test "a site admin counts only its own site's events", ctx do
      assert %{total: 1} = EventLog.counts(star(ctx.site_a))
      assert %{total: 0} = EventLog.counts(nil)
    end
  end

  describe "a site user's writes that name another site's record" do
    alias MishkaDocument.{SectionTag, SectionView, WorkspaceVersionLineage}

    setup do
      a = site_graph(create_site!())
      b = site_graph(create_site!())
      %{a: a, b: b, actor: star(a.site)}
    end

    defp site_graph(site) do
      workspace = create_workspace!(site_id: site.id, skip_version: true)
      version = create_workspace_version!(workspace_id: workspace.id, site_id: site.id)
      section = create_section!(site_id: site.id, workspace_version_id: version.id)

      %{
        site: site,
        workspace: workspace,
        version: version,
        section: section,
        note: create_note!(site_id: site.id, section_id: section.id),
        tag: create_document_tag!(site_id: site.id),
        user: create_user!(site_id: site.id),
        draft: create_section_draft!(site_id: site.id, workspace_version_id: version.id),
        note_draft:
          create_note_draft!(
            site_id: site.id,
            section_id: section.id,
            workspace_version_id: version.id
          )
      }
    end

    defp create_as(resource, action, attrs, actor, tenant) do
      resource
      |> Ash.Changeset.for_create(action, attrs, actor: actor, tenant: tenant)
      |> Ash.create()
    end

    defp update_as(record, attrs, actor, tenant) do
      record
      |> Ash.Changeset.for_update(:update, attrs, actor: actor, tenant: tenant)
      |> Ash.update()
    end

    defp refused_on?({:error, %{errors: errors}}, field),
      do: Enum.any?(errors, &(Map.get(&1, :field) == field))

    defp refused_on?(_result, _field), do: false

    defp creates(a, b) do
      section = fn extra ->
        Map.merge(
          %{
            workspace_version_id: a.version.id,
            title: "T",
            slug: "t-#{System.unique_integer([:positive])}",
            language: "fa"
          },
          extra
        )
      end

      draft = fn extra ->
        Map.merge(
          %{
            workspace_version_id: a.version.id,
            title: "D",
            slug: "d-#{System.unique_integer([:positive])}",
            language: "fa",
            change_version: "0.0.1",
            version_increment_type: :minor
          },
          extra
        )
      end

      note_draft = fn extra ->
        Map.merge(
          %{
            workspace_version_id: a.version.id,
            section_id: a.section.id,
            title: "ND",
            content: "c",
            change_version: "0.0.1",
            version_increment_type: :minor
          },
          extra
        )
      end

      [
        {Note, :create, %{section_id: b.section.id, title: "N", content: "c"}, :section_id},
        {Workspace, :create,
         %{
           name: "W",
           slug: "w-x",
           status: :active,
           language: "fa",
           language_group_id: b.workspace.id
         }, :language_group_id},
        {Section, :create, section.(%{workspace_version_id: b.version.id}),
         :workspace_version_id},
        {Section, :create, section.(%{parent_section_id: b.section.id}), :parent_section_id},
        {Section, :create, section.(%{language_group_id: b.section.id}), :language_group_id},
        {Section, :create, section.(%{source_section_id: b.section.id}), :source_section_id},
        {SectionDraft, :create, draft.(%{workspace_version_id: b.version.id}),
         :workspace_version_id},
        {SectionDraft, :create, draft.(%{source_section_id: b.section.id}), :source_section_id},
        {SectionDraft, :create, draft.(%{parent_section_id: b.section.id}), :parent_section_id},
        {SectionDraft, :create, draft.(%{language_group_id: b.section.id}), :language_group_id},
        {SectionDraft, :create, draft.(%{created_by_user_id: b.user.id}), :created_by_user_id},
        {NoteDraft, :create, note_draft.(%{workspace_version_id: b.version.id}),
         :workspace_version_id},
        {NoteDraft, :create, note_draft.(%{section_id: b.section.id}), :section_id},
        {NoteDraft, :create, note_draft.(%{source_note_id: b.note.id}), :source_note_id},
        {NoteDraft, :create, note_draft.(%{created_by_user_id: b.user.id}), :created_by_user_id},
        {NoteDraft, :create,
         note_draft.(%{
           section_id: nil,
           section_draft_id: b.draft.id,
           change_version: b.draft.change_version
         }), :section_draft_id},
        {WorkspaceVersion, :create,
         %{
           workspace_id: a.workspace.id,
           version_number: "9.9.9",
           status: :draft,
           source_version_id: b.version.id
         }, :source_version_id},
        {WorkspaceVersionLineage, :create,
         %{new_version_id: b.version.id, source_version_id: a.version.id}, :new_version_id},
        {WorkspaceVersionLineage, :create,
         %{new_version_id: a.version.id, source_version_id: b.version.id}, :source_version_id},
        {Tag, :create, %{name: "G", slug: "g-x", language: "fa", language_group_id: b.tag.id},
         :language_group_id},
        {SectionView, :create, %{section_id: b.section.id, ip_address: "203.0.113.9"},
         :section_id}
      ]
    end

    defp updates(a, b) do
      [
        {a.note, %{section_id: b.section.id}, :section_id},
        {a.workspace, %{language_group_id: b.workspace.id}, :language_group_id},
        {a.section, %{workspace_version_id: b.version.id}, :workspace_version_id},
        {a.section, %{parent_section_id: b.section.id}, :parent_section_id},
        {a.section, %{language_group_id: b.section.id}, :language_group_id},
        {a.section, %{source_section_id: b.section.id}, :source_section_id},
        {a.draft, %{workspace_version_id: b.version.id}, :workspace_version_id},
        {a.draft, %{source_section_id: b.section.id}, :source_section_id},
        {a.draft, %{parent_section_id: b.section.id}, :parent_section_id},
        {a.draft, %{language_group_id: b.section.id}, :language_group_id},
        {a.note_draft, %{workspace_version_id: b.version.id}, :workspace_version_id},
        {a.note_draft, %{section_id: b.section.id}, :section_id},
        {a.note_draft, %{source_note_id: b.note.id}, :source_note_id},
        {a.note_draft, %{section_id: nil, section_draft_id: b.draft.id}, :section_draft_id},
        {a.version, %{workspace_id: b.workspace.id}, :workspace_id},
        {a.tag, %{language_group_id: b.tag.id}, :language_group_id}
      ]
    end

    test "creating a row that points at another site's record is refused", %{
      a: a,
      b: b,
      actor: actor
    } do
      for {resource, action, attrs, field} <- creates(a, b) do
        result = create_as(resource, action, attrs, actor, a.site.id)

        assert refused_on?(result, field),
               "#{inspect(resource)}.#{action} took site B's #{field}: #{inspect(result, limit: 3)}"
      end
    end

    test "pointing a row at another site's record is refused", %{a: a, b: b, actor: actor} do
      for {record, attrs, field} <- updates(a, b) do
        result = update_as(record, attrs, actor, a.site.id)

        assert refused_on?(result, field),
               "#{inspect(record.__struct__)}.update took site B's #{field}: #{inspect(result, limit: 3)}"
      end
    end

    test "tagging another site's section, or with another site's tag, is refused", %{
      a: a,
      b: b,
      actor: actor
    } do
      assert refused_on?(
               create_as(
                 SectionTag,
                 :assign,
                 %{section_id: b.section.id, tag_id: b.tag.id},
                 actor,
                 nil
               ),
               :section_id
             )

      assert refused_on?(
               create_as(
                 SectionTag,
                 :assign,
                 %{section_id: a.section.id, tag_id: b.tag.id},
                 actor,
                 nil
               ),
               :tag_id
             )

      assert {:ok, _} =
               create_as(
                 SectionTag,
                 :assign,
                 %{section_id: a.section.id, tag_id: a.tag.id},
                 actor,
                 nil
               )
    end

    test "the own site's records are still taken", %{a: a, actor: actor} do
      assert {:ok, _} =
               create_as(
                 Workspace,
                 :create,
                 %{
                   name: "W2",
                   slug: "w-own",
                   status: :active,
                   language: "fa",
                   language_group_id: a.workspace.id
                 },
                 actor,
                 a.site.id
               )

      assert {:ok, _} =
               create_as(
                 Tag,
                 :create,
                 %{name: "G2", slug: "g-own", language: "fa", language_group_id: a.tag.id},
                 actor,
                 a.site.id
               )

      assert {:ok, _} =
               create_as(
                 Section,
                 :create,
                 %{
                   workspace_version_id: a.version.id,
                   parent_section_id: a.section.id,
                   source_section_id: copy_of!(a.section).id,
                   language_group_id: a.section.id,
                   title: "Own",
                   slug: "own-section",
                   language: "fa"
                 },
                 actor,
                 a.site.id
               )

      assert {:ok, _} =
               create_as(
                 WorkspaceVersion,
                 :create,
                 %{
                   workspace_id: a.workspace.id,
                   version_number: "8.8.8",
                   status: :draft,
                   source_version_id: a.version.id
                 },
                 actor,
                 a.site.id
               )

      assert {:ok, _} =
               update_as(a.note, %{section_id: a.section.id, title: "Renamed"}, actor, a.site.id)

      assert {:ok, %{created_by_user_id: user_id}} =
               create_as(
                 SectionDraft,
                 :create,
                 %{
                   workspace_version_id: a.version.id,
                   title: "D",
                   slug: "d-own-creator",
                   language: "fa",
                   change_version: "0.0.1",
                   version_increment_type: :minor,
                   created_by_user_id: a.user.id
                 },
                 actor,
                 a.site.id
               )

      assert user_id == a.user.id
    end

    test "naming a master as a draft's creator is refused to a site user", %{a: a, actor: actor} do
      assert refused_on?(
               create_as(
                 SectionDraft,
                 :create,
                 %{
                   workspace_version_id: a.version.id,
                   title: "D",
                   slug: "d-master-creator",
                   language: "fa",
                   change_version: "0.0.1",
                   version_increment_type: :minor,
                   created_by_user_id: master().id
                 },
                 actor,
                 a.site.id
               ),
               :created_by_user_id
             )
    end

    test "a note draft for the own site's new section draft is taken", %{a: a, actor: actor} do
      assert {:ok, draft} =
               create_as(
                 NoteDraft,
                 :create,
                 %{
                   workspace_version_id: a.version.id,
                   section_draft_id: a.draft.id,
                   title: "ND",
                   content: "c",
                   change_version: a.draft.change_version,
                   version_increment_type: :minor
                 },
                 actor,
                 a.site.id
               )

      assert draft.section_draft_id == a.draft.id
    end
  end

  describe "join, follow, bookmark and view rows" do
    alias MishkaDocument.{SectionBookmark, SectionTag, SectionView, WorkspaceFollower}

    setup do
      site_a = create_site!()
      site_b = create_site!()

      rows = fn site ->
        # A draft workspace and a section still in review: an admin reaches them whatever their state.
        section = create_section!(site_id: site.id)
        workspace = create_workspace!(site_id: site.id, skip_version: true, status: :draft)
        visitor = create_user!(site_id: site.id)

        tag_row =
          create_section_tag!(
            section_id: section.id,
            tag_id: create_document_tag!(site_id: site.id).id
          )

        view =
          [section_id: section.id]
          |> MishkaDocument.Dev.Generator.section_view(visitor)
          |> Ash.Generator.generate()

        %{
          section: section,
          workspace: workspace,
          tag_row: tag_row,
          view: view,
          bookmark: create_section_bookmark!(user_id: visitor.id, section_id: section.id),
          follow: create_workspace_follower!(workspace_id: workspace.id, actor: visitor)
        }
      end

      %{site_a: site_a, a: rows.(site_a), b: rows.(site_b)}
    end

    defp keys(%SectionTag{} = row), do: {row.section_id, row.tag_id}
    defp keys(row), do: row.id

    defp visible(resource, actor, action \\ :read, args \\ %{}) do
      page = if Ash.Resource.Info.action(resource, action).pagination, do: [limit: 1000]

      resource
      |> Ash.Query.for_read(action, args, actor: actor)
      |> Ash.read!(page: page)
      |> case do
        %{results: results} -> results
        results -> results
      end
      |> MapSet.new(&keys/1)
    end

    test "a site admin reads only its own site's rows", %{site_a: site_a, a: a, b: b} do
      actor = star(site_a)

      for {resource, key} <- [
            {SectionTag, :tag_row},
            {SectionView, :view},
            {SectionBookmark, :bookmark},
            {WorkspaceFollower, :follow}
          ] do
        rows = visible(resource, actor)
        assert keys(Map.fetch!(a, key)) in rows, "#{inspect(resource)} hid the own site's row"
        refute keys(Map.fetch!(b, key)) in rows, "#{inspect(resource)} served site B's row"
      end

      refute b.follow.id in visible(WorkspaceFollower, actor, :by_workspace, %{
               workspace_id: b.workspace.id
             })
    end

    test "a master reads every site's rows", %{a: a, b: b} do
      actor = master()

      for {resource, key} <- [
            {SectionTag, :tag_row},
            {SectionView, :view},
            {SectionBookmark, :bookmark},
            {WorkspaceFollower, :follow}
          ] do
        rows = visible(resource, actor)
        assert keys(Map.fetch!(a, key)) in rows
        assert keys(Map.fetch!(b, key)) in rows
      end
    end

    test "a site admin cannot remove or change another site's rows", %{site_a: site_a, b: b} do
      actor = star(site_a)

      assert {:error, %Ash.Error.Forbidden{}} =
               Ash.destroy(b.tag_row, action: :destroy, actor: actor)

      assert {:error, %Ash.Error.Forbidden{}} =
               Ash.destroy(b.bookmark, action: :remove, actor: actor)

      assert {:error, %Ash.Error.Forbidden{}} =
               Ash.destroy(b.follow, action: :unfollow, actor: actor)

      assert {:error, %Ash.Error.Forbidden{}} =
               b.follow
               |> Ash.Changeset.for_update(:toggle_notifications, %{notification_enabled: false},
                 actor: actor
               )
               |> Ash.update()
    end

    test "a site admin still removes its own site's rows", %{site_a: site_a, a: a} do
      actor = star(site_a)

      assert :ok = Ash.destroy(a.tag_row, action: :destroy, actor: actor)
      assert :ok = Ash.destroy(a.bookmark, action: :remove, actor: actor)
      assert :ok = Ash.destroy(a.follow, action: :unfollow, actor: actor)
    end

    test "a visitor still loads a section's tags through the section", %{a: a} do
      section = Ash.load!(a.section, [:tags], tenant: a.section.site_id, actor: nil)
      assert a.tag_row.tag_id in Enum.map(section.tags, & &1.id)
    end
  end

  describe "a section view" do
    alias MishkaDocument.SectionView

    setup do
      site = create_site!()
      %{site: site, section: create_section!(site_id: site.id)}
    end

    defp track(site, attrs, actor) do
      SectionView
      |> Ash.Changeset.for_create(:create, Map.put(attrs, :ip_address, "203.0.113.20"),
        actor: actor,
        tenant: site.id
      )
      |> Ash.create()
    end

    test "is recorded for the signed-in viewer", %{site: site, section: section} do
      viewer = create_user!(site_id: site.id)

      assert {:ok, view} = track(site, %{section_id: section.id}, viewer)
      assert view.user_id == viewer.id
    end

    test "is a guest view when nobody is signed in", %{site: site, section: section} do
      assert {:ok, view} = track(site, %{section_id: section.id}, nil)
      assert is_nil(view.user_id)
    end

    test "never takes the viewer from the input", %{site: site, section: section} do
      someone_else = create_user!(site_id: site.id)

      assert {:error, %Ash.Error.Invalid{}} =
               track(site, %{section_id: section.id, user_id: someone_else.id}, nil)

      refute Enum.any?(
               Ash.read!(SectionView, authorize?: false),
               &(&1.user_id == someone_else.id)
             )
    end
  end

  describe "a section's breadcrumb and version count" do
    test "never read another site's sections, even through a pointer written before the rule" do
      site_a = create_site!()
      site_b = create_site!()
      own_root = create_section!(site_id: site_a.id, title: "Own root")

      foreign_parent =
        [site_id: site_b.id, title: "Secret B heading"]
        |> create_section!()
        |> point!(:parent_section_id, own_root.id)

      foreign_twin = create_section!(site_id: site_b.id)

      own_parent =
        [site_id: site_a.id, title: "Own heading"]
        |> create_section!()
        |> point!(:parent_section_id, foreign_parent.id)

      section =
        [site_id: site_a.id]
        |> create_section!()
        |> point!(:parent_section_id, foreign_parent.id)
        |> point!(:section_lineage_id, foreign_twin.section_lineage_id)

      nested =
        create_section!(
          site_id: site_a.id,
          workspace_version_id: own_parent.workspace_version_id,
          parent_section_id: own_parent.id
        )

      [loaded, nested] =
        Ash.load!([section, nested], [:breadcrumb_path, :section_versions_count],
          tenant: site_a.id,
          actor: star(site_a)
        )

      refute Enum.any?(loaded.breadcrumb_path, &(&1["title"] == "Secret B heading"))
      assert loaded.section_versions_count == 1
      assert Enum.map(nested.breadcrumb_path, & &1["title"]) == ["Own heading"]
    end
  end
end
