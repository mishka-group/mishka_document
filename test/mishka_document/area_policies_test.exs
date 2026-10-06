defmodule MishkaDocument.AreaPoliciesTest do
  @moduledoc """
  Every document record answers to one of the two document areas, on the surface the request came
  from — the same names the document screens are gated by.

    * Workspaces, their versions and version lineage are read and written by `document:workspace`.
      On the dashboard a section admin also reads workspaces and versions, because every section
      screen is drawn inside its workspace version; it reads no lineage, and on the admin JSON:API
      none of the three.
    * Sections, notes, drafts, tags, issues, issue comments, section-tag links, other users'
      bookmarks and section views are read and written by `document:section` only.
    * Other users' workspace follows are `document:workspace`'s.
    * An event in the log is read by the area of the record it is about.

  An admin of any other area holds none of it. On the admin JSON:API (`admin_surface: :api` in the
  shared context) the `admin:api:` names answer and the dashboard's do not, and the other way round.
  """
  use MishkaDocument.DataCase, async: false

  import MishkaDocument.Test.Factory

  require Ash.Query

  @workspace "admin:dashboard:document:workspace"
  @section "admin:dashboard:document:section"
  @whole "admin:dashboard:document:*"
  @unrelated "admin:dashboard:runtime:page"
  @api_workspace "admin:api:document:workspace"
  @api_section "admin:api:document:section"

  @workspace_side [
    MishkaDocument.Workspace,
    MishkaDocument.WorkspaceVersion,
    MishkaDocument.WorkspaceVersionLineage
  ]

  # What a section screen is drawn inside.
  @drawn_around [MishkaDocument.Workspace, MishkaDocument.WorkspaceVersion]

  @section_side [
    MishkaDocument.Section,
    MishkaDocument.Note,
    MishkaDocument.SectionDraft,
    MishkaDocument.NoteDraft,
    MishkaDocument.Tag,
    MishkaDocument.Issue,
    MishkaDocument.IssueComment
  ]

  setup do
    site = create_site!()
    workspace = create_workspace!(site_id: site.id, skip_version: true)
    version = create_workspace_version!(workspace_id: workspace.id, site_id: site.id)
    section = create_section!(site_id: site.id, workspace_version_id: version.id)
    issue = create_issue!(site_id: site.id, section_id: section.id)

    records = %{
      MishkaDocument.Workspace => workspace,
      MishkaDocument.WorkspaceVersion => version,
      MishkaDocument.WorkspaceVersionLineage =>
        create_workspace_version_lineage!(source_version_id: version.id, site_id: site.id),
      MishkaDocument.Section => section,
      MishkaDocument.Note => create_note!(site_id: site.id, section_id: section.id),
      MishkaDocument.SectionDraft =>
        create_section_draft!(site_id: site.id, workspace_version_id: version.id),
      MishkaDocument.NoteDraft =>
        create_note_draft!(
          site_id: site.id,
          section_id: section.id,
          workspace_version_id: version.id
        ),
      MishkaDocument.Tag => create_document_tag!(site_id: site.id),
      MishkaDocument.Issue => issue,
      MishkaDocument.IssueComment => create_issue_comment!(site_id: site.id, issue_id: issue.id)
    }

    {:ok, site: site, records: records, section: section, workspace: workspace}
  end

  defp admin(names, site), do: create_user_with_permissions!(names, site_id: site.id)

  defp opts(actor, site, surface) do
    [actor: actor, tenant: site.id, context: %{shared: %{admin_surface: surface}}]
  end

  defp read(%resource{id: id}, actor, site, surface) do
    opts = opts(actor, site, surface)

    resource
    |> Ash.Query.for_read(:read, %{}, opts)
    |> Ash.Query.filter(id == ^id)
    |> Ash.read(opts)
  end

  defp update(record, actor, site, surface) do
    opts = opts(actor, site, surface)

    record
    |> Ash.Changeset.for_update(:update, %{}, opts)
    |> Ash.update(opts)
  end

  # A new record of `resource`, written as `actor` through its tenant `:create`.
  defp created?(resource, attrs, actor, site, surface) do
    opts = opts(actor, site, surface)

    case resource |> Ash.Changeset.for_create(:create, attrs, opts) |> Ash.create(opts) do
      {:ok, _record} -> true
      {:error, %Ash.Error.Forbidden{}} -> false
    end
  end

  # `record` removed through its tenant `:destroy`: archiving a workspace, deleting a version or a
  # lineage row.
  defp destroyed?(record, actor, site, surface) do
    opts = opts(actor, site, surface)

    case record |> Ash.Changeset.for_destroy(:destroy, %{}, opts) |> Ash.destroy(opts) do
      :ok -> true
      {:error, %Ash.Error.Forbidden{}} -> false
    end
  end

  # What `:create` needs for each workspace-side resource, and a fresh record for `:destroy` to
  # remove, so every actor asked starts from the same state.
  defp new_attrs(MishkaDocument.Workspace, _site, _workspace) do
    n = System.unique_integer([:positive])
    %{name: "New #{n}", slug: "new-#{n}", status: :active, language: "en"}
  end

  defp new_attrs(MishkaDocument.WorkspaceVersion, _site, workspace) do
    %{
      workspace_id: workspace.id,
      version_number: "9.#{System.unique_integer([:positive])}.0",
      status: :draft
    }
  end

  defp new_attrs(MishkaDocument.WorkspaceVersionLineage, site, workspace) do
    source = create_workspace_version!(workspace_id: workspace.id, site_id: site.id)
    cloned = create_workspace_version!(workspace_id: workspace.id, site_id: site.id)
    %{source_version_id: source.id, new_version_id: cloned.id}
  end

  defp disposable(MishkaDocument.Workspace, site, _workspace),
    do: create_workspace!(site_id: site.id, skip_version: true)

  defp disposable(MishkaDocument.WorkspaceVersion, site, workspace),
    do: create_workspace_version!(workspace_id: workspace.id, site_id: site.id)

  defp disposable(MishkaDocument.WorkspaceVersionLineage, site, workspace) do
    source = create_workspace_version!(workspace_id: workspace.id, site_id: site.id)
    create_workspace_version_lineage!(source_version_id: source.id, site_id: site.id)
  end

  # Read back through the area's own read: a record held back by a filter is as unread as one
  # refused outright.
  defp readable?(record, actor, site, surface \\ :dashboard) do
    case read(record, actor, site, surface) do
      {:ok, [_record]} -> true
      {:ok, []} -> false
      {:error, %Ash.Error.Forbidden{}} -> false
    end
  end

  defp writable?(record, actor, site, surface \\ :dashboard) do
    case update(record, actor, site, surface) do
      {:ok, _record} -> true
      {:error, %Ash.Error.Forbidden{}} -> false
    end
  end

  describe "the workspace side" do
    test "a workspace admin reads and writes it", %{site: site, records: records} do
      admin = admin([@workspace], site)

      for resource <- @workspace_side do
        assert readable?(records[resource], admin, site),
               "#{inspect(resource)} refused its own area a read"

        assert writable?(records[resource], admin, site),
               "#{inspect(resource)} refused its own area a write"
      end
    end

    test "a section admin reads the workspaces and versions its sections sit in, no lineage, and writes none of it",
         %{site: site, records: records} do
      admin = admin([@section], site)

      for resource <- @workspace_side do
        assert readable?(records[resource], admin, site) == resource in @drawn_around,
               "#{inspect(resource)} answered a section admin's read wrongly"

        refute writable?(records[resource], admin, site),
               "#{inspect(resource)} let a section admin write it"
      end
    end

    test "an admin of another area neither reads nor writes it", %{site: site, records: records} do
      admin = admin([@unrelated], site)

      for resource <- @workspace_side do
        refute readable?(records[resource], admin, site),
               "#{inspect(resource)} let a page admin read it"

        refute writable?(records[resource], admin, site),
               "#{inspect(resource)} let a page admin write it"
      end
    end
  end

  describe "creating and removing on the workspace side" do
    test "a workspace admin creates and removes each of its records", %{
      site: site,
      workspace: workspace
    } do
      admin = admin([@workspace], site)

      for resource <- @workspace_side do
        assert created?(resource, new_attrs(resource, site, workspace), admin, site, :dashboard),
               "#{inspect(resource)} refused its own area a create"

        assert destroyed?(disposable(resource, site, workspace), admin, site, :dashboard),
               "#{inspect(resource)} refused its own area a removal"
      end
    end

    test "a section admin, or an admin of another area, creates and removes none of them", %{
      site: site,
      workspace: workspace
    } do
      for names <- [[@section], [@unrelated]], resource <- @workspace_side do
        actor = admin(names, site)

        refute created?(resource, new_attrs(resource, site, workspace), actor, site, :dashboard),
               "#{inspect(resource)} let #{inspect(names)} create one"

        refute destroyed?(disposable(resource, site, workspace), actor, site, :dashboard),
               "#{inspect(resource)} let #{inspect(names)} remove one"
      end
    end

    test "on the API, only the API's workspace name creates and removes them", %{
      site: site,
      workspace: workspace
    } do
      api_workspace = admin([@api_workspace], site)

      for resource <- @workspace_side do
        assert created?(
                 resource,
                 new_attrs(resource, site, workspace),
                 api_workspace,
                 site,
                 :api
               ),
               "#{inspect(resource)} refused the API workspace name a create"

        assert destroyed?(disposable(resource, site, workspace), api_workspace, site, :api),
               "#{inspect(resource)} refused the API workspace name a removal"
      end

      for names <- [[@api_section], [@workspace]], resource <- @workspace_side do
        actor = admin(names, site)

        refute created?(resource, new_attrs(resource, site, workspace), actor, site, :api),
               "#{inspect(resource)} let #{inspect(names)} create one on the API"

        refute destroyed?(disposable(resource, site, workspace), actor, site, :api),
               "#{inspect(resource)} let #{inspect(names)} remove one on the API"
      end
    end
  end

  describe "the section side" do
    test "a section admin reads and writes it", %{site: site, records: records} do
      admin = admin([@section], site)

      for resource <- @section_side do
        assert readable?(records[resource], admin, site),
               "#{inspect(resource)} refused its own area a read"

        assert writable?(records[resource], admin, site),
               "#{inspect(resource)} refused its own area a write"
      end
    end

    test "a workspace admin neither reads nor writes it", %{site: site, records: records} do
      admin = admin([@workspace], site)

      for resource <- @section_side do
        refute readable?(records[resource], admin, site),
               "#{inspect(resource)} let a workspace admin read it"

        refute writable?(records[resource], admin, site),
               "#{inspect(resource)} let a workspace admin write it"
      end
    end

    test "an admin of another area neither reads nor writes it", %{site: site, records: records} do
      admin = admin([@unrelated], site)

      for resource <- @section_side do
        refute readable?(records[resource], admin, site),
               "#{inspect(resource)} let a page admin read it"

        refute writable?(records[resource], admin, site),
               "#{inspect(resource)} let a page admin write it"
      end
    end
  end

  test "the whole extension holds both sides", %{site: site, records: records} do
    admin = admin([@whole], site)

    for resource <- @workspace_side ++ @section_side do
      assert readable?(records[resource], admin, site)
      assert writable?(records[resource], admin, site)
    end
  end

  describe "the fields only admins see" do
    test "a workspace's maintainers and health go to either area and to nobody else", %{
      site: site,
      workspace: workspace
    } do
      for {names, shown?} <- [{[@workspace], true}, {[@section], true}, {[@unrelated], false}] do
        actor = admin(names, site)

        loaded =
          Ash.load!(workspace, [:maintainers_info, :health_metrics],
            actor: actor,
            tenant: site.id
          )

        assert match?(%Ash.ForbiddenField{}, loaded.maintainers_info) == not shown?,
               "#{inspect(names)} was answered wrongly about a workspace's maintainers"
      end
    end

    test "a section's draft and version counts go to the section area only", %{
      site: site,
      section: section
    } do
      for {names, shown?} <- [{[@section], true}, {[@workspace], false}] do
        actor = admin(names, site)

        loaded = Ash.load!(section, [:section_versions_count], actor: actor, tenant: site.id)

        assert match?(%Ash.ForbiddenField{}, loaded.section_versions_count) == not shown?,
               "#{inspect(names)} was answered wrongly about a section's version count"
      end
    end

    test "a note's draft counts go to the section area only", %{site: site, records: records} do
      for {names, shown?} <- [{[@section], true}, {[@workspace], false}] do
        actor = admin(names, site)

        loaded =
          Ash.load!(records[MishkaDocument.Note], [:approved_note_draft_count],
            actor: actor,
            tenant: site.id
          )

        assert match?(%Ash.ForbiddenField{}, loaded.approved_note_draft_count) == not shown?,
               "#{inspect(names)} was answered wrongly about a note's draft count"
      end
    end
  end

  describe "rows that belong to other users" do
    test "another user's section bookmarks are the section area's", %{
      site: site,
      section: section
    } do
      reader = create_user!(site_id: site.id)
      create_section_bookmark!(user_id: reader.id, section_id: section.id)

      for {names, count} <- [{[@section], 1}, {[@workspace], 0}, {[@unrelated], 0}] do
        actor = admin(names, site)

        assert count ==
                 MishkaDocument.SectionBookmark
                 |> Ash.Query.filter(user_id == ^reader.id)
                 |> Ash.read!(actor: actor)
                 |> length(),
               "#{inspect(names)} was answered wrongly about another user's bookmarks"
      end
    end

    test "another user's workspace follows are the workspace area's", %{
      site: site,
      workspace: workspace
    } do
      reader = create_user!(site_id: site.id)
      create_workspace_follower!(workspace_id: workspace.id, actor: reader)

      for {names, count} <- [{[@workspace], 1}, {[@section], 0}, {[@unrelated], 0}] do
        actor = admin(names, site)

        assert count ==
                 MishkaDocument.WorkspaceFollower
                 |> Ash.Query.filter(follower_user_id == ^reader.id)
                 |> Ash.read!(actor: actor)
                 |> length(),
               "#{inspect(names)} was answered wrongly about another user's follows"
      end
    end

    test "section views are read by the section area only", %{site: site, section: section} do
      MishkaDocument.SectionView
      |> Ash.Changeset.for_create(:create, %{section_id: section.id, ip_address: "127.0.0.1"},
        authorize?: false
      )
      |> Ash.create!()

      for {names, readable?} <- [{[@section], true}, {[@workspace], false}, {[@unrelated], false}] do
        actor = admin(names, site)

        result =
          MishkaDocument.SectionView
          |> Ash.Query.filter(section_id == ^section.id)
          |> Ash.read(actor: actor)

        assert match?({:ok, [_ | _]}, result) == readable?,
               "#{inspect(names)} was answered wrongly about section views"
      end
    end

    test "linking a tag to a section is the section area's", %{site: site, section: section} do
      for {names, linked?} <- [{[@section], true}, {[@workspace], false}, {[@unrelated], false}] do
        actor = admin(names, site)
        tag = create_document_tag!(site_id: site.id)

        result =
          MishkaDocument.SectionTag
          |> Ash.Changeset.for_create(:assign, %{section_id: section.id, tag_id: tag.id},
            actor: actor
          )
          |> Ash.create()

        assert match?({:ok, _link}, result) == linked?,
               "#{inspect(names)} was answered wrongly about linking a tag"
      end
    end

    test "a section's tag links are the section area's", %{site: site, section: section} do
      tag = create_document_tag!(site_id: site.id)
      create_section_tag!(section_id: section.id, tag_id: tag.id)

      for {names, readable?} <- [{[@section], true}, {[@workspace], false}, {[@unrelated], false}] do
        actor = admin(names, site)

        result =
          MishkaDocument.SectionTag
          |> Ash.Query.filter(section_id == ^section.id)
          |> Ash.read(actor: actor)

        assert match?({:ok, [_ | _]}, result) == readable?,
               "#{inspect(names)} was answered wrongly about a section's tag links"
      end
    end
  end

  describe "the event log" do
    # The resources whose events `names` reads through the log's table read, or `:refused`.
    defp logged_for(names, site, surface) do
      actor = admin(names, site)
      opts = [actor: actor, context: %{shared: %{admin_surface: surface}}]

      case MishkaDocument.EventLog
           |> Ash.Query.for_read(:table_read, %{}, opts)
           |> Ash.read(Keyword.put(opts, :page, limit: 1_000)) do
        {:ok, %{results: events}} -> MapSet.new(events, & &1.resource)
        {:error, %Ash.Error.Forbidden{}} -> :refused
      end
    end

    defp logged_side(area), do: MapSet.new(MishkaDocument.EventLog.logged(area))

    test "shows each area the events of its own records only", %{site: site} do
      workspace_side = logged_side(:workspace)
      section_side = logged_side(:section)

      workspace_events = logged_for([@workspace], site, :dashboard)
      section_events = logged_for([@section], site, :dashboard)

      assert MishkaDocument.Workspace in workspace_events
      assert MapSet.subset?(workspace_events, workspace_side)

      assert MishkaDocument.Section in section_events
      assert MapSet.subset?(section_events, section_side)

      both = MapSet.union(workspace_events, section_events)
      assert logged_for([@workspace, @section], site, :dashboard) == both
      assert logged_for([@whole], site, :dashboard) == both

      assert logged_for([@unrelated], site, :dashboard) == :refused
    end

    test "on the API the API names answer, and the dashboard's do not", %{site: site} do
      assert logged_for([@api_workspace], site, :api) ==
               logged_for([@workspace], site, :dashboard)

      assert logged_for([@api_section], site, :api) == logged_for([@section], site, :dashboard)

      assert logged_for([@workspace], site, :api) == :refused
      assert logged_for([@api_section], site, :dashboard) == :refused
    end

    test "the counts beside it count only what the area reads", %{site: site} do
      count = fn names -> MishkaDocument.EventLog.counts(admin(names, site)).total end

      both = count.([@workspace, @section])

      assert count.([@workspace]) < both
      assert count.([@section]) < both
      assert count.([@workspace]) + count.([@section]) == both
    end

    test "every resource writing to it is read by exactly one area" do
      writers =
        MishkaDocument
        |> Ash.Domain.Info.resources()
        |> Enum.filter(&(AshEvents.Events in Spark.extensions(&1)))
        |> Enum.filter(&(AshEvents.Events.Info.events_event_log!(&1) == MishkaDocument.EventLog))

      for resource <- writers do
        owners =
          Enum.filter([:workspace, :section], &(resource in MishkaDocument.EventLog.logged(&1)))

        assert length(owners) == 1, "#{inspect(resource)} is read by #{inspect(owners)}"
      end

      assert MapSet.new(writers) ==
               MapSet.new(
                 Enum.flat_map([:workspace, :section], &MishkaDocument.EventLog.logged/1)
               )
    end
  end

  # A master's `:read_any` reads every site's rows; it asks the same area as the rest.
  test "a master reads every site's rows with the area, and none without it" do
    masters = %{
      workspace: create_user_with_permissions!([@workspace]),
      section: create_user_with_permissions!([@section]),
      page: create_user_with_permissions!([@unrelated])
    }

    read_any? = fn resource, actor ->
      case resource
           |> Ash.Query.for_read(:read_any, %{}, actor: actor)
           |> Ash.Query.limit(1)
           |> Ash.read(actor: actor) do
        {:ok, _page} -> true
        {:error, %Ash.Error.Forbidden{}} -> false
      end
    end

    for {resource, readers} <- [
          {MishkaDocument.Workspace, [:workspace, :section]},
          {MishkaDocument.WorkspaceVersion, [:workspace, :section]},
          {MishkaDocument.Section, [:section]},
          {MishkaDocument.Note, [:section]},
          {MishkaDocument.SectionDraft, [:section]},
          {MishkaDocument.Tag, [:section]}
        ],
        {who, master} <- masters do
      assert read_any?.(resource, master) == who in readers,
             "#{inspect(resource)} answered a #{who} master wrongly"
    end
  end

  test "a site admin holding the area reads none of every site's rows", %{
    site: site,
    records: records
  } do
    assert records[MishkaDocument.Workspace].site_id == site.id

    for {resource, names} <- [
          {MishkaDocument.Workspace, [@workspace]},
          {MishkaDocument.WorkspaceVersion, [@workspace]},
          {MishkaDocument.Section, [@section]},
          {MishkaDocument.Note, [@section]},
          {MishkaDocument.SectionDraft, [@section]},
          {MishkaDocument.Tag, [@section]}
        ] do
      actor = admin(names, site)

      result =
        resource
        |> Ash.Query.for_read(:read_any, %{}, actor: actor)
        |> Ash.Query.limit(1)
        |> Ash.read(actor: actor)

      assert match?({:ok, []}, result) or match?({:ok, %{results: []}}, result) or
               match?({:error, %Ash.Error.Forbidden{}}, result),
             "#{inspect(resource)} gave a site admin every site's rows"
    end
  end

  test "a section admin writes a new section into a version it reads", %{
    site: site,
    records: records
  } do
    version = records[MishkaDocument.WorkspaceVersion]

    create = fn names ->
      actor = admin(names, site)

      MishkaDocument.Section
      |> Ash.Changeset.for_create(
        :create,
        %{
          workspace_version_id: version.id,
          title: "Written by #{hd(names)}",
          slug: "written-#{System.unique_integer([:positive])}",
          content: "Body",
          language: "en"
        },
        actor: actor,
        tenant: site.id
      )
      |> Ash.create()
    end

    assert {:ok, _section} = create.([@section])
    assert {:error, %Ash.Error.Forbidden{}} = create.([@workspace])
  end

  describe "on the admin JSON:API" do
    test "the API names answer and the dashboard's do not", %{site: site, records: records} do
      api_workspace = admin([@api_workspace], site)
      api_section = admin([@api_section], site)
      dashboard_workspace = admin([@workspace], site)
      dashboard_section = admin([@section], site)

      assert writable?(records[MishkaDocument.Workspace], api_workspace, site, :api)
      assert writable?(records[MishkaDocument.Section], api_section, site, :api)

      refute readable?(records[MishkaDocument.Workspace], dashboard_workspace, site, :api)
      refute writable?(records[MishkaDocument.Workspace], dashboard_workspace, site, :api)
      refute readable?(records[MishkaDocument.Section], dashboard_section, site, :api)
      refute writable?(records[MishkaDocument.Section], dashboard_section, site, :api)
    end

    test "the workspace side is read by the API's workspace name, and not by its section name", %{
      site: site,
      records: records
    } do
      api_workspace = admin([@api_workspace], site)
      api_section = admin([@api_section], site)

      for resource <- @workspace_side do
        assert readable?(records[resource], api_workspace, site, :api),
               "#{inspect(resource)} refused the API workspace name a read"

        refute readable?(records[resource], api_section, site, :api),
               "#{inspect(resource)} let the API section name read it"
      end
    end

    test "a master holding the API's section name reads no site's workspaces or versions there" do
      master = create_user_with_permissions!([@api_section])
      opts = [actor: master, context: %{shared: %{admin_surface: :api}}]

      for resource <- @drawn_around do
        assert {:error, %Ash.Error.Forbidden{}} =
                 resource
                 |> Ash.Query.for_read(:read_any, %{}, opts)
                 |> Ash.Query.limit(1)
                 |> Ash.read(opts),
               "#{inspect(resource)} let an API section master read every site's rows"
      end
    end

    test "a comment on a closed issue is refused there as on the dashboard", %{
      site: site,
      records: records
    } do
      issue = records[MishkaDocument.Issue]
      Ash.update!(issue, %{}, action: :mark_closed, tenant: site.id, authorize?: false)

      for {names, surface} <- [{[@api_section], :api}, {[@section], :dashboard}] do
        actor = admin(names, site)
        opts = opts(actor, site, surface)

        assert {:error, %Ash.Error.Invalid{} = error} =
                 MishkaDocument.IssueComment
                 |> Ash.Changeset.for_create(
                   :create,
                   %{issue_id: issue.id, content: "Late"},
                   opts
                 )
                 |> Ash.create(opts)

        assert Exception.message(error) =~ "Cannot add comments to a closed issue",
               "a #{surface} admin commented on a closed issue"
      end
    end

    test "and an API name opens nothing on the dashboard", %{site: site, records: records} do
      api_section = admin([@api_section], site)

      refute readable?(records[MishkaDocument.Section], api_section, site)
      refute writable?(records[MishkaDocument.Section], api_section, site)
    end
  end
end
