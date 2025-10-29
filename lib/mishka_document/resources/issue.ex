defmodule MishkaDocument.Issue do
  @moduledoc """
  Manages documentation issues and feedback submissions.

  This resource represents issues reported on documentation content, including typos,
  broken links, incorrect content, suggestions, and review feedback. Each issue can
  optionally link to a specific note or section and is tracked through its lifecycle
  from open to resolved/closed.

  Issues support multi-tenancy and are site-specific. The resource implements soft
  deletion via archival for tracking all changes and status transitions.

  Multi-tenant isolation ensures issues are properly segregated between sites.
  """
  use Ash.Resource,
    otp_app: :mishka_document,
    domain: MishkaDocument,
    data_layer: AshPostgres.DataLayer,
    extensions: [
      AshArchival.Resource,
      AshEvents.Events,
      MishkaGervaz.Resource,
      GuardedStruct.AshResource
    ],
    notifiers: [Ash.Notifier.PubSub, MishkaCmsCore.Runtime.Resources.Notifiers.PluginHook],
    authorizers: [Ash.Policy.Authorizer]

  require Ash.Query

  use MishkaGervaz.Messages, backend: MishkaCmsCore.Gettext

  # The card's action squares. `MishkaDocumentWeb.Templates.IssueCard` draws the labelled Comment
  # button itself, so everything the resource declares is icon-only and hides its own label — which
  # still reaches the DOM as `title` and as a `.lbl` span, or the button would have no accessible name.
  @icon_action_class "inline-flex size-8 flex-none items-center justify-center rounded-[9px] border " <>
                       "border-[#ecebe6] bg-[#faf9f6] text-[#6d6a63] transition-colors " <>
                       "hover:bg-[#f2f1fc] hover:text-[#4f4bcc] [&_.lbl]:hidden"

  @danger_action_class "inline-flex size-8 flex-none items-center justify-center rounded-[9px] border " <>
                         "border-[#f0dcd8] bg-[#fdf3f1] text-[#c0473d] transition-colors " <>
                         "hover:bg-[#fbe9e7] [&_.lbl]:hidden"

  @admin_fields [
    :note_id,
    :section_id,
    :reporter_id,
    :title,
    :description,
    :issue_type,
    :status,
    :site_id
  ]

  # Database configuration for issues storage with indexing
  postgres do
    table "mishka_document_issues"
    repo Application.compile_env!(:mishka_cms_core, :repo)

    # Database-level optimization for archived records
    base_filter_sql "(archived_at IS NULL)"

    references do
      reference :site, on_delete: :delete
      reference :section, on_delete: :delete
      reference :note, on_delete: :delete
      reference :reporter, on_delete: :nilify
    end

    custom_indexes do
      index [:note_id]
      index [:section_id]
      index [:reporter_id]
      index [:issue_type]
      index [:status]
      index [:site_id]
    end

    check_constraints do
      check_constraint :title, "title_not_empty",
        check: "length(title) >= 1",
        message: dgettext_noop("errors", "Title cannot be empty.")

      check_constraint :description, "description_not_empty",
        check: "length(description) >= 1",
        message: dgettext_noop("errors", "Description cannot be empty.")

      # At least one of note_id or section_id must be present
      check_constraint :note_id, "issue_must_reference_content",
        check: "note_id IS NOT NULL OR section_id IS NOT NULL",
        message: dgettext_noop("errors", "Issue must reference either a note or a section.")
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

  # Event tracking configuration for activity logging
  events do
    event_log MishkaDocument.EventLog

    only_actions [
      :create,
      :master_create,
      :update,
      :master_update,
      :mark_in_progress,
      :mark_resolved,
      :mark_closed,
      :reopen,
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
        name :issues
        route "/admin/dashboard/document/issues"
        stream_name :issues
      end

      source do
        preload do
          always [:site, :reporter, :reporter_master?, :comments_count]
        end
      end

      columns do
        # Newest first, which is what the design's "Sort by" opens on.
        default_sort inserted_at: :desc

        # The card reads the record directly (`MishkaDocumentWeb.Templates.IssueCard`), so no column
        # draws anything. They stay as the field-selection contract — `requires` is what puts a field
        # on the record the card reads — and as the vocabulary the Sort by menu offers.
        column :issue_title_info do
          static true
          sortable true
          sort_field [:title]
          requires [:title, :issue_type]
          label fn -> dgettext("mishka_gervaz", "Title") end
          position :first
        end

        column :issue_status do
          static true
          sortable true
          sort_field [:status]
          requires [:status]
          label fn -> dgettext("mishka_gervaz", "Status") end
        end

        column :issue_description do
          static true
          requires [:description]
          label fn -> dgettext("mishka_gervaz", "Description") end
        end

        column :issue_meta do
          static true
          requires [:reporter, :comments_count]
          label fn -> dgettext("mishka_gervaz", "Details") end
        end

        column :issue_site do
          static true
          requires [:site]
          label fn -> dgettext("mishka_gervaz", "Site") end
          position :last
        end

        column :issue_date do
          static true
          sortable true
          sort_field [:inserted_at]
          requires [:inserted_at]
          label fn -> dgettext("mishka_gervaz", "Created") end
        end
      end

      filters do
        filter :id, :text do
          visible false

          apply fn query, value, _context ->
            Ash.Query.filter_input(query, %{id: %{eq: value}})
          end
        end

        filter :search, :text do
          fields [:title, :description]

          ui do
            label fn -> dgettext("mishka_gervaz", "Search") end
            placeholder fn -> dgettext("mishka_gervaz", "Search issues…") end
          end
        end

        filter :status, :select do
          options fn ->
            [
              {dgettext("mishka_gervaz", "Open"), :open},
              {dgettext("mishka_gervaz", "In Progress"), :in_progress},
              {dgettext("mishka_gervaz", "Resolved"), :resolved},
              {dgettext("mishka_gervaz", "Closed"), :closed}
            ]
          end

          ui do
            prompt dgettext_noop("mishka_gervaz", "All Statuses")
            label fn -> dgettext("mishka_gervaz", "Status") end
          end
        end

        filter :issue_type, :select do
          options fn ->
            [
              {dgettext("mishka_gervaz", "Typo"), :typo},
              {dgettext("mishka_gervaz", "Broken Link"), :broken_link},
              {dgettext("mishka_gervaz", "Incorrect Content"), :incorrect_content},
              {dgettext("mishka_gervaz", "Suggestion"), :suggestion},
              {dgettext("mishka_gervaz", "Review Feedback"), :review_feedback},
              {dgettext("mishka_gervaz", "Other"), :other}
            ]
          end

          ui do
            prompt dgettext_noop("mishka_gervaz", "All Types")
            label fn -> dgettext("mishka_gervaz", "Issue Type") end
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

        filter :created_at, :date_range do
          source :inserted_at

          ui do
            label fn -> dgettext("mishka_gervaz", "Created") end
          end
        end
      end

      row_actions do
        action :edit do
          type :edit
          visible :active
          js fn _record -> MishkaCmsCore.CoreComponents.show_modal("issue-form-modal") end

          ui do
            label fn -> dgettext("mishka_gervaz", "Edit") end
            icon "hero-pencil-square"
            class @icon_action_class
          end
        end

        action :delete do
          type :destroy
          confirm fn _record -> dgettext("mishka_gervaz", "Archive this issue?") end
          visible :active

          ui do
            label fn -> dgettext("mishka_gervaz", "Archive") end
            icon "hero-trash"
            class @danger_action_class
          end
        end

        action :unarchive do
          type :unarchive
          confirm fn _record -> dgettext("mishka_gervaz", "Restore this issue?") end
          visible :archived

          ui do
            label fn -> dgettext("mishka_gervaz", "Restore") end
            icon "hero-arrow-path"
            class @icon_action_class
          end
        end

        action :permanent_destroy do
          type :permanent_destroy

          confirm fn _record ->
            dgettext("mishka_gervaz", "Permanently delete? This cannot be undone.")
          end

          visible :archived

          ui do
            label fn -> dgettext("mishka_gervaz", "Delete permanently") end
            icon "hero-x-circle"
            class @danger_action_class
          end
        end
      end

      row do
        selectable true
      end

      bulk_actions do
        action :archive,
          type: :destroy,
          confirm: dgettext_noop("mishka_gervaz", "Archive selected issues?")

        action :unarchive,
          type: :unarchive,
          confirm: dgettext_noop("mishka_gervaz", "Restore selected?"),
          visible: :archived

        action :permanent_destroy,
          type: :permanent_destroy,
          confirm: dgettext_noop("mishka_gervaz", "Permanently delete?"),
          visible: :archived
      end

      realtime do
        prefix "issue"
      end

      url_sync do
        mode :bidirectional
        params [:filters, :sort, :page, :search]
        prefix "issues"
        max_filter_length 500
      end

      hooks do
        on_expand fn _id, socket ->
          {:cont, socket}
        end
      end

      pagination do
        page_size 20
      end

      presentation do
        ui_adapter MishkaCmsCoreWeb.UIAdapters.Admin
        features [:filter, :select, :bulk_actions, :paginate, :expand]
      end

      empty_state message: dgettext_noop("mishka_gervaz", "No issues found"),
                  icon: "hero-exclamation-triangle"
    end

    form do
      identity do
        name :issue_form
      end

      fields do
        field :site_id, :relation do
          restricted true
          required true
          show_on :create
          display_field :name
          search_field :name
          mode :search

          ui do
            label fn -> dgettext("mishka_gervaz", "Site") end
          end
        end

        field :title, :text do
          required true

          ui do
            label fn -> dgettext("mishka_gervaz", "Title") end
          end
        end

        field :issue_type, :select do
          required true

          options fn ->
            [
              {dgettext("mishka_gervaz", "Typo"), :typo},
              {dgettext("mishka_gervaz", "Broken link"), :broken_link},
              {dgettext("mishka_gervaz", "Incorrect content"), :incorrect_content},
              {dgettext("mishka_gervaz", "Suggestion"), :suggestion},
              {dgettext("mishka_gervaz", "Review feedback"), :review_feedback},
              {dgettext("mishka_gervaz", "Other"), :other}
            ]
          end

          ui do
            label fn -> dgettext("mishka_gervaz", "Issue Type") end
          end
        end

        field :status, :select do
          required true

          options fn ->
            [
              {dgettext("mishka_gervaz", "Open"), :open},
              {dgettext("mishka_gervaz", "In progress"), :in_progress},
              {dgettext("mishka_gervaz", "Resolved"), :resolved},
              {dgettext("mishka_gervaz", "Closed"), :closed}
            ]
          end

          ui do
            label fn -> dgettext("mishka_gervaz", "Status") end
          end
        end

        field :section_id, :relation do
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

            if site_id, do: Ash.Query.filter_input(query, %{site_id: site_id}), else: query
          end

          ui do
            label fn -> dgettext("mishka_gervaz", "Section") end
          end
        end

        field :note_id, :relation do
          display_field :title
          search_field :title
          mode :search
          depends_on :section_id

          load fn query, state ->
            section_id = Map.get(state.field_values, :section_id)

            if section_id,
              do: Ash.Query.filter_input(query, %{section_id: section_id}),
              else: query
          end

          ui do
            label fn -> dgettext("mishka_gervaz", "Note") end
          end
        end

        field :reporter_id, :relation do
          restricted true
          required true
          readonly fn state -> state.mode == :update end
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
            label fn -> dgettext("mishka_gervaz", "Reporter") end
          end
        end

        field :description, :textarea do
          required true

          ui do
            label fn -> dgettext("mishka_gervaz", "Description") end
            rows 4
          end
        end
      end

      groups do
        group :basic_info do
          fields [:site_id, :title, :issue_type, :status]

          ui do
            label fn -> dgettext("mishka_gervaz", "Basic Information") end
            columns 2
          end
        end

        group :references do
          fields [:section_id, :note_id, :reporter_id]

          ui do
            label fn -> dgettext("mishka_gervaz", "References") end
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

    field :title, :string,
      derives: "sanitize(strip_tags, trim) validate(string, not_empty, min_len=1, max_len=500)"

    field :description, :string,
      derives: "sanitize(basic_html) validate(string, not_empty, min_len=1)"

    field :issue_type, :atom,
      derives:
        "validate(atom, enum=Atom[typo::broken_link::incorrect_content::suggestion::review_feedback::other])"

    field :status, :atom,
      derives: "validate(atom, enum=Atom[open::in_progress::resolved::closed])"
  end

  actions do
    defaults [:read]

    default_accept @admin_fields

    create :create do
      primary? true
      accept @admin_fields -- [:site_id, :reporter_id]

      validate present([:title])
      validate present([:description])
      validate present([:issue_type])

      validate {MishkaCmsCore.Runtime.Resources.Validations.TenantContext, require_master: false}

      # Validate at least one of note_id or section_id is present
      validate fn changeset, _context ->
        note_id = Ash.Changeset.get_attribute(changeset, :note_id)
        section_id = Ash.Changeset.get_attribute(changeset, :section_id)

        if is_nil(note_id) and is_nil(section_id) do
          {:error,
           message:
             dgettext_noop("errors", "Issue must reference either a note or a section (or both)."),
           fields: [:note_id, :section_id]}
        else
          :ok
        end
      end

      # Validate section belongs to the same tenant (if provided)
      validate {MishkaCmsCore.Runtime.Resources.Validations.TenantIsolation,
                field: :section_id,
                resource: MishkaDocument.Section,
                message:
                  dgettext_noop("errors", "Section not found or does not belong to your site.")}

      # Validate note belongs to the same tenant (if provided)
      validate {MishkaCmsCore.Runtime.Resources.Validations.TenantIsolation,
                field: :note_id,
                resource: MishkaDocument.Note,
                message:
                  dgettext_noop("errors", "Note not found or does not belong to your site.")}

      change &Ash.Changeset.force_change_attribute(&1, :site_id, &2.tenant)
      change relate_actor(:reporter)

      # Add metadata for event tracking
      change fn changeset, context ->
        Ash.Changeset.put_context(changeset, :ash_events_metadata, %{
          site_id: context.tenant,
          title: Ash.Changeset.get_attribute(changeset, :title)
        })
      end

      description "Creates issue for tenant users - requires tenant context, auto-assigns site_id and reporter from actor"
    end

    create :master_create do
      validate present([:title])
      validate present([:description])
      validate present([:reporter_id])
      validate present([:issue_type])
      validate present([:site_id])

      validate {MishkaCmsCore.Runtime.Resources.Validations.TenantContext, require_master: true}

      # Validate at least one of note_id or section_id is present
      validate fn changeset, _context ->
        note_id = Ash.Changeset.get_attribute(changeset, :note_id)
        section_id = Ash.Changeset.get_attribute(changeset, :section_id)

        if is_nil(note_id) and is_nil(section_id) do
          {:error,
           message:
             dgettext_noop("errors", "Issue must reference either a note or a section (or both)."),
           fields: [:note_id, :section_id]}
        else
          :ok
        end
      end

      change fn changeset, _context ->
        site_id = Ash.Changeset.get_attribute(changeset, :site_id)
        Ash.Changeset.set_tenant(changeset, site_id)
      end

      # Add metadata for event tracking
      change fn changeset, _context ->
        Ash.Changeset.put_context(changeset, :ash_events_metadata, %{
          site_id: Ash.Changeset.get_attribute(changeset, :site_id),
          title: Ash.Changeset.get_attribute(changeset, :title)
        })
      end

      description "Creates issue for master users - requires explicit site_id"
    end

    update :update do
      primary? true
      require_atomic? false
      transaction? true
      accept @admin_fields -- [:site_id, :reporter_id]

      validate {MishkaCmsCore.Runtime.Resources.Validations.TenantContext, require_master: false}

      # Validate section belongs to the same tenant (if being changed)
      validate {MishkaCmsCore.Runtime.Resources.Validations.TenantIsolation,
                field: :section_id,
                resource: MishkaDocument.Section,
                message:
                  dgettext_noop("errors", "Section not found or does not belong to your site.")}

      # Validate note belongs to the same tenant (if being changed)
      validate {MishkaCmsCore.Runtime.Resources.Validations.TenantIsolation,
                field: :note_id,
                resource: MishkaDocument.Note,
                message:
                  dgettext_noop("errors", "Note not found or does not belong to your site.")}

      # Add metadata for event tracking
      change fn changeset, context ->
        Ash.Changeset.put_context(changeset, :ash_events_metadata, %{
          site_id: context.tenant || changeset.data.site_id,
          title: Ash.Changeset.get_attribute(changeset, :title) || changeset.data.title
        })
      end

      description "Updates issue for tenant users - requires tenant context, prevents site_id and reporter_id changes"
    end

    update :master_update do
      description "Updates issue for master users - bypasses multi-tenancy, prevents site_id and reporter_id changes"
      require_atomic? false
      transaction? true
      accept @admin_fields |> List.delete(:site_id) |> List.delete(:reporter_id)
      multitenancy :bypass

      validate {MishkaCmsCore.Runtime.Resources.Validations.TenantContext, require_master: true}

      validate absent(:archived_at) do
        message dgettext_noop("errors", "Cannot edit archived issue. Please unarchive it first.")
      end

      # Add metadata for event tracking
      change fn changeset, _context ->
        Ash.Changeset.put_context(changeset, :ash_events_metadata, %{
          site_id: changeset.data.site_id,
          title: Ash.Changeset.get_attribute(changeset, :title) || changeset.data.title
        })
      end
    end

    # Status transition actions
    update :mark_in_progress do
      description "Marks issue as in progress"
      accept []
      require_atomic? false

      validate {MishkaCmsCore.Runtime.Resources.Validations.TenantContext, require_master: false}

      change set_attribute(:status, :in_progress)

      # Add metadata for event tracking
      change fn changeset, context ->
        Ash.Changeset.put_context(changeset, :ash_events_metadata, %{
          site_id: context.tenant || changeset.data.site_id,
          title: changeset.data.title
        })
      end
    end

    update :mark_resolved do
      description "Marks issue as resolved"
      accept []
      require_atomic? false

      validate {MishkaCmsCore.Runtime.Resources.Validations.TenantContext, require_master: false}

      change set_attribute(:status, :resolved)

      # Add metadata for event tracking
      change fn changeset, context ->
        Ash.Changeset.put_context(changeset, :ash_events_metadata, %{
          site_id: context.tenant || changeset.data.site_id,
          title: changeset.data.title
        })
      end
    end

    update :mark_closed do
      description "Marks issue as closed"
      accept []
      require_atomic? false

      validate {MishkaCmsCore.Runtime.Resources.Validations.TenantContext, require_master: false}

      change set_attribute(:status, :closed)

      # Add metadata for event tracking
      change fn changeset, context ->
        Ash.Changeset.put_context(changeset, :ash_events_metadata, %{
          site_id: context.tenant || changeset.data.site_id,
          title: changeset.data.title
        })
      end
    end

    update :reopen do
      description "Reopens a closed or resolved issue"
      accept []
      require_atomic? false

      validate {MishkaCmsCore.Runtime.Resources.Validations.TenantContext, require_master: false}

      change set_attribute(:status, :open)

      # Add metadata for event tracking
      change fn changeset, context ->
        Ash.Changeset.put_context(changeset, :ash_events_metadata, %{
          site_id: context.tenant || changeset.data.site_id,
          title: changeset.data.title
        })
      end
    end

    read :master_read do
      description "Reads all issues system-wide, bypassing tenant filtering (master users only)"
      multitenancy :bypass
      pagination offset?: true, default_limit: 20, max_page_size: 100, countable: true

      validate {MishkaCmsCore.Runtime.Resources.Validations.TenantContext, require_master: true}
    end

    read :master_get do
      multitenancy :bypass
      get? true
      description "Retrieves single issue by ID, bypassing tenant filtering"

      validate {MishkaCmsCore.Runtime.Resources.Validations.TenantContext, require_master: true}
    end

    read :by_note do
      description "Retrieves all issues for a specific note"
      argument :note_id, :uuid, allow_nil?: false
      filter expr(note_id == ^arg(:note_id))
      pagination offset?: true, default_limit: 50, max_page_size: 200, countable: true

      validate {MishkaCmsCore.Runtime.Resources.Validations.TenantContext, require_master: false}
    end

    read :by_section do
      description "Retrieves all issues for a specific section"
      argument :section_id, :uuid, allow_nil?: false
      filter expr(section_id == ^arg(:section_id))
      pagination offset?: true, default_limit: 50, max_page_size: 200, countable: true

      validate {MishkaCmsCore.Runtime.Resources.Validations.TenantContext, require_master: false}
    end

    read :by_reporter do
      description "Retrieves all issues reported by a specific user"
      argument :reporter_id, :uuid, allow_nil?: false
      filter expr(reporter_id == ^arg(:reporter_id))
      pagination offset?: true, default_limit: 50, max_page_size: 200, countable: true

      validate {MishkaCmsCore.Runtime.Resources.Validations.TenantContext, require_master: false}
    end

    read :by_status do
      description "Retrieves issues filtered by status"
      argument :status, :atom, allow_nil?: false
      filter expr(status == ^arg(:status))
      pagination offset?: true, default_limit: 50, max_page_size: 200, countable: true

      validate {MishkaCmsCore.Runtime.Resources.Validations.TenantContext, require_master: false}
    end

    read :by_type do
      description "Retrieves issues filtered by issue type"
      argument :issue_type, :atom, allow_nil?: false
      filter expr(issue_type == ^arg(:issue_type))
      pagination offset?: true, default_limit: 50, max_page_size: 200, countable: true

      validate {MishkaCmsCore.Runtime.Resources.Validations.TenantContext, require_master: false}
    end

    read :open_issues do
      description "Retrieves all open issues"
      filter expr(status == :open)
      pagination offset?: true, default_limit: 50, max_page_size: 200, countable: true

      validate {MishkaCmsCore.Runtime.Resources.Validations.TenantContext, require_master: false}
    end

    read :archived do
      filter expr(not is_nil(archived_at))
      pagination offset?: true, default_limit: 20, max_page_size: 100, countable: true

      validate {MishkaCmsCore.Runtime.Resources.Validations.TenantContext, require_master: false}

      description "Lists archived issues within current tenant context"
    end

    read :get_archived do
      get? true
      filter expr(not is_nil(archived_at))

      validate {MishkaCmsCore.Runtime.Resources.Validations.TenantContext, require_master: false}

      description "Retrieves single archived issue for recovery or inspection (tenant users)"
    end

    read :master_get_archived do
      get? true
      multitenancy :bypass
      filter expr(not is_nil(archived_at))

      validate {MishkaCmsCore.Runtime.Resources.Validations.TenantContext, require_master: true}

      description "Retrieves single archived issue for recovery or inspection (master users)"
    end

    read :master_archived do
      multitenancy :bypass
      filter expr(not is_nil(archived_at))
      pagination offset?: true, default_limit: 20, max_page_size: 100, countable: true

      validate {MishkaCmsCore.Runtime.Resources.Validations.TenantContext, require_master: true}

      description "Lists all archived issues system-wide, bypassing tenant filtering"
    end

    destroy :destroy do
      description "Soft deletes issue by archiving (tenant users)"
      primary? true
      require_atomic? false

      validate {MishkaCmsCore.Runtime.Resources.Validations.TenantContext, require_master: false}

      validate fn changeset, _context ->
        if changeset.data.archived_at do
          {:error,
           field: :archived_at, message: dgettext_noop("errors", "Issue is already archived.")}
        else
          :ok
        end
      end

      # Add metadata for event tracking
      change fn changeset, context ->
        Ash.Changeset.put_context(changeset, :ash_events_metadata, %{
          site_id: context.tenant || changeset.data.site_id,
          title: changeset.data.title
        })
      end
    end

    destroy :master_destroy do
      description "Soft deletes issue by archiving (master users) - bypasses multi-tenancy"
      require_atomic? false
      multitenancy :bypass

      validate {MishkaCmsCore.Runtime.Resources.Validations.TenantContext, require_master: true}

      validate fn changeset, _context ->
        if changeset.data.archived_at do
          {:error,
           field: :archived_at, message: dgettext_noop("errors", "Issue is already archived.")}
        else
          :ok
        end
      end

      change fn changeset, _context ->
        Ash.Changeset.put_context(changeset, :ash_events_metadata, %{
          site_id: changeset.data.site_id,
          title: changeset.data.title
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
          title: changeset.data.title
        })
      end

      description "Restores archived issue (tenant users)"
    end

    update :master_unarchive do
      description "Restores archived issue (master users) - bypasses multi-tenancy"
      accept []
      require_atomic? false
      multitenancy :bypass

      validate {MishkaCmsCore.Runtime.Resources.Validations.TenantContext, require_master: true}

      validate fn changeset, _context ->
        if is_nil(changeset.data.archived_at) do
          {:error,
           field: :archived_at, message: dgettext_noop("errors", "Issue is not archived.")}
        else
          :ok
        end
      end

      change set_attribute(:archived_at, nil)

      # Add metadata for event tracking
      change fn changeset, _context ->
        Ash.Changeset.put_context(changeset, :ash_events_metadata, %{
          site_id: changeset.data.site_id,
          title: changeset.data.title
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
          title: changeset.data.title
        })
      end

      description "Permanently removes issue from database (tenant users) - use with extreme caution"
    end

    destroy :master_permanent_destroy do
      description "Permanently removes issue from database (master users) - bypasses multi-tenancy, irreversible"
      require_atomic? false
      multitenancy :bypass

      validate {MishkaCmsCore.Runtime.Resources.Validations.TenantContext, require_master: true}

      change fn changeset, _context ->
        Ash.Changeset.put_context(changeset, :ash_events_metadata, %{
          site_id: changeset.data.site_id,
          title: changeset.data.title
        })
      end
    end
  end

  # Authorization policies for issue access
  policies do
    # The section area, for every action.
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
    prefix "issue"

    publish :create, [[nil, :site_id], "created"]
    publish :update, [[nil, :site_id], "updated"]
    publish :mark_in_progress, [[nil, :site_id], "updated"]
    publish :mark_resolved, [[nil, :site_id], "updated"]
    publish :mark_closed, [[nil, :site_id], "updated"]
    publish :reopen, [[nil, :site_id], "updated"]
    publish :unarchive, [[nil, :site_id], "updated"]
    publish :destroy, [[nil, :site_id], "destroyed"]
    publish :permanent_destroy, [[nil, :site_id], "destroyed"]
    publish :master_create, [[nil, :site_id], "created"]
    publish :master_update, [[nil, :site_id], "updated"]
    publish :master_unarchive, [[nil, :site_id], "updated"]
    publish :master_destroy, [[nil, :site_id], "destroyed"]
    publish :master_permanent_destroy, [[nil, :site_id], "destroyed"]
  end

  # Every id this record holds names a record of its own site, whoever writes it.
  validations do
    validate {MishkaCmsCore.Runtime.Resources.Validations.SameSiteReference,
              field: :note_id,
              resource: MishkaDocument.Note,
              label: dgettext_noop("errors", "note"),
              read_action: :master_get},
             where: [changing(:note_id)],
             only_when_valid?: true

    validate {MishkaCmsCore.Runtime.Resources.Validations.SameSiteReference,
              field: :section_id,
              resource: MishkaDocument.Section,
              label: dgettext_noop("errors", "section"),
              read_action: :master_get},
             where: [changing(:section_id)],
             only_when_valid?: true

    validate {MishkaCmsCore.Runtime.Resources.Validations.SameSiteReference,
              field: :reporter_id,
              resource: MishkaCmsCore.Accounts.User,
              label: dgettext_noop("errors", "user"),
              read_action: :related,
              shared?: true},
             where: [changing(:reporter_id)]
  end

  # Multi-tenancy configuration - issues are always site-specific
  multitenancy do
    strategy :attribute
    attribute :site_id
    # Issues are NEVER global - always site-specific
    global? false
  end

  attributes do
    uuid_primary_key :id

    attribute :title, :string do
      allow_nil? false
      public? true
      constraints min_length: 1, max_length: 500, trim?: true
      description "Title of the issue"
    end

    attribute :description, :string do
      allow_nil? false
      public? true
      constraints min_length: 1, trim?: true
      description "Detailed description of the issue"
    end

    attribute :issue_type, :atom do
      allow_nil? false
      public? true
      default :other

      constraints one_of: [
                    :typo,
                    :broken_link,
                    :incorrect_content,
                    :suggestion,
                    :review_feedback,
                    :other
                  ]

      description "Type of issue (typo, broken_link, incorrect_content, suggestion, review_feedback, other)"
    end

    attribute :status, :atom do
      allow_nil? false
      public? true
      default :open
      constraints one_of: [:open, :in_progress, :resolved, :closed]
      description "Current status of the issue (open, in_progress, resolved, closed)"
    end

    create_timestamp :inserted_at
    update_timestamp :updated_at
  end

  relationships do
    belongs_to :site, MishkaCmsCore.Runtime.Site do
      read_action :read_any
      allow_nil? false
      public? true
      description "The site this issue belongs to"
    end

    belongs_to :note, MishkaDocument.Note do
      allow_nil? true
      public? true
      description "The note this issue is about (optional)"
    end

    belongs_to :section, MishkaDocument.Section do
      allow_nil? true
      public? true
      description "The section this issue is about (optional)"
    end

    belongs_to :reporter, MishkaCmsCore.Accounts.User do
      # How any resource reaches an account — see `MishkaCmsCore.Accounts.User`'s `:related`.
      read_action :related
      sortable? false
      allow_nil? true
      public? true
      description "The user who reported this issue"
    end

    # Master admin relationships - bypass tenant filtering
    belongs_to :master_note, MishkaDocument.Note do
      public? true
      source_attribute :note_id
      define_attribute? false
      read_action :read_any
      description "The note this issue is about (master admin access, bypass tenant)"

      filter expr(not is_nil(type(^actor(:id), :uuid)) and is_nil(type(^actor(:site_id), :uuid)))
    end

    belongs_to :master_section, MishkaDocument.Section do
      public? true
      source_attribute :section_id
      define_attribute? false
      read_action :read_any
      description "The section this issue is about (master admin access, bypass tenant)"

      filter expr(not is_nil(type(^actor(:id), :uuid)) and is_nil(type(^actor(:site_id), :uuid)))
    end

    has_many :site_issues, MishkaDocument.Issue do
      source_attribute :site_id
      destination_attribute :site_id
      description "All issues for the same site (for site-level statistics)"
    end
  end

  calculations do
    calculate :reporter_master?,
              :boolean,
              {MishkaCmsCore.Accounts.Calculations.ByMaster, field: :reporter_id} do
      description "Whether the reporter is a master, for a reader who cannot load a master's account"
    end
  end

  aggregates do
    count :open_issues_count, :site_issues do
      public? true
      authorize? false
      multitenancy :bypass
      filter expr(status == :open)
      description "Returns count of open issues for the site"
    end

    count :in_progress_issues_count, :site_issues do
      public? true
      authorize? false
      multitenancy :bypass
      filter expr(status == :in_progress)
      description "Returns count of in_progress issues for the site"
    end
  end

  identities do
    # No unique constraints needed for issues
  end
end
