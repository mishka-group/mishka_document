defmodule MishkaDocument.Test.Factory do
  @moduledoc """
  Fixtures for this extension's suite — the document's own records, plus the accounts and runtime
  ones a document record cannot exist without (a workspace belongs to a site, a bookmark to a user).

  The generators themselves are not copied. `MishkaDocument.Dev.Generator` and
  `MishkaCmsCore.Dev.Generator` both ship in `lib/`, so this builds on exactly what the CMS's own
  factory builds on; only the `create_*!` wrappers live here, because the CMS's factory sits in the
  CMS's `test/support` where a dependency cannot reach it.

  Document records are tenant-scoped, so each wrapper pops `:site_id` and passes it as the Ash tenant.
  """

  import MishkaDocument.Dev.Generator, except: [generate: 1, generate: 2]
  import MishkaCmsCore.Dev.Generator, except: [generate: 1, generate: 2]
  import Ash.Generator, only: [generate: 1]

  require Ash.Query

  def create_site!(overrides \\ []) do
    overrides
    |> site()
    |> generate()
  end

  # Component factory
  def create_component!(overrides \\ []) do
    {site_id, overrides} = Keyword.pop(overrides, :site_id)

    tenant = site_id

    overrides
    |> component(tenant)
    |> generate()
  end

  # Layout factory
  def create_layout!(overrides \\ []) do
    {site_id, overrides} = Keyword.pop(overrides, :site_id)
    tenant = site_id

    overrides
    |> layout(tenant)
    |> generate()
  end

  # ErrorPage factory
  def create_error_page!(overrides \\ []) do
    {site_id, overrides} = Keyword.pop(overrides, :site_id)

    # ErrorPage MUST have a site_id (not global)
    site_id = site_id || create_site!().id
    tenant = site_id

    overrides
    |> error_page(tenant)
    |> generate()
  end

  # JsHook factory
  def create_js_hook!(overrides \\ []) do
    {site_id, overrides} = Keyword.pop(overrides, :site_id)
    tenant = site_id

    overrides
    |> js_hook(tenant)
    |> generate()
  end

  # Page factory
  def create_page!(overrides \\ []) do
    {site_id, overrides} = Keyword.pop(overrides, :site_id)
    # Page MUST have a site_id (not global)
    site_id = site_id || create_site!().id
    tenant = site_id

    overrides
    |> page(tenant)
    |> generate()
  end

  # User factory
  def create_user!(overrides \\ []) do
    {site_id, overrides} = Keyword.pop(overrides, :site_id)
    # User can be global (nil) or site-specific
    tenant = site_id

    overrides
    |> user(tenant)
    |> generate()
  end

  # Permission factory
  def create_permission!(overrides \\ []) do
    overrides
    |> permission()
    |> generate()
  end

  @doc """
  A user holding `permission_names`, returned with `:permissions` loaded so it can be used directly
  as an Ash `actor:` without a further load.

  Authorization in this CMS turns on two independent things — WHICH permissions a user holds and
  WHICH site they belong to — so most policy tests need the same three actors: a master
  (`site_id: nil`) with roles, a tenant with the same roles, and a tenant with none. Permissions are
  looked up before being created so several actors can share one named permission in a test.

      master = create_user_with_permissions!(["admin:dashboard:*"])
      tenant = create_user_with_permissions!(["admin:dashboard:*"], site_id: site.id)
      nobody = create_user!(site_id: site.id)
  """
  def create_user_with_permissions!(permission_names, overrides \\ []) do
    user = create_user!(overrides)
    permission_ids = Enum.map(permission_names, &find_or_create_permission!(&1).id)

    user
    |> Ash.Changeset.for_update(:assign_permissions, %{permission_ids: permission_ids},
      authorize?: false,
      tenant: user.site_id
    )
    |> Ash.update!()
    |> Ash.load!([:permissions], authorize?: false, tenant: user.site_id)
  end

  defp find_or_create_permission!(name) do
    MishkaCmsCore.Accounts.Permission
    |> Ash.Query.filter(name == ^name)
    |> Ash.read_one(authorize?: false)
    |> case do
      {:ok, nil} -> create_permission!(name: name)
      {:ok, permission} -> permission
    end
  end

  # MediaCategory factory

  # Workspace factory
  def create_workspace!(overrides \\ []) do
    {site_id, overrides} = Keyword.pop(overrides, :site_id)
    {skip_version, overrides} = Keyword.pop(overrides, :skip_version, false)

    # Workspace MUST have a site_id (not global)
    site_id = site_id || create_site!().id
    tenant = site_id

    # Step 1: Create workspace (no version_ids needed)
    workspace =
      overrides
      |> workspace(tenant)
      |> generate()

    # Step 2: Create a default version unless skip_version is true
    unless skip_version do
      _version = create_workspace_version!(workspace_id: workspace.id, site_id: site_id)
    end

    workspace
  end

  # WorkspaceVersion factory
  def create_workspace_version!(overrides \\ []) do
    {site_id, overrides} = Keyword.pop(overrides, :site_id)
    {workspace_id, overrides} = Keyword.pop(overrides, :workspace_id)

    {site_id, workspace_id} =
      cond do
        site_id && workspace_id ->
          {site_id, workspace_id}

        workspace_id ->
          workspace =
            Ash.get!(MishkaDocument.Workspace, workspace_id,
              action: :master_get,
              authorize?: false
            )

          {workspace.site_id, workspace.id}

        site_id ->
          workspace = create_workspace!(site_id: site_id)
          {site_id, workspace.id}

        true ->
          workspace = create_workspace!()
          {workspace.site_id, workspace.id}
      end

    tenant = site_id

    overrides
    |> Keyword.put(:workspace_id, workspace_id)
    |> workspace_version(tenant)
    |> generate()
  end

  # WorkspaceVersionLineage factory
  def create_workspace_version_lineage!(overrides \\ []) do
    {new_version_id, overrides} = Keyword.pop(overrides, :new_version_id)
    {source_version_id, overrides} = Keyword.pop(overrides, :source_version_id)
    {site_id, overrides} = Keyword.pop(overrides, :site_id)

    # An explicit past cloned_at keeps lineage timestamps deterministic across a test run.
    overrides =
      Keyword.put_new(
        overrides,
        :cloned_at,
        DateTime.utc_now() |> DateTime.add(-3600, :second) |> DateTime.truncate(:second)
      )

    # If new_version_id not provided, create a new version
    if is_nil(new_version_id) && is_nil(source_version_id) do
      # Create both versions in same workspace
      site_id = site_id || create_site!().id
      workspace = create_workspace!(site_id: site_id)
      source = create_workspace_version!(workspace_id: workspace.id, site_id: site_id)
      new_version = create_workspace_version!(workspace_id: workspace.id, site_id: site_id)
      tenant = site_id

      overrides
      |> Keyword.put(:new_version_id, new_version.id)
      |> Keyword.put(:source_version_id, source.id)
      |> workspace_version_lineage(tenant)
      |> generate()
    else
      # Extract site_id from one of the provided versions
      version_for_site =
        cond do
          new_version_id ->
            Ash.get!(MishkaDocument.WorkspaceVersion, new_version_id,
              action: :master_get,
              authorize?: false
            )

          source_version_id ->
            Ash.get!(MishkaDocument.WorkspaceVersion, source_version_id,
              action: :master_get,
              authorize?: false
            )

          true ->
            nil
        end

      site_id = site_id || version_for_site.site_id
      tenant = site_id

      # If only one version provided, create the other
      new_version_id =
        new_version_id ||
          create_workspace_version!(
            workspace_id: version_for_site.workspace_id,
            site_id: site_id
          ).id

      source_version_id =
        source_version_id ||
          create_workspace_version!(
            workspace_id: version_for_site.workspace_id,
            site_id: site_id
          ).id

      overrides
      |> Keyword.put(:new_version_id, new_version_id)
      |> Keyword.put(:source_version_id, source_version_id)
      |> workspace_version_lineage(tenant)
      |> generate()
    end
  end

  # Section factory
  def create_section!(overrides \\ []) do
    {site_id, overrides} = Keyword.pop(overrides, :site_id)
    {workspace_version_id, overrides} = Keyword.pop(overrides, :workspace_version_id)

    # Section MUST have site_id and workspace_version_id
    site_id = site_id || create_site!().id

    workspace_version_id =
      workspace_version_id ||
        create_workspace_version!(
          workspace_id: create_workspace!(site_id: site_id).id,
          site_id: site_id
        ).id

    tenant = site_id

    overrides
    |> Keyword.put(:site_id, site_id)
    |> Keyword.put(:workspace_version_id, workspace_version_id)
    |> section(tenant)
    |> generate()
  end

  # SectionBookmark factory
  def create_section_bookmark!(overrides \\ []) do
    {user_id, overrides} = Keyword.pop(overrides, :user_id)
    {section_id, _overrides} = Keyword.pop(overrides, :section_id)

    # SectionBookmark requires both user and section
    # Get or create user (need full user struct for actor)
    user =
      if user_id do
        Ash.get!(MishkaCmsCore.Accounts.User, user_id, authorize?: false)
      else
        create_user!()
      end

    section_id =
      section_id ||
        create_section!(
          content_review_status: :approved,
          technical_review_status: :approved
        ).id

    # Use the create action with actor (which uses relate_actor)
    MishkaDocument.SectionBookmark
    |> Ash.Changeset.for_create(
      :create,
      %{section_id: section_id},
      actor: user,
      authorize?: false
    )
    |> Ash.create!()
  end

  # Document Tag factory (MishkaDocument.Tag)
  def create_document_tag!(overrides \\ []) do
    {site_id, overrides} = Keyword.pop(overrides, :site_id)
    # Tag MUST have a site_id (not global)
    site_id = site_id || create_site!().id
    tenant = site_id

    overrides
    |> document_tag(tenant)
    |> generate()
  end

  # Note factory (MishkaDocument.Note)
  def create_note!(overrides \\ []) do
    {site_id, overrides} = Keyword.pop(overrides, :site_id)
    {section_id, overrides} = Keyword.pop(overrides, :section_id)

    # Note MUST have a site_id (not global) and section_id
    site_id = site_id || create_site!().id
    section_id = section_id || create_section!(site_id: site_id).id
    tenant = site_id

    overrides
    |> Keyword.put(:section_id, section_id)
    |> note(tenant)
    |> generate()
  end

  # SectionTag factory (MishkaDocument.SectionTag - join table)
  def create_section_tag!(overrides \\ []) do
    # Get or create section_id and tag_id
    {section_id, overrides} = Keyword.pop(overrides, :section_id)
    {tag_id, overrides} = Keyword.pop(overrides, :tag_id)

    section_id = section_id || create_section!().id

    # A tag of the section's own site: a section is never tagged with another site's tag.
    tag_id =
      tag_id ||
        create_document_tag!(
          site_id:
            Ash.get!(MishkaDocument.Section, section_id, action: :master_get, authorize?: false).site_id
        ).id

    overrides
    |> Keyword.put(:section_id, section_id)
    |> Keyword.put(:tag_id, tag_id)
    |> section_tag(nil)
    |> generate()
  end

  # Issue factory (MishkaDocument.Issue)
  def create_issue!(overrides \\ []) do
    {site_id, overrides} = Keyword.pop(overrides, :site_id)
    {reporter_id, overrides} = Keyword.pop(overrides, :reporter_id)
    {section_id, overrides} = Keyword.pop(overrides, :section_id)
    {note_id, overrides} = Keyword.pop(overrides, :note_id)

    # Issue MUST have a site_id (not global)
    site_id = site_id || create_site!().id

    # Get or create reporter user (will be used as actor)
    reporter =
      if reporter_id do
        Ash.get!(MishkaCmsCore.Accounts.User, reporter_id, authorize?: false)
      else
        create_user!()
      end

    # Issue MUST have either section_id or note_id (or both)
    # If neither provided, create a section
    {section_id, note_id} =
      case {section_id, note_id} do
        {nil, nil} ->
          created_section_id = create_section!(site_id: site_id).id
          {created_section_id, nil}

        {s, n} ->
          {s, n}
      end

    tenant = site_id

    # Build attributes map with defaults
    attrs =
      %{
        title: "Test Issue",
        description: "Test issue description",
        issue_type: :other
      }
      |> Map.merge(Enum.into(overrides, %{}))
      |> Map.put_new(:section_id, section_id)
      |> Map.put_new(:note_id, note_id)
      |> Map.reject(fn {_k, v} -> is_nil(v) end)

    # Create issue with actor (reporter will be set from actor automatically)
    MishkaDocument.Issue
    |> Ash.Changeset.for_create(:create, attrs,
      actor: reporter,
      tenant: tenant,
      authorize?: false
    )
    |> Ash.create!()
  end

  # IssueComment factory (MishkaDocument.IssueComment)
  def create_issue_comment!(overrides \\ []) do
    {site_id, overrides} = Keyword.pop(overrides, :site_id)
    {contributor_id, overrides} = Keyword.pop(overrides, :contributor_id)
    {issue_id, overrides} = Keyword.pop(overrides, :issue_id)

    # IssueComment MUST have a site_id (not global)
    site_id = site_id || create_site!().id

    # Get or create contributor user (will be used as actor). The default is a user of the comment's
    # own site: a master's comment is read-only to that site's admins, so defaulting to a master
    # would make every comment one a tenant cannot change. Pass a master's id to get one.
    contributor =
      if contributor_id do
        Ash.get!(MishkaCmsCore.Accounts.User, contributor_id, authorize?: false)
      else
        create_user!(site_id: site_id)
      end

    # IssueComment MUST have an issue_id
    issue_id = issue_id || create_issue!(site_id: site_id).id

    tenant = site_id

    # Build attributes map with defaults
    attrs =
      %{
        content: "Test comment content"
      }
      |> Map.merge(Enum.into(overrides, %{}))
      |> Map.put(:issue_id, issue_id)
      |> Map.reject(fn {_k, v} -> is_nil(v) end)

    # Create comment with actor (contributor will be set from actor automatically)
    MishkaDocument.IssueComment
    |> Ash.Changeset.for_create(:create, attrs,
      actor: contributor,
      tenant: tenant,
      authorize?: false
    )
    |> Ash.create!()
  end

  # SectionDraft factory (MishkaDocument.SectionDraft)
  def create_section_draft!(overrides \\ []) do
    {site_id, overrides} = Keyword.pop(overrides, :site_id)
    {workspace_version_id, overrides} = Keyword.pop(overrides, :workspace_version_id)

    # SectionDraft MUST have site_id and workspace_version_id
    site_id = site_id || create_site!().id

    workspace_version_id =
      workspace_version_id ||
        create_workspace_version!(
          workspace_id: create_workspace!(site_id: site_id, skip_version: true).id,
          site_id: site_id,
          status: :draft
        ).id

    tenant = site_id

    overrides
    |> Keyword.put(:site_id, site_id)
    |> Keyword.put(:workspace_version_id, workspace_version_id)
    |> section_draft(tenant)
    |> generate()
  end

  # NoteDraft factory (MishkaDocument.NoteDraft)
  def create_note_draft!(overrides \\ []) do
    {site_id, overrides} = Keyword.pop(overrides, :site_id)
    {section_id, overrides} = Keyword.pop(overrides, :section_id)
    {workspace_version_id, overrides} = Keyword.pop(overrides, :workspace_version_id)

    # NoteDraft requires workspace_version_id AND (section_id XOR section_draft_id)
    site_id = site_id || create_site!().id

    # If neither section_id nor workspace_version_id provided, create both
    {section_id, workspace_version_id} =
      if is_nil(section_id) && is_nil(workspace_version_id) do
        section = create_section!(site_id: site_id)
        {section.id, section.workspace_version_id}
      else
        # If only workspace_version_id provided, create a section in that version
        if is_nil(section_id) && workspace_version_id do
          section =
            create_section!(site_id: site_id, workspace_version_id: workspace_version_id)

          {section.id, workspace_version_id}
        else
          # section_id provided, get workspace_version_id if needed
          if section_id && is_nil(workspace_version_id) do
            section =
              Ash.get!(MishkaDocument.Section, section_id,
                action: :master_get,
                authorize?: false
              )

            {section_id, section.workspace_version_id}
          else
            {section_id, workspace_version_id}
          end
        end
      end

    tenant = site_id

    overrides
    |> Keyword.put(:site_id, site_id)
    |> Keyword.put(:workspace_version_id, workspace_version_id)
    |> Keyword.put(:section_id, section_id)
    |> Keyword.put(:section_draft_id, nil)
    |> note_draft(tenant)
    |> generate()
  end
end
