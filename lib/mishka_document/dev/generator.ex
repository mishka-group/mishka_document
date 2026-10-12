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

  @workspace_names [
    "Product Documentation",
    "API Reference",
    "User Guide",
    "Developer Handbook",
    "Architecture Overview",
    "Operations Runbook",
    "Security Guidelines",
    "Onboarding Guide",
    "Style Guide",
    "Release Notes"
  ]

  @section_titles [
    "Introduction",
    "Getting Started",
    "Installation",
    "Configuration",
    "Core Concepts",
    "Advanced Usage",
    "Troubleshooting",
    "FAQ",
    "Best Practices",
    "Migration Guide",
    "Changelog",
    "Contributing"
  ]

  @note_titles [
    "Implementation Note",
    "Performance Consideration",
    "Security Warning",
    "Deprecation Notice",
    "Known Limitation",
    "Design Decision",
    "Open Question",
    "TODO",
    "Reference",
    "Example"
  ]

  @issue_types [:typo, :broken_link, :incorrect_content, :suggestion, :review_feedback, :other]
  @issue_statuses [:open, :in_progress, :resolved, :closed]

  @tag_names [
    "api",
    "authentication",
    "authorization",
    "caching",
    "configuration",
    "deployment",
    "error-handling",
    "events",
    "logging",
    "migrations",
    "performance",
    "security",
    "testing",
    "webhooks",
    "workers"
  ]

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
        path: nil,
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

  def workspace_follower(opts \\ [], actor \\ nil) do
    changeset_generator(
      MishkaDocument.WorkspaceFollower,
      :create,
      authorize?: false,
      defaults: [
        workspace_id: nil,
        follower_user_id: nil,
        notification_enabled: true
      ],
      overrides: opts,
      actor: actor
    )
  end

  def workspace_version_lineage(opts \\ [], tenant \\ nil) do
    changeset_generator(
      MishkaDocument.WorkspaceVersionLineage,
      :create,
      authorize?: false,
      defaults: [
        new_version_id: nil,
        source_version_id: nil
      ],
      overrides: opts,
      tenant: tenant
    )
  end

  def section(opts \\ [], tenant \\ nil, actor \\ nil) do
    changeset_generator(
      MishkaDocument.Section,
      :create,
      authorize?: false,
      actor: actor,
      defaults: [
        title: sequence(:title, &"Test Section #{&1}"),
        slug: sequence(:slug, &"test-section-#{&1}"),
        content: sequence(:content, &"Test section content #{&1}"),
        order_position: 0,
        front_page: false,
        group_heading: false,
        group_page: false,
        change_version: "0.0.1",
        content_review_status: :pending,
        technical_review_status: :pending,
        schema: [],
        seo_tags: [],
        permissions: [],
        language: "en",
        language_group_id: nil,
        workspace_version_id: nil,
        parent_section_id: nil,
        section_lineage_id: nil,
        source_section_id: nil,
        site_id: nil,
        tag_ids: []
      ],
      overrides: opts,
      tenant: tenant
    )
  end

  def section_bookmark(opts \\ [], actor \\ nil) do
    changeset_generator(
      MishkaDocument.SectionBookmark,
      :create,
      authorize?: false,
      actor: actor,
      defaults: [
        section_id: nil,
        user_id: nil
      ],
      overrides: opts,
      tenant: nil
    )
  end

  @doc """
  Tracks one page view of a section.

  `MishkaDocument.SectionView` is not site-scoped and takes no tenant. The view belongs to `actor`,
  and a nil `actor` with a distinct `ip_address` is a guest view. The create action upserts on
  `{section_id, user_id, ip_address}`, so repeated rows collapse instead of failing.
  """
  def section_view(opts \\ [], actor \\ nil) do
    changeset_generator(
      MishkaDocument.SectionView,
      :create,
      authorize?: false,
      actor: actor,
      defaults: [
        section_id: nil,
        ip_address: sequence(:section_view_ip, &"203.0.113.#{rem(&1, 254) + 1}"),
        user_agent:
          "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0 Safari/537.36",
        referer: nil
      ],
      overrides: opts,
      tenant: nil
    )
  end

  def document_tag(opts \\ [], tenant \\ nil, actor \\ nil) do
    changeset_generator(
      MishkaDocument.Tag,
      :create,
      authorize?: false,
      actor: actor,
      defaults: [
        name: sequence(:name, &"Test Document Tag #{&1}"),
        slug: sequence(:slug, &"test-document-tag-#{&1}"),
        language: "en",
        language_group_id: nil,
        site_id: nil
      ],
      overrides: opts,
      tenant: tenant
    )
  end

  def note(opts \\ [], tenant \\ nil, actor \\ nil) do
    changeset_generator(
      MishkaDocument.Note,
      :create,
      authorize?: false,
      actor: actor,
      defaults: [
        section_id: nil,
        title: sequence(:title, &"Test Note #{&1}"),
        content: sequence(:content, &"Test note content #{&1}"),
        order_position: 0,
        change_version: "0.0.1",
        content_review_status: :pending,
        technical_review_status: :pending,
        schema: [],
        seo_tags: [],
        site_id: nil
      ],
      overrides: opts,
      tenant: tenant
    )
  end

  def section_tag(opts \\ [], _tenant \\ nil) do
    changeset_generator(
      MishkaDocument.SectionTag,
      :assign,
      authorize?: false,
      defaults: [
        section_id: nil,
        tag_id: nil
      ],
      overrides: opts,
      tenant: nil
    )
  end

  def issue(opts \\ [], tenant \\ nil) do
    changeset_generator(
      MishkaDocument.Issue,
      :master_create,
      authorize?: false,
      defaults: [
        note_id: nil,
        section_id: nil,
        reporter_id: nil,
        title: sequence(:title, &"Test Issue #{&1}"),
        description: sequence(:description, &"Test issue description #{&1}"),
        issue_type: :other,
        status: :open,
        site_id: nil
      ],
      overrides: opts,
      tenant: tenant
    )
  end

  def issue_comment(opts \\ [], tenant \\ nil, actor \\ nil) do
    changeset_generator(
      MishkaDocument.IssueComment,
      :create,
      authorize?: false,
      actor: actor,
      defaults: [
        issue_id: nil,
        contributor_id: nil,
        content: sequence(:content, &"Test comment content #{&1}"),
        site_id: nil
      ],
      overrides: opts,
      tenant: tenant
    )
  end

  def section_draft(opts \\ [], tenant \\ nil, actor \\ nil) do
    changeset_generator(
      MishkaDocument.SectionDraft,
      :create,
      authorize?: false,
      actor: actor,
      defaults: [
        workspace_version_id: nil,
        source_section_id: nil,
        parent_section_id: nil,
        title: sequence(:title, &"Test Section Draft #{&1}"),
        slug: sequence(:slug, &"test-section-draft-#{&1}"),
        content: sequence(:content, &"Test section draft content #{&1}"),
        order_position: 0,
        change_version: "0.0.1",
        version_increment_type: :minor,
        content_review_status: :pending,
        technical_review_status: :pending,
        schema: [],
        seo_tags: [],
        permissions: [],
        language: "en",
        language_group_id: nil,
        created_by_user_id: nil,
        site_id: nil
      ],
      overrides: opts,
      tenant: tenant
    )
  end

  def note_draft(opts \\ [], tenant \\ nil, actor \\ nil) do
    changeset_generator(
      MishkaDocument.NoteDraft,
      :create,
      authorize?: false,
      actor: actor,
      defaults: [
        source_note_id: nil,
        section_id: nil,
        section_draft_id: nil,
        title: sequence(:title, &"Test Note Draft #{&1}"),
        content: sequence(:content, &"Test note draft content #{&1}"),
        order_position: 0,
        change_version: "0.0.1",
        version_increment_type: :minor,
        content_review_status: :pending,
        technical_review_status: :pending,
        schema: [],
        seo_tags: [],
        created_by_user_id: nil,
        site_id: nil
      ],
      overrides: opts,
      tenant: tenant
    )
  end

  @doc """
  Creates a note draft through the master action, which is the only path that can attach the draft
  to a `section_draft_id`.

  The tenant `:create` action resolves the parent section draft with
  `Ash.get(MishkaDocument.SectionDraft, id, authorize?: false)` and passes no tenant, so on a
  `global? false` resource that lookup always fails and the create is rejected with "Section draft
  not found". `:master_create` performs the same lookup through `:master_get`, which bypasses
  multitenancy. Note drafts hanging off a real section take `note_draft/3` instead.
  """
  def master_note_draft(opts \\ [], actor \\ nil) do
    changeset_generator(
      MishkaDocument.NoteDraft,
      :master_create,
      authorize?: false,
      actor: actor,
      defaults: [
        source_note_id: nil,
        section_id: nil,
        section_draft_id: nil,
        title: sequence(:title, &"Test Note Draft #{&1}"),
        content: sequence(:content, &"Test note draft content #{&1}"),
        order_position: 0,
        change_version: "0.0.1",
        version_increment_type: :minor,
        content_review_status: :pending,
        technical_review_status: :pending,
        schema: [],
        seo_tags: [],
        created_by_user_id: nil,
        site_id: nil
      ],
      overrides: opts,
      tenant: nil
    )
  end

  # ---------------------------------------------------------------------------
  # DEV generators (realistic data)
  # ---------------------------------------------------------------------------

  def dev_workspace(opts \\ [], tenant \\ nil, actor \\ nil) do
    changeset_generator(
      MishkaDocument.Workspace,
      :create,
      authorize?: false,
      actor: actor,
      defaults: [
        name:
          sequence(:dev_workspace_name, fn i ->
            "#{Enum.at(@workspace_names, rem(i, length(@workspace_names)))} v#{div(i, length(@workspace_names)) + 1}"
          end),
        slug:
          sequence(:dev_workspace_slug, fn i ->
            base = Enum.at(@workspace_names, rem(i, length(@workspace_names)))
            slug = base |> String.downcase() |> String.replace(~r/[^a-z0-9]+/, "-")
            "#{slug}-#{i}"
          end),
        path: nil,
        description:
          StreamData.repeatedly(fn ->
            name = Enum.random(@workspace_names)
            "Comprehensive #{name} covering all aspects with examples and best practices."
          end),
        status: StreamData.member_of([:active, :draft]),
        schema: [],
        seo_tags: [],
        permissions: [],
        featured: StreamData.boolean(),
        display_order: StreamData.integer(0..100),
        language: "en",
        language_group_id: nil,
        site_id: nil
      ],
      overrides: opts,
      tenant: tenant
    )
  end

  def dev_workspace_version(opts \\ [], tenant \\ nil, actor \\ nil) do
    changeset_generator(
      MishkaDocument.WorkspaceVersion,
      :create,
      authorize?: false,
      actor: actor,
      defaults: [
        workspace_id: nil,
        version_number:
          sequence(:dev_version_number, fn i ->
            major = div(i, 10)
            minor = rem(i, 10)
            "#{major}.#{minor}.0"
          end),
        version_name:
          sequence(:dev_version_name, fn i ->
            names = ["Initial Release", "Stable", "LTS", "RC1", "Beta", "Alpha", "Current"]
            "#{Enum.at(names, rem(i, length(names)))} #{i}"
          end),
        description:
          StreamData.repeatedly(fn ->
            "This version includes major improvements, bug fixes, and new features."
          end),
        status: StreamData.member_of([:draft, :alpha, :beta]),
        is_latest_for_version: false,
        source_version_id: nil,
        published_at:
          StreamData.repeatedly(fn ->
            days_ago = :rand.uniform(365)
            DateTime.add(DateTime.utc_now(), -days_ago * 86400, :second)
          end),
        site_id: nil
      ],
      overrides: opts,
      tenant: tenant
    )
  end

  def dev_section(opts \\ [], tenant \\ nil, actor \\ nil) do
    changeset_generator(
      MishkaDocument.Section,
      :create,
      authorize?: false,
      actor: actor,
      defaults: [
        title:
          sequence(:dev_section_title, fn i ->
            "#{Enum.at(@section_titles, rem(i, length(@section_titles)))} #{div(i, length(@section_titles)) + 1}"
          end),
        slug:
          sequence(:dev_section_slug, fn i ->
            base = Enum.at(@section_titles, rem(i, length(@section_titles)))
            slug = base |> String.downcase() |> String.replace(~r/[^a-z0-9]+/, "-")
            "#{slug}-#{i}"
          end),
        content:
          StreamData.repeatedly(fn ->
            title = Enum.random(@section_titles)

            "<h2>#{title}</h2>\n<p>This section covers #{String.downcase(title)} in detail with practical examples and step-by-step instructions.</p>\n<p>Follow these guidelines to ensure correct implementation and avoid common pitfalls.</p>"
          end),
        order_position: StreamData.integer(0..100),
        front_page: false,
        group_heading: false,
        group_page: false,
        change_version: "1.0.0",
        content_review_status: StreamData.member_of([:pending, :approved, :rejected]),
        technical_review_status: StreamData.member_of([:pending, :approved, :rejected]),
        schema: [],
        seo_tags: [],
        permissions: [],
        language: "en",
        language_group_id: nil,
        workspace_version_id: nil,
        parent_section_id: nil,
        section_lineage_id: nil,
        source_section_id: nil,
        site_id: nil,
        tag_ids: []
      ],
      overrides: opts,
      tenant: tenant
    )
  end

  def dev_note(opts \\ [], tenant \\ nil, actor \\ nil) do
    changeset_generator(
      MishkaDocument.Note,
      :create,
      authorize?: false,
      actor: actor,
      defaults: [
        section_id: nil,
        title:
          sequence(:dev_note_title, fn i ->
            "#{Enum.at(@note_titles, rem(i, length(@note_titles)))} #{div(i, length(@note_titles)) + 1}"
          end),
        content:
          StreamData.repeatedly(fn ->
            type = Enum.random(@note_titles)

            "**#{type}:** This note provides additional context and important information about this section. Pay attention to these details when implementing the described functionality."
          end),
        order_position: StreamData.integer(0..50),
        change_version: "1.0.0",
        content_review_status: StreamData.member_of([:pending, :approved]),
        technical_review_status: StreamData.member_of([:pending, :approved]),
        schema: [],
        seo_tags: [],
        site_id: nil
      ],
      overrides: opts,
      tenant: tenant
    )
  end

  def dev_issue(opts \\ [], tenant \\ nil, actor \\ nil) do
    changeset_generator(
      MishkaDocument.Issue,
      :master_create,
      authorize?: false,
      actor: actor,
      defaults: [
        note_id: nil,
        section_id: nil,
        reporter_id: nil,
        title:
          sequence(:dev_issue_title, fn i ->
            type = Enum.at(@issue_types, rem(i, length(@issue_types)))
            "#{String.capitalize(to_string(type))}: Section needs attention #{i}"
          end),
        description:
          StreamData.repeatedly(fn ->
            issue_type = Enum.random(@issue_types)

            "Found a #{issue_type} issue in this section. The content needs to be reviewed and updated to reflect current best practices."
          end),
        issue_type: StreamData.member_of(@issue_types),
        status: StreamData.member_of(@issue_statuses),
        site_id: nil
      ],
      overrides: opts,
      tenant: tenant
    )
  end

  def dev_document_tag(opts \\ [], tenant \\ nil, actor \\ nil) do
    changeset_generator(
      MishkaDocument.Tag,
      :create,
      authorize?: false,
      actor: actor,
      defaults: [
        name:
          sequence(:dev_doc_tag_name, fn i ->
            Enum.at(@tag_names, rem(i, length(@tag_names)))
          end),
        slug:
          sequence(:dev_doc_tag_slug, fn i ->
            "#{Enum.at(@tag_names, rem(i, length(@tag_names)))}-#{i}"
          end),
        language: "en",
        language_group_id: nil,
        site_id: nil
      ],
      overrides: opts,
      tenant: tenant
    )
  end
end
