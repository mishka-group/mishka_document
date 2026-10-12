defmodule MishkaDocument.Note do
  @moduledoc """
  Manages documentation notes within sections.

  This resource represents individual notes that contain the actual documentation content.
  Each note belongs to a specific section and supports content and technical review workflows
  with multiple approval states.

  Notes are the core content units of the documentation system, containing the detailed
  information organized within sections. The resource supports multi-language content,
  SEO optimization, and comprehensive review workflows.

  Multi-tenant isolation ensures notes are properly segregated between sites.
  """
  use Ash.Resource,
    otp_app: :mishka_document,
    domain: MishkaDocument,
    data_layer: AshPostgres.DataLayer,
    extensions: [
      AshArchival.Resource,
      AshJsonApi.Resource,
      AshEvents.Events,
      MishkaGervaz.Resource,
      GuardedStruct.AshResource
    ],
    notifiers: [Ash.Notifier.PubSub, MishkaCmsCore.Runtime.Resources.Notifiers.PluginHook],
    authorizers: [Ash.Policy.Authorizer]

  use MishkaGervaz.Messages, backend: MishkaCmsCore.Gettext

  @admin_fields [
    :section_id,
    :title,
    :content,
    :order_position,
    :change_version,
    :content_review_status,
    :technical_review_status,
    :schema,
    :seo_tags,
    :site_id
  ]

  # Database configuration for notes storage with indexing
  postgres do
    table "mishka_document_notes"
    repo Application.compile_env!(:mishka_cms_core, :repo)

    # Database-level optimization for archived records
    base_filter_sql "(archived_at IS NULL)"

    references do
      reference :site, on_delete: :delete
      reference :section, on_delete: :delete
    end

    custom_indexes do
      index [:section_id]
      index [:order_position]
      index [:content_review_status]
      index [:technical_review_status]
      index [:site_id]
    end

    check_constraints do
      check_constraint :title, "title_not_empty",
        check: "length(title) >= 1",
        message: dgettext_noop("errors", "Title cannot be empty.")

      check_constraint :content, "content_not_empty",
        check: "length(content) >= 1",
        message: dgettext_noop("errors", "Content cannot be empty.")

      check_constraint :order_position, "order_position_non_negative",
        check: "order_position >= 0",
        message: dgettext_noop("errors", "Order position must be non-negative.")
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
    type "note"

    includes [:section]
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
    form do
      identity do
        name :note_form
      end

      source do
        preload do
          always [:site]
          master master_section: :section
          tenant [:section]
        end
      end

      fields do
        field :site_id, :relation do
          restricted true
          show_on :create
          readonly fn state -> Map.has_key?(state.defaults || %{}, :site_id) end
          display_field :name
          search_field :name
          mode :search

          ui do
            label fn -> dgettext("mishka_gervaz", "Site") end
          end
        end

        field :section_id, :relation do
          restricted true
          display_field :title
          search_field :title
          mode :search
          depends_on :site_id

          load fn query, state ->
            site_id =
              if state.master_user? do
                Map.get(state.field_values, :site_id)
              else
                Map.get(state.current_user, :site_id)
              end

            if site_id do
              Ash.Query.filter_input(query, %{site_id: site_id})
            else
              query
            end
          end

          ui do
            label fn -> dgettext("mishka_gervaz", "Section") end
          end
        end

        field :title, :text do
          required true

          ui do
            label fn -> dgettext("mishka_gervaz", "Title") end
            placeholder fn -> dgettext("mishka_gervaz", "Note title") end
          end
        end

        field :content, :textarea do
          required true

          ui do
            label fn -> dgettext("mishka_gervaz", "Content") end
            placeholder fn -> dgettext("mishka_gervaz", "Note content...") end

            # The rich-text editor, with components placed as blocks; their markers are what is
            # stored. `MishkaCmsCoreWeb.UIAdapters.Admin.textarea/1` is what reads this.
            extra %{content_editor: true}
          end
        end

        field :order_position do
          ui do
            label fn -> dgettext("mishka_gervaz", "Order Position") end
          end
        end

        field :content_review_status, :select do
          required true

          options fn ->
            [
              {dgettext("mishka_gervaz", "Pending"), :pending},
              {dgettext("mishka_gervaz", "Approved"), :approved},
              {dgettext("mishka_gervaz", "Rejected"), :rejected},
              {dgettext("mishka_gervaz", "Needs revision"), :needs_revision},
              {dgettext("mishka_gervaz", "Archived"), :archived}
            ]
          end

          ui do
            label fn -> dgettext("mishka_gervaz", "Content Review") end
          end
        end

        field :technical_review_status, :select do
          required true

          options fn ->
            [
              {dgettext("mishka_gervaz", "Pending"), :pending},
              {dgettext("mishka_gervaz", "Approved"), :approved},
              {dgettext("mishka_gervaz", "Rejected"), :rejected},
              {dgettext("mishka_gervaz", "Needs revision"), :needs_revision},
              {dgettext("mishka_gervaz", "Archived"), :archived}
            ]
          end

          ui do
            label fn -> dgettext("mishka_gervaz", "Technical Review") end
          end
        end

        field :seo_tags, :nested do
          ui do
            label fn -> dgettext("mishka_gervaz", "SEO Tags") end
            add_label fn -> dgettext("mishka_gervaz", "+ Add SEO Tag") end
            remove_label fn -> dgettext("mishka_gervaz", "Remove") end
          end

          nested_field :tag do
            ui do
              label fn -> dgettext("mishka_gervaz", "Tag") end
              placeholder "meta, link, script"
            end
          end

          nested_field :attrs, :json do
            ui do
              label fn -> dgettext("mishka_gervaz", "Attributes") end
              placeholder ~s({"name": "description", "property": "og:title"})
            end
          end

          nested_field :content do
            ui do
              label fn -> dgettext("mishka_gervaz", "Content") end
              placeholder fn -> dgettext("mishka_gervaz", "Tag content text") end
            end
          end
        end
      end

      groups do
        group :references do
          fields [:site_id, :section_id]

          ui do
            label fn -> dgettext("mishka_gervaz", "References") end
            columns 2
          end
        end

        group :main_fields do
          fields [:title, :content]

          ui do
            columns 1
          end
        end

        group :settings do
          fields [:order_position, :content_review_status, :technical_review_status]

          ui do
            columns 3
          end
        end

        group :seo do
          fields [:seo_tags]

          ui do
            columns 1
          end
        end
      end

      presentation do
        features :all

        # For `textarea/1` only — the adapter falls back to Tailwind for everything else. It is what
        # turns the `content` field's `extra %{content_editor: true}` into the editor.
        ui_adapter MishkaCmsCoreWeb.UIAdapters.Admin
      end

      hooks do
        on_cancel fn state -> state end
      end
    end
  end

  guardedstruct do
    auto_wire true

    field :title, :string,
      validator: {MishkaCmsCore.PlainText, :field},
      derives: "sanitize(trim) validate(string, not_empty, min_len=1, max_len=500)"

    field :content, :string, derives: "sanitize(basic_html) validate(string, not_empty)"

    field :order_position, :integer, derives: "validate(optional=[integer, min_len=0])"

    field :change_version, :string,
      derives: "sanitize(trim) validate(optional=[string, max_len=50, semver])"

    field :content_review_status, :atom,
      derives: "validate(atom, enum=Atom[pending::approved::rejected::needs_revision::archived])"

    field :technical_review_status, :atom,
      derives: "validate(atom, enum=Atom[pending::approved::rejected::needs_revision::archived])"

    field :schema, {:array, :map}, derives: "validate(list)"
    field :seo_tags, {:array, :map}, derives: "validate(list)"
  end

  # Field-level policies for calculated fields
  field_policies do
    # Draft count calculations are admin-only
    field_policy [
      :pending_note_draft_content_review_count,
      :pending_note_draft_technical_review_count,
      :approved_note_draft_count
    ] do
      authorize_if {MishkaCmsCore.Accounts.Checks.AccessPermissions,
                    permissions: [
                      "admin:dashboard:document:section",
                      "admin:api:document:section"
                    ]}
    end

    # All other fields use the default policy
    field_policy :* do
      authorize_if always()
    end
  end

  actions do
    defaults [:read]

    default_accept @admin_fields

    create :create do
      primary? true
      accept @admin_fields |> List.delete(:site_id)

      validate present([:section_id])
      validate present([:title])
      validate present([:content])

      validate {MishkaCmsCore.Runtime.Resources.Validations.TenantContext, require_master: false}

      validate {MishkaCmsCore.Runtime.Resources.Validations.TenantIsolation,
                field: :section_id, resource: MishkaDocument.Section}

      change &Ash.Changeset.force_change_attribute(&1, :site_id, &2.tenant)

      # Stores the components the sanitized content names, before the row is written.
      change MishkaDocument.Resources.Changes.ContentFacts

      change {MishkaDocument.Resources.Changes.SetEventMetadata,
              resource_type: :note, for_action: :create}

      description "Creates note for tenant users - requires tenant context, auto-assigns site_id"
    end

    create :master_create do
      validate present([:section_id])
      validate present([:title])
      validate present([:content])
      validate present([:site_id])

      validate {MishkaCmsCore.Runtime.Resources.Validations.TenantContext, require_master: true}

      change fn changeset, _context ->
        site_id = Ash.Changeset.get_attribute(changeset, :site_id)
        Ash.Changeset.set_tenant(changeset, site_id)
      end

      change MishkaDocument.Resources.Changes.ContentFacts

      change {MishkaDocument.Resources.Changes.SetEventMetadata,
              resource_type: :note, for_action: :create}

      description "Creates note for master users - requires explicit site_id"
    end

    update :update do
      primary? true
      require_atomic? false
      transaction? true
      accept @admin_fields |> List.delete(:site_id)

      validate {MishkaCmsCore.Runtime.Resources.Validations.TenantContext, require_master: false}

      validate {MishkaCmsCore.Runtime.Resources.Validations.TenantIsolation,
                field: :section_id, resource: MishkaDocument.Section},
               where: [changing(:section_id)]

      change MishkaDocument.Resources.Changes.ContentFacts

      change {MishkaDocument.Resources.Changes.SetEventMetadata,
              resource_type: :note, for_action: :update}

      description "Updates note for tenant users - requires tenant context, prevents site_id changes"
    end

    update :master_update do
      description "Updates note for master users - bypasses multi-tenancy, prevents site_id changes"
      require_atomic? false
      transaction? true
      accept @admin_fields |> List.delete(:site_id)
      multitenancy :bypass

      validate {MishkaCmsCore.Runtime.Resources.Validations.TenantContext, require_master: true}

      validate absent(:archived_at) do
        message dgettext_noop("errors", "Cannot edit archived note. Please unarchive it first.")
      end

      change MishkaDocument.Resources.Changes.ContentFacts

      change {MishkaDocument.Resources.Changes.SetEventMetadata,
              resource_type: :note, for_action: :update}
    end

    read :master_read do
      description "Reads all notes system-wide, bypassing tenant filtering (master users only)"
      multitenancy :bypass
      pagination offset?: true, default_limit: 20, max_page_size: 100, countable: true

      validate {MishkaCmsCore.Runtime.Resources.Validations.TenantContext, require_master: true}
    end

    read :master_get do
      multitenancy :bypass
      get? true
      description "Retrieves single note by ID, bypassing tenant filtering"

      validate {MishkaCmsCore.Runtime.Resources.Validations.TenantContext, require_master: true}
    end

    read :by_section do
      description "Retrieves all notes for a specific section"
      argument :section_id, :uuid, allow_nil?: false
      filter expr(section_id == ^arg(:section_id))
      pagination offset?: true, default_limit: 50, max_page_size: 200, countable: true

      validate {MishkaCmsCore.Runtime.Resources.Validations.TenantContext, require_master: false}
    end

    read :public_list do
      description "Public endpoint to list approved notes (no authentication required)"
      filter expr(content_review_status == :approved and technical_review_status == :approved)

      pagination offset?: true,
                 default_limit: 20,
                 max_page_size: 100,
                 countable: true,
                 required?: false
    end

    read :public_get do
      description "Public endpoint to get a single approved note by ID (no authentication required)"
      get? true
      filter expr(content_review_status == :approved and technical_review_status == :approved)
    end

    read :read_any do
      multitenancy :bypass
      description "Reads all notes bypassing tenant filtering (for master relationships)"
      pagination offset?: true, default_limit: 20, max_page_size: 100, countable: true
    end

    read :archived do
      filter expr(not is_nil(archived_at))
      pagination offset?: true, default_limit: 20, max_page_size: 100, countable: true

      validate {MishkaCmsCore.Runtime.Resources.Validations.TenantContext, require_master: false}

      description "Lists archived notes within current tenant context"
    end

    read :get_archived do
      get? true
      filter expr(not is_nil(archived_at))

      validate {MishkaCmsCore.Runtime.Resources.Validations.TenantContext, require_master: false}

      description "Retrieves single archived note for recovery or inspection (tenant users)"
    end

    read :master_get_archived do
      get? true
      multitenancy :bypass
      filter expr(not is_nil(archived_at))

      validate {MishkaCmsCore.Runtime.Resources.Validations.TenantContext, require_master: true}

      description "Retrieves single archived note for recovery or inspection (master users)"
    end

    read :master_archived do
      multitenancy :bypass
      filter expr(not is_nil(archived_at))
      pagination offset?: true, default_limit: 20, max_page_size: 100, countable: true

      validate {MishkaCmsCore.Runtime.Resources.Validations.TenantContext, require_master: true}

      description "Lists all archived notes system-wide, bypassing tenant filtering"
    end

    destroy :destroy do
      description "Soft deletes note by archiving (tenant users)"
      primary? true
      require_atomic? false

      validate {MishkaCmsCore.Runtime.Resources.Validations.TenantContext, require_master: false}

      validate fn changeset, _context ->
        if changeset.data.archived_at do
          {:error,
           field: :archived_at, message: dgettext_noop("errors", "Note is already archived.")}
        else
          :ok
        end
      end

      change before_action(fn changeset, _context ->
               Ash.Changeset.force_change_attribute(changeset, :content_review_status, :archived)
             end)

      change before_action(fn changeset, _context ->
               Ash.Changeset.force_change_attribute(
                 changeset,
                 :technical_review_status,
                 :archived
               )
             end)

      change {MishkaDocument.Resources.Changes.SetEventMetadata,
              resource_type: :note, for_action: :destroy}
    end

    destroy :master_destroy do
      description "Soft deletes note by archiving (master users) - bypasses multi-tenancy"
      require_atomic? false
      multitenancy :bypass

      validate {MishkaCmsCore.Runtime.Resources.Validations.TenantContext, require_master: true}

      validate fn changeset, _context ->
        if changeset.data.archived_at do
          {:error,
           field: :archived_at, message: dgettext_noop("errors", "Note is already archived.")}
        else
          :ok
        end
      end

      change before_action(fn changeset, _context ->
               Ash.Changeset.force_change_attribute(changeset, :content_review_status, :archived)
             end)

      change before_action(fn changeset, _context ->
               Ash.Changeset.force_change_attribute(
                 changeset,
                 :technical_review_status,
                 :archived
               )
             end)

      change {MishkaDocument.Resources.Changes.SetEventMetadata,
              resource_type: :note, for_action: :destroy}
    end

    update :unarchive do
      accept []
      require_atomic? false

      validate {MishkaCmsCore.Runtime.Resources.Validations.TenantContext, require_master: false}

      change set_attribute(:archived_at, nil)
      change set_attribute(:content_review_status, :pending)
      change set_attribute(:technical_review_status, :pending)

      atomic_upgrade_with :archived

      change {MishkaDocument.Resources.Changes.SetEventMetadata,
              resource_type: :note, for_action: :update}

      description "Restores archived note to pending review status (tenant users)"
    end

    update :master_unarchive do
      description "Restores archived note to pending review status (master users) - bypasses multi-tenancy"
      accept []
      require_atomic? false
      multitenancy :bypass

      validate {MishkaCmsCore.Runtime.Resources.Validations.TenantContext, require_master: true}

      validate fn changeset, _context ->
        if is_nil(changeset.data.archived_at) do
          {:error, field: :archived_at, message: dgettext_noop("errors", "Note is not archived.")}
        else
          :ok
        end
      end

      change set_attribute(:archived_at, nil)
      change set_attribute(:content_review_status, :pending)
      change set_attribute(:technical_review_status, :pending)

      change {MishkaDocument.Resources.Changes.SetEventMetadata,
              resource_type: :note, for_action: :update}
    end

    destroy :permanent_destroy do
      require_atomic? false

      validate {MishkaCmsCore.Runtime.Resources.Validations.TenantContext, require_master: false}

      change {MishkaDocument.Resources.Changes.SetEventMetadata,
              resource_type: :note, for_action: :destroy}

      description "Permanently removes note from database (tenant users) - use with extreme caution"
    end

    destroy :master_permanent_destroy do
      description "Permanently removes note from database (master users) - bypasses multi-tenancy, irreversible"
      require_atomic? false
      multitenancy :bypass

      validate {MishkaCmsCore.Runtime.Resources.Validations.TenantContext, require_master: true}

      change {MishkaDocument.Resources.Changes.SetEventMetadata,
              resource_type: :note, for_action: :destroy}
    end
  end

  # Authorization policies for note access
  policies do
    # Allow public access to view approved notes
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

  # PubSub configuration for real-time updates
  pub_sub do
    module Application.compile_env!(:mishka_cms_core, :endpoint)
    prefix "note"

    publish :create, [[nil, :site_id], "created"]
    publish :update, [[nil, :site_id], "updated"]
    publish :unarchive, [[nil, :site_id], "updated"]
    publish :destroy, [[nil, :site_id], "destroyed"]
    publish :permanent_destroy, [[nil, :site_id], "destroyed"]

    # Master actions
    publish :master_create, [[nil, :site_id], "created"]
    publish :master_update, [[nil, :site_id], "updated"]
    publish :master_unarchive, [[nil, :site_id], "updated"]
    publish :master_destroy, [[nil, :site_id], "destroyed"]
    publish :master_permanent_destroy, [[nil, :site_id], "destroyed"]
  end

  # Every id this record holds names a record of its own site, whoever writes it.
  validations do
    validate {MishkaCmsCore.Runtime.Resources.Validations.SameSiteReference,
              field: :section_id,
              resource: MishkaDocument.Section,
              label: dgettext_noop("errors", "section"),
              read_action: :master_get},
             where: [changing(:section_id)],
             only_when_valid?: true
  end

  # Multi-tenancy configuration - notes are always site-specific
  multitenancy do
    strategy :attribute
    attribute :site_id
    # Notes are NEVER global - always site-specific
    global? false
  end

  attributes do
    uuid_primary_key :id

    attribute :title, :string do
      allow_nil? false
      public? true
      constraints min_length: 1, max_length: 1000, trim?: true
      description "Title of the note"
    end

    attribute :content, :string do
      allow_nil? false
      public? true
      constraints min_length: 1, trim?: true
      description "Main content of the note - can be very long"
    end

    # WORKED OUT WITH THE CONTENT, never written by hand nor on a read —
    # `MishkaDocument.Resources.Changes.ContentFacts`.
    attribute :content_components, {:array, :string} do
      allow_nil? true
      public? false
      description "The components the content's markers name, nil when it names none"
    end

    # WORKED OUT WITH THE CONTENT, never written by hand nor on a read —
    # `MishkaDocument.Resources.Changes.ContentFacts`.
    attribute :content_icons, {:array, :string} do
      allow_nil? true
      public? false
      description "The icon classes the content names, nil when it names none"
    end

    # WORKED OUT WITH THE CONTENT, never written by hand nor on a read —
    # `MishkaDocument.Resources.Changes.ContentFacts`.
    attribute :content_classes, {:array, :string} do
      allow_nil? true
      public? false
      description "The classes the content writes, nil when it writes none"
    end

    attribute :order_position, :integer do
      allow_nil? true
      public? true
      default 0
      constraints min: 0
      description "Position for ordering notes within a section"
    end

    attribute :change_version, :string do
      allow_nil? true
      public? true
      default "0.0.1"
      constraints max_length: 50, trim?: true
      description "Semantic version of this note (e.g., 1.2.0, 2.0.0-beta-1)"
    end

    attribute :content_review_status, :atom do
      allow_nil? false
      public? true
      default :pending
      constraints one_of: [:pending, :approved, :rejected, :needs_revision, :archived]
      description "Content review status (pending, approved, rejected, needs_revision, archived)"
    end

    attribute :technical_review_status, :atom do
      allow_nil? false
      public? true
      default :pending
      constraints one_of: [:pending, :approved, :rejected, :needs_revision, :archived]

      description "Technical review status (pending, approved, rejected, needs_revision, archived)"
    end

    attribute :schema, {:array, :map} do
      default []
      public? true
      description "Schema.org structured data"
    end

    attribute :seo_tags, {:array, :map} do
      default []
      public? true

      constraints items: [
                    fields: [
                      tag: [
                        type: :string,
                        allow_nil?: false
                      ],
                      attrs: [
                        type: :map,
                        allow_nil?: false
                      ],
                      content: [
                        type: :string,
                        allow_nil?: true
                      ]
                    ]
                  ]

      description "SEO meta tags and structured data"
    end

    create_timestamp :inserted_at
    update_timestamp :updated_at
  end

  relationships do
    belongs_to :site, MishkaCmsCore.Runtime.Site do
      read_action :read_any
      allow_nil? false
      public? true
      description "The site this note belongs to"
    end

    belongs_to :section, MishkaDocument.Section do
      allow_nil? false
      public? true
      description "The section this note belongs to"
    end

    belongs_to :master_section, MishkaDocument.Section do
      public? true
      source_attribute :section_id
      destination_attribute :id
      define_attribute? false
      read_action :read_any
      description "Section relationship that bypasses multitenancy (for master users)"

      filter expr(not is_nil(type(^actor(:id), :uuid)) and is_nil(type(^actor(:site_id), :uuid)))
    end

    has_many :note_drafts, MishkaDocument.NoteDraft do
      public? true
      destination_attribute :source_note_id
      description "All drafts for this note"
    end
  end

  calculations do
    calculate :content_word_count, :integer, MishkaDocument.Resources.Calculations.WordCount do
      public? true
      description "Returns word count of the note content"
    end
  end

  aggregates do
    count :pending_note_draft_content_review_count, :note_drafts do
      public? true
      authorize? false
      multitenancy :bypass
      filter expr(content_review_status == :pending)
      description "Returns count of note drafts pending content review for this note"
    end

    count :pending_note_draft_technical_review_count, :note_drafts do
      public? true
      authorize? false
      multitenancy :bypass
      filter expr(technical_review_status == :pending)
      description "Returns count of note drafts pending technical review for this note"
    end

    count :approved_note_draft_count, :note_drafts do
      public? true
      authorize? false
      multitenancy :bypass
      filter expr(content_review_status == :approved and technical_review_status == :approved)
      description "Returns count of note drafts with both reviews approved for this note"
    end
  end

  # No identities needed - notes are unique by their section relationship
end
