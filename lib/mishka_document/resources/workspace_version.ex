defmodule MishkaDocument.WorkspaceVersion do
  @moduledoc """
  Manages workspace versions in the MishkaDocument plugin.

  This resource represents different versions of a workspace, allowing version control
  and history tracking for workspace configurations. Each version belongs to a specific
  workspace and can have various statuses (draft, alpha, beta, stable, archived).

  Versions support semantic versioning patterns (e.g., "0.0.1", "1.0.0") and can be
  cloned from existing versions. The resource tracks which version is the latest for
  a given workspace and maintains publication timestamps.

  Database-level constraints ensure data integrity with version number validation.
  Multi-tenant isolation ensures versions are properly segregated between sites through
  their parent workspace relationship.
  """
  use Ash.Resource,
    otp_app: :mishka_document,
    domain: MishkaDocument,
    data_layer: AshPostgres.DataLayer,
    extensions: [
      AshJsonApi.Resource,
      AshEvents.Events,
      MishkaGervaz.Resource,
      GuardedStruct.AshResource
    ],
    notifiers: [
      Ash.Notifier.PubSub,
      MishkaCmsCore.Runtime.Resources.Notifiers.PluginHook,
      MishkaCmsCore.Runtime.Resources.Notifiers.SitemapRefresh
    ],
    authorizers: [Ash.Policy.Authorizer]

  use MishkaGervaz.Messages, backend: MishkaCmsCore.Gettext
  import Phoenix.Component, only: [sigil_H: 2]
  import MishkaGervaz.UIAdapters.Tailwind, only: [cell_stacked: 1]

  @admin_fields [
    :workspace_id,
    :version_number,
    :version_name,
    :description,
    :status,
    :is_latest_for_version,
    :source_version_id,
    :published_at,
    :site_id
  ]

  # Database configuration for workspace versions storage with indexing
  postgres do
    table "mishka_document_workspace_versions"
    repo Application.compile_env!(:mishka_cms_core, :repo)

    references do
      reference :site, on_delete: :delete
      reference :workspace, on_delete: :delete
      # A version goes with the version it was cloned from — see `DestroyClones`.
      reference :source_version, on_delete: :delete
    end

    custom_indexes do
      index [:workspace_id]
      index [:status]
      index [:is_latest_for_version]
      index [:source_version_id]
      index [:published_at]
      index [:site_id]
    end

    check_constraints do
      check_constraint :version_number, "version_number_not_empty",
        check: "version_number != ''",
        message: dgettext_noop("errors", "Version number cannot be empty.")

      check_constraint :version_number, "version_number_length",
        check: "length(version_number) >= 1 AND length(version_number) <= 50",
        message: dgettext_noop("errors", "Version number must be between 1 and 50 characters.")

      check_constraint :status, "valid_publish_constraints",
        check: "status != 'stable' OR published_at IS NOT NULL",
        message: dgettext_noop("errors", "Stable versions must have published_at timestamp.")
    end

    identity_index_names unique_version_per_workspace: "doc_ws_ver_uniq_idx"
  end

  # JSON API configuration for REST endpoints
  json_api do
    type "workspace_version"

    includes [
      :workspace,
      :source_version,
      :lineage_as_new,
      :lineage_as_source,
      :sections,
      :tenant_sections,
      :master_sections
    ]

    paginated_includes [
      :workspace,
      :lineage_as_source,
      :sections,
      :tenant_sections,
      :master_sections
    ]
  end

  # Event tracking configuration for activity logging
  events do
    event_log MishkaDocument.EventLog

    only_actions [
      :create,
      :master_create,
      :clone,
      :master_clone,
      :detach,
      :master_detach,
      :update,
      :master_update,
      :publish,
      :mark_as_latest,
      :destroy,
      :master_destroy
    ]
  end

  mishka_gervaz do
    table do
      identity do
        name :workspace_versions
        route "/admin/dashboard/document/workspace-version/:workspace_id"
        stream_name :workspace_versions
      end

      source do
        actions do
          read {:master_read, :tenant_read}
          get {:master_get, :read}
          destroy {:master_destroy, :destroy}
        end

        preload do
          always [:clone_numbers]
          master [:master_source_version]
          tenant [:source_version]
        end
      end

      columns do
        auto_columns do
          except [
            :id,
            :version_number,
            :version_name,
            :is_latest_for_version,
            :status,
            :description
          ]

          defaults do
            sortable true
          end

          override :inserted_at
        end

        column :version_info do
          static true
          requires [:version_number, :version_name, :is_latest_for_version]
          label fn -> dgettext("mishka_gervaz", "Version") end
          position :first

          ui do
            width "minmax(170px,1.6fr)"
          end

          render fn record ->
            assigns = %{
              version_number: record.version_number,
              version_name: record.version_name,
              is_latest: record.is_latest_for_version
            }

            ~H"""
            <div class="flex min-w-0 items-center gap-[8px]">
              <.cell_stacked variant={:title} primary={@version_number} secondary={@version_name} />
              <span
                :if={@is_latest}
                class="inline-flex flex-none items-center rounded-[5px] bg-[#e6f6ee] px-[7px] py-[2px] text-[10px] font-bold uppercase tracking-[0.04em] text-[#177a53]"
              >
                {gettext("Latest")}
              </span>
            </div>
            """
          end
        end

        column :status do
          label fn -> dgettext("mishka_gervaz", "Status") end

          ui do
            type :badge

            extra %{
              colors: %{
                "draft" => "bg-[#f4f3ef] text-[#6d6a63]",
                "alpha" => "bg-[#fbf1df] text-[#a5691a]",
                "beta" => "bg-[#eef1fc] text-[#4f4bcc]",
                "rc" => "bg-[#f4ecfb] text-[#7a5bd0]",
                "stable" => "bg-[#e6f6ee] text-[#177a53]",
                "archived" => "bg-[#fbe9e7] text-[#c0473d]"
              },
              labels: %{
                "draft" => dgettext_noop("mishka_gervaz", "Draft"),
                "alpha" => dgettext_noop("mishka_gervaz", "Alpha"),
                "beta" => dgettext_noop("mishka_gervaz", "Beta"),
                "rc" => dgettext_noop("mishka_gervaz", "Rc"),
                "stable" => dgettext_noop("mishka_gervaz", "Stable"),
                "archived" => dgettext_noop("mishka_gervaz", "Archived")
              },
              default_color: "bg-[#f4f3ef] text-[#6d6a63]"
            }
          end
        end

        column :cloned_from do
          static true
          requires [:source_version_id, :master_source_version, :source_version]
          label fn -> dgettext("mishka_gervaz", "Cloned From") end
          position {:after, :status_badge}

          ui do
            width "minmax(120px,1fr)"
          end

          render fn record ->
            source =
              cond do
                record.master_source_version &&
                    !match?(%Ash.NotLoaded{}, record.master_source_version) ->
                  record.master_source_version

                record.source_version && !match?(%Ash.NotLoaded{}, record.source_version) ->
                  record.source_version

                true ->
                  nil
              end

            assigns = %{source: source}

            ~H"""
            <.cell_stacked
              variant={:meta}
              icon="hero-arrow-uturn-left"
              primary={@source && @source.version_number}
            />
            """
          end
        end

        column :published_at do
          sortable true
          label fn -> dgettext("mishka_gervaz", "Published at") end
        end

        column :inserted_at do
          sortable true
          label fn -> dgettext("mishka_gervaz", "Inserted at") end
        end

        column :updated_at do
          sortable true
          label fn -> dgettext("mishka_gervaz", "Updated at") end
        end
      end

      filters do
        filter :search, :text do
          fields [:version_number, :version_name]

          ui do
            label fn -> dgettext("mishka_gervaz", "Search") end
          end
        end

        filter :status, :select do
          options fn ->
            [
              {dgettext("mishka_gervaz", "Draft"), :draft},
              {dgettext("mishka_gervaz", "Alpha"), :alpha},
              {dgettext("mishka_gervaz", "Beta"), :beta},
              {dgettext("mishka_gervaz", "Rc"), :rc},
              {dgettext("mishka_gervaz", "Stable"), :stable},
              {dgettext("mishka_gervaz", "Archived"), :archived}
            ]
          end

          ui do
            prompt dgettext_noop("mishka_gervaz", "All Statuses")
            label fn -> dgettext("mishka_gervaz", "Status") end
          end
        end
      end

      row_actions do
        action :edit do
          type :edit
          visible :active

          js fn _record ->
            MishkaCmsCore.CoreComponents.show_modal("workspace-version-form-modal")
          end

          ui do
            label fn -> dgettext("mishka_gervaz", "Edit") end
          end
        end

        # Sends `{:row_action, "clone", %{"id" => id}}` to the versions screen, which opens its
        # clone form — `MishkaDocumentWeb.Live.Admin.Dashboard.WorkspaceVersion.Index`.
        action :clone do
          type :event
          event "clone"

          visible fn _record, state ->
            state.archive_status == :active and
              MishkaDocument.WorkspaceVersion.clone_allowed?(state.current_user)
          end

          ui do
            label fn -> dgettext("mishka_gervaz", "Clone") end
            icon "hero-document-duplicate"
          end
        end

        # Sends the `:detach` update, which unties this version from the one it was cloned from.
        action :detach do
          type :update
          action {:master_detach, :detach}

          visible fn record, state ->
            state.archive_status == :active and not is_nil(record.source_version_id) and
              MishkaDocument.WorkspaceVersion.clone_allowed?(state.current_user)
          end

          confirm &MishkaDocument.WorkspaceVersion.detach_confirm/1

          ui do
            label fn -> dgettext("mishka_gervaz", "Make independent") end
            icon "hero-link-slash"
          end
        end

        action :delete do
          type :destroy

          confirm &MishkaDocument.WorkspaceVersion.delete_confirm/1

          visible :active
        end
      end

      row do
        selectable true
      end

      bulk_actions do
        action :delete,
          type: :destroy,
          confirm:
            dgettext_noop(
              "mishka_gervaz",
              "Permanently delete selected versions? This cannot be undone."
            )
      end

      realtime do
        prefix "workspace_version"
      end

      url_sync do
        mode :bidirectional
        params [:filters, :sort, :page, :search]
        prefix "versions"
        max_filter_length 500
      end

      pagination do
        page_size 20
      end

      empty_state message: dgettext_noop("mishka_gervaz", "No versions found for this workspace"),
                  icon: "hero-document-duplicate"
    end

    form do
      identity do
        name :workspace_version_form
      end

      fields do
        field :version_number do
          required true

          ui do
            label fn -> dgettext("mishka_gervaz", "Version Number") end
            placeholder fn -> dgettext("mishka_gervaz", "e.g., 1.0.0") end
          end
        end

        field :version_name do
          ui do
            label fn -> dgettext("mishka_gervaz", "Version Name") end
            placeholder fn -> dgettext("mishka_gervaz", "Optional friendly name") end
          end
        end

        # The site a master writes for, given by the screen as the document's own.
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

        # The version a new one is copied from, among its own document's versions — the form's
        # `workspace_id` default, or the record's. Shown on an edit as the version it came from,
        # which no update changes.
        field :source_version_id, :relation do
          mode :search
          search_field :version_number
          display_field &MishkaDocument.WorkspaceVersion.source_label/1
          include_nil fn -> dgettext("mishka_gervaz", "None — an empty version") end
          readonly fn state -> state.mode == :update end

          visible fn state ->
            state.mode == :update or
              MishkaDocument.WorkspaceVersion.clone_allowed?(state.current_user)
          end

          depends_on :site_id

          load fn query, state ->
            Ash.Query.filter_input(query, %{
              site_id: MishkaDocument.WorkspaceVersion.form_site_id(state),
              workspace_id: MishkaDocument.WorkspaceVersion.form_workspace_id(state)
            })
          end

          ui do
            label fn -> dgettext("mishka_gervaz", "Clone from") end
            placeholder fn -> dgettext("mishka_gervaz", "Search a version of this document") end

            description fn ->
              dgettext(
                "mishka_gervaz",
                "Every page, note and tag of that version is copied into the new one."
              )
            end
          end
        end

        field :status, :select do
          required true

          options fn ->
            [
              {dgettext("mishka_gervaz", "Draft"), :draft},
              {dgettext("mishka_gervaz", "Alpha"), :alpha},
              {dgettext("mishka_gervaz", "Beta"), :beta},
              {dgettext("mishka_gervaz", "Rc"), :rc},
              {dgettext("mishka_gervaz", "Stable"), :stable},
              {dgettext("mishka_gervaz", "Archived"), :archived}
            ]
          end

          ui do
            label fn -> dgettext("mishka_gervaz", "Status") end
          end
        end

        field :is_latest_for_version, :toggle do
          ui do
            label fn -> dgettext("mishka_gervaz", "Mark as Latest Version") end
          end
        end

        field :published_at, :datetime do
          ui do
            label fn -> dgettext("mishka_gervaz", "Published At") end
          end
        end

        field :description, :textarea do
          ui do
            label fn -> dgettext("mishka_gervaz", "Description") end
            rows 3
          end
        end
      end

      groups do
        group :version_info do
          fields [:site_id, :version_number, :version_name, :status, :source_version_id]

          ui do
            label fn -> dgettext("mishka_gervaz", "Version Information") end
            columns 2
          end
        end

        group :settings do
          fields [:is_latest_for_version, :published_at]

          ui do
            label fn -> dgettext("mishka_gervaz", "Settings") end
            columns 2
          end
        end

        group :details do
          fields [:description]

          ui do
            label fn -> dgettext("mishka_gervaz", "Details") end
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

    field :version_number, :string,
      derives: "sanitize(trim) validate(string, not_empty, min_len=1, max_len=50, semver)"

    field :version_name, :string,
      validator: {MishkaCmsCore.PlainText, :field},
      derives: "sanitize(trim) validate(optional=[string, max_len=255])"

    field :description, :string,
      validator: {MishkaCmsCore.PlainText, :field},
      derives: "sanitize(trim) validate(optional=[string, max_len=5000])"

    field :status, :atom,
      derives: "validate(atom, enum=Atom[draft::alpha::beta::rc::stable::archived])"

    field :is_latest_for_version, :boolean, derives: "validate(boolean)"

    field :published_at, :utc_datetime,
      derives: "validate(optional=[utc_datetime, past_datetime])"
  end

  actions do
    defaults [:read]

    default_accept @admin_fields

    create :create do
      primary? true
      transaction? true
      accept @admin_fields |> List.delete(:source_version_id) |> List.delete(:site_id)

      validate present(:workspace_id)
      validate present(:version_number)
      validate present(:status)

      validate {MishkaCmsCore.Runtime.Resources.Validations.TenantContext, require_master: false}

      validate fn changeset, context ->
        workspace_id = Ash.Changeset.get_attribute(changeset, :workspace_id)
        tenant = context.tenant

        if workspace_id && tenant do
          case Ash.get(MishkaDocument.Workspace, workspace_id, tenant: tenant, authorize?: false) do
            {:ok, _} ->
              :ok

            _ ->
              {:error,
               field: :workspace_id,
               message: dgettext_noop("errors", "Workspace not found in your tenant.")}
          end
        else
          :ok
        end
      end

      change &Ash.Changeset.force_change_attribute(&1, :site_id, &2.tenant)
      change MishkaDocument.Resources.Changes.EnsureSingleLatestVersion

      validate fn changeset, _context ->
        status = Ash.Changeset.get_attribute(changeset, :status)
        published_at = Ash.Changeset.get_attribute(changeset, :published_at)

        if status == :stable and is_nil(published_at) do
          {:error,
           field: :published_at,
           message: dgettext_noop("errors", "Stable versions must have published_at timestamp.")}
        else
          :ok
        end
      end

      argument :source_version_id, :uuid do
        description "Optional version to start from: its pages, notes and tags are copied into the new one"
      end

      argument :copy_pages, :boolean do
        default true

        description "Whether a version given a source starts as a copy of its pages, notes and tags"
      end

      change fn changeset, context ->
        source_version_id = Ash.Changeset.get_argument(changeset, :source_version_id)

        if source_version_id do
          Ash.Changeset.change_attribute(changeset, :source_version_id, source_version_id)
        else
          changeset
        end
      end

      validate {MishkaCmsCore.Runtime.Resources.Validations.TenantIsolation,
                field: :source_version_id, resource: MishkaDocument.WorkspaceVersion}

      change {MishkaDocument.Resources.Changes.CloneVersion, as: :create}

      # Add metadata for event tracking
      change fn changeset, context ->
        Ash.Changeset.put_context(changeset, :ash_events_metadata, %{
          site_id: context.tenant,
          title: Ash.Changeset.get_attribute(changeset, :version_number)
        })
      end

      description "Creates workspace version for tenant users - requires tenant context, auto-assigns site_id"
    end

    create :master_create do
      transaction? true

      validate present(:workspace_id)
      validate present(:version_number)
      validate present(:status)
      validate present(:site_id)

      validate {MishkaCmsCore.Runtime.Resources.Validations.TenantContext, require_master: true}

      change fn changeset, _context ->
        site_id = Ash.Changeset.get_attribute(changeset, :site_id)
        Ash.Changeset.set_tenant(changeset, site_id)
      end

      change MishkaDocument.Resources.Changes.EnsureSingleLatestVersion

      validate fn changeset, _context ->
        status = Ash.Changeset.get_attribute(changeset, :status)
        published_at = Ash.Changeset.get_attribute(changeset, :published_at)

        if status == :stable and is_nil(published_at) do
          {:error,
           field: :published_at,
           message: dgettext_noop("errors", "Stable versions must have published_at timestamp.")}
        else
          :ok
        end
      end

      argument :source_version_id, :uuid do
        description "Optional version to start from: its pages, notes and tags are copied into the new one"
      end

      argument :copy_pages, :boolean do
        default true

        description "Whether a version given a source starts as a copy of its pages, notes and tags"
      end

      change fn changeset, context ->
        source_version_id = Ash.Changeset.get_argument(changeset, :source_version_id)

        if source_version_id do
          Ash.Changeset.change_attribute(changeset, :source_version_id, source_version_id)
        else
          changeset
        end
      end

      change {MishkaDocument.Resources.Changes.CloneVersion, as: :create}

      # Add metadata for event tracking
      change fn changeset, _context ->
        Ash.Changeset.put_context(changeset, :ash_events_metadata, %{
          site_id: Ash.Changeset.get_attribute(changeset, :site_id),
          title: Ash.Changeset.get_attribute(changeset, :version_number)
        })
      end

      description "Creates workspace version for master users - requires explicit site_id"
    end

    # A NEW VERSION COPIED FROM ANOTHER of the same document, with every page, note and tag of it —
    # `MishkaDocument.Resources.Changes.CloneVersion`. It is a draft and not the latest; its
    # workspace and site are the source's.
    create :clone do
      transaction? true
      accept [:version_number, :version_name, :description]

      argument :source_version_id, :uuid do
        allow_nil? false
        description "The version to copy"
      end

      validate present(:version_number)

      validate {MishkaCmsCore.Runtime.Resources.Validations.TenantContext, require_master: false}

      change MishkaDocument.Resources.Changes.CloneVersion

      validate {MishkaCmsCore.Runtime.Resources.Validations.TenantIsolation,
                field: :source_version_id, resource: MishkaDocument.WorkspaceVersion}

      description "Copies a version of the tenant's document, with its pages, notes and tags, into a new draft version"
    end

    create :master_clone do
      transaction? true
      accept [:version_number, :version_name, :description]

      argument :source_version_id, :uuid do
        allow_nil? false
        description "The version to copy"
      end

      validate present(:version_number)

      validate {MishkaCmsCore.Runtime.Resources.Validations.TenantContext, require_master: true}

      change MishkaDocument.Resources.Changes.CloneVersion

      description "Copies a version of any site's document, with its pages, notes and tags, into a new draft version of that site (master users only)"
    end

    update :update do
      primary? true
      require_atomic? false
      transaction? true
      # A version's source is the one it was created from; it does not change after.
      accept @admin_fields -- [:site_id, :source_version_id]

      validate {MishkaCmsCore.Runtime.Resources.Validations.TenantContext, require_master: false}

      validate {MishkaCmsCore.Runtime.Resources.Validations.TenantIsolation,
                field: :workspace_id, resource: MishkaDocument.Workspace},
               where: [changing(:workspace_id)]

      change MishkaDocument.Resources.Changes.EnsureSingleLatestVersion

      validate fn changeset, _context ->
        status = Ash.Changeset.get_attribute(changeset, :status)
        published_at = Ash.Changeset.get_attribute(changeset, :published_at)

        if status == :stable and is_nil(published_at) do
          {:error,
           field: :published_at,
           message: dgettext_noop("errors", "Stable versions must have published_at timestamp.")}
        else
          :ok
        end
      end

      # Add metadata for event tracking
      change fn changeset, context ->
        Ash.Changeset.put_context(changeset, :ash_events_metadata, %{
          site_id: context.tenant || changeset.data.site_id,
          title:
            Ash.Changeset.get_attribute(changeset, :version_number) ||
              changeset.data.version_number
        })
      end

      description "Updates workspace version for tenant users - requires tenant context, prevents site_id changes"
    end

    update :master_update do
      description "Updates workspace version for master users - bypasses multi-tenancy, prevents site_id changes"
      require_atomic? false
      transaction? true
      accept @admin_fields -- [:site_id, :workspace_id, :source_version_id]
      multitenancy :bypass

      validate {MishkaCmsCore.Runtime.Resources.Validations.TenantContext, require_master: true}

      change MishkaDocument.Resources.Changes.EnsureSingleLatestVersion

      change fn changeset, _context ->
        Ash.Changeset.put_context(changeset, :ash_events_metadata, %{
          site_id: changeset.data.site_id,
          title:
            Ash.Changeset.get_attribute(changeset, :version_name) || changeset.data.version_name
        })
      end
    end

    read :master_read do
      description "Reads all workspace versions system-wide, bypassing tenant filtering (master users only)"
      multitenancy :bypass
      pagination offset?: true, default_limit: 20, max_page_size: 100, countable: true

      validate {MishkaCmsCore.Runtime.Resources.Validations.TenantContext, require_master: true}
    end

    read :master_get do
      multitenancy :bypass
      get? true
      description "Retrieves single workspace version by ID, bypassing tenant filtering"

      validate {MishkaCmsCore.Runtime.Resources.Validations.TenantContext, require_master: true}
    end

    read :tenant_read do
      description "Reads workspace versions for the tenant with pagination (tenant users only)"
      pagination offset?: true, default_limit: 20, max_page_size: 100, countable: true

      validate {MishkaCmsCore.Runtime.Resources.Validations.TenantContext, require_master: false}
    end

    read :by_workspace do
      description "Retrieves all versions for a specific workspace"
      argument :workspace_id, :uuid, allow_nil?: false
      filter expr(workspace_id == ^arg(:workspace_id))
      pagination offset?: true, default_limit: 20, max_page_size: 100, countable: true

      validate {MishkaCmsCore.Runtime.Resources.Validations.TenantContext, require_master: false}
    end

    read :master_by_workspace do
      multitenancy :bypass
      description "Retrieves all versions for a specific workspace (master users only)"
      argument :workspace_id, :uuid, allow_nil?: false
      filter expr(workspace_id == ^arg(:workspace_id))
      pagination offset?: true, default_limit: 20, max_page_size: 100, countable: true

      validate {MishkaCmsCore.Runtime.Resources.Validations.TenantContext, require_master: true}
    end

    read :latest_versions do
      description "Retrieves only the latest versions across all workspaces"
      filter expr(is_latest_for_version == true)
      pagination offset?: true, default_limit: 20, max_page_size: 100, countable: true

      validate {MishkaCmsCore.Runtime.Resources.Validations.TenantContext, require_master: false}
    end

    read :by_status do
      description "Retrieves versions by status"
      argument :status, :atom, allow_nil?: false
      filter expr(status == ^arg(:status))
      pagination offset?: true, default_limit: 20, max_page_size: 100, countable: true

      validate {MishkaCmsCore.Runtime.Resources.Validations.TenantContext, require_master: false}
    end

    read :public_list do
      description "Public endpoint to list all published versions - alpha, beta, rc, and stable (no authentication required)"
      filter expr(status in [:alpha, :beta, :rc, :stable])

      pagination offset?: true,
                 default_limit: 20,
                 max_page_size: 100,
                 countable: true,
                 required?: false

      prepare {MishkaDocument.Resources.Preparations.OpenToActor, kind: :version}
    end

    read :public_get do
      description "Public endpoint to get a single published version by ID - alpha, beta, rc, or stable (no authentication required)"
      get? true
      filter expr(status in [:alpha, :beta, :rc, :stable])

      prepare {MishkaDocument.Resources.Preparations.OpenToActor, kind: :version}
    end

    read :read_any do
      multitenancy :bypass
      description "Reads all versions bypassing tenant filtering (for master relationships)"

      pagination offset?: true,
                 default_limit: 20,
                 max_page_size: 100,
                 countable: true,
                 required?: false
    end

    update :publish do
      description "Publishes a version by setting published_at timestamp and status to stable"
      accept []
      require_atomic? false

      validate {MishkaCmsCore.Runtime.Resources.Validations.TenantContext, require_master: false}

      validate fn changeset, _context ->
        if changeset.data.published_at do
          {:error,
           field: :published_at, message: dgettext_noop("errors", "Version is already published.")}
        else
          :ok
        end
      end

      change fn changeset, _context ->
        changeset
        |> Ash.Changeset.force_change_attribute(:published_at, DateTime.utc_now())
        |> Ash.Changeset.force_change_attribute(:status, :stable)
      end

      # Add metadata for event tracking
      change fn changeset, context ->
        Ash.Changeset.put_context(changeset, :ash_events_metadata, %{
          site_id: context.tenant || changeset.data.site_id,
          title: changeset.data.version_number
        })
      end
    end

    update :mark_as_latest do
      description "Marks this version as the latest for its workspace, unmarking others"
      accept []
      require_atomic? false
      transaction? true

      validate {MishkaCmsCore.Runtime.Resources.Validations.TenantContext, require_master: false}

      change fn changeset, _context ->
        Ash.Changeset.force_change_attribute(changeset, :is_latest_for_version, true)
      end

      change MishkaDocument.Resources.Changes.EnsureSingleLatestVersion

      # Add metadata for event tracking
      change fn changeset, context ->
        Ash.Changeset.put_context(changeset, :ash_events_metadata, %{
          site_id: context.tenant || changeset.data.site_id,
          title: changeset.data.version_number
        })
      end
    end

    # A CLONED VERSION MADE INDEPENDENT of the version it was cloned from, so deleting that one
    # leaves it — `MishkaDocument.Resources.Changes.DetachVersion`.
    update :detach do
      accept []
      require_atomic? false
      transaction? true

      validate {MishkaCmsCore.Runtime.Resources.Validations.TenantContext, require_master: false}

      change MishkaDocument.Resources.Changes.DetachVersion

      description "Unties a cloned version, and its pages, from the version it was cloned from"
    end

    update :master_detach do
      accept []
      require_atomic? false
      transaction? true
      multitenancy :bypass

      validate {MishkaCmsCore.Runtime.Resources.Validations.TenantContext, require_master: true}

      change MishkaDocument.Resources.Changes.DetachVersion

      description "Unties a cloned version of any site, and its pages, from the version it was cloned from (master users only)"
    end

    destroy :destroy do
      description "Permanently removes workspace version from database (tenant users)"
      primary? true
      require_atomic? false

      validate {MishkaCmsCore.Runtime.Resources.Validations.TenantContext, require_master: false}

      validate fn changeset, _context ->
        if changeset.data.is_latest_for_version do
          {:error,
           field: :is_latest_for_version,
           message:
             dgettext_noop(
               "errors",
               "Cannot delete the latest version. Mark another version as latest first."
             )}
        else
          :ok
        end
      end

      change MishkaDocument.Resources.Changes.DestroyClones
    end

    destroy :master_destroy do
      description "Permanently removes workspace version from database (master users) - bypasses multi-tenancy"
      require_atomic? false
      multitenancy :bypass

      validate {MishkaCmsCore.Runtime.Resources.Validations.TenantContext, require_master: true}

      validate fn changeset, _context ->
        if changeset.data.is_latest_for_version do
          {:error,
           field: :is_latest_for_version,
           message:
             dgettext_noop(
               "errors",
               "Cannot delete the latest version. Mark another version as latest first."
             )}
        else
          :ok
        end
      end

      change MishkaDocument.Resources.Changes.DestroyClones
    end
  end

  # Authorization policies for workspace version access
  policies do
    # Allow public access to view stable versions
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

    # The workspace area reads and writes versions. A section admin reads them on the dashboard,
    # where every section screen is drawn inside one; the admin API's version routes are the
    # workspace area's alone.
    policy always() do
      access_type :strict

      authorize_if {MishkaCmsCore.Accounts.Checks.AccessPermissions,
                    permissions: [
                      "admin:dashboard:document:workspace",
                      "admin:api:document:workspace"
                    ]}

      forbid_if context_equals([:shared, :admin_surface], :api)

      authorize_if {MishkaCmsCore.Accounts.Checks.AccessPermissions,
                    permissions: [
                      "admin:dashboard:document:section",
                      "admin:api:document:section"
                    ]}
    end

    policy action_type([:create, :update, :destroy]) do
      access_type :strict

      authorize_if {MishkaCmsCore.Accounts.Checks.AccessPermissions,
                    permissions: [
                      "admin:dashboard:document:workspace",
                      "admin:api:document:workspace"
                    ]}
    end

    # A clone writes the source's pages and notes as well, and making one independent its pages,
    # which are the section area's.
    policy action([:clone, :master_clone, :detach, :master_detach]) do
      access_type :strict

      authorize_if {MishkaCmsCore.Accounts.Checks.AccessPermissions,
                    permissions: [
                      "admin:dashboard:document:section",
                      "admin:api:document:section"
                    ]}
    end
  end

  # PubSub configuration for real-time updates
  # Note: master_update and master_destroy are generic actions that internally call
  # :update and :destroy, so they will trigger notifications through those actions
  pub_sub do
    module Application.compile_env!(:mishka_cms_core, :endpoint)
    prefix "workspace_version"

    publish :create, [[nil, :site_id], "created"]
    publish :master_create, [[nil, :site_id], "created"]
    publish :clone, [[nil, :site_id], "created"]
    publish :master_clone, [[nil, :site_id], "created"]
    publish :detach, [[nil, :site_id], "updated"]
    publish :master_detach, [[nil, :site_id], "updated"]
    publish :update, [[nil, :site_id], "updated"]
    publish :publish, [[nil, :site_id], "updated"]
    publish :mark_as_latest, [[nil, :site_id], "updated"]
    publish :destroy, [[nil, :site_id], "destroyed"]

    # Master actions
    publish :master_update, [[nil, :site_id], "updated"]
    publish :master_destroy, [[nil, :site_id], "destroyed"]
  end

  # Every id this record holds names a record of its own site, whoever writes it.
  validations do
    validate {MishkaCmsCore.Runtime.Resources.Validations.SameSiteReference,
              field: :workspace_id,
              resource: MishkaDocument.Workspace,
              label: dgettext_noop("errors", "workspace"),
              read_action: :master_get},
             where: [changing(:workspace_id)],
             only_when_valid?: true

    validate {MishkaCmsCore.Runtime.Resources.Validations.SameSiteReference,
              field: :source_version_id,
              resource: MishkaDocument.WorkspaceVersion,
              label: dgettext_noop("errors", "version"),
              read_action: :read_any},
             where: [changing(:source_version_id)],
             only_when_valid?: true
  end

  # Multi-tenancy configuration - versions are always site-specific
  multitenancy do
    strategy :attribute
    attribute :site_id
    # Versions are NEVER global - always site-specific
    global? false
  end

  attributes do
    uuid_primary_key :id

    attribute :version_number, :string do
      allow_nil? false
      public? true
      constraints min_length: 1, max_length: 50, trim?: true
      description "Semantic version number (e.g., '0.0.1', '1.0.0')"
    end

    attribute :version_name, :string do
      allow_nil? true
      public? true
      constraints max_length: 255, trim?: true
      description "Optional friendly name for this version"
    end

    attribute :description, :string do
      allow_nil? true
      public? true
      constraints max_length: 5000, trim?: true
      description "Description of changes or features in this version"
    end

    attribute :status, :atom do
      allow_nil? false
      public? true
      default :draft
      constraints one_of: [:draft, :alpha, :beta, :rc, :stable, :archived]
      description "Status of the version (draft, alpha, beta, stable, archived)"
    end

    attribute :is_latest_for_version, :boolean do
      allow_nil? false
      public? true
      default false
      description "Whether this is the latest version for the workspace"
    end

    attribute :published_at, :utc_datetime do
      allow_nil? true
      public? true
      description "Timestamp when the version was published"
    end

    create_timestamp :inserted_at do
      public? true
      sortable? true
    end

    update_timestamp :updated_at
  end

  relationships do
    belongs_to :site, MishkaCmsCore.Runtime.Site do
      read_action :read_any
      allow_nil? false
      public? true
      description "The site this version belongs to"
    end

    belongs_to :workspace, MishkaDocument.Workspace do
      allow_nil? false
      public? true
      attribute_writable? true
      description "The workspace this version belongs to"
    end

    # Bypass relationship - for master admin users without tenant
    belongs_to :master_workspace, MishkaDocument.Workspace do
      public? true
      source_attribute :workspace_id
      destination_attribute :id
      define_attribute? false
      read_action :master_read
      description "The workspace this version belongs to (master admin access, bypass tenant)"

      filter expr(not is_nil(type(^actor(:id), :uuid)) and is_nil(type(^actor(:site_id), :uuid)))
    end

    belongs_to :source_version, MishkaDocument.WorkspaceVersion do
      allow_nil? true
      public? true
      description "The version this was cloned from"
    end

    belongs_to :master_source_version, MishkaDocument.WorkspaceVersion do
      public? true
      source_attribute :source_version_id
      destination_attribute :id
      define_attribute? false
      read_action :master_read
      description "The version this was cloned from (master admin access, bypass tenant)"

      filter expr(not is_nil(type(^actor(:id), :uuid)) and is_nil(type(^actor(:site_id), :uuid)))
    end

    has_many :cloned_versions, MishkaDocument.WorkspaceVersion do
      public? true
      destination_attribute :source_version_id
      description "Versions that were cloned from this version"
    end

    # Lineage tracking - when this version was created by cloning
    has_one :lineage_as_new, MishkaDocument.WorkspaceVersionLineage do
      public? true
      destination_attribute :new_version_id
      description "Lineage record when this version was created by cloning"
    end

    # Lineage tracking - versions cloned from this version
    has_many :lineage_as_source, MishkaDocument.WorkspaceVersionLineage do
      public? true
      destination_attribute :source_version_id
      description "Lineage records for versions cloned from this version"
    end

    # Relationship - for public users (guests/users without permissions)
    has_many :sections, MishkaDocument.Section do
      public? true
      destination_attribute :workspace_version_id
      read_action :public_list
      description "Published approved sections of this version (public access)"
    end

    # Relationship - for admin users with tenant
    has_many :tenant_sections, MishkaDocument.Section do
      public? true
      destination_attribute :workspace_version_id
      description "All sections of this version (tenant admin access)"
    end

    # Bypass relationship - for master admin users without tenant
    has_many :master_sections, MishkaDocument.Section do
      public? true
      destination_attribute :workspace_version_id
      read_action :read_any
      description "All sections of this version (master admin access, bypass tenant)"

      filter expr(not is_nil(type(^actor(:id), :uuid)) and is_nil(type(^actor(:site_id), :uuid)))
    end
  end

  calculations do
    # Who may open the version: its document's permissions.
    calculate :effective_permissions, {:array, :string}, expr(workspace.permissions)

    # What deleting the version deletes with it: the versions cloned from it, however deep.
    calculate :clone_numbers,
              {:array, :string},
              MishkaDocument.Resources.Calculations.CloneNumbers do
      description "The version numbers of every version cloned from this one, nearest first"
    end
  end

  identities do
    identity :unique_version_per_workspace, [:version_number, :workspace_id, :site_id] do
      description "Ensures version numbers are unique within each workspace and site"
      message dgettext_noop("errors", "Version number must be unique within a workspace.")
      all_tenants? true
      nils_distinct? false
    end
  end

  @doc """
  Whether `actor` may clone a version on the dashboard: it holds the workspace area, which writes
  versions, and the section area, which writes their pages and notes — what `:clone` and
  `:master_clone` ask.
  """
  @spec clone_allowed?(map() | nil) :: boolean()
  def clone_allowed?(actor) do
    Enum.all?(
      ["admin:dashboard:document:workspace", "admin:dashboard:document:section"],
      &MishkaCmsCore.Accounts.Checks.AccessPermissions.match?(actor, %{}, permissions: [&1])
    )
  end

  @doc """
  How a version is named in a list of versions to pick: its number, and its name when it has one.
  """
  @spec source_label(map()) :: String.t()
  def source_label(%{version_number: number, version_name: name})
      when is_binary(name) and name != "",
      do: "#{number} — #{name}"

  def source_label(%{version_number: number}), do: to_string(number)

  @doc """
  The site the version form writes for: a master's chosen site, a site user's own.
  """
  @spec form_site_id(map()) :: String.t() | nil
  def form_site_id(%{master_user?: true} = state) do
    Map.get(state.field_values || %{}, :site_id) || Map.get(state.defaults || %{}, :site_id)
  end

  def form_site_id(%{current_user: user}), do: user && Map.get(user, :site_id)

  @doc """
  The document the version form is for: the one it was opened with, or the edited record's.
  `nil` when it names none, so its pickers offer no version.
  """
  @spec form_workspace_id(map()) :: String.t() | nil
  def form_workspace_id(state) do
    Map.get(state.defaults || %{}, :workspace_id) ||
      Map.get(state.field_values || %{}, :workspace_id)
  end

  @doc """
  What the delete button asks before a version is deleted: a warning naming every version cloned
  from it (`:clone_numbers`), which goes with it, or the plain question when there is none.
  """
  @spec delete_confirm(map()) :: String.t()
  def delete_confirm(%{clone_numbers: [_ | _] = clones, version_number: number}) do
    ngettext(
      "Warning: deleting %{version} also deletes 1 version cloned from it — %{clones} — with all its pages and notes. This cannot be undone.",
      "Warning: deleting %{version} also deletes %{count} versions cloned from it — %{clones} — with all their pages and notes. This cannot be undone.",
      length(clones),
      version: number,
      clones: Enum.join(clones, ", ")
    )
  end

  def delete_confirm(_version),
    do: dgettext("mishka_gervaz", "Permanently delete this version? This cannot be undone.")

  @doc """
  What "Make independent" asks before it unties a version from the one it was cloned from.
  """
  @spec detach_confirm(map()) :: String.t()
  def detach_confirm(version) do
    gettext(
      "%{version} will no longer be tied to %{source}; deleting %{source} will not delete it.",
      version: version.version_number,
      source: source_number(version)
    )
  end

  defp source_number(version) do
    [Map.get(version, :master_source_version), Map.get(version, :source_version)]
    |> Enum.find_value(fn
      %__MODULE__{version_number: number} -> number
      _not_loaded -> nil
    end)
    |> Kernel.||(gettext("its source"))
  end
end
