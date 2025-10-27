defmodule MishkaDocument.WorkspaceVersionLineage do
  @moduledoc """
  Tracks the lineage and cloning history of workspace versions.

  This resource maintains a detailed audit trail of version cloning operations,
  recording when a workspace version was created by cloning another version.
  It provides a clear parent-child relationship and timestamp for version branching.

  This is useful for:
  - Building version history trees
  - Tracking when versions were cloned
  - Auditing version branching operations
  - Understanding version evolution over time

  Multi-tenant isolation ensures lineage records are properly segregated between sites.

  The `cloned_at_not_future` check reads `cloned_at <= timezone('UTC', clock_timestamp())`, and both
  halves of that matter:

    * `clock_timestamp()` rather than `NOW()`, because `NOW()` is the TRANSACTION's start time. Any
      caller that opens a transaction, does some work and only then writes a lineage row with a
      freshly-read timestamp was rejected for a clock it never got ahead of — the longer the
      transaction, the likelier the false rejection.
    * `timezone('UTC', ...)` because `cloned_at` is a `timestamp WITHOUT TIME ZONE` holding UTC,
      while `clock_timestamp()` is a `timestamptz`. Comparing the two directly makes Postgres read
      the column in the SESSION's zone, so on a connection west of UTC a genuinely past value is
      rejected (measured: a value two hours old fails under `America/New_York`). Wrapping pins both
      sides to UTC, which is what the column actually stores. `MishkaBlog.BlogPost`'s
      `scheduled_publish_at` check already does this.

  The comparison is strictly more permissive than the old `NOW()` one, so no row that satisfied it
  can fail the new one.
  """
  use Ash.Resource,
    otp_app: :mishka_document,
    domain: MishkaDocument,
    data_layer: AshPostgres.DataLayer,
    extensions: [GuardedStruct.AshResource],
    authorizers: [Ash.Policy.Authorizer],
    notifiers: [MishkaCmsCore.Runtime.Resources.Notifiers.PluginHook]

  use Gettext, backend: MishkaCmsCore.Gettext

  @admin_fields [
    :new_version_id,
    :source_version_id,
    :cloned_at,
    :site_id
  ]

  # Database configuration for version lineage storage with indexing
  postgres do
    table "mishka_document_workspace_version_lineage"
    repo Application.compile_env!(:mishka_cms_core, :repo)

    references do
      reference :site, on_delete: :delete
      reference :new_version, on_delete: :delete
      reference :source_version, on_delete: :delete
    end

    custom_indexes do
      index [:source_version_id]
      index [:cloned_at]
      index [:site_id]
    end

    check_constraints do
      check_constraint :cloned_at, "cloned_at_not_future",
        check: "cloned_at <= timezone('UTC', clock_timestamp())",
        message: dgettext_noop("errors", "Cloned at timestamp cannot be in the future.")
    end

    identity_index_names unique_new_version: "doc_ws_ver_lin_uniq_idx"
  end

  guardedstruct do
    auto_wire true

    field :cloned_at, :utc_datetime, derives: "validate(utc_datetime, past_datetime)"
  end

  actions do
    defaults [:read]

    default_accept @admin_fields

    create :create do
      primary? true
      accept @admin_fields |> List.delete(:site_id)

      validate present([:new_version_id, :source_version_id])

      validate {MishkaCmsCore.Runtime.Resources.Validations.TenantContext, require_master: false}

      validate {MishkaCmsCore.Runtime.Resources.Validations.TenantIsolation,
                field: :new_version_id, resource: MishkaDocument.WorkspaceVersion}

      validate {MishkaCmsCore.Runtime.Resources.Validations.TenantIsolation,
                field: :source_version_id, resource: MishkaDocument.WorkspaceVersion}

      change &Ash.Changeset.force_change_attribute(&1, :site_id, &2.tenant)

      change fn changeset, _context ->
        # Auto-set cloned_at if not provided
        case Ash.Changeset.get_attribute(changeset, :cloned_at) do
          nil -> Ash.Changeset.change_attribute(changeset, :cloned_at, DateTime.utc_now())
          _ -> changeset
        end
      end

      validate fn changeset, _context ->
        new_version_id = Ash.Changeset.get_attribute(changeset, :new_version_id)
        source_version_id = Ash.Changeset.get_attribute(changeset, :source_version_id)

        if new_version_id == source_version_id do
          {:error,
           field: :source_version_id,
           message: dgettext_noop("errors", "Version cannot be cloned from itself.")}
        else
          :ok
        end
      end

      description "Creates lineage record for tenant users - requires tenant context, auto-assigns site_id and cloned_at"
    end

    create :master_create do
      validate present([:new_version_id, :source_version_id, :site_id])

      validate {MishkaCmsCore.Runtime.Resources.Validations.TenantContext, require_master: true}

      change fn changeset, _context ->
        site_id = Ash.Changeset.get_attribute(changeset, :site_id)
        Ash.Changeset.set_tenant(changeset, site_id)
      end

      change fn changeset, _context ->
        # Auto-set cloned_at if not provided
        case Ash.Changeset.get_attribute(changeset, :cloned_at) do
          nil -> Ash.Changeset.change_attribute(changeset, :cloned_at, DateTime.utc_now())
          _ -> changeset
        end
      end

      validate fn changeset, _context ->
        new_version_id = Ash.Changeset.get_attribute(changeset, :new_version_id)
        source_version_id = Ash.Changeset.get_attribute(changeset, :source_version_id)

        if new_version_id == source_version_id do
          {:error,
           field: :source_version_id,
           message: dgettext_noop("errors", "Version cannot be cloned from itself.")}
        else
          :ok
        end
      end

      description "Creates lineage record for master users - requires explicit site_id, auto-assigns cloned_at"
    end

    update :update do
      primary? true
      require_atomic? false
      transaction? true
      accept [:cloned_at]

      validate {MishkaCmsCore.Runtime.Resources.Validations.TenantContext, require_master: false}

      description "Updates lineage record for tenant users - only cloned_at can be updated, prevents site_id changes"
    end

    update :master_update do
      description "Updates lineage record for master users - bypasses multi-tenancy, only cloned_at can be updated, prevents site_id changes"
      require_atomic? false
      transaction? true
      accept [:cloned_at]
      multitenancy :bypass

      validate {MishkaCmsCore.Runtime.Resources.Validations.TenantContext, require_master: true}
    end

    read :master_read do
      description "Reads all lineage records system-wide, bypassing tenant filtering (master users only)"
      multitenancy :bypass
      pagination offset?: true, default_limit: 20, max_page_size: 100, countable: true

      validate {MishkaCmsCore.Runtime.Resources.Validations.TenantContext, require_master: true}
    end

    read :master_get do
      multitenancy :bypass
      get? true
      description "Retrieves single lineage record by ID, bypassing tenant filtering"

      validate {MishkaCmsCore.Runtime.Resources.Validations.TenantContext, require_master: true}
    end

    read :by_new_version do
      description "Get the lineage record for a specific new version"
      argument :new_version_id, :uuid, allow_nil?: false
      filter expr(new_version_id == ^arg(:new_version_id))

      validate {MishkaCmsCore.Runtime.Resources.Validations.TenantContext, require_master: false}
    end

    read :by_source_version do
      description "Get all versions that were cloned from a specific source version"
      argument :source_version_id, :uuid, allow_nil?: false
      filter expr(source_version_id == ^arg(:source_version_id))
      pagination offset?: true, default_limit: 20, max_page_size: 100, countable: true

      validate {MishkaCmsCore.Runtime.Resources.Validations.TenantContext, require_master: false}
    end

    read :by_date_range do
      description "Get lineage records within a date range"
      argument :start_date, :utc_datetime, allow_nil?: false
      argument :end_date, :utc_datetime, allow_nil?: false

      filter expr(cloned_at >= ^arg(:start_date) and cloned_at <= ^arg(:end_date))

      pagination offset?: true, default_limit: 20, max_page_size: 100, countable: true

      validate {MishkaCmsCore.Runtime.Resources.Validations.TenantContext, require_master: false}
    end

    read :recent_clones do
      description "Get recently cloned versions, sorted by clone date descending"

      prepare fn query, _context ->
        Ash.Query.sort(query, cloned_at: :desc)
      end

      pagination offset?: true, default_limit: 20, max_page_size: 100, countable: true

      validate {MishkaCmsCore.Runtime.Resources.Validations.TenantContext, require_master: false}
    end

    read :master_by_new_version do
      description "Get the lineage record for a specific new version on any site (master users only)"
      multitenancy :bypass
      argument :new_version_id, :uuid, allow_nil?: false
      filter expr(new_version_id == ^arg(:new_version_id))

      validate {MishkaCmsCore.Runtime.Resources.Validations.TenantContext, require_master: true}
    end

    read :master_by_source_version do
      description "Get all versions cloned from a specific source version on any site (master users only)"
      multitenancy :bypass
      argument :source_version_id, :uuid, allow_nil?: false
      filter expr(source_version_id == ^arg(:source_version_id))
      pagination offset?: true, default_limit: 20, max_page_size: 100, countable: true

      validate {MishkaCmsCore.Runtime.Resources.Validations.TenantContext, require_master: true}
    end

    read :master_by_date_range do
      description "Get lineage records within a date range on every site (master users only)"
      multitenancy :bypass
      argument :start_date, :utc_datetime, allow_nil?: false
      argument :end_date, :utc_datetime, allow_nil?: false

      filter expr(cloned_at >= ^arg(:start_date) and cloned_at <= ^arg(:end_date))

      pagination offset?: true, default_limit: 20, max_page_size: 100, countable: true

      validate {MishkaCmsCore.Runtime.Resources.Validations.TenantContext, require_master: true}
    end

    read :master_recent_clones do
      description "Get recently cloned versions on every site, sorted by clone date descending (master users only)"
      multitenancy :bypass

      prepare fn query, _context ->
        Ash.Query.sort(query, cloned_at: :desc)
      end

      pagination offset?: true, default_limit: 20, max_page_size: 100, countable: true

      validate {MishkaCmsCore.Runtime.Resources.Validations.TenantContext, require_master: true}
    end

    read :public_by_new_version do
      description "Get the lineage record for a specific public new version (only if both versions are published - alpha, beta, rc, or stable)"
      argument :new_version_id, :uuid, allow_nil?: false

      filter expr(
               new_version_id == ^arg(:new_version_id) and
                 new_version.status in [:alpha, :beta, :rc, :stable] and
                 source_version.status in [:alpha, :beta, :rc, :stable]
             )

      pagination offset?: true, default_limit: 20, max_page_size: 100, countable: true
    end

    read :public_by_source_version do
      description "Get all public versions that were cloned from a specific source version (only published versions - alpha, beta, rc, or stable)"
      argument :source_version_id, :uuid, allow_nil?: false

      filter expr(
               source_version_id == ^arg(:source_version_id) and
                 new_version.status in [:alpha, :beta, :rc, :stable] and
                 source_version.status in [:alpha, :beta, :rc, :stable]
             )

      pagination offset?: true, default_limit: 20, max_page_size: 100, countable: true
    end

    read :public_recent_clones do
      description "Get recently cloned public versions, sorted by clone date descending (only published versions - alpha, beta, rc, or stable)"

      filter expr(
               new_version.status in [:alpha, :beta, :rc, :stable] and
                 source_version.status in [:alpha, :beta, :rc, :stable]
             )

      prepare fn query, _context ->
        Ash.Query.sort(query, cloned_at: :desc)
      end

      pagination offset?: true, default_limit: 20, max_page_size: 100, countable: true
    end

    read :public_get do
      description "Get a single public lineage record by ID (only if both versions are published - alpha, beta, rc, or stable)"
      get? true

      filter expr(
               new_version.status in [:alpha, :beta, :rc, :stable] and
                 source_version.status in [:alpha, :beta, :rc, :stable]
             )
    end

    destroy :destroy do
      description "Permanently removes lineage record from database (tenant users)"
      primary? true
      require_atomic? false

      validate {MishkaCmsCore.Runtime.Resources.Validations.TenantContext, require_master: false}
    end

    destroy :master_destroy do
      description "Permanently removes lineage record from database (master users) - bypasses multi-tenancy"
      require_atomic? false
      multitenancy :bypass

      validate {MishkaCmsCore.Runtime.Resources.Validations.TenantContext, require_master: true}
    end
  end

  # Authorization policies for lineage access
  policies do
    # Allow public access to view stable version lineage
    bypass action(:public_by_new_version) do
      authorize_if always()
    end

    bypass action(:public_by_source_version) do
      authorize_if always()
    end

    bypass action(:public_recent_clones) do
      authorize_if always()
    end

    bypass action(:public_get) do
      authorize_if always()
    end

    # Read and written by the workspace area only: no section screen draws a version's lineage.
    policy always() do
      access_type :strict

      authorize_if {MishkaCmsCore.Accounts.Checks.AccessPermissions,
                    permissions: [
                      "admin:dashboard:document:workspace",
                      "admin:api:document:workspace"
                    ]}
    end
  end

  # Every id this record holds names a record of its own site, whoever writes it.
  validations do
    validate {MishkaCmsCore.Runtime.Resources.Validations.SameSiteReference,
              field: :new_version_id,
              resource: MishkaDocument.WorkspaceVersion,
              label: dgettext_noop("errors", "version"),
              read_action: :read_any},
             where: [changing(:new_version_id)],
             only_when_valid?: true

    validate {MishkaCmsCore.Runtime.Resources.Validations.SameSiteReference,
              field: :source_version_id,
              resource: MishkaDocument.WorkspaceVersion,
              label: dgettext_noop("errors", "version"),
              read_action: :read_any},
             where: [changing(:source_version_id)],
             only_when_valid?: true
  end

  # Multi-tenancy configuration - lineage records are always site-specific
  multitenancy do
    strategy :attribute
    attribute :site_id
    # Lineage records are NEVER global - always site-specific
    global? false
  end

  attributes do
    uuid_primary_key :id

    attribute :cloned_at, :utc_datetime do
      allow_nil? false
      public? true
      default &DateTime.utc_now/0
      description "Timestamp when the version was cloned"
    end

    create_timestamp :inserted_at
    update_timestamp :updated_at
  end

  relationships do
    belongs_to :site, MishkaCmsCore.Runtime.Site do
      read_action :read_any
      allow_nil? false
      public? true
      description "The site this lineage record belongs to"
    end

    belongs_to :new_version, MishkaDocument.WorkspaceVersion do
      allow_nil? false
      public? true
      attribute_writable? true
      description "The new version that was created by cloning"
    end

    belongs_to :source_version, MishkaDocument.WorkspaceVersion do
      allow_nil? false
      public? true
      attribute_writable? true
      description "The original version that was cloned from"
    end
  end

  identities do
    identity :unique_new_version, [:new_version_id, :site_id] do
      description "Ensures each new version can only have one lineage record per site"
      message dgettext_noop("errors", "This version already has a lineage record.")
      all_tenants? true
      nils_distinct? false
    end
  end
end
