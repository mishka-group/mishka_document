defmodule MishkaDocument.Dev.Generator do
  @moduledoc """
  Generator for MishkaDocument resources.
  - Test functions (no prefix): simple, deterministic — used by factory and tests.
  - Dev functions (dev_ prefix): realistic, rich data — used by dev seeds.

  Every generator takes the tenant (where the resource is site-scoped) and the actor as trailing
  optional arguments. The actor matters beyond authorization: `MishkaDocument.EventLog` persists it
  as `actor_id`, and `MishkaDocument.Resources.Calculations.WorkspaceMaintainers` derives a
  workspace's maintainer list purely from those event rows, so a create without an actor produces a
  workspace nobody appears to maintain.

  `status: :archived` on `workspace_version/3` is a plain label — `MishkaDocument.WorkspaceVersion`
  has no AshArchival and its `:destroy` is a hard delete, so the label is the only way to express an
  archived version. It is deliberately absent from `workspace/3`: `MishkaDocument.Workspace` carries
  `archived_at`, and a workspace holding only the status label renders as archived while still
  sitting in the Active tab.
  """
  use Ash.Generator

  # ---------------------------------------------------------------------------
  # TEST generators
  # ---------------------------------------------------------------------------

  def workspace(opts \\ [], tenant \\ nil, actor \\ nil) do
    changeset_generator(
      MishkaDocument.Workspace,
      :create,
      authorize?: false,
      actor: actor,
      defaults: [
        name: sequence(:name, &"Test Workspace #{&1}"),
        slug: sequence(:slug, &"test-workspace-#{&1}"),
        description: sequence(:description, &"Test workspace description #{&1}"),
        status: StreamData.member_of([:active, :draft]),
        schema: [],
        seo_tags: [],
        permissions: [],
        featured: false,
        display_order: 0,
        language: "en",
        language_group_id: nil,
        site_id: nil
      ],
      overrides: opts,
      tenant: tenant
    )
  end

  def workspace_version(opts \\ [], tenant \\ nil, actor \\ nil) do
    changeset_generator(
      MishkaDocument.WorkspaceVersion,
      :create,
      authorize?: false,
      actor: actor,
      defaults: [
        workspace_id: nil,
        version_number: sequence(:version_number, &"0.0.#{&1}"),
        version_name: sequence(:version_name, &"Test Version #{&1}"),
        description: sequence(:description, &"Test version description #{&1}"),
        status: StreamData.member_of([:draft, :alpha, :beta, :archived]),
        is_latest_for_version: false,
        source_version_id: nil,
        published_at: nil,
        site_id: nil
      ],
      overrides: opts,
      tenant: tenant
    )
  end
end
