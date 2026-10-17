# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_document/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaDocument.Tag do
  @moduledoc """
  Manages tags for categorizing and organizing documentation sections.

  This resource represents simple tags that can categorize and organize documentation
  sections. Each tag belongs to a specific site and provides basic metadata for content
  organization. Tags feature soft deletion via archival and provide API endpoints for
  external integrations.

  Database-level constraints ensure data integrity with slug validation. Multi-tenant
  isolation ensures tags are properly segregated between sites.
  """
  use Ash.Resource,
    otp_app: :mishka_document,
    domain: MishkaDocument,
    data_layer: AshPostgres.DataLayer,
    extensions: [
      AshArchival.Resource,
      AshSlug,
      AshJsonApi.Resource,
      AshEvents.Events,
      MishkaGervaz.Resource,
      GuardedStruct.AshResource
    ],
    notifiers: [Ash.Notifier.PubSub, MishkaCmsCore.Runtime.Resources.Notifiers.PluginHook],
    authorizers: [Ash.Policy.Authorizer]

  use MishkaGervaz.Messages, backend: MishkaCmsCore.Gettext
  import Phoenix.Component, only: [sigil_H: 2]
  import MishkaGervaz.UIAdapters.Tailwind, only: [cell_stacked: 1, cell_stats: 1]
  alias Ecto.Adapters.SQL
  alias MishkaCmsCore.Localized
  alias MishkaCmsCore.Runtime.Helpers

  @admin_fields [:name, :slug, :language, :language_group_id, :site_id]

  @repo Application.compile_env!(:mishka_cms_core, :repo)

  # Database configuration for tags storage with indexing
  postgres do
    table "mishka_document_tags"
    repo @repo

    references do
      reference :site, on_delete: :delete
    end

    # Database-level optimization for archived records
    base_filter_sql "(archived_at IS NULL)"

    custom_indexes do
      index [:language]
      index [:language_group_id]
    end

    check_constraints do
      check_constraint :slug, "slug_length_check",
        check: "length(slug) >= 1 AND length(slug) <= 255",
        message: dgettext_noop("errors", "Slug must be between 1 and 255 characters.")

      check_constraint :slug, "no_empty_slug",
        check: "slug != ''",
        message: dgettext_noop("errors", "Slug cannot be empty.")

      check_constraint :name, "name_length",
        check: "length(name) >= 1 AND length(name) <= 255",
        message: dgettext_noop("errors", "Name must be between 1 and 255 characters.")
    end

    # Database-level trigger to prevent updates on archived records
    custom_statements do
      statement :prevent_archived_tag_updates_function do
        up """
        CREATE OR REPLACE FUNCTION prevent_archived_document_tag_updates()
        RETURNS TRIGGER AS $$
        BEGIN
          -- Allow unarchiving (archived_at: NOT NULL -> NULL)
          IF OLD.archived_at IS NOT NULL AND NEW.archived_at IS NULL THEN
            RETURN NEW;
          END IF;

          -- Prevent other updates on archived records
          IF OLD.archived_at IS NOT NULL THEN
            RAISE EXCEPTION 'Cannot update archived tag'
              USING ERRCODE = 'check_violation';
          END IF;

          RETURN NEW;
        END;
        $$ LANGUAGE plpgsql;
        """

        down "DROP FUNCTION IF EXISTS prevent_archived_document_tag_updates();"
      end

      statement :prevent_archived_tag_updates_trigger do
        up """
        CREATE TRIGGER prevent_archived_document_tag_updates_trigger
          BEFORE UPDATE ON mishka_document_tags
          FOR EACH ROW
          EXECUTE FUNCTION prevent_archived_document_tag_updates();
        """

        down "DROP TRIGGER IF EXISTS prevent_archived_document_tag_updates_trigger ON mishka_document_tags;"
      end
    end
  end

  # Soft deletion configuration using archived_at timestamp
  archive do
    exclude_read_actions [
      :archived,
      :get_archived,
      :master_get_archived,
      :master_get,
      :master_archived
    ]

    exclude_destroy_actions [:permanent_destroy, :master_permanent_destroy]
  end

  # JSON API configuration for REST endpoints
  json_api do
    type "tag"

    includes [
      :sections,
      :master_sections,
      :tenant_sections,
      :language_variants,
      :tenant_language_variants,
      :master_language_variants
    ]

    paginated_includes [
      :sections,
      :master_sections,
      :tenant_sections,
      :language_variants,
      :tenant_language_variants,
      :master_language_variants
    ]
  end

  # Event tracking configuration for activity logging
  events do
    event_log MishkaDocument.EventLog

    only_actions [
      :create,
      :master_create,
      :update,
      :master_update,
      :unarchive,
      :master_unarchive,
      :destroy,
      :master_destroy,
      :permanent_destroy,
      :master_permanent_destroy
    ]
  end

  mishka_gervaz do
    table do
      identity do
        name :tags
        route "/admin/dashboard/document/tags"
        stream_name :tags
      end

      source do
        actions do
          read {:master_read, :tenant_read}
          get {:master_get, :read}
          destroy {:master_destroy, :destroy}
        end

        preload do
          always [:sections_count, :site]
        end
      end

      columns do
        column :tag_info do
          static true
          requires [:id, :name, :slug]
          label fn -> dgettext("mishka_gervaz", "Tag") end
          sortable true
          sort_field [:name]

          ui do
            width "minmax(170px,1.2fr)"
          end

          render fn record ->
            assigns = %{id: record.id, name: record.name, slug: record.slug}

            ~H"""
            <.cell_stacked
              variant={:title}
              primary={@name}
              secondary={"/#{@slug}"}
              copy={%{id: "document-tag-slug-copy-#{@id}", value: @slug, label: gettext("Copy slug")}}
            />
            """
          end
        end

        column :site_datetime do
          static true
          requires [:site, :inserted_at]
          label fn -> dgettext("mishka_gervaz", "Site / Date") end

          ui do
            width "minmax(140px,1.2fr)"
          end

          render fn record, state ->
            site_name =
              case record.site do
                %{name: name} -> name
                _unloaded -> nil
              end

            assigns = %{
              site: (state.master_user? && site_name) || nil,
              date: inserted_on(record.inserted_at)
            }

            ~H"""
            <.cell_stacked
              variant={:meta}
              icon="hero-server-stack"
              primary={@site || @date}
              secondary={(@site && @date) || nil}
            />
            """
          end
        end

        column :stats_info do
          static true
          requires [:sections_count, :language]
          label fn -> dgettext("mishka_gervaz", "Stats") end

          ui do
            width "minmax(120px,1fr)"
          end

          render fn record ->
            assigns = %{count: counted(record.sections_count), language: record.language}

            ~H"""
            <.cell_stats
              items={[%{icon: "hero-document-text", value: @count, label: gettext("Sections")}]}
              chips={(@language && [%{text: @language, label: gettext("Language")}]) || []}
            />
            """
          end
        end
      end

      filters do
        filter :search, :text do
          fields [:name, :slug]

          ui do
            label fn -> dgettext("mishka_gervaz", "Search") end
          end
        end

        filter :site_id, :relation do
          mode :search_multi
          display_field :name
          search_field :name
          min_chars 1
          page_size 15
          restricted true

          ui do
            label fn -> dgettext("mishka_gervaz", "Site") end
            placeholder fn -> dgettext("mishka_gervaz", "Search sites...") end
          end
        end

        filter :language, :select do
          options fn ->
            case SQL.query(
                   @repo,
                   "SELECT DISTINCT language FROM mishka_document_tags WHERE language IS NOT NULL ORDER BY language"
                 ) do
              {:ok, %{rows: rows}} -> Enum.map(rows, fn [lang] -> {String.upcase(lang), lang} end)
              _ -> []
            end
          end

          ui do
            prompt dgettext_noop("mishka_gervaz", "All Languages")
            label fn -> dgettext("mishka_gervaz", "Language") end
          end
        end

        filter :created_at, :date_range do
          source :inserted_at

          ui do
            label fn -> dgettext("mishka_gervaz", "Created at") end
          end
        end
      end

      row_actions do
        action :edit do
          type :edit
          visible :active
          js fn _record -> MishkaCmsCore.CoreComponents.show_modal("document-tag-form-modal") end

          ui do
            label fn -> dgettext("mishka_gervaz", "Edit") end
          end
        end

        action :delete do
          type :destroy

          confirm fn _record ->
            dgettext("mishka_gervaz", "Archive this tag?")
          end

          visible :active
        end

        action :unarchive do
          type :unarchive

          confirm fn _record ->
            dgettext("mishka_gervaz", "Restore this tag?")
          end

          visible :archived

          ui do
            label fn -> dgettext("mishka_gervaz", "Restore") end
            icon "hero-arrow-path"
          end
        end

        action :permanent_destroy,
          type: :permanent_destroy,
          confirm: fn _record ->
            dgettext("mishka_gervaz", "Permanently delete? This cannot be undone.")
          end,
          visible: :archived
      end

      row do
        selectable true
      end

      bulk_actions do
        action :archive,
          type: :destroy,
          confirm: dgettext_noop("mishka_gervaz", "Archive selected tags?")

        action :unarchive,
          type: :unarchive,
          confirm: dgettext_noop("mishka_gervaz", "Restore selected?"),
          visible: :archived

        action :permanent_destroy,
          type: :permanent_destroy,
          confirm: dgettext_noop("mishka_gervaz", "Permanently delete selected?"),
          visible: :archived
      end

      realtime do
        prefix "tag"
      end

      url_sync do
        mode :bidirectional
        params [:filters, :sort, :page, :search]
        prefix "tags"
        max_filter_length 500
      end

      pagination do
        page_size 20
      end

      empty_state message: dgettext_noop("mishka_gervaz", "No tags found"), icon: "hero-tag"
    end

    form do
      identity do
        name :tag_form
      end

      fields do
        field :site_id, :relation do
          restricted true
          show_on :create
          display_field :name
          search_field :name
          mode :search

          ui do
            label fn -> dgettext("mishka_gervaz", "Site") end
          end
        end

        field :name, :text do
          required true

          ui do
            label fn -> dgettext("mishka_gervaz", "Name") end
          end
        end

        field :slug, :text do
          required true

          ui do
            label fn -> dgettext("mishka_gervaz", "Slug") end
          end
        end

        field :language, :combobox do
          required true

          options fn ->
            case SQL.query(
                   @repo,
                   "SELECT DISTINCT language FROM mishka_document_tags WHERE language IS NOT NULL ORDER BY language"
                 ) do
              {:ok, %{rows: rows}} -> Enum.map(rows, fn [lang] -> {String.upcase(lang), lang} end)
              _ -> []
            end
          end

          ui do
            label fn -> dgettext("mishka_gervaz", "Language") end
            placeholder fn -> dgettext("mishka_gervaz", "en, fa, ar, ...") end

            description fn ->
              dgettext(
                "mishka_gervaz",
                "Add this code under Settings → Languages as well, or its URL answers 404."
              )
            end
          end
        end

        field :language_group_id, :relation do
          value_field :language_group_id
          display_field fn record -> "#{record.name} (#{record.language})" end
          search_field :name
          mode :search
          depends_on :site_id
          include_nil fn -> dgettext("mishka_gervaz", "New Language Group (auto-generate)") end

          load fn query, state ->
            site_id =
              if state.master_user? do
                Map.get(state.field_values, :site_id)
              else
                Map.get(state.current_user, :site_id)
              end

            Ash.Query.filter_input(query, %{site_id: site_id})
          end

          ui do
            label fn -> dgettext("mishka_gervaz", "Language Group") end
          end
        end
      end

      groups do
        group :basic_info do
          fields [:site_id, :name, :slug]

          ui do
            label fn -> dgettext("mishka_gervaz", "Basic Information") end
            columns 2
          end
        end

        group :localization do
          fields [:language, :language_group_id]

          ui do
            label fn -> dgettext("mishka_gervaz", "Localization") end
            columns 2
          end
        end
      end

      hooks do
        # While a tag is added, its slug follows the name until the author types one.
        on_validate fn params, state ->
          Helpers.follow_slug(params, state, :name)
        end

        on_cancel fn state -> state end
      end
    end
  end

  guardedstruct do
    auto_wire true

    field :name, :string,
      validator: {MishkaCmsCore.PlainText, :field},
      derives: "sanitize(trim) validate(string, not_empty, min_len=1, max_len=255)"

    field :slug, :string,
      derives: "sanitize(trim) validate(string, not_empty, min_len=1, max_len=255)"

    field :language, :string,
      derives: "sanitize(trim, downcase) validate(string, not_empty, max_len=10, language_code)"

    field :language_group_id, :uuid, derives: "validate(optional=[uuid])"
  end

  actions do
    defaults [:read]

    default_accept @admin_fields

    create :create do
      primary? true
      accept List.delete(@admin_fields, :site_id)

      validate present([:name, :slug])

      validate {MishkaCmsCore.Runtime.Resources.Validations.TenantContext, require_master: false}

      validate {MishkaCmsCore.Runtime.Resources.Validations.TenantIsolation,
                field: :language_group_id, resource: MishkaDocument.Tag}

      change &Ash.Changeset.force_change_attribute(&1, :site_id, &2.tenant)
      change slugify(:slug, into: :slug, ignore: [".", "!", "?"])
      change {MishkaCmsCore.Runtime.Resources.Changes.SetLanguageGroupId, before_action?: true}

      # Add metadata for event tracking
      change fn changeset, context ->
        Ash.Changeset.put_context(changeset, :ash_events_metadata, %{
          site_id: context.tenant,
          title: Ash.Changeset.get_attribute(changeset, :name)
        })
      end

      description "Creates tag for tenant users - requires tenant context, auto-assigns site_id and language_group_id"
    end

    create :master_create do
      validate present([:name, :slug])
      validate present([:site_id])

      validate {MishkaCmsCore.Runtime.Resources.Validations.TenantContext, require_master: true}

      change fn changeset, _context ->
        site_id = Ash.Changeset.get_attribute(changeset, :site_id)
        Ash.Changeset.set_tenant(changeset, site_id)
      end

      change slugify(:slug, into: :slug, ignore: [".", "!", "?"])
      change {MishkaCmsCore.Runtime.Resources.Changes.SetLanguageGroupId, before_action?: true}

      # Add metadata for event tracking
      change fn changeset, _context ->
        Ash.Changeset.put_context(changeset, :ash_events_metadata, %{
          site_id: Ash.Changeset.get_attribute(changeset, :site_id),
          title: Ash.Changeset.get_attribute(changeset, :name)
        })
      end

      description "Creates tag for master users - bypasses multi-tenancy, requires explicit site_id, auto-assigns language_group_id"
    end

    update :update do
      primary? true
      require_atomic? false
      transaction? true
      accept List.delete(@admin_fields, :site_id)

      validate {MishkaCmsCore.Runtime.Resources.Validations.TenantContext, require_master: false}

      validate {MishkaCmsCore.Runtime.Resources.Validations.TenantIsolation,
                field: :language_group_id, resource: MishkaDocument.Tag},
               where: [changing(:language_group_id)]

      validate absent(:archived_at) do
        message dgettext_noop("errors", "Cannot edit archived tag. Please unarchive it first.")
      end

      change slugify(:slug, into: :slug, ignore: [".", "!", "?"])

      # Add metadata for event tracking
      change fn changeset, context ->
        Ash.Changeset.put_context(changeset, :ash_events_metadata, %{
          site_id: context.tenant || changeset.data.site_id,
          title: Ash.Changeset.get_attribute(changeset, :name) || changeset.data.name
        })
      end

      description "Updates tag for tenant users - requires tenant context, prevents site_id changes"
    end

    update :master_update do
      description "Updates tag for master users - bypasses multi-tenancy, prevents site_id changes"
      require_atomic? false
      transaction? true
      accept List.delete(@admin_fields, :site_id)
      multitenancy :bypass

      validate {MishkaCmsCore.Runtime.Resources.Validations.TenantContext, require_master: true}

      validate absent(:archived_at) do
        message dgettext_noop("errors", "Cannot edit archived tag. Please unarchive it first.")
      end

      change slugify(:slug, into: :slug, ignore: [".", "!", "?"])

      change fn changeset, _context ->
        Ash.Changeset.put_context(changeset, :ash_events_metadata, %{
          site_id: changeset.data.site_id,
          title: Ash.Changeset.get_attribute(changeset, :name) || changeset.data.name
        })
      end
    end

    read :read_any do
      multitenancy :bypass
    end

    read :tenant_read do
      description "Reads tags for the tenant with pagination"
      pagination offset?: true, default_limit: 20, max_page_size: 100, countable: true

      validate {MishkaCmsCore.Runtime.Resources.Validations.TenantContext, require_master: false}
    end

    read :master_read do
      description "Reads all tags system-wide, bypassing tenant filtering (master users only)"
      multitenancy :bypass

      pagination offset?: true,
                 default_limit: 20,
                 max_page_size: 100,
                 countable: true,
                 required?: false

      validate {MishkaCmsCore.Runtime.Resources.Validations.TenantContext, require_master: true}
    end

    read :master_get do
      multitenancy :bypass
      get? true
      description "Retrieves single tag by ID, bypassing tenant filtering"

      validate {MishkaCmsCore.Runtime.Resources.Validations.TenantContext, require_master: true}
    end

    read :archived do
      filter expr(not is_nil(archived_at))
      pagination offset?: true, default_limit: 20, max_page_size: 100, countable: true

      validate {MishkaCmsCore.Runtime.Resources.Validations.TenantContext, require_master: false}

      description "Lists archived tags within current tenant context"
    end

    read :get_archived do
      get? true
      filter expr(not is_nil(archived_at))

      validate {MishkaCmsCore.Runtime.Resources.Validations.TenantContext, require_master: false}

      description "Retrieves single archived tag for recovery or inspection (tenant users)"
    end

    read :master_get_archived do
      get? true
      multitenancy :bypass
      filter expr(not is_nil(archived_at))

      validate {MishkaCmsCore.Runtime.Resources.Validations.TenantContext, require_master: true}

      description "Retrieves single archived tag for recovery or inspection (master users)"
    end

    read :master_archived do
      multitenancy :bypass
      filter expr(not is_nil(archived_at))
      pagination offset?: true, default_limit: 20, max_page_size: 100, countable: true

      validate {MishkaCmsCore.Runtime.Resources.Validations.TenantContext, require_master: true}

      description "Lists all archived tags system-wide, bypassing tenant filtering"
    end

    read :public_list do
      description "Public endpoint to list all tags with pagination (no authentication required)"

      pagination offset?: true,
                 default_limit: 20,
                 max_page_size: 100,
                 countable: true,
                 required?: false

      validate {MishkaCmsCore.Runtime.Resources.Validations.TenantContext, require_master: false}
    end

    read :public_get do
      description "Public endpoint to get a single tag by ID (no authentication required)"
      get? true

      validate {MishkaCmsCore.Runtime.Resources.Validations.TenantContext, require_master: false}
    end

    update :assign_sections do
      description "Replaces tag's sections with the provided list of section IDs"
      accept []
      require_atomic? false

      argument :section_ids, {:array, :uuid} do
        allow_nil? false
        description "List of section IDs to tag with this tag"
      end

      validate {MishkaCmsCore.Runtime.Resources.Validations.TenantContext, require_master: false}

      change manage_relationship(:section_ids, :sections,
               type: :append_and_remove,
               on_no_match: :error,
               on_match: :ignore
             )
    end

    update :add_section do
      description "Tags a single section with this tag"
      accept []
      require_atomic? false

      argument :section_id, :uuid do
        allow_nil? false
        description "Section ID to tag with this tag"
      end

      validate {MishkaCmsCore.Runtime.Resources.Validations.TenantContext, require_master: false}

      change manage_relationship(:section_id, :sections, type: :append, on_no_match: :error)
    end

    update :remove_section do
      description "Removes this tag from a single section"
      accept []
      require_atomic? false

      argument :section_id, :uuid do
        allow_nil? false
        description "Section ID to remove this tag from"
      end

      validate {MishkaCmsCore.Runtime.Resources.Validations.TenantContext, require_master: false}

      change manage_relationship(:section_id, :sections, type: :remove)
    end

    destroy :destroy do
      description "Soft deletes tag by archiving (tenant users)"
      primary? true
      require_atomic? false

      validate {MishkaCmsCore.Runtime.Resources.Validations.TenantContext, require_master: false}

      validate fn changeset, _context ->
        if changeset.data.archived_at do
          {:error,
           field: :archived_at, message: dgettext_noop("errors", "Tag is already archived.")}
        else
          :ok
        end
      end

      # Add metadata for event tracking
      change fn changeset, context ->
        Ash.Changeset.put_context(changeset, :ash_events_metadata, %{
          site_id: context.tenant || changeset.data.site_id,
          title: changeset.data.name
        })
      end
    end

    destroy :master_destroy do
      description "Soft deletes tag by archiving (master users) - bypasses multi-tenancy"
      require_atomic? false
      multitenancy :bypass

      validate {MishkaCmsCore.Runtime.Resources.Validations.TenantContext, require_master: true}

      validate fn changeset, _context ->
        if changeset.data.archived_at do
          {:error,
           field: :archived_at, message: dgettext_noop("errors", "Tag is already archived.")}
        else
          :ok
        end
      end

      change fn changeset, _context ->
        Ash.Changeset.put_context(changeset, :ash_events_metadata, %{
          site_id: changeset.data.site_id,
          title: changeset.data.name
        })
      end
    end

    update :unarchive do
      accept []
      require_atomic? false

      validate {MishkaCmsCore.Runtime.Resources.Validations.TenantContext, require_master: false}

      change set_attribute(:archived_at, nil)

      atomic_upgrade_with :archived

      # Add metadata for event tracking
      change fn changeset, context ->
        Ash.Changeset.put_context(changeset, :ash_events_metadata, %{
          site_id: context.tenant || changeset.data.site_id,
          title: changeset.data.name
        })
      end

      description "Restores archived tag (tenant users)"
    end

    update :master_unarchive do
      description "Restores archived tag (master users) - bypasses multi-tenancy"
      accept []
      require_atomic? false
      multitenancy :bypass

      validate {MishkaCmsCore.Runtime.Resources.Validations.TenantContext, require_master: true}

      validate fn changeset, _context ->
        if is_nil(changeset.data.archived_at) do
          {:error, field: :archived_at, message: dgettext_noop("errors", "Tag is not archived.")}
        else
          :ok
        end
      end

      change set_attribute(:archived_at, nil)

      change fn changeset, _context ->
        Ash.Changeset.put_context(changeset, :ash_events_metadata, %{
          site_id: changeset.data.site_id,
          title: changeset.data.name
        })
      end
    end

    destroy :permanent_destroy do
      require_atomic? false

      validate {MishkaCmsCore.Runtime.Resources.Validations.TenantContext, require_master: false}

      # Add metadata for event tracking
      change fn changeset, context ->
        Ash.Changeset.put_context(changeset, :ash_events_metadata, %{
          site_id: context.tenant || changeset.data.site_id,
          title: changeset.data.name
        })
      end

      description "Permanently removes tag from database (tenant users) - use with extreme caution"
    end

    destroy :master_permanent_destroy do
      description "Permanently removes tag from database (master users) - bypasses multi-tenancy, irreversible"
      require_atomic? false
      multitenancy :bypass

      validate {MishkaCmsCore.Runtime.Resources.Validations.TenantContext, require_master: true}

      change fn changeset, _context ->
        Ash.Changeset.put_context(changeset, :ash_events_metadata, %{
          site_id: changeset.data.site_id,
          title: changeset.data.name
        })
      end
    end
  end

  # Authorization policies for tag access
  policies do
    # Allow public access to view tags
    bypass action(:public_list) do
      authorize_if always()
    end

    bypass action(:public_get) do
      authorize_if always()
    end

    # Reads every site's rows, so it serves a master (a user with no site) and nobody else. The area
    # is asked by the policy below, as for every other action.
    policy action(:read_any) do
      authorize_if actor_attribute_equals(:site_id, nil)
    end

    # The section area, for everything but the public reads above.
    policy always() do
      access_type :strict

      authorize_if {MishkaCmsCore.Accounts.Checks.AccessPermissions,
                    permissions: [
                      "admin:dashboard:document:section",
                      "admin:api:document:section"
                    ]}
    end
  end

  pub_sub do
    module Application.compile_env!(:mishka_cms_core, :endpoint)
    prefix "tag"

    # Tenant actions - publish to site-specific topics
    publish :create, [[nil, :site_id], "created"]
    publish :update, [[nil, :site_id], "updated"]
    publish :unarchive, [[nil, :site_id], "updated"]
    publish :destroy, [[nil, :site_id], "destroyed"]
    publish :permanent_destroy, [[nil, :site_id], "destroyed"]

    # Master actions - publish to site-specific topics
    publish :master_create, [[nil, :site_id], "created"]
    publish :master_update, [[nil, :site_id], "updated"]
    publish :master_unarchive, [[nil, :site_id], "updated"]
    publish :master_destroy, [[nil, :site_id], "destroyed"]
    publish :master_permanent_destroy, [[nil, :site_id], "destroyed"]
  end

  # Every id this record holds names a record of its own site, whoever writes it.
  validations do
    validate {MishkaCmsCore.Runtime.Resources.Validations.SameSiteReference,
              field: :language_group_id,
              resource: MishkaDocument.Tag,
              label: dgettext_noop("errors", "language group"),
              read_action: :master_get},
             where: [changing(:language_group_id)],
             only_when_valid?: true
  end

  # Multi-tenancy configuration - tags are always site-specific
  multitenancy do
    strategy :attribute
    attribute :site_id
    # Tags are NEVER global - always site-specific
    global? false
  end

  attributes do
    uuid_primary_key :id

    attribute :name, :string do
      allow_nil? false
      public? true
      constraints min_length: 1, max_length: 255, trim?: true
      description "Name of the tag"
    end

    attribute :slug, :string do
      allow_nil? false
      public? true
      constraints min_length: 1, max_length: 255, trim?: true
      description "URL-friendly slug for the tag"
    end

    attribute :language, :string do
      allow_nil? false
      public? true
      default "en"
      constraints trim?: true, max_length: 10
      description "Primary language of the tag (ISO 639-1 code, e.g., en, fa, ar, ru)"
    end

    attribute :language_group_id, :uuid do
      allow_nil? true
      public? true
      description "Shared ID linking all language variants of this tag together"
    end

    create_timestamp :inserted_at
    update_timestamp :updated_at
  end

  relationships do
    belongs_to :site, MishkaCmsCore.Runtime.Site do
      read_action :read_any
      allow_nil? false
      public? true
      description "The site this tag belongs to"
    end

    # Relationship - for public language variants
    has_many :language_variants, MishkaDocument.Tag do
      public? true
      destination_attribute :language_group_id
      source_attribute :language_group_id
      description "All language variants (translations) of this tag (public access)"
      read_action :public_list
      filter expr(site_id == parent(site_id))
    end

    # Relationship - for tenant admin language variants
    has_many :tenant_language_variants, MishkaDocument.Tag do
      public? true
      destination_attribute :language_group_id
      source_attribute :language_group_id
      description "All language variants (translations) of this tag (tenant admin access)"
      filter expr(site_id == parent(site_id))
    end

    # Relationship - for master admin language variants (bypass tenant)
    has_many :master_language_variants, MishkaDocument.Tag do
      public? true
      destination_attribute :language_group_id
      source_attribute :language_group_id
      description "All language variants (translations) of this tag (master bypass access)"
      read_action :master_read

      filter expr(
               not is_nil(type(^actor(:id), :uuid)) and is_nil(type(^actor(:site_id), :uuid)) and
                 site_id == parent(site_id)
             )
    end

    # Relationship - for public approved sections
    many_to_many :sections, MishkaDocument.Section do
      public? true
      description "Documentation sections tagged with this tag"
      through MishkaDocument.SectionTag
      source_attribute_on_join_resource :tag_id
      destination_attribute_on_join_resource :section_id
      read_action :public_list
    end

    # Relationship - for admin users with tenant
    many_to_many :tenant_sections, MishkaDocument.Section do
      public? true
      description "All tenant sections tagged with this tag"
      through MishkaDocument.SectionTag
      source_attribute_on_join_resource :tag_id
      destination_attribute_on_join_resource :section_id
    end

    # Bypass relationship - for admin users without tenant
    many_to_many :master_sections, MishkaDocument.Section do
      public? true
      description "All sections (bypass tenant) tagged with this tag"
      through MishkaDocument.SectionTag
      source_attribute_on_join_resource :tag_id
      destination_attribute_on_join_resource :section_id
      read_action :read_any

      filter expr(not is_nil(type(^actor(:id), :uuid)) and is_nil(type(^actor(:site_id), :uuid)))
    end
  end

  aggregates do
    count :sections_count, :tenant_sections do
      public? true
      authorize? false
      multitenancy :bypass
      description "Returns count of sections using this tag"
    end
  end

  identities do
    identity :unique_slug_per_site, [:slug, :site_id] do
      description "Ensures tag slugs are unique within each site for clear identification"
      message dgettext_noop("errors", "Tag slug must be unique within a site.")
      all_tenants? true
      nils_distinct? false
    end
  end

  defp counted(value) when is_integer(value) and value >= 0, do: value
  defp counted(_value), do: 0

  @spec inserted_on(term()) :: String.t()
  defp inserted_on(at) when is_struct(at, DateTime) or is_struct(at, NaiveDateTime),
    do: Localized.date(at, :yMMMd)

  defp inserted_on(_missing), do: "—"
end
