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
end
