defmodule MishkaDocument.SectionBookmark do
  @moduledoc """
  Manages user bookmarks for documentation sections.

  This resource represents bookmarks that users create to save documentation sections
  for later reading or reference. Each bookmark links a user to a specific section,
  creating a personal documentation reference list.

  A bookmark keeps the section it was made for. To bookmark another section, remove this one
  (`:remove`) and create a new one (`:create`).
  """
  use Ash.Resource,
    otp_app: :mishka_document,
    domain: MishkaDocument,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshJsonApi.Resource],
    authorizers: [Ash.Policy.Authorizer],
    notifiers: [MishkaCmsCore.Runtime.Resources.Notifiers.PluginHook]

  require Ash.Query
  use Gettext, backend: MishkaCmsCore.Gettext

  # Database configuration for section_bookmarks storage with indexing
  postgres do
    table "mishka_document_section_bookmarks"
    repo Application.compile_env!(:mishka_cms_core, :repo)

    custom_indexes do
      index [:user_id]
      index [:inserted_at]
    end

    references do
      reference :section, on_delete: :delete
      reference :user, on_delete: :delete
    end

    identity_index_names unique_user_section_bookmark: "doc_sec_bkm_uniq_idx"
  end

  # JSON API configuration for REST endpoints
  json_api do
    type "section_bookmark"

    includes [:section, :user]
  end

  actions do
    defaults [:read, :destroy]

    default_accept [:section_id, :user_id]

    create :create do
      description "Creates a bookmark for a documentation section"
      primary? true
      accept [:section_id]
      upsert? true
      upsert_identity :unique_user_section_bookmark

      # Validate section belongs to the same tenant as the user
      validate {MishkaCmsCore.Runtime.Resources.Validations.TenantIsolation,
                field: :section_id,
                resource: MishkaDocument.Section,
                message:
                  dgettext_noop("errors", "Section not found or does not belong to your site.")}

      # A section its actor may not open takes nothing from them, as though it were not there.
      validate {MishkaDocument.Resources.Validations.OpenToActor,
                field: :section_id,
                resource: MishkaDocument.Section,
                lock: :effective_permissions,
                message:
                  dgettext_noop("errors", "Section not found or does not belong to your site.")}

      change relate_actor(:user, allow_nil?: true)
    end

    read :my_bookmarks do
      description "Reads all bookmarks for a specific user with pagination"
      pagination offset?: true, default_limit: 20, max_page_size: 100, countable: true

      validate {MishkaCmsCore.Runtime.Resources.Validations.TenantContext, require_master: false}

      prepare fn query, context ->
        if actor = context.actor do
          query
          |> Ash.Query.filter(user_id == ^actor.id)
          |> Ash.Query.filter(
            section.content_review_status == :approved and
              section.technical_review_status == :approved
          )
        else
          Ash.Query.filter(query, false)
        end
      end
    end

    destroy :remove do
      description "Removes a bookmark"
      primary? true
    end
  end

  # Authorization policies - users can only manage their own bookmarks
  policies do
    # Require actor for my_bookmarks action
    bypass action(:my_bookmarks) do
      access_type :strict
      authorize_if actor_present()
    end

    bypass action_type(:read) do
      authorize_if expr(user_id == ^actor(:id))
    end

    bypass action_type(:create) do
      authorize_if actor_present()
    end

    bypass action_type(:destroy) do
      authorize_if expr(user_id == ^actor(:id))
    end

    # The section area: a master to every site's bookmarks, a site admin to its own site's
    policy always() do
      forbid_unless {MishkaCmsCore.Accounts.Checks.AccessPermissions,
                     permissions: [
                       "admin:dashboard:document:section",
                       "admin:api:document:section"
                     ]}

      authorize_if actor_attribute_equals(:site_id, nil)
      authorize_if expr(owning_section.site_id == ^actor(:site_id))
    end
  end

  # The owner is a user of the section's site or a master.
  validations do
    validate {MishkaCmsCore.Runtime.Resources.Validations.SameSiteReference,
              field: :user_id,
              resource: MishkaCmsCore.Accounts.User,
              label: dgettext_noop("errors", "user"),
              read_action: :related,
              shared?: true,
              own: {:section_id, MishkaDocument.Section, :master_get}},
             where: [changing(:user_id)],
             only_when_valid?: true
  end

  attributes do
    uuid_primary_key :id

    create_timestamp :inserted_at, public?: true
    update_timestamp :updated_at, public?: true
  end

  relationships do
    belongs_to :section, MishkaDocument.Section do
      description "The documentation section being bookmarked"
      allow_nil? false
      public? true
      read_action :public_list
    end

    belongs_to :owning_section, MishkaDocument.Section do
      source_attribute :section_id
      define_attribute? false

      description "The bookmarked section whatever its review state, which says the bookmark's site"
    end

    belongs_to :user, MishkaCmsCore.Accounts.User do
      # How any resource reaches an account — see `MishkaCmsCore.Accounts.User`'s `:related`.
      read_action :related
      sortable? false
      description "The user who bookmarked the section"
      allow_nil? false
      public? true

      domain MishkaCmsCore.Accounts
    end
  end

  identities do
    identity :unique_user_section_bookmark, [:user_id, :section_id] do
      description "Ensures each user can only bookmark a section once"
    end
  end
end
