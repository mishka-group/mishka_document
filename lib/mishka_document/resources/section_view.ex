defmodule MishkaDocument.SectionView do
  @moduledoc """
  Tracks unique page views for documentation sections using upsert.

  Simple and efficient view tracking:
  - For authenticated users: One view per user per section (by user_id + section_id); the user is
    the actor, never a `user_id` in the input
  - For guests: One view per IP per section (by ip_address + section_id)
  - Uses upsert: No queries, no time checks - just insert or ignore
  - Works for both JSON API and Phoenix controllers
  """
  use Ash.Resource,
    otp_app: :mishka_document,
    domain: MishkaDocument,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshJsonApi.Resource, GuardedStruct.AshResource],
    authorizers: [Ash.Policy.Authorizer],
    notifiers: [MishkaCmsCore.Runtime.Resources.Notifiers.PluginHook]

  use Gettext, backend: MishkaCmsCore.Gettext

  postgres do
    table "mishka_document_section_views"
    repo Application.compile_env!(:mishka_cms_core, :repo)

    custom_indexes do
      index [:section_id]
    end

    references do
      reference :section, on_delete: :delete
      reference :user, on_delete: :delete
    end

    # SQL translations for conditional identities
    identity_wheres_to_sql unique_user_view: "user_id IS NOT NULL",
                           unique_guest_view: "user_id IS NULL"
  end

  json_api do
    type "section_view"
  end

  guardedstruct do
    auto_wire true

    field :ip_address, :string,
      derives: "sanitize(trim) validate(string, not_empty, max_len=45, ip)"

    field :user_agent, :string,
      derives: "sanitize(trim, no_zero_width) validate(optional=[string, max_len=500])"

    field :referer, :string, derives: "sanitize(trim) validate(optional=[string, max_len=500])"
  end

  actions do
    defaults [:read]

    create :create do
      description "Track a page view (upserts automatically - no duplicates)"
      primary? true
      accept [:section_id, :ip_address, :user_agent, :referer]

      validate {MishkaCmsCore.Runtime.Resources.Validations.TenantIsolation,
                field: :section_id, resource: MishkaDocument.Section}

      change relate_actor(:user, allow_nil?: true)

      upsert? true
      upsert_identity :unique_view
      upsert_fields []
    end
  end

  policies do
    # Anyone can track views
    policy action_type(:create) do
      authorize_if always()
    end

    # The section area reads view data: a master every site's, a site admin its own site's
    policy action_type(:read) do
      forbid_unless {MishkaCmsCore.Accounts.Checks.AccessPermissions,
                     permissions: [
                       "admin:dashboard:document:section",
                       "admin:api:document:section"
                     ]}

      authorize_if actor_attribute_equals(:site_id, nil)
      authorize_if expr(section.site_id == ^actor(:site_id))
    end
  end

  # The viewer is a user of the section's site or a master.
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

    attribute :ip_address, :string do
      allow_nil? false
      public? true
      constraints max_length: 45
      description "IP address (required for guest tracking)"
    end

    attribute :user_agent, :string do
      allow_nil? true
      public? true
      constraints max_length: 500
      description "Browser user agent"
    end

    attribute :referer, :string do
      allow_nil? true
      public? true
      constraints max_length: 500
      description "HTTP referer"
    end

    create_timestamp :inserted_at
  end

  relationships do
    belongs_to :section, MishkaDocument.Section do
      description "The documentation section being viewed"
      allow_nil? false
      public? true
    end

    belongs_to :user, MishkaCmsCore.Accounts.User do
      # How any resource reaches an account — see `MishkaCmsCore.Accounts.User`'s `:related`.
      read_action :related
      sortable? false
      description "The user who viewed (null for guests)"
      allow_nil? true
      public? true

      domain MishkaCmsCore.Accounts
    end
  end

  identities do
    # For authenticated users: unique by user_id + section_id
    identity :unique_user_view, [:section_id, :user_id],
      where: expr(not is_nil(user_id)),
      nils_distinct?: false

    # For guests: unique by ip_address + section_id
    identity :unique_guest_view, [:section_id, :ip_address],
      where: expr(is_nil(user_id)),
      nils_distinct?: false

    # Combined identity for upsert
    identity :unique_view, [:section_id, :user_id, :ip_address], nils_distinct?: false
  end
end
