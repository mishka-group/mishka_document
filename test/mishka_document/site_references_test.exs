# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_document/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaDocument.SiteReferencesTest do
  @moduledoc """
  Which records a document record may name by id.

  A site's workspace, version, section, note, draft, tag, issue and comment names only records of
  its own site — whoever writes: an admin of that site, a master working on it, or the system. A
  user it names is an account of that site or a master. The join, view, bookmark and follow rows
  have no site of their own; they take the site of the section or workspace they hang off, and
  hold the tag or user they name to it.

  A row whose link was written before this rule still takes an edit that leaves the link alone.

  The user a draft, an issue or a comment names is who wrote it: it is set when the record is
  created and no update takes it.
  """
  use MishkaDocument.DataCase, async: false

  require Ash.Query
  import Ash.Expr, only: [ref: 1]

  alias MishkaDocument.{
    Issue,
    IssueComment,
    Note,
    NoteDraft,
    Section,
    SectionBookmark,
    SectionDraft,
    SectionTag,
    SectionView,
    Tag,
    Workspace,
    WorkspaceFollower,
    WorkspaceVersion,
    WorkspaceVersionLineage
  }

  @moduletag :unit
  @moduletag :capture_log

  @refused "is not one this site can use"
  # How an action's own tenant check words its refusal.
  @not_found "not found"

  # {resource, the record's kind, the field, the kind of record it names, an edit that leaves it alone}
  @links [
    {Workspace, :workspace, :language_group_id, :workspace, :description},
    {WorkspaceVersion, :workspace_version, :workspace_id, :workspace, :description},
    {WorkspaceVersion, :workspace_version, :source_version_id, :workspace_version, :description},
    {WorkspaceVersionLineage, :lineage, :new_version_id, :workspace_version, :cloned_at},
    {WorkspaceVersionLineage, :lineage, :source_version_id, :workspace_version, :cloned_at},
    {Section, :section, :workspace_version_id, :workspace_version, :content},
    {Section, :section, :parent_section_id, :section, :content},
    {Section, :section, :language_group_id, :section, :content},
    {Section, :section, :section_lineage_id, :section, :content},
    {Section, :section, :source_section_id, :section, :content},
    {Note, :note, :section_id, :section, :content},
    {SectionDraft, :section_draft, :workspace_version_id, :workspace_version, :content},
    {SectionDraft, :section_draft, :source_section_id, :section, :content},
    {SectionDraft, :section_draft, :parent_section_id, :section, :content},
    {SectionDraft, :section_draft, :language_group_id, :section, :content},
    {SectionDraft, :section_draft, :created_by_user_id, :user, :content},
    {NoteDraft, :note_draft, :workspace_version_id, :workspace_version, :content},
    {NoteDraft, :note_draft, :section_id, :section, :content},
    {NoteDraft, :note_draft, :section_draft_id, :section_draft, :content},
    {NoteDraft, :note_draft, :source_note_id, :note, :content},
    {NoteDraft, :note_draft, :created_by_user_id, :user, :content},
    {Tag, :tag, :language_group_id, :tag, :name},
    {Issue, :issue, :note_id, :note, :description},
    {Issue, :issue, :section_id, :section, :description},
    {Issue, :issue, :reporter_id, :user, :description},
    {IssueComment, :issue_comment, :issue_id, :issue, :content},
    {IssueComment, :issue_comment, :contributor_id, :user, :content}
  ]

  setup do
    site = create_site!()
    other = create_site!()

    %{
      site: site,
      other: other,
      master: create_user_with_permissions!(["*"]),
      admin: create_user_with_permissions!(["*"], site_id: site.id),
      member: create_user!(site_id: site.id)
    }
  end

  defp unique, do: System.unique_integer([:positive])

  # One record of `kind` on `site_id`, built the way the factories build them.
  defp make(:workspace, site_id), do: create_workspace!(site_id: site_id, skip_version: true)
  defp make(:workspace_version, site_id), do: create_workspace_version!(site_id: site_id)
  defp make(:lineage, site_id), do: create_workspace_version_lineage!(site_id: site_id)
  defp make(:section, site_id), do: create_section!(site_id: site_id)
  defp make(:note, site_id), do: create_note!(site_id: site_id)
  defp make(:section_draft, site_id), do: create_section_draft!(site_id: site_id)
  defp make(:note_draft, site_id), do: create_note_draft!(site_id: site_id)
  defp make(:tag, site_id), do: create_document_tag!(site_id: site_id)
  defp make(:user, site_id), do: create_user!(site_id: site_id)

  defp make(:issue, site_id),
    do: create_issue!(site_id: site_id, reporter_id: create_user!(site_id: site_id).id)

  defp make(:issue_comment, site_id), do: create_issue_comment!(site_id: site_id)

  # What a new record of `kind` on `site_id` needs, its required links on its own site.
  defp new_attrs(:workspace, _site_id),
    do: %{name: "Workspace #{unique()}", slug: "ws-#{unique()}", status: :active, language: "en"}

  defp new_attrs(:workspace_version, site_id),
    do: %{
      workspace_id: make(:workspace, site_id).id,
      version_number: "9.#{unique()}.0",
      status: :draft
    }

  defp new_attrs(:lineage, site_id) do
    workspace = make(:workspace, site_id)
    source = create_workspace_version!(workspace_id: workspace.id, site_id: site_id)
    fresh = create_workspace_version!(workspace_id: workspace.id, site_id: site_id)
    %{new_version_id: fresh.id, source_version_id: source.id}
  end

  defp new_attrs(:section, site_id),
    do: %{
      workspace_version_id: make(:workspace_version, site_id).id,
      title: "Section #{unique()}",
      slug: "section-#{unique()}",
      language: "en"
    }

  defp new_attrs(:note, site_id),
    do: %{section_id: make(:section, site_id).id, title: "Note #{unique()}", content: "Body"}

  defp new_attrs(:section_draft, site_id),
    do: %{
      workspace_version_id: make(:workspace_version, site_id).id,
      title: "Draft #{unique()}",
      slug: "draft-#{unique()}",
      language: "en",
      change_version: "0.0.1",
      version_increment_type: :minor
    }

  defp new_attrs(:note_draft, site_id) do
    section = make(:section, site_id)

    %{
      workspace_version_id: section.workspace_version_id,
      section_id: section.id,
      title: "Note draft #{unique()}",
      content: "Body",
      change_version: "0.0.1",
      version_increment_type: :minor
    }
  end

  defp new_attrs(:tag, _site_id), do: %{name: "Tag #{unique()}", slug: "tag-#{unique()}"}

  defp new_attrs(:issue, site_id),
    do: %{
      title: "Issue #{unique()}",
      description: "Something is wrong",
      issue_type: :other,
      section_id: make(:section, site_id).id,
      reporter_id: make(:user, site_id).id
    }

  defp new_attrs(:issue_comment, site_id),
    do: %{
      issue_id: make(:issue, site_id).id,
      contributor_id: make(:user, site_id).id,
      content: "A comment"
    }

  # The value naming `target` in `field`, and what else the write needs to name it.
  defp link(:note_draft, :section_draft_id, draft),
    do: %{section_draft_id: draft.id, section_id: nil, change_version: draft.change_version}

  defp link(_kind, :language_group_id, target),
    do: %{language_group_id: target.id, language: "fa"}

  defp link(_kind, field, target), do: %{field => target.id}

  # A section, draft or note draft names the records of its own workspace version, and a section the
  # one it was copied from in another version of the same workspace (see
  # `MishkaDocument.WorkspaceVersionLinksTest`), so naming one of this site's puts the record there.
  @same_version [
    {:section, :parent_section_id},
    {:section_draft, :source_section_id},
    {:section_draft, :parent_section_id},
    {:note_draft, :section_id},
    {:note_draft, :section_draft_id}
  ]

  defp placed_link(kind, field, target, site_id),
    do: Map.merge(link(kind, field, target), placement(kind, field, target, site_id))

  defp placement(kind, field, target, _site_id) when {kind, field} in @same_version,
    do: %{workspace_version_id: target.workspace_version_id}

  # A version's source is one of its own document's versions.
  defp placement(:workspace_version, :source_version_id, source, _site_id),
    do: %{workspace_id: source.workspace_id}

  defp placement(:section, :source_section_id, source, site_id),
    do: %{workspace_version_id: another_version(source, site_id).id}

  defp placement(:note_draft, :source_note_id, note, _site_id) do
    section = reload(Section, %{id: note.section_id})
    %{section_id: section.id, workspace_version_id: section.workspace_version_id}
  end

  defp placement(:note_draft, :workspace_version_id, version, site_id),
    do: %{section_id: create_section!(site_id: site_id, workspace_version_id: version.id).id}

  defp placement(_kind, _field, _target, _site_id), do: %{}

  defp another_version(section, site_id) do
    %{workspace_id: workspace_id} =
      Ash.get!(WorkspaceVersion, section.workspace_version_id,
        action: :read_any,
        authorize?: false
      )

    create_workspace_version!(workspace_id: workspace_id, site_id: site_id)
  end

  defp copy_attrs(source, site_id),
    do:
      :section
      |> new_attrs(site_id)
      |> Map.merge(placed_link(:section, :source_section_id, source, site_id))

  defp accepts(resource, action) do
    %{accept: accept, arguments: arguments} = Ash.Resource.Info.action(resource, action)
    accept ++ Enum.map(arguments, & &1.name)
  end

  defp accepts?(resource, action, field), do: field in accepts(resource, action)

  defp create_action(ctx, :master, site_id),
    do: {:master_create, [actor: ctx.master], %{site_id: site_id}}

  defp create_action(ctx, :admin, site_id),
    do: {:create, [actor: ctx.admin, tenant: site_id], %{}}

  defp create_action(ctx, :system, site_id),
    do: {:create, [actor: ctx.member, tenant: site_id, authorize?: false], %{}}

  defp update_action(ctx, :master, _site_id), do: {:master_update, [actor: ctx.master]}
  defp update_action(ctx, :admin, site_id), do: {:update, [actor: ctx.admin, tenant: site_id]}
  defp update_action(_ctx, :system, site_id), do: {:update, [tenant: site_id, authorize?: false]}

  defp create_as(ctx, who, resource, site_id, attrs) do
    {action, opts, extra} = create_action(ctx, who, site_id)

    resource
    |> Ash.Changeset.for_create(
      action,
      attrs |> Map.merge(extra) |> Map.take(accepts(resource, action)),
      opts
    )
    |> Ash.create(opts)
  end

  defp update_as(ctx, who, resource, record, attrs) do
    {action, opts} = update_action(ctx, who, record.site_id)

    resource
    |> reload(record)
    |> Ash.Changeset.for_update(action, Map.take(attrs, accepts(resource, action)), opts)
    |> Ash.update(opts)
  end

  # Read back with no tenant attached, so a master's action can take it.
  defp reload(resource, record),
    do: Ash.get!(resource, record.id, action: :master_get, authorize?: false)

  defp refused?({:error, error}), do: Exception.message(error) =~ @refused
  defp refused?({:ok, _written}), do: false

  # Refused with one error on `field`. A write carrying the site as its tenant, the site admin's or
  # the system's, may be refused first by the action's own tenant check, in its words.
  defp refused_once?({:error, error}, field, who) do
    case for(%{field: ^field} = e <- Ash.Error.to_error_class(error).errors, do: e.message) do
      [message] -> message =~ @refused or (who != :master and message =~ @not_found)
      _none_or_several -> false
    end
  end

  defp refused_once?({:ok, _written}, _field, _who), do: false

  # Writes a link as it stood before the rule, past every check.
  defp write_raw!(resource, record, field, id) do
    table = AshPostgres.DataLayer.Info.table(resource)

    Ecto.Adapters.SQL.query!(
      MishkaDocument.Repo,
      "UPDATE #{table} SET #{field} = $1 WHERE id = $2",
      [Ecto.UUID.dump!(id), Ecto.UUID.dump!(record.id)]
    )
  end

  defp view(section, actor, opts),
    do:
      SectionView
      |> Ash.Changeset.for_create(
        :create,
        %{section_id: section.id, ip_address: "203.0.113.#{rem(unique(), 250) + 1}"},
        [actor: actor] ++ opts
      )
      |> Ash.create([actor: actor] ++ opts)

  defp bookmark(section, actor, opts),
    do:
      SectionBookmark
      |> Ash.Changeset.for_create(:create, %{section_id: section.id}, [actor: actor] ++ opts)
      |> Ash.create([actor: actor] ++ opts)

  defp follow(workspace, actor, opts),
    do:
      WorkspaceFollower
      |> Ash.Changeset.for_create(:create, %{workspace_id: workspace.id}, [actor: actor] ++ opts)
      |> Ash.create([actor: actor] ++ opts)

  defp unrelated_edit(:cloned_at), do: %{cloned_at: DateTime.add(DateTime.utc_now(), -60)}
  defp unrelated_edit(field), do: %{field => "Edited #{unique()}"}

  for {resource, kind, field, target_kind, edit} <- @links do
    @link {resource, kind, field, target_kind, edit}

    describe "#{inspect(resource)}.#{field}" do
      test "never names another site's #{target_kind}, whoever writes it", ctx do
        {resource, kind, field, target_kind, _edit} = @link
        theirs = make(target_kind, ctx.other.id)

        creates =
          for who <- [:master, :admin, :system],
              accepts?(resource, elem(create_action(ctx, who, ctx.site.id), 0), field) do
            attrs = Map.merge(new_attrs(kind, ctx.site.id), link(kind, field, theirs))
            {who, :create, create_as(ctx, who, resource, ctx.site.id, attrs)}
          end

        updates =
          for who <- [:master, :admin, :system],
              accepts?(resource, elem(update_action(ctx, who, ctx.site.id), 0), field) do
            record = make(kind, ctx.site.id)
            result = update_as(ctx, who, resource, record, link(kind, field, theirs))
            assert Map.get(reload(resource, record), field) == Map.get(record, field)
            {who, :update, result}
          end

        assert Enum.any?(creates ++ updates, &(elem(&1, 0) == :master))

        for {who, write, result} <- creates ++ updates do
          assert refused_once?(result, field, who),
                 "#{who} #{write} of #{inspect(resource)}.#{field} named another site's " <>
                   "#{target_kind} and was not refused once: #{inspect(result)}"
        end
      end

      test "names its own site's #{target_kind}", ctx do
        {resource, kind, field, target_kind, _edit} = @link
        ours = make(target_kind, ctx.site.id)

        named = placed_link(kind, field, ours, ctx.site.id)

        result =
          if accepts?(resource, :master_update, field) do
            update_as(ctx, :master, resource, make(kind, ctx.site.id), named)
          else
            attrs = Map.merge(new_attrs(kind, ctx.site.id), named)
            create_as(ctx, :master, resource, ctx.site.id, attrs)
          end

        assert {:ok, written} = result
        assert Map.get(written, field) == ours.id
      end

      test "a #{target_kind} named before the rule does not stop an edit elsewhere", ctx do
        {resource, kind, field, target_kind, edit} = @link
        record = make(kind, ctx.site.id)
        theirs = make(target_kind, ctx.other.id)
        write_raw!(resource, record, field, theirs.id)

        assert {:ok, edited} =
                 update_as(ctx, :master, resource, record, unrelated_edit(edit))

        assert Map.get(edited, field) == theirs.id
      end
    end
  end

  describe "a user named by a site's record" do
    for {resource, kind, field} <- [
          {SectionDraft, :section_draft, :created_by_user_id},
          {NoteDraft, :note_draft, :created_by_user_id},
          {Issue, :issue, :reporter_id},
          {IssueComment, :issue_comment, :contributor_id}
        ] do
      @user_link {resource, kind, field}

      test "#{inspect(resource)}.#{field} may be a master", ctx do
        {resource, kind, field} = @user_link
        attrs = Map.put(new_attrs(kind, ctx.site.id), field, ctx.master.id)

        assert {:ok, written} = create_as(ctx, :master, resource, ctx.site.id, attrs)
        assert Map.get(written, field) == ctx.master.id
      end

      test "#{inspect(resource)}.#{field} is who wrote it, and no update changes it", ctx do
        {resource, kind, field} = @user_link
        record = make(kind, ctx.site.id)
        someone_else = make(:user, ctx.site.id)

        for who <- [:master, :admin, :system] do
          {action, opts} = update_action(ctx, who, record.site_id)

          assert {:error, %Ash.Error.Invalid{errors: errors}} =
                   resource
                   |> reload(record)
                   |> Ash.Changeset.for_update(action, %{field => someone_else.id}, opts)
                   |> Ash.update(opts)

          assert Enum.any?(errors, &match?(%Ash.Error.Invalid.NoSuchInput{input: ^field}, &1)),
                 "#{who}'s #{action} of #{inspect(resource)} changed #{field}"
        end

        assert Map.get(reload(resource, record), field) == Map.get(record, field)
      end
    end
  end

  describe "an update that keeps a record on its site" do
    test "says so in its description", _ctx do
      silent =
        for resource <- Ash.Domain.Info.resources(MishkaDocument),
            Ash.Resource.Info.attribute(resource, :site_id),
            name <- [:update, :master_update],
            %{accept: accept, description: description} <- [
              Ash.Resource.Info.action(resource, name)
            ],
            :site_id not in accept,
            not String.contains?(description || "", "prevents site_id"),
            do: {resource, name}

      assert silent == []
    end
  end

  describe "a section's tags" do
    test "never pair a section with another site's tag, whoever writes the row", ctx do
      section = make(:section, ctx.site.id)
      theirs = make(:tag, ctx.other.id)

      assert refused?(
               SectionTag
               |> Ash.Changeset.for_create(:assign, %{section_id: section.id, tag_id: theirs.id},
                 authorize?: false
               )
               |> Ash.create(authorize?: false)
             )

      assert refused?(update_as(ctx, :master, Section, section, %{tag_ids: [theirs.id]}))

      assert [] ==
               SectionTag
               |> Ash.Query.filter(section_id == ^section.id)
               |> Ash.read!(authorize?: false)
    end

    test "pair a section with its own site's tag", ctx do
      section = make(:section, ctx.site.id)
      ours = make(:tag, ctx.site.id)
      another = make(:tag, ctx.site.id)

      assert {:ok, _row} =
               SectionTag
               |> Ash.Changeset.for_create(:assign, %{section_id: section.id, tag_id: ours.id},
                 authorize?: false
               )
               |> Ash.create(authorize?: false)

      assert {:ok, _section} =
               update_as(ctx, :master, Section, section, %{tag_ids: [ours.id, another.id]})

      assert 2 ==
               SectionTag
               |> Ash.Query.filter(section_id == ^section.id)
               |> Ash.count!(authorize?: false)
    end
  end

  describe "a section's lineage" do
    test "takes a clone whose lineage's first section is gone, whoever writes it", ctx do
      first = make(:section, ctx.site.id)

      clone =
        create_section!(
          site_id: ctx.site.id,
          workspace_version_id: another_version(first, ctx.site.id).id,
          source_section_id: first.id
        )

      assert clone.section_lineage_id == first.id

      assert {:ok, clone} = update_as(ctx, :master, Section, clone, %{source_section_id: nil})

      assert :ok =
               Ash.destroy(reload(Section, first),
                 action: :master_permanent_destroy,
                 actor: ctx.master
               )

      for who <- [:master, :admin, :system] do
        attrs = copy_attrs(clone, ctx.site.id)

        assert {:ok, written} = create_as(ctx, who, Section, ctx.site.id, attrs),
               "#{who} could not clone a section of a lineage whose first section is gone"

        assert written.section_lineage_id == first.id
      end
    end

    test "never comes from another site through the section it clones, whoever writes it", ctx do
      source = make(:section, ctx.site.id)
      theirs = make(:section, ctx.other.id)
      write_raw!(Section, source, :section_lineage_id, theirs.id)

      for who <- [:master, :admin, :system] do
        attrs = copy_attrs(source, ctx.site.id)

        assert refused?(create_as(ctx, who, Section, ctx.site.id, attrs)),
               "#{who} cloned a section into another site's lineage"
      end

      assert [source.id] ==
               Section
               |> Ash.Query.filter(section_lineage_id == ^theirs.id)
               |> Ash.read!(tenant: ctx.site.id, authorize?: false)
               |> Enum.map(& &1.id)
    end
  end

  describe "who views, bookmarks or follows" do
    test "is never another site's user, even when the system writes the row", ctx do
      stranger = make(:user, ctx.other.id)
      section = make(:section, ctx.site.id)
      workspace = make(:workspace, ctx.site.id)

      for write <- [
            &view(section, &1, &2),
            &bookmark(section, &1, &2),
            &follow(workspace, &1, &2)
          ] do
        assert refused?(write.(stranger, authorize?: false))

        # Writing for the site, the stranger is refused once, by the action's tenant check.
        assert {:error, error} = write.(stranger, tenant: ctx.site.id)
        assert [refusal] = Ash.Error.to_error_class(error).errors
        assert refusal.message =~ @not_found
      end

      for {resource, field} <- [
            {SectionView, :user_id},
            {SectionBookmark, :user_id},
            {WorkspaceFollower, :follower_user_id}
          ] do
        refute resource
               |> Ash.Query.filter(^ref(field) == ^stranger.id)
               |> Ash.exists?(authorize?: false)
      end
    end

    test "a bookmark never moves to another site's section, whoever writes it", ctx do
      {:ok, kept} = bookmark(make(:section, ctx.site.id), ctx.member, tenant: ctx.site.id)
      theirs = make(:section, ctx.other.id)

      for %{type: :update, name: action} <- Ash.Resource.Info.actions(SectionBookmark),
          opts <- [
            [authorize?: false],
            [actor: ctx.master, tenant: ctx.other.id],
            [actor: ctx.member, tenant: ctx.site.id]
          ] do
        assert {:error, _} =
                 kept
                 |> Ash.Changeset.for_update(action, %{section_id: theirs.id}, opts)
                 |> Ash.update(opts),
               "#{action} moved a bookmark to another site's section with #{inspect(opts)}"
      end

      assert Ash.get!(SectionBookmark, kept.id, authorize?: false).section_id == kept.section_id
    end

    test "is the site's own user, a master or a guest", ctx do
      section = make(:section, ctx.site.id)
      workspace = make(:workspace, ctx.site.id)

      for actor <- [ctx.member, ctx.master] do
        assert {:ok, _} = view(section, actor, tenant: ctx.site.id)
        assert {:ok, _} = bookmark(section, actor, tenant: ctx.site.id)
        assert {:ok, _} = follow(workspace, actor, tenant: ctx.site.id)
      end

      assert {:ok, %{user_id: nil}} = view(section, nil, tenant: ctx.site.id)
    end
  end

  describe "the dev seeds" do
    test "never make another site's user an author, even when handed only such users", ctx do
      stranger = make(:user, ctx.other.id)

      assert :ok =
               MishkaDocument.Dev.Seeds.stress_seed(ctx.site.id, [stranger],
                 workspaces: 3,
                 versions_per_workspace: 1,
                 sections_per_version: 2,
                 notes_per_section: 1,
                 issues: 2,
                 tags: 1
               )

      for {resource, field} <- [
            {SectionDraft, :created_by_user_id},
            {NoteDraft, :created_by_user_id},
            {Issue, :reporter_id},
            {IssueComment, :contributor_id},
            {SectionView, :user_id},
            {SectionBookmark, :user_id},
            {WorkspaceFollower, :follower_user_id}
          ] do
        refute resource
               |> Ash.Query.filter(^ref(field) == ^stranger.id)
               |> Ash.exists?(tenant: ctx.site.id, authorize?: false),
               "#{inspect(resource)}.#{field} names another site's user"
      end
    end
  end

  describe "the admin form pickers" do
    alias MishkaGervaz.Resource.Info.Form

    defp site_owned?(resource),
      do:
        resource != MishkaCmsCore.Runtime.Site and
          not is_nil(Ash.Resource.Info.attribute(resource, :site_id))

    defp pickers do
      for resource <- Ash.Domain.Info.resources(MishkaDocument),
          fields = Form.fields(resource),
          field <- fields,
          field.type == :relation and field.name != :site_id and site_owned?(field.resource),
          do: {resource, field, fields}
    end

    defp site_chain(%{depends_on: :site_id}, _fields), do: true
    defp site_chain(%{depends_on: nil}, _fields), do: false

    defp site_chain(%{depends_on: parent}, fields) do
      case Enum.find(fields, &(&1.name == parent)) do
        nil -> false
        field -> site_chain(field, fields)
      end
    end

    test "offer a site's records only once the form's site is known" do
      offenders =
        for {resource, field, fields} <- pickers(),
            field.readonly != true and not site_chain(field, fields),
            do: "#{inspect(resource)}.#{field.name}"

      assert offenders == []
    end

    test "narrow a master's options to the value of the field each one follows", ctx do
      for {resource, %{load: load, depends_on: parent} = field, _fields} <- pickers(),
          is_function(load, 2) do
        chosen = Ash.UUID.generate()

        state = %{
          master_user?: true,
          current_user: ctx.master,
          field_values: %{parent => chosen},
          defaults: %{}
        }

        query = load.(Ash.Query.new(field.resource), state)

        assert inspect(query.filter) =~ chosen,
               "#{inspect(resource)}.#{field.name} does not follow #{inspect(parent)}"
      end
    end
  end
end
