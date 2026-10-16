# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_document/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaDocument.NoteDraft do
  @moduledoc """
  Manages draft proposals for note changes within sections.

  This resource represents proposed changes to notes that must go through
  a dual approval workflow (content review and technical review) before being
  applied to the actual Note resource.

  Three main use cases:
  1. Creating a new note in an existing section (section_id set, source_note_id nil)
  2. Editing an existing note (section_id set, source_note_id set)
  3. Creating a note as part of a new section (section_draft_id set, source_note_id nil)

  The draft includes version management:
  - version_increment_type determines if a new version should be created
  - When approved, changes are automatically applied via AutoApplyDraft change
  - If part of a section draft, must wait for section draft to be applied first

  Multi-tenant isolation ensures drafts are properly segregated between sites.
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

  require Ash.Query

  use MishkaGervaz.Messages, backend: MishkaCmsCore.Gettext
  import Phoenix.Component, only: [sigil_H: 2]
  import MishkaGervaz.UIAdapters.Tailwind, only: [cell_stacked: 1, cell_stats: 1]
  alias MishkaCmsCore.Localized

  # The review-chip palette the draft cards already use, so a status reads the same colour whichever
  # view you land on and note drafts match section drafts row for row.
  @reviews %{
    approved: %{label: gettext_noop("Approved"), class: "bg-[#e6f6ee] text-[#177a53]"},
    pending: %{label: gettext_noop("Pending"), class: "bg-[#fbf1df] text-[#a5691a]"},
    rejected: %{label: gettext_noop("Rejected"), class: "bg-[#fbe9e7] text-[#b3433a]"},
    needs_revision: %{label: gettext_noop("Needs Revision"), class: "bg-[#f4ecfb] text-[#8a4bcc]"},
    archived: %{label: gettext_noop("Archived"), class: "bg-[#f2f1ec] text-[#6d6a63]"}
  }

  @unknown_review %{label: "—", class: "bg-[#f2f1ec] text-[#8a877f]"}

  @applied_states %{
    applied: %{label: gettext_noop("Applied"), class: "bg-[#e6f6ee] text-[#177a53]"},
    ready: %{label: gettext_noop("Ready"), class: "bg-[#eef1fc] text-[#4f4bcc]"},
    rejected: %{label: gettext_noop("Rejected"), class: "bg-[#fbe9e7] text-[#b3433a]"},
    revision: %{label: gettext_noop("Revision"), class: "bg-[#f4ecfb] text-[#8a4bcc]"},
    pending: %{label: gettext_noop("Pending"), class: "bg-[#f2f1ec] text-[#6d6a63]"}
  }

  @admin_fields [
    :workspace_version_id,
    :section_id,
    :section_draft_id,
    :source_note_id,
    :title,
    :content,
    :order_position,
    :change_version,
    :version_increment_type,
    :content_review_status,
    :technical_review_status,
    :schema,
    :seo_tags,
    :created_by_user_id,
    :site_id
  ]

  # The note's fields a draft of it holds, and applying it writes when it changes them — see
  # `MishkaDocument.Resources.Changes.StartFromSource`.
  @note_fields [:title, :content, :order_position, :change_version, :schema, :seo_tags]

  @start_from_source [
    source: :source_note_id,
    resource: MishkaDocument.Note,
    fields: @note_fields
  ]

  @doc "The note's fields a draft of it holds."
  @spec note_fields() :: [atom()]
  def note_fields, do: @note_fields

  # Database configuration for note drafts storage with indexing
  postgres do
    table "mishka_document_note_drafts"
    repo Application.compile_env!(:mishka_cms_core, :repo)

    # Database-level optimization for archived records
    base_filter_sql "(archived_at IS NULL)"

    references do
      reference :site, on_delete: :delete
      reference :workspace_version, on_delete: :delete
      reference :section, on_delete: :delete
      reference :section_draft, on_delete: :delete
      reference :source_note, on_delete: :delete
      reference :created_by_user, on_delete: :nilify
    end

    custom_indexes do
      index [:workspace_version_id]
      index [:section_id]
      index [:section_draft_id]
      index [:source_note_id]
      index [:content_review_status]
      index [:technical_review_status]
      index [:applied_at]
      index [:created_by_user_id]
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
    type "note_draft"

    includes [
      :workspace_version,
      :section,
      :section_draft,
      :source_note,
      :created_by_user
    ]

    paginated_includes []
  end

  # Event tracking configuration for activity logging
  events do
    event_log MishkaDocument.EventLog

    only_actions [
      :create,
      :master_create,
      :update,
      :master_update,
      :mark_applied,
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
        name :note_drafts
        route "/admin/dashboard/document/note-drafts"
        stream_name :note_drafts
      end

      source do
        preload do
          always [:site, :created_by_user, :created_by_master?, :content_word_count]
        end
      end

      columns do
        # The row's headline. `cell_stacked variant={:title}` is what finally renders the title bold
        # (#17161a, 13.5px, font-semibold) instead of the old plain span, with the order folded under it.
        column :draft_info do
          static true
          requires [:title, :order_position]
          label fn -> dgettext("mishka_gervaz", "Draft") end
          position :first

          ui do
            width "minmax(190px,2fr)"
          end

          render fn record ->
            order = record.order_position

            assigns = %{
              title: record.title,
              order:
                (is_integer(order) && order > 0 &&
                   dgettext("mishka_gervaz", "Order %{order}", order: order)) || nil
            }

            ~H"""
            <.cell_stacked variant={:title} primary={@title} secondary={@order} />
            """
          end
        end

        column :draft_version do
          static true
          requires [:change_version, :version_increment_type]
          label fn -> dgettext("mishka_gervaz", "Version") end

          ui do
            width "minmax(115px,0.85fr)"
          end

          render fn record ->
            assigns = %{
              version: version_label(record.change_version),
              type: increment_label(record.version_increment_type)
            }

            ~H"""
            <.cell_stats chips={[
              %{
                text: @version,
                class: "bg-[#f4ecfb] text-[#7a5bd0]",
                label: dgettext("mishka_gervaz", "Change version")
              },
              %{text: @type, label: dgettext("mishka_gervaz", "Increment type")}
            ]} />
            """
          end
        end

        column :draft_review do
          static true
          requires [:content_review_status, :technical_review_status]
          label fn -> dgettext("mishka_gervaz", "Content / Technical Review") end

          ui do
            width "minmax(150px,1.1fr)"
          end

          render fn record ->
            assigns = %{
              content: review_badge(record.content_review_status),
              technical: review_badge(record.technical_review_status)
            }

            ~H"""
            <div class="flex flex-wrap items-center gap-[5px]">
              <span
                class={["rounded-[6px] px-[7px] py-[3px] text-[10.5px] font-bold", @content.class]}
                title={dgettext("mishka_gervaz", "Content review")}
              >
                {@content.label}
              </span>
              <span
                class={["rounded-[6px] px-[7px] py-[3px] text-[10.5px] font-bold", @technical.class]}
                title={dgettext("mishka_gervaz", "Technical review")}
              >
                {@technical.label}
              </span>
            </div>
            """
          end
        end

        column :draft_applied do
          static true
          requires [:applied_at, :content_review_status, :technical_review_status]
          label fn -> dgettext("mishka_gervaz", "Applied") end

          ui do
            width "minmax(120px,1fr)"
          end

          render fn record ->
            {state, detail} = applied_status(record)
            assigns = %{state: state, detail: detail}

            ~H"""
            <div class="min-w-0">
              <span class={[
                "inline-flex rounded-[6px] px-[7px] py-[3px] text-[10.5px] font-bold",
                @state.class
              ]}>
                {@state.label}
              </span>
              <div
                :if={@detail}
                class="mt-[3px] truncate text-[10.5px] font-medium text-[#a8a5a0]"
                title={@detail}
              >
                {@detail}
              </div>
            </div>
            """
          end
        end

        column :draft_creator do
          static true

          requires [
            :id,
            :created_by_user,
            :created_by_user_id,
            :created_by_master?,
            :updated_at
          ]

          label fn -> dgettext("mishka_gervaz", "Creator") end

          ui do
            width "minmax(140px,1.2fr)"
          end

          render fn record ->
            assigns = %{
              id: record.id,
              creator: creator(record),
              updated:
                dgettext("mishka_gervaz", "Updated %{date}", date: inserted_on(record.updated_at))
            }

            ~H"""
            <div id={"note-draft-creator-#{@id}"}>
              <.cell_stacked
                variant={:meta}
                icon="hero-user"
                primary={@creator}
                secondary={@updated}
              />
            </div>
            """
          end
        end

        # The merged final cell: the site only when the reader is a master user, the created date under
        # it either way, so a tenant sees just the date and a master sees where the draft lives and when.
        column :site_info do
          static true
          requires [:site_id, :site, :inserted_at]
          label fn -> dgettext("mishka_gervaz", "Site / Date") end
          position :last

          ui do
            width "minmax(125px,1.2fr)"
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
      end

      filter_groups do
        group :primary do
          filters [:search]
        end

        group :advanced do
          filters [
            :content_review_status,
            :technical_review_status,
            :version_increment_type,
            :workspace_version_id,
            :section_id,
            :section_draft_id,
            :site_id,
            :source_note_id,
            :created_at
          ]

          collapsible true

          ui do
            label fn -> dgettext("mishka_gervaz", "Advanced Search") end
            icon "hero-funnel"
            columns 3
          end
        end
      end

      filters do
        filter :search, :text do
          fields [:title, :content, :change_version]

          ui do
            label fn -> dgettext("mishka_gervaz", "Search") end
          end
        end

        filter :content_review_status, :select do
          options fn ->
            [
              {dgettext("mishka_gervaz", "Pending"), :pending},
              {dgettext("mishka_gervaz", "Approved"), :approved},
              {dgettext("mishka_gervaz", "Rejected"), :rejected},
              {dgettext("mishka_gervaz", "Needs Revision"), :needs_revision}
            ]
          end

          ui do
            prompt dgettext_noop("mishka_gervaz", "All Content Statuses")
            label fn -> dgettext("mishka_gervaz", "Content Review") end
          end
        end

        filter :technical_review_status, :select do
          options fn ->
            [
              {dgettext("mishka_gervaz", "Pending"), :pending},
              {dgettext("mishka_gervaz", "Approved"), :approved},
              {dgettext("mishka_gervaz", "Rejected"), :rejected},
              {dgettext("mishka_gervaz", "Needs Revision"), :needs_revision}
            ]
          end

          ui do
            prompt dgettext_noop("mishka_gervaz", "All Technical Statuses")
            label fn -> dgettext("mishka_gervaz", "Technical Review") end
          end
        end

        filter :version_increment_type, :select do
          options fn ->
            [
              {dgettext("mishka_gervaz", "Major"), :major},
              {dgettext("mishka_gervaz", "Minor"), :minor},
              {dgettext("mishka_gervaz", "Patch"), :patch},
              {dgettext("mishka_gervaz", "Prerelease"), :prerelease},
              {dgettext("mishka_gervaz", "None"), :none}
            ]
          end

          ui do
            prompt dgettext_noop("mishka_gervaz", "All Increment Types")
            label fn -> dgettext("mishka_gervaz", "Increment Type") end
          end
        end

        filter :workspace_version_id, :relation do
          mode :search_multi
          display_field :version_number
          search_field :version_number
          min_chars 1
          page_size 15

          ui do
            label fn -> dgettext("mishka_gervaz", "Workspace Version") end
            placeholder fn -> dgettext("mishka_gervaz", "Search versions...") end
          end
        end

        filter :section_id, :relation do
          mode :search_multi
          display_field :title
          search_field :title
          min_chars 1
          page_size 15

          ui do
            label fn -> dgettext("mishka_gervaz", "Section") end
            placeholder fn -> dgettext("mishka_gervaz", "Search sections...") end
          end
        end

        filter :section_draft_id, :relation do
          mode :search_multi
          display_field :title
          search_field :title
          min_chars 1
          page_size 15

          ui do
            label fn -> dgettext("mishka_gervaz", "Section Draft") end
            placeholder fn -> dgettext("mishka_gervaz", "Search section drafts...") end
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

        filter :source_note_id, :relation do
          mode :search_multi
          display_field :title
          search_field :title
          min_chars 1
          page_size 15

          ui do
            label fn -> dgettext("mishka_gervaz", "Source Note") end
            placeholder fn -> dgettext("mishka_gervaz", "Search notes...") end
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
          js fn _record -> MishkaCmsCore.CoreComponents.show_modal("note-draft-form-modal") end

          ui do
            label fn -> dgettext("mishka_gervaz", "Edit") end
          end
        end

        action :delete do
          type :destroy
          confirm fn _record -> dgettext("mishka_gervaz", "Archive this note draft?") end
          visible :active
        end

        action :unarchive do
          type :unarchive
          confirm fn _record -> dgettext("mishka_gervaz", "Restore this note draft?") end
          visible :archived
        end

        action :permanent_destroy do
          type :permanent_destroy

          confirm fn _record ->
            dgettext("mishka_gervaz", "Permanently delete? This cannot be undone.")
          end

          visible :archived
        end
      end

      row do
        selectable true
      end

      bulk_actions do
        action :archive,
          type: :destroy,
          confirm: dgettext_noop("mishka_gervaz", "Archive selected note drafts?")

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
        prefix "note_draft"
      end

      url_sync do
        mode :bidirectional
        params [:filters, :sort, :page, :search]
        prefix "note_drafts"
        max_filter_length 500
        preserve_params [:return_to]
      end

      hooks do
        on_expand fn _id, socket ->
          {:cont, socket}
        end
      end

      empty_state message: dgettext_noop("mishka_gervaz", "No note drafts found"),
                  icon: "hero-document-text"
    end

    form do
      identity do
        name :note_draft_form
      end

      source do
        preload do
          master [:master_workspace_version]
          tenant [:workspace_version]
        end
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

        field :title, :text do
          required true

          ui do
            label fn -> dgettext("mishka_gervaz", "Title") end
            placeholder fn -> dgettext("mishka_gervaz", "Note title") end
          end
        end

        field :workspace, :relation do
          virtual true
          resource MishkaDocument.Workspace
          display_field :name
          search_field :name
          mode :search
          depends_on :site_id

          derive_value fn record ->
            cond do
              match?(%{master_workspace_version: %{workspace_id: _}}, record) ->
                record.master_workspace_version.workspace_id

              match?(%{workspace_version: %{workspace_id: _}}, record) ->
                record.workspace_version.workspace_id

              true ->
                nil
            end
          end

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
            label fn -> dgettext("mishka_gervaz", "Workspace") end
          end
        end

        field :workspace_version_id, :relation do
          required true
          display_field &MishkaDocument.WorkspaceVersion.source_label/1
          search_field :version_number
          mode :search
          depends_on :workspace

          load fn query, state ->
            workspace_id = Map.get(state.field_values, :workspace)

            if workspace_id do
              Ash.Query.filter_input(query, %{workspace_id: workspace_id})
            else
              query
            end
          end

          ui do
            label fn -> dgettext("mishka_gervaz", "Workspace Version") end
          end
        end

        field :change_version, :text do
          required true

          ui do
            label fn -> dgettext("mishka_gervaz", "Change Version") end
            placeholder "0.0.1"
          end
        end

        field :version_increment_type, :select do
          required true

          options fn ->
            [
              {dgettext("mishka_gervaz", "Major"), :major},
              {dgettext("mishka_gervaz", "Minor"), :minor},
              {dgettext("mishka_gervaz", "Patch"), :patch},
              {dgettext("mishka_gervaz", "Prerelease"), :prerelease},
              {dgettext("mishka_gervaz", "None"), :none}
            ]
          end

          ui do
            label fn -> dgettext("mishka_gervaz", "Increment Type") end
          end
        end

        field :order_position, :text do
          ui do
            label fn -> dgettext("mishka_gervaz", "Order Position") end
            placeholder "0"
          end
        end

        field :content_review_status, :select do
          required true

          options fn ->
            [
              {dgettext("mishka_gervaz", "Pending"), :pending},
              {dgettext("mishka_gervaz", "Approved"), :approved},
              {dgettext("mishka_gervaz", "Rejected"), :rejected},
              {dgettext("mishka_gervaz", "Needs revision"), :needs_revision}
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
              {dgettext("mishka_gervaz", "Needs revision"), :needs_revision}
            ]
          end

          ui do
            label fn -> dgettext("mishka_gervaz", "Technical Review") end
          end
        end

        field :section_id, :relation do
          display_field :title
          search_field :title
          mode :search
          depends_on :workspace_version_id
          include_nil fn -> dgettext("mishka_gervaz", "No section") end

          load fn query, state ->
            Ash.Query.filter_input(query, %{
              workspace_version_id: Map.get(state.field_values, :workspace_version_id)
            })
          end

          ui do
            label fn -> dgettext("mishka_gervaz", "Section") end
          end
        end

        field :section_draft_id, :relation do
          display_field :title
          search_field :title
          mode :search
          depends_on :workspace_version_id
          include_nil fn -> dgettext("mishka_gervaz", "No section draft") end

          load fn query, state ->
            Ash.Query.filter_input(query, %{
              workspace_version_id: Map.get(state.field_values, :workspace_version_id)
            })
          end

          ui do
            label fn -> dgettext("mishka_gervaz", "Section Draft") end
          end
        end

        field :source_note_id, :relation do
          display_field :title
          search_field :title
          mode :search
          depends_on :workspace_version_id
          include_nil fn -> dgettext("mishka_gervaz", "No source note") end

          load fn query, state ->
            version_id = Map.get(state.field_values, :workspace_version_id)
            Ash.Query.filter(query, section.workspace_version_id == ^version_id)
          end

          ui do
            label fn -> dgettext("mishka_gervaz", "Source Note") end
          end
        end

        field :content, :textarea do
          required true

          ui do
            label fn -> dgettext("mishka_gervaz", "Content") end
            placeholder fn -> dgettext("mishka_gervaz", "Note content...") end
            rows 6

            # The rich-text editor, with components placed as blocks; their markers are what is
            # stored. `MishkaCmsCoreWeb.UIAdapters.Admin.textarea/1` is what reads this.
            extra %{content_editor: true}
          end
        end

        field :created_by_user_id, :relation do
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
              Ash.Query.filter_input(query, %{site_id: site_id})
            else
              query
            end
          end

          ui do
            label fn -> dgettext("mishka_gervaz", "Created By") end
          end
        end
      end

      groups do
        group :basic_info do
          fields [:site_id, :title, :change_version, :version_increment_type]

          ui do
            label fn -> dgettext("mishka_gervaz", "Basic Information") end
            columns 2
          end
        end

        group :references do
          fields [
            :workspace,
            :workspace_version_id,
            :section_id,
            :section_draft_id,
            :source_note_id
          ]

          ui do
            label fn -> dgettext("mishka_gervaz", "References") end
            columns 2
          end
        end

        group :review do
          fields [:content_review_status, :technical_review_status, :order_position]

          ui do
            label fn -> dgettext("mishka_gervaz", "Review & Settings") end
            columns 3
          end
        end

        group :content do
          fields [:content]

          ui do
            label fn -> dgettext("mishka_gervaz", "Content") end
            columns 1
          end
        end

        group :meta do
          fields [:created_by_user_id]

          ui do
            label fn -> dgettext("mishka_gervaz", "Metadata") end
            columns 1
          end
        end
      end

      # For `textarea/1` only — the adapter falls back to Tailwind for everything else. It is what
      # turns the `content` field's `extra %{content_editor: true}` into the editor.
      presentation do
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

    field :content, :string, derives: "sanitize(html5) validate(string, not_empty)"

    field :order_position, :integer, derives: "validate(optional=[integer, min_len=0])"

    field :change_version, :string,
      derives: "sanitize(trim) validate(optional=[string, max_len=50, semver])"

    field :version_increment_type, :atom,
      derives: "validate(optional=[atom, enum=Atom[major::minor::patch::prerelease::none]])"

    field :content_review_status, :atom,
      derives: "validate(atom, enum=Atom[pending::approved::rejected::needs_revision::archived])"

    field :technical_review_status, :atom,
      derives: "validate(atom, enum=Atom[pending::approved::rejected::needs_revision::archived])"

    field :applied_at, :utc_datetime, derives: "validate(optional=[utc_datetime, past_datetime])"
    field :schema, {:array, :map}, derives: "validate(list)"
    field :seo_tags, {:array, :map}, derives: "validate(list)"
  end

  actions do
    defaults [:read]

    default_accept @admin_fields

    create :create do
      primary? true
      accept @admin_fields |> List.delete(:site_id)

      validate present(:workspace_version_id)
      validate present(:title)
      validate present(:content)
      validate present(:change_version)
      validate present(:version_increment_type)

      validate {MishkaCmsCore.Runtime.Resources.Validations.TenantContext, require_master: false}

      validate {MishkaCmsCore.Runtime.Resources.Validations.TenantIsolation,
                field: :workspace_version_id, resource: MishkaDocument.WorkspaceVersion}

      validate {MishkaCmsCore.Runtime.Resources.Validations.TenantIsolation,
                field: :section_id, resource: MishkaDocument.Section}

      validate {MishkaCmsCore.Runtime.Resources.Validations.TenantIsolation,
                field: :source_note_id, resource: MishkaDocument.Note}

      validate {MishkaCmsCore.Runtime.Resources.Validations.TenantIsolation,
                field: :created_by_user_id, resource: MishkaCmsCore.Accounts.User}

      change &Ash.Changeset.force_change_attribute(&1, :site_id, &2.tenant)

      # Set created_by_user_id from actor only if not provided in form
      change fn changeset, context ->
        existing_user_id = Ash.Changeset.get_attribute(changeset, :created_by_user_id)

        if is_nil(existing_user_id) do
          case context.actor do
            %{id: user_id} ->
              Ash.Changeset.force_change_attribute(changeset, :created_by_user_id, user_id)

            _ ->
              changeset
          end
        else
          changeset
        end
      end

      # Validate section_id XOR section_draft_id
      validate fn changeset, _context ->
        section_id = Ash.Changeset.get_attribute(changeset, :section_id)
        section_draft_id = Ash.Changeset.get_attribute(changeset, :section_draft_id)

        cond do
          is_nil(section_id) and is_nil(section_draft_id) ->
            {:error,
             message:
               dgettext_noop("errors", "Must specify either section_id or section_draft_id.")}

          !is_nil(section_id) and !is_nil(section_draft_id) ->
            {:error,
             message:
               dgettext_noop("errors", "Cannot specify both section_id and section_draft_id.")}

          true ->
            :ok
        end
      end

      # If section_draft_id is set, ensure change_version matches the section draft
      validate fn changeset, _context ->
        section_draft_id = Ash.Changeset.get_attribute(changeset, :section_draft_id)
        change_version = Ash.Changeset.get_attribute(changeset, :change_version)

        if section_draft_id do
          case Ash.get(MishkaDocument.SectionDraft, section_draft_id,
                 tenant: changeset.tenant,
                 authorize?: false
               ) do
            {:ok, section_draft} ->
              if section_draft.change_version == change_version do
                :ok
              else
                {:error,
                 field: :change_version,
                 message:
                   dgettext_noop("errors", "Version must match parent section draft version.")}
              end

            _ ->
              {:error,
               field: :section_draft_id,
               message: dgettext_noop("errors", "Section draft not found.")}
          end
        else
          :ok
        end
      end

      # Highlights the code blocks of the sanitized content, before the row is written.
      change MishkaDocument.Resources.Changes.HighlightCode
      change {MishkaDocument.Resources.Changes.StartFromSource, @start_from_source}

      change {MishkaDocument.Resources.Changes.SetEventMetadata,
              resource_type: :note_draft, for_action: :create}

      description "Creates note draft for tenant users - requires tenant context, auto-assigns site_id"
    end

    create :master_create do
      validate present(:workspace_version_id)
      validate present(:title)
      validate present(:content)
      validate present(:site_id)
      validate present(:change_version)
      validate present(:version_increment_type)

      validate {MishkaCmsCore.Runtime.Resources.Validations.TenantContext, require_master: true}

      change fn changeset, _context ->
        site_id = Ash.Changeset.get_attribute(changeset, :site_id)
        Ash.Changeset.set_tenant(changeset, site_id)
      end

      # Set created_by_user_id from actor only if not provided in form
      change fn changeset, context ->
        existing_user_id = Ash.Changeset.get_attribute(changeset, :created_by_user_id)

        if is_nil(existing_user_id) do
          case context.actor do
            %{id: user_id} ->
              Ash.Changeset.force_change_attribute(changeset, :created_by_user_id, user_id)

            _ ->
              changeset
          end
        else
          changeset
        end
      end

      # Validate section_id XOR section_draft_id
      validate fn changeset, _context ->
        section_id = Ash.Changeset.get_attribute(changeset, :section_id)
        section_draft_id = Ash.Changeset.get_attribute(changeset, :section_draft_id)

        cond do
          is_nil(section_id) and is_nil(section_draft_id) ->
            {:error,
             message:
               dgettext_noop("errors", "Must specify either section_id or section_draft_id.")}

          !is_nil(section_id) and !is_nil(section_draft_id) ->
            {:error,
             message:
               dgettext_noop("errors", "Cannot specify both section_id and section_draft_id.")}

          true ->
            :ok
        end
      end

      # If section_draft_id is set, ensure change_version matches the section draft
      validate fn changeset, _context ->
        section_draft_id = Ash.Changeset.get_attribute(changeset, :section_draft_id)
        change_version = Ash.Changeset.get_attribute(changeset, :change_version)

        if section_draft_id do
          case Ash.get(MishkaDocument.SectionDraft, section_draft_id,
                 authorize?: false,
                 action: :master_get
               ) do
            {:ok, section_draft} ->
              if section_draft.change_version == change_version do
                :ok
              else
                {:error,
                 field: :change_version,
                 message:
                   dgettext_noop("errors", "Version must match parent section draft version.")}
              end

            _ ->
              {:error,
               field: :section_draft_id,
               message: dgettext_noop("errors", "Section draft not found.")}
          end
        else
          :ok
        end
      end

      # Highlights the code blocks of the sanitized content, before the row is written.
      change MishkaDocument.Resources.Changes.HighlightCode
      change {MishkaDocument.Resources.Changes.StartFromSource, @start_from_source}

      change {MishkaDocument.Resources.Changes.SetEventMetadata,
              resource_type: :note_draft, for_action: :create}

      description "Creates note draft for master users - requires explicit site_id"
    end

    update :update do
      primary? true
      require_atomic? false
      transaction? true

      accept @admin_fields |> List.delete(:site_id) |> List.delete(:created_by_user_id)

      validate {MishkaCmsCore.Runtime.Resources.Validations.TenantContext, require_master: false}

      validate {MishkaCmsCore.Runtime.Resources.Validations.TenantIsolation,
                field: :workspace_version_id, resource: MishkaDocument.WorkspaceVersion},
               where: [changing(:workspace_version_id)]

      validate {MishkaCmsCore.Runtime.Resources.Validations.TenantIsolation,
                field: :section_id, resource: MishkaDocument.Section},
               where: [changing(:section_id)]

      validate {MishkaCmsCore.Runtime.Resources.Validations.TenantIsolation,
                field: :section_draft_id, resource: MishkaDocument.SectionDraft},
               where: [changing(:section_draft_id)]

      validate {MishkaCmsCore.Runtime.Resources.Validations.TenantIsolation,
                field: :source_note_id, resource: MishkaDocument.Note},
               where: [changing(:source_note_id)]

      change MishkaDocument.Resources.Changes.HighlightCode
      change {MishkaDocument.Resources.Changes.StartFromSource, @start_from_source}

      # Auto-apply when both approvals are granted
      change MishkaDocument.Resources.Changes.AutoApplyNoteDraft

      change {MishkaDocument.Resources.Changes.SetEventMetadata,
              resource_type: :note_draft, for_action: :update}

      description "Updates note draft for tenant users - requires tenant context, prevents site_id and created_by_user_id changes, triggers auto-apply when both approvals granted"
    end

    update :mark_applied do
      accept [:applied_at]
      require_atomic? false

      change {MishkaDocument.Resources.Changes.SetEventMetadata,
              resource_type: :note_draft, for_action: :update}

      description "Internal action to mark draft as applied with timestamp"
    end

    update :master_update do
      description "Updates note draft for master users - bypasses multi-tenancy, prevents site_id and created_by_user_id changes, triggers auto-apply when both approvals granted"
      require_atomic? false
      transaction? true

      accept @admin_fields |> List.delete(:site_id) |> List.delete(:created_by_user_id)

      multitenancy :bypass

      validate {MishkaCmsCore.Runtime.Resources.Validations.TenantContext, require_master: true}

      validate absent(:archived_at) do
        message dgettext_noop(
                  "errors",
                  "Cannot edit archived note draft. Please unarchive it first."
                )
      end

      change MishkaDocument.Resources.Changes.HighlightCode
      change {MishkaDocument.Resources.Changes.StartFromSource, @start_from_source}

      # Auto-apply when both approvals are granted
      change MishkaDocument.Resources.Changes.AutoApplyNoteDraft

      change {MishkaDocument.Resources.Changes.SetEventMetadata,
              resource_type: :note_draft, for_action: :update}
    end

    read :master_read do
      description "Reads all note drafts system-wide, bypassing tenant filtering (master users only)"
      multitenancy :bypass
      pagination offset?: true, default_limit: 20, max_page_size: 100, countable: true

      validate {MishkaCmsCore.Runtime.Resources.Validations.TenantContext, require_master: true}
    end

    read :master_get do
      multitenancy :bypass
      get? true
      description "Retrieves single note draft by ID, bypassing tenant filtering"

      validate {MishkaCmsCore.Runtime.Resources.Validations.TenantContext, require_master: true}
    end

    read :archived do
      filter expr(not is_nil(archived_at))
      pagination offset?: true, default_limit: 20, max_page_size: 100, countable: true

      validate {MishkaCmsCore.Runtime.Resources.Validations.TenantContext, require_master: false}

      description "Lists archived note drafts within current tenant context"
    end

    read :get_archived do
      get? true
      filter expr(not is_nil(archived_at))

      validate {MishkaCmsCore.Runtime.Resources.Validations.TenantContext, require_master: false}

      description "Retrieves single archived note draft for recovery or inspection (tenant users)"
    end

    read :master_get_archived do
      get? true
      multitenancy :bypass
      filter expr(not is_nil(archived_at))

      validate {MishkaCmsCore.Runtime.Resources.Validations.TenantContext, require_master: true}

      description "Retrieves single archived note draft for recovery or inspection (master users)"
    end

    read :master_archived do
      multitenancy :bypass
      filter expr(not is_nil(archived_at))
      pagination offset?: true, default_limit: 20, max_page_size: 100, countable: true

      validate {MishkaCmsCore.Runtime.Resources.Validations.TenantContext, require_master: true}

      description "Lists all archived note drafts system-wide, bypassing tenant filtering"
    end

    destroy :destroy do
      description "Soft deletes note draft by archiving (tenant users)"
      primary? true
      require_atomic? false

      validate {MishkaCmsCore.Runtime.Resources.Validations.TenantContext, require_master: false}

      validate fn changeset, _context ->
        if changeset.data.archived_at do
          {:error,
           field: :archived_at,
           message: dgettext_noop("errors", "Note draft is already archived.")}
        else
          :ok
        end
      end

      change {MishkaDocument.Resources.Changes.SetEventMetadata,
              resource_type: :note_draft, for_action: :destroy}
    end

    destroy :master_destroy do
      description "Soft deletes note draft by archiving (master users) - bypasses multi-tenancy"
      require_atomic? false
      multitenancy :bypass

      validate {MishkaCmsCore.Runtime.Resources.Validations.TenantContext, require_master: true}

      validate fn changeset, _context ->
        if changeset.data.archived_at do
          {:error,
           field: :archived_at,
           message: dgettext_noop("errors", "Note draft is already archived.")}
        else
          :ok
        end
      end

      change {MishkaDocument.Resources.Changes.SetEventMetadata,
              resource_type: :note_draft, for_action: :destroy}
    end

    update :unarchive do
      accept []
      require_atomic? false

      validate {MishkaCmsCore.Runtime.Resources.Validations.TenantContext, require_master: false}

      change set_attribute(:archived_at, nil)

      atomic_upgrade_with :archived

      change {MishkaDocument.Resources.Changes.SetEventMetadata,
              resource_type: :note_draft, for_action: :update}

      description "Restores archived note draft (tenant users)"
    end

    update :master_unarchive do
      description "Restores archived note draft (master users) - bypasses multi-tenancy"
      accept []
      require_atomic? false
      multitenancy :bypass

      validate {MishkaCmsCore.Runtime.Resources.Validations.TenantContext, require_master: true}

      validate fn changeset, _context ->
        if is_nil(changeset.data.archived_at) do
          {:error,
           field: :archived_at, message: dgettext_noop("errors", "Note draft is not archived.")}
        else
          :ok
        end
      end

      change set_attribute(:archived_at, nil)

      change {MishkaDocument.Resources.Changes.SetEventMetadata,
              resource_type: :note_draft, for_action: :update}
    end

    destroy :permanent_destroy do
      require_atomic? false

      validate {MishkaCmsCore.Runtime.Resources.Validations.TenantContext, require_master: false}

      change {MishkaDocument.Resources.Changes.SetEventMetadata,
              resource_type: :note_draft, for_action: :destroy}

      description "Permanently removes note draft from database (tenant users) - use with extreme caution"
    end

    destroy :master_permanent_destroy do
      description "Permanently removes note draft from database (master users) - bypasses multi-tenancy, irreversible"
      require_atomic? false
      multitenancy :bypass

      validate {MishkaCmsCore.Runtime.Resources.Validations.TenantContext, require_master: true}

      change {MishkaDocument.Resources.Changes.SetEventMetadata,
              resource_type: :note_draft, for_action: :destroy}
    end
  end

  # Authorization policies for note draft access
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

  # PubSub configuration for real-time updates
  pub_sub do
    module Application.compile_env!(:mishka_cms_core, :endpoint)
    prefix "note_draft"

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
              field: :workspace_version_id,
              resource: MishkaDocument.WorkspaceVersion,
              label: dgettext_noop("errors", "version"),
              read_action: :read_any},
             where: [changing(:workspace_version_id)],
             only_when_valid?: true

    validate {MishkaCmsCore.Runtime.Resources.Validations.SameSiteReference,
              field: :section_id,
              resource: MishkaDocument.Section,
              label: dgettext_noop("errors", "section"),
              read_action: :master_get},
             where: [changing(:section_id)],
             only_when_valid?: true

    validate {MishkaCmsCore.Runtime.Resources.Validations.SameSiteReference,
              field: :section_draft_id,
              resource: MishkaDocument.SectionDraft,
              label: dgettext_noop("errors", "section draft"),
              read_action: :master_get},
             where: [changing(:section_draft_id)],
             only_when_valid?: true

    validate {MishkaCmsCore.Runtime.Resources.Validations.SameSiteReference,
              field: :source_note_id,
              resource: MishkaDocument.Note,
              label: dgettext_noop("errors", "note"),
              read_action: :master_get},
             where: [changing(:source_note_id)],
             only_when_valid?: true

    validate {MishkaCmsCore.Runtime.Resources.Validations.SameSiteReference,
              field: :created_by_user_id,
              resource: MishkaCmsCore.Accounts.User,
              label: dgettext_noop("errors", "user"),
              read_action: :related,
              shared?: true},
             where: [changing(:created_by_user_id)],
             only_when_valid?: true

    # The section, section draft and note it names are its own workspace version's.
    validate {MishkaDocument.Resources.Validations.SameWorkspaceVersion,
              field: :section_id,
              resource: MishkaDocument.Section,
              label: dgettext_noop("errors", "section")},
             only_when_valid?: true

    validate {MishkaDocument.Resources.Validations.SameWorkspaceVersion,
              field: :section_draft_id,
              resource: MishkaDocument.SectionDraft,
              label: dgettext_noop("errors", "section draft")},
             only_when_valid?: true

    validate {MishkaDocument.Resources.Validations.SameWorkspaceVersion,
              field: :source_note_id,
              resource: MishkaDocument.Note,
              label: dgettext_noop("errors", "note"),
              through: {:section_id, MishkaDocument.Section}},
             only_when_valid?: true
  end

  # Multi-tenancy configuration - note drafts are always site-specific
  multitenancy do
    strategy :attribute
    attribute :site_id
    # Drafts are NEVER global - always site-specific
    global? false
  end

  attributes do
    uuid_primary_key :id

    attribute :title, :string do
      allow_nil? false
      public? true
      constraints min_length: 1, max_length: 1000, trim?: true
      description "Title of the note draft"
    end

    attribute :content, :string do
      allow_nil? false
      public? true
      constraints min_length: 1, trim?: true
      description "Main content of the note - can be very long"
    end

    attribute :order_position, :integer do
      allow_nil? true
      public? true
      default 0
      constraints min: 0
      description "Position for ordering notes within a section"
    end

    attribute :change_version, :string do
      allow_nil? false
      public? true
      constraints max_length: 50, trim?: true
      description "Target semantic version for this draft (e.g., 0.0.3-beta.1, 0.0.2)"
    end

    attribute :version_increment_type, :atom do
      allow_nil? false
      public? true
      constraints one_of: [:major, :minor, :patch, :prerelease, :none]

      description "How to handle versioning: major/minor/patch/prerelease creates new version, none updates current"
    end

    attribute :content_review_status, :atom do
      allow_nil? false
      public? true
      default :pending
      constraints one_of: [:pending, :approved, :rejected, :needs_revision]
      description "Content review status (pending, approved, rejected, needs_revision)"
    end

    attribute :technical_review_status, :atom do
      allow_nil? false
      public? true
      default :pending
      constraints one_of: [:pending, :approved, :rejected, :needs_revision]
      description "Technical review status (pending, approved, rejected, needs_revision)"
    end

    attribute :applied_at, :utc_datetime do
      allow_nil? true
      public? true

      description "Timestamp when this draft was applied to the actual note (null if not yet applied)"
    end

    attribute :changed_fields, {:array, :atom} do
      allow_nil? false
      default []
      public? true
      writable? false
      constraints items: [one_of: @note_fields]

      description "The note's fields this draft changes; applying it writes these and no other"
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
      description "The site this note draft belongs to"
    end

    belongs_to :workspace_version, MishkaDocument.WorkspaceVersion do
      allow_nil? false
      public? true
      description "The workspace version this note draft is for"
    end

    # Bypass relationship - for master admin users without tenant
    belongs_to :master_workspace_version, MishkaDocument.WorkspaceVersion do
      public? true
      source_attribute :workspace_version_id
      destination_attribute :id
      define_attribute? false
      read_action :read_any
      description "The workspace version (master admin access, bypass tenant)"
      filter expr(not is_nil(type(^actor(:id), :uuid)) and is_nil(type(^actor(:site_id), :uuid)))
    end

    belongs_to :section, MishkaDocument.Section do
      allow_nil? true
      public? true

      description "The section this note belongs to (for editing existing notes or adding to existing section)"
    end

    # Bypass relationship - for master admin users without tenant
    belongs_to :master_section, MishkaDocument.Section do
      public? true
      source_attribute :section_id
      destination_attribute :id
      define_attribute? false
      read_action :read_any
      description "The section (master admin access, bypass tenant)"
      filter expr(not is_nil(type(^actor(:id), :uuid)) and is_nil(type(^actor(:site_id), :uuid)))
    end

    belongs_to :section_draft, MishkaDocument.SectionDraft do
      allow_nil? true
      public? true
      description "The section draft this note is part of (for new sections)"
    end

    # Bypass relationship - for master admin users without tenant
    belongs_to :master_section_draft, MishkaDocument.SectionDraft do
      public? true
      source_attribute :section_draft_id
      destination_attribute :id
      define_attribute? false
      read_action :master_read
      description "The section draft (master admin access, bypass tenant)"
      filter expr(not is_nil(type(^actor(:id), :uuid)) and is_nil(type(^actor(:site_id), :uuid)))
    end

    belongs_to :source_note, MishkaDocument.Note do
      allow_nil? true
      public? true
      description "The original note being edited (null for new notes)"
    end

    # Bypass relationship - for master admin users without tenant
    belongs_to :master_source_note, MishkaDocument.Note do
      public? true
      source_attribute :source_note_id
      destination_attribute :id
      define_attribute? false
      read_action :read_any
      description "The source note (master admin access, bypass tenant)"
      filter expr(not is_nil(type(^actor(:id), :uuid)) and is_nil(type(^actor(:site_id), :uuid)))
    end

    belongs_to :created_by_user, MishkaCmsCore.Accounts.User do
      # How any resource reaches an account — see `MishkaCmsCore.Accounts.User`'s `:related`.
      read_action :related
      sortable? false
      allow_nil? true
      public? true
      domain MishkaCmsCore.Accounts
      description "User who created this draft"
    end
  end

  calculations do
    calculate :content_word_count, :integer, MishkaDocument.Resources.Calculations.WordCount do
      public? true
      description "Returns word count of the note draft content"
    end

    calculate :created_by_master?,
              :boolean,
              {MishkaCmsCore.Accounts.Calculations.ByMaster, field: :created_by_user_id} do
      description "Whether the creator is a master, for a reader who cannot load a master's account"
    end
  end

  @doc """
  Who created `draft`, for the reader whose read loaded its `:created_by_user` and
  `:created_by_master?`: the email the reader may see, "Master" for a master, else "Unknown".
  """
  @spec creator(map()) :: String.t()
  def creator(draft) do
    MishkaCmsCore.Accounts.Helper.who(
      Map.get(draft, :created_by_user),
      Map.get(draft, :created_by_master?) == true,
      :unknown
    )
  end

  @spec review_badge(term()) :: %{label: String.t(), class: String.t()}
  defp review_badge(status) when is_map_key(@reviews, status),
    do: translate_label(@reviews[status])

  defp review_badge(_unknown), do: @unknown_review

  # The render fn only receives the `requires` fields, so this matches on those keys directly. A nil
  # `applied_at` fails the struct guard and falls through to the review-derived verdicts.
  @spec applied_status(map()) :: {%{label: String.t(), class: String.t()}, String.t() | nil}
  defp applied_status(%{applied_at: at})
       when is_struct(at, DateTime) or is_struct(at, NaiveDateTime),
       do: {translate_label(@applied_states.applied), Localized.datetime(at, :yMMMdHm)}

  defp applied_status(%{content_review_status: :approved, technical_review_status: :approved}),
    do: {translate_label(@applied_states.ready), gettext("Both approved, pending apply")}

  defp applied_status(%{content_review_status: :rejected}),
    do: {translate_label(@applied_states.rejected), gettext("Review rejected")}

  defp applied_status(%{technical_review_status: :rejected}),
    do: {translate_label(@applied_states.rejected), gettext("Review rejected")}

  defp applied_status(%{content_review_status: :needs_revision}),
    do: {translate_label(@applied_states.revision), gettext("Needs revision")}

  defp applied_status(%{technical_review_status: :needs_revision}),
    do: {translate_label(@applied_states.revision), gettext("Needs revision")}

  defp applied_status(_pending),
    do: {translate_label(@applied_states.pending), gettext("Awaiting review")}

  defp translate_label(%{label: label} = badge),
    do: %{badge | label: Gettext.gettext(MishkaCmsCore.Gettext, label)}

  defp increment_label(:major), do: gettext("major")
  defp increment_label(:minor), do: gettext("minor")
  defp increment_label(:patch), do: gettext("patch")
  defp increment_label(:prerelease), do: gettext("prerelease")
  defp increment_label(:none), do: gettext("none")
  defp increment_label(type), do: to_string(type)

  @spec version_label(term()) :: String.t()
  defp version_label(version) when is_binary(version) and version != "", do: "v" <> version
  defp version_label(_missing), do: "v0.0.1"

  @spec inserted_on(term()) :: String.t()
  defp inserted_on(at) when is_struct(at, DateTime) or is_struct(at, NaiveDateTime),
    do: Localized.date(at, :yMMMd)

  defp inserted_on(_missing), do: "—"
end
