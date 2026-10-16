# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_document/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaDocument.IssueComment do
  @moduledoc """
  Manages comments on documentation issues.

  This resource represents comments posted on issues for discussions, updates,
  and collaborative problem-solving. Each comment belongs to an issue and is
  authored by a contributor (user).

  Comments support multi-tenancy through their parent issue relationship and
  implement soft deletion via archival for data retention.

  Multi-tenant isolation is inherited from the parent issue.
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

  require Ash.Query

  @admin_fields [
    :issue_id,
    :contributor_id,
    :content,
    :site_id
  ]

  # Database configuration for issue comments storage with indexing
  postgres do
    table "mishka_document_issue_comments"
    repo Application.compile_env!(:mishka_cms_core, :repo)

    # Database-level optimization for archived records
    base_filter_sql "(archived_at IS NULL)"

    custom_indexes do
      index [:issue_id]
      index [:contributor_id]
      index [:site_id]
    end

    references do
      reference :site, on_delete: :delete
      reference :issue, on_delete: :delete
      reference :contributor, on_delete: :nilify
    end

    check_constraints do
      check_constraint :content, "content_not_empty",
        check: "length(content) >= 1",
        message: dgettext_noop("errors", "Content cannot be empty.")
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
    type "issue_comment"

    includes [:issue, :contributor, :master_issue, :master_contributor]
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
        name :issue_comment_form
      end

      fields do
        field :site_id, :relation do
          restricted true
          required true
          show_on :create
          readonly fn state -> Map.has_key?(state.defaults || %{}, :site_id) end
          display_field :name
          search_field :name
          mode :search

          ui do
            label fn -> dgettext("mishka_gervaz", "Site") end
          end
        end

        field :issue_id, :relation do
          required true
          readonly true
          display_field :title
          search_field :title
          mode :search

          ui do
            label fn -> dgettext("mishka_gervaz", "Issue") end
          end
        end

        field :contributor_id, :relation do
          restricted true
          required true
          show_on :create
          display_field :email
          search_field :email
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
              Ash.Query.filter(query, site_id == ^site_id or is_nil(site_id))
            else
              query
            end
          end

          ui do
            label fn -> dgettext("mishka_gervaz", "Contributor") end
          end
        end

        field :content, :textarea do
          required true

          ui do
            label fn -> dgettext("mishka_gervaz", "Content") end
            rows 3
          end
        end
      end

      groups do
        group :meta do
          fields [:site_id, :issue_id, :contributor_id]

          ui do
            label fn -> dgettext("mishka_gervaz", "Meta") end
            columns 2
          end
        end

        group :content do
          fields [:content]

          ui do
            label fn -> dgettext("mishka_gervaz", "Content") end
            columns 1
          end
        end
      end

      hooks do
        on_cancel fn state -> state end
      end
    end
  end

  guardedstruct do
    auto_wire true

    field :content, :string,
      derives: "sanitize(basic_html) validate(string, not_empty, min_len=1)"
  end

  actions do
    defaults [:read]

    default_accept @admin_fields

    create :create do
      primary? true
      accept @admin_fields -- [:site_id, :contributor_id]

      validate present([:issue_id])
      validate present([:content])

      validate {MishkaCmsCore.Runtime.Resources.Validations.TenantContext, require_master: false}

      validate fn changeset, context ->
        if is_nil(context.actor) do
          {:error,
           field: :contributor_id, message: dgettext_noop("errors", "contributor is required")}
        else
          :ok
        end
      end

      # Validate issue belongs to the same tenant
      validate {MishkaCmsCore.Runtime.Resources.Validations.TenantIsolation,
                field: :issue_id,
                resource: MishkaDocument.Issue,
                message:
                  dgettext_noop("errors", "Issue not found or does not belong to your site.")}

      # Prevent comments on closed or resolved issues
      validate fn changeset, context ->
                 issue_id = Ash.Changeset.get_attribute(changeset, :issue_id)

                 case Ash.get(MishkaDocument.Issue, issue_id, Ash.Scope.to_opts(context)) do
                   {:ok, %{status: :closed}} ->
                     {:error,
                      field: :issue_id,
                      message: dgettext_noop("errors", "Cannot add comments to a closed issue.")}

                   {:ok, %{status: :resolved}} ->
                     {:error,
                      field: :issue_id,
                      message: dgettext_noop("errors", "Cannot add comments to a resolved issue.")}

                   _ ->
                     :ok
                 end
               end,
               only_when_valid?: true

      change &Ash.Changeset.force_change_attribute(&1, :site_id, &2.tenant)
      change relate_actor(:contributor, allow_nil?: true)

      # Add metadata for event tracking
      change fn changeset, context ->
        Ash.Changeset.put_context(changeset, :ash_events_metadata, %{
          site_id: context.tenant,
          title: "Issue Comment"
        })
      end

      description "Creates comment for tenant users - requires tenant context, auto-assigns site_id and contributor from actor"
    end

    create :master_create do
      validate present([:issue_id])
      validate present([:contributor_id])
      validate present([:content])
      validate present([:site_id])

      validate {MishkaCmsCore.Runtime.Resources.Validations.TenantContext, require_master: true}

      # Prevent comments on closed or resolved issues
      validate fn changeset, _context ->
                 issue_id = Ash.Changeset.get_attribute(changeset, :issue_id)

                 case Ash.get(MishkaDocument.Issue, issue_id,
                        action: :master_get,
                        authorize?: false
                      ) do
                   {:ok, %{status: :closed}} ->
                     {:error,
                      field: :issue_id,
                      message: dgettext_noop("errors", "Cannot add comments to a closed issue.")}

                   {:ok, %{status: :resolved}} ->
                     {:error,
                      field: :issue_id,
                      message: dgettext_noop("errors", "Cannot add comments to a resolved issue.")}

                   _ ->
                     :ok
                 end
               end,
               only_when_valid?: true

      change fn changeset, _context ->
        site_id = Ash.Changeset.get_attribute(changeset, :site_id)
        Ash.Changeset.set_tenant(changeset, site_id)
      end

      # Add metadata for event tracking
      change fn changeset, _context ->
        Ash.Changeset.put_context(changeset, :ash_events_metadata, %{
          site_id: Ash.Changeset.get_attribute(changeset, :site_id),
          title: "Issue Comment"
        })
      end

      description "Creates comment for master users - requires explicit site_id"
    end

    update :update do
      primary? true
      require_atomic? false
      transaction? true
      accept [:content]

      validate {MishkaCmsCore.Runtime.Resources.Validations.TenantContext, require_master: false}

      # A master's comment is read-only to a tenant
      validate MishkaDocument.Resources.Validations.MasterCommentReadOnly

      # Validate issue belongs to the same tenant (if issue_id is updated)
      validate {MishkaCmsCore.Runtime.Resources.Validations.TenantIsolation,
                field: :issue_id,
                resource: MishkaDocument.Issue,
                message:
                  dgettext_noop("errors", "Issue not found or does not belong to your site.")}

      # Add metadata for event tracking
      change fn changeset, context ->
        Ash.Changeset.put_context(changeset, :ash_events_metadata, %{
          site_id: context.tenant || changeset.data.site_id,
          title: "Issue Comment"
        })
      end

      description "Updates comment content for tenant users - requires tenant context, prevents site_id changes"
    end

    update :master_update do
      description "Updates comment for master users - bypasses multi-tenancy, prevents site_id changes"
      require_atomic? false
      transaction? true
      accept [:content]
      multitenancy :bypass

      validate {MishkaCmsCore.Runtime.Resources.Validations.TenantContext, require_master: true}

      validate absent(:archived_at) do
        message dgettext_noop(
                  "errors",
                  "Cannot edit archived comment. Please unarchive it first."
                )
      end

      # Add metadata for event tracking
      change fn changeset, _context ->
        Ash.Changeset.put_context(changeset, :ash_events_metadata, %{
          site_id: changeset.data.site_id,
          title: "Issue Comment"
        })
      end
    end

    read :master_read do
      description "Reads all comments system-wide, bypassing tenant filtering (master users only)"
      multitenancy :bypass
      pagination offset?: true, default_limit: 50, max_page_size: 200, countable: true

      validate {MishkaCmsCore.Runtime.Resources.Validations.TenantContext, require_master: true}
    end

    read :master_get do
      multitenancy :bypass
      get? true
      description "Retrieves single comment by ID, bypassing tenant filtering"

      validate {MishkaCmsCore.Runtime.Resources.Validations.TenantContext, require_master: true}
    end

    read :by_issue do
      description "Retrieves all comments for a specific issue"
      argument :issue_id, :uuid, allow_nil?: false
      filter expr(issue_id == ^arg(:issue_id))
      pagination offset?: true, default_limit: 50, max_page_size: 200, countable: true

      validate {MishkaCmsCore.Runtime.Resources.Validations.TenantContext, require_master: false}

      prepare fn query, _context ->
        Ash.Query.sort(query, inserted_at: :asc)
      end
    end

    read :by_contributor do
      description "Retrieves all comments by a specific contributor"
      argument :contributor_id, :uuid, allow_nil?: false
      filter expr(contributor_id == ^arg(:contributor_id))
      pagination offset?: true, default_limit: 50, max_page_size: 200, countable: true

      validate {MishkaCmsCore.Runtime.Resources.Validations.TenantContext, require_master: false}

      prepare fn query, _context ->
        Ash.Query.sort(query, inserted_at: :desc)
      end
    end

    read :archived do
      filter expr(not is_nil(archived_at))
      pagination offset?: true, default_limit: 20, max_page_size: 100, countable: true

      validate {MishkaCmsCore.Runtime.Resources.Validations.TenantContext, require_master: false}

      description "Lists archived comments within current tenant context"
    end

    read :get_archived do
      get? true
      filter expr(not is_nil(archived_at))

      validate {MishkaCmsCore.Runtime.Resources.Validations.TenantContext, require_master: false}

      description "Retrieves single archived comment for recovery or inspection (tenant users)"
    end

    read :master_get_archived do
      get? true
      multitenancy :bypass
      filter expr(not is_nil(archived_at))

      validate {MishkaCmsCore.Runtime.Resources.Validations.TenantContext, require_master: true}

      description "Retrieves single archived comment for recovery or inspection (master users)"
    end

    read :master_archived do
      multitenancy :bypass
      filter expr(not is_nil(archived_at))
      pagination offset?: true, default_limit: 20, max_page_size: 100, countable: true

      validate {MishkaCmsCore.Runtime.Resources.Validations.TenantContext, require_master: true}

      description "Lists all archived comments system-wide, bypassing tenant filtering"
    end

    destroy :destroy do
      description "Soft deletes comment by archiving (tenant users)"
      primary? true
      require_atomic? false

      validate {MishkaCmsCore.Runtime.Resources.Validations.TenantContext, require_master: false}

      # A master's comment is read-only to a tenant
      validate MishkaDocument.Resources.Validations.MasterCommentReadOnly

      validate fn changeset, _context ->
        if changeset.data.archived_at do
          {:error,
           field: :archived_at, message: dgettext_noop("errors", "Comment is already archived.")}
        else
          :ok
        end
      end

      # Add metadata for event tracking
      change fn changeset, context ->
        Ash.Changeset.put_context(changeset, :ash_events_metadata, %{
          site_id: context.tenant || changeset.data.site_id,
          title: "Issue Comment"
        })
      end
    end

    destroy :master_destroy do
      description "Soft deletes comment by archiving (master users) - bypasses multi-tenancy"
      require_atomic? false
      multitenancy :bypass

      validate {MishkaCmsCore.Runtime.Resources.Validations.TenantContext, require_master: true}

      validate fn changeset, _context ->
        if changeset.data.archived_at do
          {:error,
           field: :archived_at, message: dgettext_noop("errors", "Comment is already archived.")}
        else
          :ok
        end
      end

      change fn changeset, _context ->
        Ash.Changeset.put_context(changeset, :ash_events_metadata, %{
          site_id: changeset.data.site_id,
          title: "Issue Comment"
        })
      end
    end

    update :unarchive do
      accept []
      require_atomic? false

      validate {MishkaCmsCore.Runtime.Resources.Validations.TenantContext, require_master: false}

      # A master's comment is read-only to a tenant
      validate MishkaDocument.Resources.Validations.MasterCommentReadOnly

      change set_attribute(:archived_at, nil)

      atomic_upgrade_with :archived

      # Add metadata for event tracking
      change fn changeset, context ->
        Ash.Changeset.put_context(changeset, :ash_events_metadata, %{
          site_id: context.tenant || changeset.data.site_id,
          title: "Issue Comment"
        })
      end

      description "Restores archived comment (tenant users)"
    end

    update :master_unarchive do
      description "Restores archived comment (master users) - bypasses multi-tenancy"
      accept []
      require_atomic? false
      multitenancy :bypass

      validate {MishkaCmsCore.Runtime.Resources.Validations.TenantContext, require_master: true}

      validate fn changeset, _context ->
        if is_nil(changeset.data.archived_at) do
          {:error,
           field: :archived_at, message: dgettext_noop("errors", "Comment is not archived.")}
        else
          :ok
        end
      end

      change set_attribute(:archived_at, nil)

      # Add metadata for event tracking
      change fn changeset, _context ->
        Ash.Changeset.put_context(changeset, :ash_events_metadata, %{
          site_id: changeset.data.site_id,
          title: "Issue Comment"
        })
      end
    end

    destroy :permanent_destroy do
      require_atomic? false

      validate {MishkaCmsCore.Runtime.Resources.Validations.TenantContext, require_master: false}

      # A master's comment is read-only to a tenant
      validate MishkaDocument.Resources.Validations.MasterCommentReadOnly

      # Add metadata for event tracking
      change fn changeset, context ->
        Ash.Changeset.put_context(changeset, :ash_events_metadata, %{
          site_id: context.tenant || changeset.data.site_id,
          title: "Issue Comment"
        })
      end

      description "Permanently removes comment from database (tenant users) - use with extreme caution"
    end

    destroy :master_permanent_destroy do
      description "Permanently removes comment from database (master users) - bypasses multi-tenancy, irreversible"
      require_atomic? false
      multitenancy :bypass

      validate {MishkaCmsCore.Runtime.Resources.Validations.TenantContext, require_master: true}

      change fn changeset, _context ->
        Ash.Changeset.put_context(changeset, :ash_events_metadata, %{
          site_id: changeset.data.site_id,
          title: "Issue Comment"
        })
      end
    end
  end

  # Authorization policies for comment access
  policies do
    policy always() do
      # When accessing from Issue resource via comments relationship
      authorize_if accessing_from(MishkaDocument.Issue, :comments)
      authorize_if accessing_from(MishkaDocument.Issue, :master_comments)

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
    prefix "issue_comment"

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
              field: :issue_id,
              resource: MishkaDocument.Issue,
              label: dgettext_noop("errors", "issue"),
              read_action: :master_get},
             where: [changing(:issue_id)],
             only_when_valid?: true

    validate {MishkaCmsCore.Runtime.Resources.Validations.SameSiteReference,
              field: :contributor_id,
              resource: MishkaCmsCore.Accounts.User,
              label: dgettext_noop("errors", "user"),
              read_action: :related,
              shared?: true},
             where: [changing(:contributor_id)]
  end

  # Multi-tenancy configuration - comments are always site-specific
  multitenancy do
    strategy :attribute
    attribute :site_id
    # Comments are NEVER global - always site-specific
    global? false
  end

  attributes do
    uuid_primary_key :id

    attribute :content, :string do
      allow_nil? false
      public? true
      constraints min_length: 1, trim?: true
      description "Content of the comment"
    end

    create_timestamp :inserted_at
    update_timestamp :updated_at
  end

  relationships do
    belongs_to :site, MishkaCmsCore.Runtime.Site do
      read_action :read_any
      allow_nil? false
      public? true
      description "The site this comment belongs to"
    end

    belongs_to :issue, MishkaDocument.Issue do
      allow_nil? false
      public? true
      description "The issue this comment is on"
    end

    belongs_to :master_issue, MishkaDocument.Issue do
      public? true
      source_attribute :issue_id
      define_attribute? false
      read_action :master_read
      description "The issue this comment is on (master admin access, bypass tenant)"

      filter expr(not is_nil(type(^actor(:id), :uuid)) and is_nil(type(^actor(:site_id), :uuid)))
    end

    belongs_to :contributor, MishkaCmsCore.Accounts.User do
      # How any resource reaches an account — see `MishkaCmsCore.Accounts.User`'s `:related`.
      read_action :related
      sortable? false
      allow_nil? true
      public? true
      description "The user who posted this comment"

      domain MishkaCmsCore.Accounts
    end

    belongs_to :master_contributor, MishkaCmsCore.Accounts.User do
      # How any resource reaches an account — see `MishkaCmsCore.Accounts.User`'s `:related`.
      read_action :related
      sortable? false
      public? true
      source_attribute :contributor_id
      define_attribute? false
      description "The user who posted this comment (master admin access)"

      domain MishkaCmsCore.Accounts
      filter expr(not is_nil(type(^actor(:id), :uuid)) and is_nil(type(^actor(:site_id), :uuid)))
    end
  end

  calculations do
    calculate :authored_by_master?,
              :boolean,
              MishkaDocument.Resources.Calculations.AuthoredByMaster do
      description "Whether a master (a user with no site) wrote this comment - a tenant cannot edit or delete it"
    end
  end
end
