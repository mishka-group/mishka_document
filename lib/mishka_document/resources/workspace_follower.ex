defmodule MishkaDocument.WorkspaceFollower do
  @moduledoc """
  Manages user follows for documentation workspaces.

  This resource represents follow relationships where users can follow workspaces to
  stay updated with the workspace's documentation updates. Each follow links a user
  to a specific workspace and tracks when the follow occurred and notification preferences.

  The unique constraint on follower_user_id and workspace_id ensures each user can
  only follow a specific workspace once. The notification_enabled field allows users
  to control whether they receive notifications about the workspace's new content,
  updates, or new versions.

  This resource has no multitenancy of its own, so a follow may only name a workspace of the site it
  is made for — see `MishkaCmsCore.Runtime.Resources.Validations.TenantIsolation`. Database-level
  constraints ensure data integrity with cascade deletes when workspaces or users are removed.
  """
  use Ash.Resource,
    otp_app: :mishka_document,
    domain: MishkaDocument,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshJsonApi.Resource, GuardedStruct.AshResource],
    authorizers: [Ash.Policy.Authorizer],
    notifiers: [MishkaCmsCore.Runtime.Resources.Notifiers.PluginHook]

  require Ash.Query
  use Gettext, backend: MishkaCmsCore.Gettext

  # Database configuration for workspace_followers storage with indexing
  postgres do
    table "mishka_document_workspace_followers"
    repo Application.compile_env!(:mishka_cms_core, :repo)

    custom_indexes do
      index [:workspace_id]
      index [:follower_user_id]
      index [:followed_at]
      index [:notification_enabled]
    end

    references do
      reference :workspace, on_delete: :delete
      reference :follower_user, on_delete: :delete, name: "user_id"
    end

    identity_index_names unique_follower_workspace: "doc_ws_fol_uniq_idx"
  end

  # JSON API configuration for REST endpoints
  json_api do
    type "workspace_follower"

    includes [:workspace]
  end

  guardedstruct do
    auto_wire true

    field :followed_at, :utc_datetime_usec,
      derives: "validate(optional=[utc_datetime, past_datetime])"

    field :notification_enabled, :boolean, derives: "validate(boolean)"
  end

  actions do
    defaults [:read, :destroy]

    default_accept [:workspace_id, :follower_user_id, :notification_enabled]

    create :create do
      description "Follows a workspace"
      primary? true
      upsert? true
      accept [:workspace_id, :notification_enabled]
      upsert_identity :unique_follower_workspace

      validate {MishkaCmsCore.Runtime.Resources.Validations.TenantIsolation,
                field: :workspace_id,
                resource: MishkaDocument.Workspace,
                message:
                  dgettext_noop("errors", "Workspace not found or does not belong to your site.")}

      # A workspace its actor may not open takes nothing from them, as though it were not there.
      validate {MishkaDocument.Resources.Validations.OpenToActor,
                field: :workspace_id,
                resource: MishkaDocument.Workspace,
                lock: :permissions,
                message:
                  dgettext_noop("errors", "Workspace not found or does not belong to your site.")}

      change relate_actor(:follower_user, allow_nil?: true)

      change fn changeset, _context ->
        Ash.Changeset.force_change_attribute(changeset, :followed_at, DateTime.utc_now())
      end
    end

    read :by_user do
      description "Reads all workspaces followed by a specific user with pagination"
      argument :follower_user_id, :uuid, allow_nil?: false
      filter expr(follower_user_id == ^arg(:follower_user_id))
      pagination offset?: true, default_limit: 20, max_page_size: 100, countable: true
    end

    read :my_following do
      description "Reads all my following workspaces"
      pagination offset?: true, default_limit: 20, max_page_size: 100, countable: true

      validate {MishkaCmsCore.Runtime.Resources.Validations.TenantContext, require_master: false}

      prepare fn query, context ->
        if actor = context.actor do
          query
          |> Ash.Query.filter(follower_user_id == ^actor.id)
          |> Ash.Query.filter(workspace.status == :active)
        else
          Ash.Query.filter(query, false)
        end
      end
    end

    read :by_workspace do
      description "Reads all followers of a specific workspace"
      argument :workspace_id, :uuid, allow_nil?: false
      filter expr(workspace_id == ^arg(:workspace_id))
      pagination offset?: true, default_limit: 20, max_page_size: 100, countable: true
    end

    update :toggle_notifications do
      description "Toggles notification preference for a follow"
      accept [:notification_enabled]
      require_atomic? false
    end

    destroy :unfollow do
      description "Unfollows a workspace"
      primary? true
    end
  end

  # Authorization policies - users can only manage their own follows
  policies do
    bypass action(:my_following) do
      access_type :strict
      authorize_if actor_present()
    end

    bypass action_type(:read) do
      authorize_if expr(follower_user_id == ^actor(:id))
    end

    bypass action_type(:create) do
      authorize_if actor_present()
    end

    bypass action_type(:update) do
      authorize_if expr(follower_user_id == ^actor(:id))
    end

    bypass action_type(:destroy) do
      authorize_if expr(follower_user_id == ^actor(:id))
    end

    # The workspace area: a master to every site's follows, a site admin to its own site's
    policy always() do
      forbid_unless {MishkaCmsCore.Accounts.Checks.AccessPermissions,
                     permissions: [
                       "admin:dashboard:document:workspace",
                       "admin:api:document:workspace"
                     ]}

      authorize_if actor_attribute_equals(:site_id, nil)
      authorize_if expr(owning_workspace.site_id == ^actor(:site_id))
    end
  end

  # The follower is a user of the workspace's site or a master.
  validations do
    validate {MishkaCmsCore.Runtime.Resources.Validations.SameSiteReference,
              field: :follower_user_id,
              resource: MishkaCmsCore.Accounts.User,
              label: dgettext_noop("errors", "user"),
              read_action: :related,
              shared?: true,
              own: {:workspace_id, MishkaDocument.Workspace, :master_get}},
             where: [changing(:follower_user_id)],
             only_when_valid?: true
  end

  attributes do
    uuid_primary_key :id

    attribute :followed_at, :utc_datetime_usec do
      allow_nil? false
      public? true
      writable? false
      default &DateTime.utc_now/0
      description "Timestamp when the user followed the workspace"
    end

    attribute :notification_enabled, :boolean do
      default true
      public? true
      description "Whether the user wants to receive notifications about this workspace's updates"
    end

    create_timestamp :inserted_at, public?: true
    update_timestamp :updated_at, public?: true
  end

  relationships do
    belongs_to :workspace, MishkaDocument.Workspace do
      description "The workspace being followed"
      allow_nil? false
      public? true
      read_action :public_list
    end

    belongs_to :owning_workspace, MishkaDocument.Workspace do
      source_attribute :workspace_id
      define_attribute? false
      description "The followed workspace whatever its status, which says the follow's site"
    end

    belongs_to :follower_user, MishkaCmsCore.Accounts.User do
      # How any resource reaches an account — see `MishkaCmsCore.Accounts.User`'s `:related`.
      read_action :related
      sortable? false
      description "The user who is following"
      allow_nil? false
      public? true

      domain MishkaCmsCore.Accounts
    end
  end

  identities do
    identity :unique_follower_workspace, [:follower_user_id, :workspace_id] do
      description "Ensures each user can only follow a workspace once"
    end
  end
end
