# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_document/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaDocument.SectionDraft do
  @moduledoc """
  Manages draft proposals for section changes within workspace versions.

  This resource represents proposed changes to sections that must go through
  a dual approval workflow (content review and technical review) before being
  applied to the actual Section resource.

  Two main use cases:
  1. Creating a new section (source_section_id is nil)
  2. Editing an existing section (source_section_id points to existing section)

  The draft includes version management:
  - version_increment_type determines if a new version should be created
  - When approved, changes are automatically applied via AutoApplyDraft change

  Multi-tenant isolation ensures drafts are properly segregated between sites.
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
  alias MishkaDocument.Resources.Helpers.Labels

  @admin_fields [
    :workspace_version_id,
    :source_section_id,
    :parent_section_id,
    :title,
    :slug,
    :content,
    :order_position,
    :change_version,
    :version_increment_type,
    :content_review_status,
    :technical_review_status,
    :schema,
    :seo_tags,
    :permissions,
    :language,
    :language_group_id,
    :created_by_user_id,
    :site_id
  ]

  # The page's fields a draft of it holds, and applying it writes when it changes them — see
  # `MishkaDocument.Resources.Changes.StartFromSource`.
  @page_fields [
    :title,
    :slug,
    :content,
    :order_position,
    :change_version,
    :parent_section_id,
    :schema,
    :seo_tags,
    :permissions,
    :language,
    :language_group_id
  ]

  @start_from_source [
    source: :source_section_id,
    resource: MishkaDocument.Section,
    fields: @page_fields
  ]

  @doc "The page's fields a draft of it holds."
  @spec page_fields() :: [atom()]
  def page_fields, do: @page_fields

  @repo Application.compile_env!(:mishka_cms_core, :repo)

  # Database configuration for section drafts storage with indexing
  postgres do
    table "mishka_document_section_drafts"
    repo @repo

    # Database-level optimization for archived records
    base_filter_sql "(archived_at IS NULL)"

    references do
      reference :site, on_delete: :delete
      reference :workspace_version, on_delete: :delete
      reference :source_section, on_delete: :delete
      reference :parent_section, on_delete: :delete
      reference :created_by_user, on_delete: :nilify
    end

    custom_indexes do
      index [:workspace_version_id]
      index [:source_section_id]
      index [:parent_section_id]
      index [:content_review_status]
      index [:technical_review_status]
      index [:applied_at]
      index [:created_by_user_id]
      index [:language]
      index [:site_id]
    end

    check_constraints do
      check_constraint :slug, "slug_length_check",
        check: "length(slug) >= 1 AND length(slug) <= 255",
        message: dgettext_noop("errors", "Slug must be between 1 and 255 characters.")

      check_constraint :slug, "no_empty_slug",
        check: "slug != ''",
        message: dgettext_noop("errors", "Slug cannot be empty.")

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
    type "section_draft"

    includes [
      :workspace_version,
      :source_section,
      :parent_section,
      :created_by_user,
      :note_drafts
    ]

    paginated_includes [:note_drafts]
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
        name :section_drafts
        route "/admin/dashboard/document/section-drafts"
        stream_name :section_drafts
      end

      source do
        preload do
          always [:site, :created_by_user, :created_by_master?, :content_word_count]
        end
      end

      columns do
        column :draft_info do
          static true
          requires [:id, :title, :slug]
          label fn -> dgettext("mishka_gervaz", "Draft") end
          position :first

          ui do
            width "minmax(190px,1.9fr)"
          end

          render fn record ->
            assigns = %{id: record.id, title: record.title, slug: record.slug}

            ~H"""
            <.cell_stacked
              variant={:title}
              primary={@title}
              secondary={"/" <> @slug}
              copy={%{id: "section-draft-slug-copy-#{@id}", value: @slug, label: gettext("Copy slug")}}
            />
            """
          end
        end

        # Version, increment intent, language, the Edit/New marker, order and word count each used to
        # own a slot; folded here they wrap under one narrow column instead of spreading the row. The
        # coloured markers ride as items (whose class never fights a base colour) and the plain labels
        # ride as chips.
        column :draft_stats do
          static true

          requires [
            :change_version,
            :version_increment_type,
            :order_position,
            :applied_at,
            :source_section_id,
            :language,
            :content_word_count
          ]

          label fn -> dgettext("mishka_gervaz", "Details") end

          ui do
            width "minmax(165px,1.5fr)"
          end

          render fn record ->
            order = Labels.counted(record.order_position)
            words = Labels.counted(record.content_word_count)

            items =
              [
                draft_marker(record.source_section_id),
                %{
                  icon: "hero-tag",
                  value: Labels.version_label(record.change_version),
                  label: gettext("Target version"),
                  class: "text-[#4f4bcc]"
                },
                order > 0 &&
                  %{
                    icon: "hero-bars-arrow-down",
                    value: order,
                    label: gettext("Order position")
                  },
                words > 0 && %{icon: "hero-document-text", value: words, label: gettext("Words")},
                applied_marker(record.applied_at)
              ]
              |> Enum.filter(& &1)

            chips = [
              %{
                text: Labels.increment_label(record.version_increment_type),
                label: gettext("Increment type")
              },
              %{text: record.language, label: gettext("Language")}
            ]

            assigns = %{items: items, chips: chips}

            ~H"""
            <.cell_stats items={@items} chips={@chips} />
            """
          end
        end

        # Content and technical review sit side by side: two badges read as one verdict, and at ~1000px
        # the row cannot spare a column each. The header names the order they appear in.
        column :draft_review do
          static true
          requires [:content_review_status, :technical_review_status]
          label fn -> dgettext("mishka_gervaz", "Content / Technical Review") end

          ui do
            width "minmax(150px,1.05fr)"
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
                title={gettext("Content review")}
              >
                {Gettext.gettext(MishkaCmsCore.Gettext, @content.label)}
              </span>
              <span
                class={["rounded-[6px] px-[7px] py-[3px] text-[10.5px] font-bold", @technical.class]}
                title={gettext("Technical review")}
              >
                {Gettext.gettext(MishkaCmsCore.Gettext, @technical.label)}
              </span>
            </div>
            """
          end
        end

        # Who raised the draft, over when it was last touched. The created date now rides in the
        # Site / Date cell, so this line only surfaces the edit date when it actually moved on.
        column :draft_creator do
          static true

          requires [
            :id,
            :created_by_user,
            :created_by_user_id,
            :created_by_master?,
            :inserted_at,
            :updated_at
          ]

          label fn -> dgettext("mishka_gervaz", "Creator") end

          ui do
            width "minmax(150px,1.2fr)"
          end

          render fn record ->
            created = Labels.inserted_on(record.inserted_at)
            updated = Labels.inserted_on(record.updated_at)

            assigns = %{
              id: record.id,
              creator: creator(record),
              updated:
                (updated not in [created, "—"] && gettext("Updated %{date}", date: updated)) ||
                  nil
            }

            ~H"""
            <div id={"section-draft-creator-#{@id}"}>
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

        # The merged Site / Date cell every dashboard table ends on: the site only when the reader is a
        # master user, the created date under it either way.
        column :site_info do
          static true
          requires [:site_id, :site, :inserted_at]
          label fn -> dgettext("mishka_gervaz", "Site / Date") end
          position :last

          ui do
            width "minmax(125px,1.1fr)"
          end

          render fn record, state ->
            site_name =
              case record.site do
                %{name: name} -> name
                _unloaded -> nil
              end

            assigns = %{
              site: (state.master_user? && site_name) || nil,
              date: Labels.inserted_on(record.inserted_at)
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
            :language,
            :workspace_version_id,
            :source_section_id,
            :site_id,
            :created_at
          ]

          collapsible true
          collapsed true

          ui do
            label fn -> dgettext("mishka_gervaz", "Advanced Search") end
            icon "hero-funnel"
            columns 3
          end
        end
      end

      filters do
        filter :search, :text do
          fields [:title, :content, :slug, :change_version]

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

        filter :language, :select do
          options fn ->
            case Ecto.Adapters.SQL.query(
                   @repo,
                   "SELECT DISTINCT language FROM mishka_document_section_drafts WHERE language IS NOT NULL AND archived_at IS NULL ORDER BY language"
                 ) do
              {:ok, %{rows: rows}} ->
                Enum.map(rows, fn [lang] -> {String.upcase(lang), lang} end)

              _ ->
                []
            end
          end

          ui do
            prompt dgettext_noop("mishka_gervaz", "All Languages")
            label fn -> dgettext("mishka_gervaz", "Language") end
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

        filter :source_section_id, :relation do
          mode :search_multi
          display_field :title
          search_field :title
          min_chars 1
          page_size 15

          ui do
            label fn -> dgettext("mishka_gervaz", "Source Section") end
            placeholder fn -> dgettext("mishka_gervaz", "Search sections...") end
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
            label fn -> dgettext("mishka_gervaz", "Created at") end
          end
        end
      end

      row_actions do
        action :edit do
          type :edit
          visible :active
          js fn _record -> MishkaCmsCore.CoreComponents.show_modal("section-draft-form-modal") end

          ui do
            label fn -> dgettext("mishka_gervaz", "Edit") end
          end
        end

        action :delete do
          type :destroy

          confirm fn _record ->
            dgettext("mishka_gervaz", "Archive this section draft?")
          end

          visible :active
        end

        action :unarchive do
          type :unarchive

          confirm fn _record ->
            dgettext("mishka_gervaz", "Restore this section draft?")
          end

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
          confirm: dgettext_noop("mishka_gervaz", "Archive selected section drafts?")

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
        prefix "section_draft"
      end

      url_sync do
        mode :bidirectional
        params [:filters, :sort, :page, :search]
        prefix "section_drafts"
        max_filter_length 500
        preserve_params [:return_to]
      end

      hooks do
        on_expand fn _id, socket ->
          {:cont, socket}
        end
      end

      empty_state message: dgettext_noop("mishka_gervaz", "No section drafts found"),
                  icon: "hero-document"
    end

    form do
      identity do
        name :section_draft_form
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
            placeholder fn -> dgettext("mishka_gervaz", "Section title") end
          end
        end

        field :slug, :text do
          required true

          ui do
            label fn -> dgettext("mishka_gervaz", "Slug") end
            placeholder fn -> dgettext("mishka_gervaz", "section-slug") end
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

        field :language, :combobox do
          required true

          options fn ->
            case Ecto.Adapters.SQL.query(
                   @repo,
                   "SELECT DISTINCT language FROM mishka_document_section_drafts WHERE language IS NOT NULL AND archived_at IS NULL ORDER BY language"
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
          display_field fn record -> "#{record.title} (#{record.language})" end
          search_field :title
          mode :search
          depends_on :site_id
          include_nil fn -> dgettext("mishka_gervaz", "No Language Group") end

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

        field :source_section_id, :relation do
          display_field :title
          search_field :title
          mode :search
          depends_on :workspace_version_id
          include_nil fn -> dgettext("mishka_gervaz", "No source section") end

          load fn query, state ->
            Ash.Query.filter_input(query, %{
              workspace_version_id: Map.get(state.field_values, :workspace_version_id)
            })
          end

          ui do
            label fn -> dgettext("mishka_gervaz", "Source Section") end
          end
        end

        field :parent_section_id, :relation do
          display_field :title
          search_field :title
          mode :search
          depends_on :workspace_version_id
          include_nil fn -> dgettext("mishka_gervaz", "No parent section") end

          load fn query, state ->
            Ash.Query.filter_input(query, %{
              workspace_version_id: Map.get(state.field_values, :workspace_version_id)
            })
          end

          ui do
            label fn -> dgettext("mishka_gervaz", "Parent Section") end
          end
        end

        field :content, :textarea do
          ui do
            label fn -> dgettext("mishka_gervaz", "Content") end
            placeholder fn -> dgettext("mishka_gervaz", "Section content...") end
            rows 4

            # The rich-text editor, with components placed as blocks; their markers are what is
            # stored. `MishkaCmsCoreWeb.UIAdapters.Admin.textarea/1` is what reads this.
            extra %{content_editor: true}
          end
        end

        field :seo_tags, :nested do
          ui do
            label fn -> dgettext("mishka_gervaz", "SEO Tags") end
            add_label fn -> dgettext("mishka_gervaz", "+ Add SEO Tag") end
            remove_label fn -> dgettext("mishka_gervaz", "Remove") end

            description fn ->
              dgettext(
                "mishka_gervaz",
                "A title replaces the page's title; meta and link tags each replace the default with the same name. A value may name a variable such as {{page.title}}."
              )
            end
          end

          nested_field :tag, :select do
            options [{"title", "title"}, {"meta", "meta"}, {"link", "link"}]

            ui do
              label fn -> dgettext("mishka_gervaz", "Tag") end
              placeholder fn -> dgettext("mishka_gervaz", "Choose a tag") end
            end
          end

          nested_field :attrs, :json do
            ui do
              label fn -> dgettext("mishka_gervaz", "Attributes") end
              placeholder ~s({"name": "description", "property": "og:title"})
            end
          end

          nested_field :content, :textarea do
            ui do
              label fn -> dgettext("mishka_gervaz", "Content") end
              placeholder fn -> dgettext("mishka_gervaz", "Tag content text...") end
              rows 3
            end
          end
        end

        # WHO MAY OPEN THE PAGE once the draft is applied: any of the permission names that exist,
        # stored by name. A draft of an existing page starts with that page's
        # (`MishkaDocument.Resources.Changes.StartFromSource`).
        field :permissions, :relation do
          resource MishkaCmsCore.Accounts.Permission
          display_field :name
          search_field :name
          value_field :name
          mode :search_multi
          page_size 15

          ui do
            label fn -> dgettext("mishka_gervaz", "Permissions") end

            description fn ->
              dgettext(
                "mishka_gervaz",
                "Who may open the page once this draft is applied: anyone holding one of these. None: as the page above it, else its document."
              )
            end
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
          fields [:site_id, :title, :slug]

          ui do
            label fn -> dgettext("mishka_gervaz", "Basic Information") end
            columns 2
          end
        end

        group :references do
          fields [:workspace, :workspace_version_id, :source_section_id, :parent_section_id]

          ui do
            label fn -> dgettext("mishka_gervaz", "References") end
            columns 2
          end
        end

        group :versioning do
          fields [:change_version, :version_increment_type, :order_position]

          ui do
            label fn -> dgettext("mishka_gervaz", "Versioning") end
            columns 3
          end
        end

        group :localization do
          fields [:language, :language_group_id]

          ui do
            label fn -> dgettext("mishka_gervaz", "Localization") end
            columns 2
          end
        end

        group :review do
          fields [:content_review_status, :technical_review_status]

          ui do
            label fn -> dgettext("mishka_gervaz", "Review") end
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

        group :seo do
          fields [:seo_tags, :permissions]

          ui do
            label fn -> dgettext("mishka_gervaz", "SEO") end
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
        # While a draft is added, its slug follows the title until the author types one.
        on_validate fn params, state ->
          MishkaCmsCore.Runtime.Helpers.follow_slug(params, state, :title)
        end

        on_cancel fn state -> state end
      end
    end
  end

  guardedstruct do
    auto_wire true

    field :title, :string,
      validator: {MishkaCmsCore.PlainText, :field},
      derives: "sanitize(trim) validate(string, not_empty, min_len=1, max_len=500)"

    field :slug, :string,
      derives: "sanitize(trim) validate(string, not_empty, min_len=1, max_len=255)"

    field :content, :string, derives: "sanitize(html5) validate(optional=[string])"

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

    field :permissions, {:array, :string},
      derives: "sanitize(each=[trim, downcase], reject_empty, uniq) validate(list)"

    field :language, :string,
      derives: "sanitize(trim, downcase) validate(optional=[string, max_len=20, language_code])"

    field :language_group_id, :uuid, derives: "validate(optional=[uuid])"
  end

  actions do
    defaults [:read]

    default_accept @admin_fields

    create :create do
      primary? true
      accept @admin_fields |> List.delete(:site_id)

      validate present(:workspace_version_id)
      validate present(:title)
      validate present(:slug)
      validate present(:language)
      validate present(:change_version)
      validate present(:version_increment_type)

      validate {MishkaCmsCore.Runtime.Resources.Validations.TenantContext, require_master: false}

      validate {MishkaCmsCore.Runtime.Resources.Validations.TenantIsolation,
                field: :workspace_version_id, resource: MishkaDocument.WorkspaceVersion}

      validate {MishkaCmsCore.Runtime.Resources.Validations.TenantIsolation,
                field: :source_section_id, resource: MishkaDocument.Section}

      validate {MishkaCmsCore.Runtime.Resources.Validations.TenantIsolation,
                field: :parent_section_id, resource: MishkaDocument.Section}

      validate {MishkaCmsCore.Runtime.Resources.Validations.TenantIsolation,
                field: :language_group_id, resource: MishkaDocument.Section}

      validate {MishkaCmsCore.Runtime.Resources.Validations.TenantIsolation,
                field: :created_by_user_id, resource: MishkaCmsCore.Accounts.User}

      change &Ash.Changeset.force_change_attribute(&1, :site_id, &2.tenant)

      change slugify(:slug, into: :slug, ignore: [".", "!", "?"])

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

      validate fn changeset, _context ->
        parent_id = Ash.Changeset.get_attribute(changeset, :parent_section_id)
        section_id = changeset.data.id

        if !is_nil(parent_id) and parent_id == section_id do
          {:error,
           field: :parent_section_id,
           message: dgettext_noop("errors", "Section draft cannot be its own parent.")}
        else
          :ok
        end
      end

      # Highlights the code blocks of the sanitized content, before the row is written.
      change MishkaDocument.Resources.Changes.HighlightCode

      change {MishkaDocument.Resources.Changes.SetEventMetadata,
              resource_type: :section_draft, for_action: :create}

      description "Creates section draft for tenant users - requires tenant context, auto-assigns site_id, language_group_id is optional"

      change {MishkaDocument.Resources.Changes.StartFromSource, @start_from_source}
    end

    create :master_create do
      validate present(:workspace_version_id)
      validate present(:title)
      validate present(:slug)
      validate present(:language)
      validate present(:site_id)
      validate present(:change_version)
      validate present(:version_increment_type)

      validate {MishkaCmsCore.Runtime.Resources.Validations.TenantContext, require_master: true}

      change fn changeset, _context ->
        site_id = Ash.Changeset.get_attribute(changeset, :site_id)
        Ash.Changeset.set_tenant(changeset, site_id)
      end

      change slugify(:slug, into: :slug, ignore: [".", "!", "?"])

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

      validate fn changeset, _context ->
        parent_id = Ash.Changeset.get_attribute(changeset, :parent_section_id)
        section_id = changeset.data.id

        if !is_nil(parent_id) and parent_id == section_id do
          {:error,
           field: :parent_section_id,
           message: dgettext_noop("errors", "Section draft cannot be its own parent.")}
        else
          :ok
        end
      end

      change MishkaDocument.Resources.Changes.HighlightCode

      change {MishkaDocument.Resources.Changes.SetEventMetadata,
              resource_type: :section_draft, for_action: :create}

      description "Creates section draft for master users - requires explicit site_id, language_group_id is optional"

      change {MishkaDocument.Resources.Changes.StartFromSource, @start_from_source}
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
                field: :source_section_id, resource: MishkaDocument.Section},
               where: [changing(:source_section_id)]

      validate {MishkaCmsCore.Runtime.Resources.Validations.TenantIsolation,
                field: :parent_section_id, resource: MishkaDocument.Section},
               where: [changing(:parent_section_id)]

      validate {MishkaCmsCore.Runtime.Resources.Validations.TenantIsolation,
                field: :language_group_id, resource: MishkaDocument.Section},
               where: [changing(:language_group_id)]

      validate fn changeset, _context ->
        parent_id = Ash.Changeset.get_attribute(changeset, :parent_section_id)
        section_id = changeset.data.id

        if !is_nil(parent_id) and parent_id == section_id do
          {:error,
           field: :parent_section_id,
           message: dgettext_noop("errors", "Section draft cannot be its own parent.")}
        else
          :ok
        end
      end

      change slugify(:slug, into: :slug, ignore: [".", "!", "?"])

      change MishkaDocument.Resources.Changes.HighlightCode
      change {MishkaDocument.Resources.Changes.StartFromSource, @start_from_source}

      # Auto-apply when both approvals are granted
      change MishkaDocument.Resources.Changes.AutoApplySectionDraft

      change {MishkaDocument.Resources.Changes.SetEventMetadata,
              resource_type: :section_draft, for_action: :update}

      description "Updates section draft for tenant users - requires tenant context, prevents site_id and created_by_user_id changes, triggers auto-apply when both approvals granted"
    end

    update :master_update do
      description "Updates section draft for master users - bypasses multi-tenancy, prevents site_id and created_by_user_id changes, triggers auto-apply when both approvals granted"
      require_atomic? false
      transaction? true

      accept @admin_fields |> List.delete(:site_id) |> List.delete(:created_by_user_id)

      multitenancy :bypass

      validate {MishkaCmsCore.Runtime.Resources.Validations.TenantContext, require_master: true}

      validate absent(:archived_at) do
        message dgettext_noop(
                  "errors",
                  "Cannot edit archived section draft. Please unarchive it first."
                )
      end

      validate fn changeset, _context ->
        parent_id = Ash.Changeset.get_attribute(changeset, :parent_section_id)
        section_id = changeset.data.id

        if !is_nil(parent_id) and parent_id == section_id do
          {:error,
           field: :parent_section_id,
           message: dgettext_noop("errors", "Section draft cannot be its own parent.")}
        else
          :ok
        end
      end

      change slugify(:slug, into: :slug, ignore: [".", "!", "?"])

      change MishkaDocument.Resources.Changes.HighlightCode
      change {MishkaDocument.Resources.Changes.StartFromSource, @start_from_source}

      # Auto-apply when both approvals are granted
      change MishkaDocument.Resources.Changes.AutoApplySectionDraft

      change {MishkaDocument.Resources.Changes.SetEventMetadata,
              resource_type: :section_draft, for_action: :update}
    end

    read :master_read do
      description "Reads all section drafts system-wide, bypassing tenant filtering (master users only)"
      multitenancy :bypass
      pagination offset?: true, default_limit: 20, max_page_size: 100, countable: true

      validate {MishkaCmsCore.Runtime.Resources.Validations.TenantContext, require_master: true}
    end

    read :master_get do
      multitenancy :bypass
      get? true
      description "Retrieves single section draft by ID, bypassing tenant filtering"

      validate {MishkaCmsCore.Runtime.Resources.Validations.TenantContext, require_master: true}
    end

    read :read_any do
      multitenancy :bypass
      description "Reads all section drafts bypassing tenant filtering (for master relationships)"
      pagination offset?: true, default_limit: 20, max_page_size: 100, countable: true
    end

    read :archived do
      filter expr(not is_nil(archived_at))
      pagination offset?: true, default_limit: 20, max_page_size: 100, countable: true

      validate {MishkaCmsCore.Runtime.Resources.Validations.TenantContext, require_master: false}

      description "Lists archived section drafts within current tenant context"
    end

    read :get_archived do
      get? true
      filter expr(not is_nil(archived_at))

      validate {MishkaCmsCore.Runtime.Resources.Validations.TenantContext, require_master: false}

      description "Retrieves single archived section draft for recovery or inspection (tenant users)"
    end

    read :master_get_archived do
      get? true
      multitenancy :bypass
      filter expr(not is_nil(archived_at))

      validate {MishkaCmsCore.Runtime.Resources.Validations.TenantContext, require_master: true}

      description "Retrieves single archived section draft for recovery or inspection (master users)"
    end

    read :master_archived do
      multitenancy :bypass
      filter expr(not is_nil(archived_at))
      pagination offset?: true, default_limit: 20, max_page_size: 100, countable: true

      validate {MishkaCmsCore.Runtime.Resources.Validations.TenantContext, require_master: true}

      description "Lists all archived section drafts system-wide, bypassing tenant filtering"
    end

    destroy :destroy do
      description "Soft deletes section draft by archiving (tenant users)"
      primary? true
      require_atomic? false

      validate {MishkaCmsCore.Runtime.Resources.Validations.TenantContext, require_master: false}

      validate fn changeset, _context ->
        if changeset.data.archived_at do
          {:error,
           field: :archived_at,
           message: dgettext_noop("errors", "Section draft is already archived.")}
        else
          :ok
        end
      end

      change {MishkaDocument.Resources.Changes.SetEventMetadata,
              resource_type: :section_draft, for_action: :destroy}
    end

    destroy :master_destroy do
      description "Soft deletes section draft by archiving (master users) - bypasses multi-tenancy"
      require_atomic? false
      multitenancy :bypass

      validate {MishkaCmsCore.Runtime.Resources.Validations.TenantContext, require_master: true}

      validate fn changeset, _context ->
        if changeset.data.archived_at do
          {:error,
           field: :archived_at,
           message: dgettext_noop("errors", "Section draft is already archived.")}
        else
          :ok
        end
      end

      change {MishkaDocument.Resources.Changes.SetEventMetadata,
              resource_type: :section_draft, for_action: :destroy}
    end

    update :unarchive do
      accept []
      require_atomic? false

      validate {MishkaCmsCore.Runtime.Resources.Validations.TenantContext, require_master: false}

      change set_attribute(:archived_at, nil)

      atomic_upgrade_with :archived

      change {MishkaDocument.Resources.Changes.SetEventMetadata,
              resource_type: :section_draft, for_action: :update}

      description "Restores archived section draft (tenant users)"
    end

    update :mark_applied do
      accept [:applied_at]
      require_atomic? false

      change {MishkaDocument.Resources.Changes.SetEventMetadata,
              resource_type: :section_draft, for_action: :update}

      description "Internal action to mark draft as applied with timestamp"
    end

    update :master_unarchive do
      description "Restores archived section draft (master users) - bypasses multi-tenancy"
      accept []
      require_atomic? false
      multitenancy :bypass

      validate {MishkaCmsCore.Runtime.Resources.Validations.TenantContext, require_master: true}

      validate fn changeset, _context ->
        if is_nil(changeset.data.archived_at) do
          {:error,
           field: :archived_at, message: dgettext_noop("errors", "Section draft is not archived.")}
        else
          :ok
        end
      end

      change set_attribute(:archived_at, nil)

      change {MishkaDocument.Resources.Changes.SetEventMetadata,
              resource_type: :section_draft, for_action: :update}
    end

    destroy :permanent_destroy do
      require_atomic? false

      validate {MishkaCmsCore.Runtime.Resources.Validations.TenantContext, require_master: false}

      change {MishkaDocument.Resources.Changes.SetEventMetadata,
              resource_type: :section_draft, for_action: :destroy}

      description "Permanently removes section draft from database (tenant users) - use with extreme caution"
    end

    destroy :master_permanent_destroy do
      description "Permanently removes section draft from database (master users) - bypasses multi-tenancy, irreversible"
      require_atomic? false
      multitenancy :bypass

      validate {MishkaCmsCore.Runtime.Resources.Validations.TenantContext, require_master: true}

      change {MishkaDocument.Resources.Changes.SetEventMetadata,
              resource_type: :section_draft, for_action: :destroy}
    end
  end

  # Authorization policies for section draft access
  policies do
    # Reads every site's rows, so it serves a master (a user with no site) and nobody else. The area
    # is asked by the policy below, as for every other action.
    policy action(:read_any) do
      authorize_if actor_attribute_equals(:site_id, nil)
    end

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
    prefix "section_draft"

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
              field: :source_section_id,
              resource: MishkaDocument.Section,
              label: dgettext_noop("errors", "section"),
              read_action: :master_get},
             where: [changing(:source_section_id)],
             only_when_valid?: true

    validate {MishkaCmsCore.Runtime.Resources.Validations.SameSiteReference,
              field: :parent_section_id,
              resource: MishkaDocument.Section,
              label: dgettext_noop("errors", "section"),
              read_action: :master_get},
             where: [changing(:parent_section_id)],
             only_when_valid?: true

    validate {MishkaCmsCore.Runtime.Resources.Validations.SameSiteReference,
              field: :language_group_id,
              resource: MishkaDocument.Section,
              label: dgettext_noop("errors", "language group"),
              read_action: :master_get},
             where: [changing(:language_group_id)],
             only_when_valid?: true

    validate {MishkaCmsCore.Runtime.Resources.Validations.SameSiteReference,
              field: :created_by_user_id,
              resource: MishkaCmsCore.Accounts.User,
              label: dgettext_noop("errors", "user"),
              read_action: :related,
              shared?: true},
             where: [changing(:created_by_user_id)],
             only_when_valid?: true

    # The sections it names are its own workspace version's.
    validate {MishkaDocument.Resources.Validations.SameWorkspaceVersion,
              field: :source_section_id,
              resource: MishkaDocument.Section,
              label: dgettext_noop("errors", "section")},
             only_when_valid?: true

    validate {MishkaDocument.Resources.Validations.SameWorkspaceVersion,
              field: :parent_section_id,
              resource: MishkaDocument.Section,
              label: dgettext_noop("errors", "section")},
             only_when_valid?: true
  end

  # Multi-tenancy configuration - section drafts are always site-specific
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
      constraints min_length: 1, max_length: 500, trim?: true
      description "Title of the section draft"
    end

    attribute :slug, :string do
      allow_nil? false
      public? true
      constraints min_length: 1, max_length: 255, trim?: true
      description "URL-friendly slug for the section"
    end

    attribute :content, :string do
      allow_nil? true
      public? true
      constraints trim?: true
      description "The page's own text, as HTML, its code blocks highlighted"
    end

    attribute :order_position, :integer do
      allow_nil? true
      public? true
      default 0
      constraints min: 0
      description "Position for ordering sections"
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

      description "Timestamp when this draft was applied to the actual section (null if not yet applied)"
    end

    attribute :changed_fields, {:array, :atom} do
      allow_nil? false
      default []
      public? true
      writable? false
      constraints items: [one_of: @page_fields]

      description "The page's fields this draft changes; applying it writes these and no other"
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

    attribute :permissions, {:array, :string} do
      default []
      public? true
      description "Permission strings the page is opened with once this draft is applied"
    end

    attribute :language, :string do
      allow_nil? false
      public? true
      default "en"
      constraints trim?: true, max_length: 10
      description "Primary language of the section (ISO 639-1 code, e.g., en, fa, ar, ru)"
    end

    attribute :language_group_id, :uuid do
      allow_nil? true
      public? true
      description "Shared ID linking all language variants of this section together"
    end

    create_timestamp :inserted_at
    update_timestamp :updated_at
  end

  relationships do
    belongs_to :site, MishkaCmsCore.Runtime.Site do
      read_action :read_any
      allow_nil? false
      public? true
      description "The site this section draft belongs to"
    end

    belongs_to :workspace_version, MishkaDocument.WorkspaceVersion do
      allow_nil? false
      public? true
      description "The workspace version this section draft is for"
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

    belongs_to :source_section, MishkaDocument.Section do
      allow_nil? true
      public? true
      description "The original section being edited (null for new sections)"
    end

    # Bypass relationship - for master admin users without tenant
    belongs_to :master_source_section, MishkaDocument.Section do
      public? true
      source_attribute :source_section_id
      destination_attribute :id
      define_attribute? false
      read_action :read_any
      description "The source section (master admin access, bypass tenant)"
      filter expr(not is_nil(type(^actor(:id), :uuid)) and is_nil(type(^actor(:site_id), :uuid)))
    end

    belongs_to :parent_section, MishkaDocument.Section do
      allow_nil? true
      public? true
      description "Parent section for nested hierarchies"
    end

    # Bypass relationship - for master admin users without tenant
    belongs_to :master_parent_section, MishkaDocument.Section do
      public? true
      source_attribute :parent_section_id
      destination_attribute :id
      define_attribute? false
      read_action :read_any
      description "Parent section (master admin access, bypass tenant)"
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

    has_many :note_drafts, MishkaDocument.NoteDraft do
      public? true
      destination_attribute :section_draft_id
      description "Note drafts that are part of this section draft"
    end

    belongs_to :language_group_section, MishkaDocument.Section do
      allow_nil? true
      public? true
      source_attribute :language_group_id
      destination_attribute :id
      define_attribute? false

      description "Reference section for language grouping - selecting this sets language_group_id"
    end

    # Bypass relationship - for master admin users without tenant
    belongs_to :master_language_group_section, MishkaDocument.Section do
      public? true
      source_attribute :language_group_id
      destination_attribute :id
      define_attribute? false
      read_action :read_any
      description "Language group section (master admin access, bypass tenant)"
      filter expr(not is_nil(type(^actor(:id), :uuid)) and is_nil(type(^actor(:site_id), :uuid)))
    end
  end

  calculations do
    calculate :content_word_count, :integer, MishkaDocument.Resources.Calculations.WordCount do
      public? true
      description "Returns word count of the section draft content"
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

  @doc false
  defdelegate review_badge(status), to: Labels

  # A draft with a source section edits an existing one; without, it proposes a new section. The
  # marker colours the two apart the way the card does.
  @spec draft_marker(term()) :: map()
  defp draft_marker(source_section_id) when is_binary(source_section_id),
    do: %{
      icon: "hero-pencil-square",
      value: gettext("Edit"),
      label: gettext("Editing an existing section"),
      class: "text-[#4f4bcc]"
    }

  defp draft_marker(_new),
    do: %{
      icon: "hero-sparkles",
      value: gettext("New"),
      label: gettext("New section"),
      class: "text-[#177a53]"
    }

  @spec applied_marker(term()) :: map() | nil
  defp applied_marker(at) when is_struct(at, DateTime) or is_struct(at, NaiveDateTime),
    do: %{
      icon: "hero-check-circle",
      value: Labels.inserted_on(at),
      label: gettext("Applied"),
      class: "text-[#177a53]"
    }

  defp applied_marker(_unapplied), do: nil
end
