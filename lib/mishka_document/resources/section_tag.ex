# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_document/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaDocument.SectionTag do
  @moduledoc """
  Manages the many-to-many relationship between documentation sections and tags.

  This resource serves as the join table that associates sections with tags,
  enabling sections to have multiple tags and tags to categorize multiple sections.
  Each record represents a tag assignment, indicating that a section is tagged
  with a specific tag for content organization and discovery.

  The resource implements upsert functionality through the assign action, preventing
  duplicate section-tag assignments while allowing efficient bulk updates.
  The unique constraint on section_id and tag_id pairs ensures that each section
  can only be assigned a specific tag once, maintaining data integrity.

  Access to this resource is controlled through policies that allow manipulation
  either through the Section or Tag resource relationships or by users with
  administrative privileges. This ensures that tag assignments can only be
  modified by authorized actors.

  An admin who is a master (a user with no site) reaches every site's rows; a site admin only rows
  whose section is on its own site. `:assign` takes only a section and a tag of the site the write is
  made for — the tenant, or the actor's own site when there is no tenant — see
  `MishkaCmsCore.Runtime.Resources.Validations.TenantIsolation`.
  """
  use Ash.Resource,
    otp_app: :mishka_document,
    domain: MishkaDocument,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer],
    notifiers: [MishkaCmsCore.Runtime.Resources.Notifiers.PluginHook]

  use Gettext, backend: MishkaCmsCore.Gettext

  # Database configuration for join table
  postgres do
    table "mishka_document_section_tags"
    repo Application.compile_env!(:mishka_cms_core, :repo)

    references do
      reference :section, on_delete: :delete
      reference :tag, on_delete: :delete
    end
  end

  actions do
    defaults [:create, :read, :destroy]

    default_accept []

    create :assign do
      description "Assigns a tag to a section, updating if already exists"
      primary? true
      accept [:section_id, :tag_id]
      upsert? true
      upsert_identity :unique_section_tag

      validate {MishkaCmsCore.Runtime.Resources.Validations.TenantIsolation,
                field: :section_id, resource: MishkaDocument.Section}

      validate {MishkaCmsCore.Runtime.Resources.Validations.TenantIsolation,
                field: :tag_id, resource: MishkaDocument.Tag}
    end
  end

  # Authorization policies for section-tag associations
  policies do
    # When accessing from Section or Tag through their tag/section relationships (join assoc names)
    bypass accessing_from(MishkaDocument.Section, :tags_join_assoc) do
      authorize_if always()
    end

    bypass accessing_from(MishkaDocument.Section, :tenant_tags_join_assoc) do
      authorize_if always()
    end

    bypass accessing_from(MishkaDocument.Section, :master_tags_join_assoc) do
      authorize_if always()
    end

    bypass accessing_from(MishkaDocument.Tag, :sections_join_assoc) do
      authorize_if always()
    end

    bypass accessing_from(MishkaDocument.Tag, :tenant_sections_join_assoc) do
      authorize_if always()
    end

    bypass accessing_from(MishkaDocument.Tag, :master_sections_join_assoc) do
      authorize_if always()
    end

    # `:assign` holds its section and tag to the site the write is made for, through TenantIsolation.
    policy action_type(:create) do
      authorize_if {MishkaCmsCore.Accounts.Checks.AccessPermissions,
                    permissions: [
                      "admin:dashboard:document:section",
                      "admin:api:document:section"
                    ]}
    end

    policy action_type([:read, :update, :destroy]) do
      forbid_unless {MishkaCmsCore.Accounts.Checks.AccessPermissions,
                     permissions: [
                       "admin:dashboard:document:section",
                       "admin:api:document:section"
                     ]}

      authorize_if actor_attribute_equals(:site_id, nil)
      authorize_if expr(section.site_id == ^actor(:site_id))
    end
  end

  # The tag is one of the section's site. Checked when the row is written: a section's `tag_ids`
  # sets both ids after the action is built.
  validations do
    validate {MishkaCmsCore.Runtime.Resources.Validations.SameSiteReference,
              field: :tag_id,
              resource: MishkaDocument.Tag,
              label: dgettext_noop("errors", "tag"),
              read_action: :master_get,
              own: {:section_id, MishkaDocument.Section, :master_get}},
             where: [changing(:tag_id)],
             before_action?: true
  end

  attributes do
    create_timestamp :inserted_at
    update_timestamp :updated_at
  end

  relationships do
    belongs_to :section, MishkaDocument.Section, primary_key?: true, allow_nil?: false
    belongs_to :tag, MishkaDocument.Tag, primary_key?: true, allow_nil?: false
  end

  identities do
    identity :unique_section_tag, [:section_id, :tag_id] do
      description "Ensures each section-tag pair is unique"
    end
  end
end
