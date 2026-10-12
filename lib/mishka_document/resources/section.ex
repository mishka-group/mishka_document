defmodule MishkaDocument.Section do
  @moduledoc """
  Manages documentation sections within workspace versions.

  This resource represents hierarchical sections that organize documentation content.
  Each section belongs to a specific workspace version and can have parent-child relationships
  for nested organization. Sections support content and technical review workflows with
  multiple approval states.

  The resource includes comprehensive metadata management with SEO tags, Schema.org
  structured data, and multi-language support. Database-level constraints ensure data
  integrity with slug validation and proper ordering.

  Multi-tenant isolation ensures sections are properly segregated between sites.
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
    notifiers: [
      Ash.Notifier.PubSub,
      MishkaCmsCore.Runtime.Resources.Notifiers.PluginHook,
      MishkaCmsCore.Runtime.Resources.Notifiers.SitemapRefresh
    ],
    authorizers: [Ash.Policy.Authorizer]

  require Ash.Query

  use MishkaGervaz.Messages, backend: MishkaCmsCore.Gettext
  import Phoenix.Component, only: [sigil_H: 2]
  import MishkaCmsCore.CoreComponents, only: [icon: 1]
  import MishkaGervaz.UIAdapters.Tailwind, only: [copy_button: 1]
  alias MishkaCmsCore.Localized

  # The card's action squares. `MishkaDocumentWeb.Templates.DocumentSection` gives them a row of their
  # own, so every one is icon-only and hides its label — which still reaches the DOM as `title` and as a
  # `.lbl` span, or the button would have no accessible name.
  @icon_action_class "inline-flex size-8 flex-none items-center justify-center rounded-[9px] border " <>
                       "border-[#ecebe6] bg-[#faf9f6] text-[#6d6a63] transition-colors " <>
                       "hover:bg-[#f2f1fc] hover:text-[#4f4bcc] [&_.lbl]:hidden"

  @notes_action_class "inline-flex size-8 flex-none items-center justify-center rounded-[9px] border " <>
                        "border-[#ecebe6] bg-[#faf9f6] text-[#6d6a63] transition-colors " <>
                        "hover:bg-[#fbf1df] hover:text-[#a5691a] [&_.lbl]:hidden"

  @danger_action_class "inline-flex size-8 flex-none items-center justify-center rounded-[9px] border " <>
                         "border-[#f0dcd8] bg-[#fdf3f1] text-[#c0473d] transition-colors " <>
                         "hover:bg-[#fbe9e7] [&_.lbl]:hidden"

  # The palette the card's review chips already use (`MishkaDocumentWeb.Templates.DocumentSection`'s
  # `@reviews`), so a status reads the same colour whichever view you are in.
  @reviews %{
    approved: %{label: gettext_noop("Approved"), class: "bg-[#e6f6ee] text-[#177a53]"},
    pending: %{label: gettext_noop("Pending"), class: "bg-[#fbf1df] text-[#a5691a]"},
    rejected: %{label: gettext_noop("Rejected"), class: "bg-[#fbe9e7] text-[#b3433a]"},
    needs_revision: %{label: gettext_noop("Needs Revision"), class: "bg-[#f4ecfb] text-[#8a4bcc]"},
    archived: %{label: gettext_noop("Archived"), class: "bg-[#f2f1ec] text-[#6d6a63]"}
  }

  @unknown_review %{label: "—", class: "bg-[#f2f1ec] text-[#8a877f]"}

  @admin_fields [
    :workspace_version_id,
    :parent_section_id,
    :front_page,
    :group_heading,
    :title,
    :slug,
    :content,
    :order_position,
    :change_version,
    :content_review_status,
    :technical_review_status,
    :schema,
    :seo_tags,
    :permissions,
    :language,
    :language_group_id,
    :section_lineage_id,
    :source_section_id,
    :site_id
  ]

  @repo Application.compile_env!(:mishka_cms_core, :repo)

  # Database configuration for sections storage with indexing
  postgres do
    table "mishka_document_sections"
    repo @repo

    # Database-level optimization for archived records
    base_filter_sql "(archived_at IS NULL)"

    identity_wheres_to_sql unique_front_page_per_version: "front_page = true"

    references do
      reference :site, on_delete: :delete
      reference :workspace_version, on_delete: :delete
      reference :parent_section, on_delete: :delete
      reference :source_section, on_delete: :delete
    end

    custom_indexes do
      index [:workspace_version_id]
      index [:parent_section_id]
      index [:order_position]
      index [:content_review_status]
      index [:technical_review_status]
      index [:language]
      index [:section_lineage_id]
      index [:source_section_id]
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
    type "section"

    includes [
      :workspace_version,
      :parent_section,
      :child_sections,
      :language_variants,
      :notes,
      :tenant_notes,
      :master_notes,
      :tags,
      :tenant_tags,
      :master_tags,
      :section_drafts,
      :master_section_drafts,
      workspace_version: [:workspace],
      master_workspace_version: [:master_workspace]
    ]

    paginated_includes [
      :child_sections,
      :language_variants,
      :notes,
      :tenant_notes,
      :master_notes,
      :tags,
      :tenant_tags,
      :master_tags,
      :section_drafts,
      :master_section_drafts
    ]
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
    table do
      identity do
        name :sections
        route "/admin/dashboard/document/sections/:workspace_version_id"
        stream_name :sections
      end

      source do
        preload do
          always [
            :site,
            :breadcrumb_path,
            :contributors_count,
            :section_versions_count,
            :content_word_count,
            :pending_section_draft_content_review_count,
            :pending_section_draft_technical_review_count,
            :approved_section_draft_count,
            :pending_note_draft_content_review_count,
            :pending_note_draft_technical_review_count
          ]
        end
      end

      columns do
        # The path chips used to own a whole column while the row still had to carry a title, a slug
        # and a content blob. The ancestors fold in here as one truncating line above the title: it
        # grows with the depth of the tree, never with the length of the text, so this cell takes the
        # smaller open share and :section_content takes the slack.
        column :section_title do
          static true
          requires [:id, :title, :slug, :front_page, :group_heading, :breadcrumb_path]
          label fn -> dgettext("mishka_gervaz", "Section") end
          position :first
          sortable true
          sort_field [:title]

          ui do
            width "minmax(170px,1.5fr)"
          end

          render fn record ->
            crumbs =
              record.breadcrumb_path
              |> List.wrap()
              |> Enum.flat_map(fn
                %{"title" => title} when is_binary(title) -> [title]
                _crumb -> []
              end)

            assigns = %{
              id: record.id,
              title: record.title,
              slug: record.slug,
              front_page?: record.front_page == true,
              group?: record.group_heading == true,
              path: Enum.join(crumbs, " › ")
            }

            ~H"""
            <div class="min-w-0">
              <div
                :if={@path != ""}
                class="truncate text-[10.5px] font-semibold text-[#a8a5a0]"
                title={@path}
              >
                {@path}
              </div>
              <div class="truncate text-[13.5px] font-semibold text-[#17161a]">{@title}</div>
              <div class="mt-[2px] flex items-center gap-[5px]">
                <span
                  :if={@group?}
                  title={dgettext("mishka_gervaz", "Only a heading in the contents, with no address")}
                  class="rounded-[5px] bg-[#f4f3ee] px-[6px] py-[1px] text-[9.5px] font-bold uppercase text-[#6d6a63]"
                >
                  {dgettext("mishka_gervaz", "Group")}
                </span>
                <span
                  :if={not @group?}
                  class="truncate font-['Space_Grotesk'] text-[11px] font-medium text-[#a8a5a0]"
                >
                  /{@slug}
                </span>
                <.copy_button
                  :if={not @group?}
                  id={"section-slug-copy-#{@id}"}
                  value={@slug}
                  label={dgettext("mishka_gervaz", "Copy slug")}
                />
                <span
                  :if={@front_page?}
                  title={dgettext("mishka_gervaz", "Drawn at the document's own address")}
                  class="rounded-[5px] bg-[#f2f1fc] px-[6px] py-[1px] text-[9.5px] font-bold uppercase text-[#4f4bcc]"
                >
                  {dgettext("mishka_gervaz", "Front page")}
                </span>
              </div>
            </div>
            """
          end
        end

        # Content and technical review share a cell, as the card draws them: two badges side by side
        # read as one verdict, and a rail leaves the table roughly 1020px — not enough for a column
        # each once every other cell has its minimum.
        column :section_review do
          static true
          requires [:content_review_status, :technical_review_status]
          # Two badges in one cell need the header to say which is which, since neither carries a
          # caption of its own — the order here is the order they stack in.
          label fn -> dgettext("mishka_gervaz", "Content / Technical Review") end
          sortable true
          sort_field [:content_review_status]

          ui do
            width "minmax(145px,1.1fr)"
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

        # The only cell that really grows with its content, so it takes the slack every fixed-length
        # cell gives up. Two clamped lines is what stops a long body owning the row, and the slice
        # keeps the rest of a long page out of the DOM twenty rows at a time.
        column :section_content do
          static true
          requires [:content]
          label fn -> dgettext("mishka_gervaz", "Content") end

          ui do
            width "minmax(170px,2.2fr)"
          end

          render fn record ->
            preview =
              case record.content do
                text when is_binary(text) -> text |> String.trim() |> String.slice(0, 300)
                _blank -> ""
              end

            assigns = %{preview: preview}

            ~H"""
            <p
              :if={@preview != ""}
              class="line-clamp-2 text-[12.5px] leading-[1.5] text-[#6d6a63]"
              title={@preview}
            >
              {@preview}
            </p>
            <span :if={@preview == ""} class="text-[12px] font-medium text-[#a8a5a0]">—</span>
            """
          end
        end

        # Every count the row used to scatter across Version and Meta, in one cell. `counted/1` is
        # what keeps an aggregate the viewer's field policy hides from reaching the DOM as a struct.
        column :section_stats do
          static true

          requires [
            :change_version,
            :order_position,
            :content_word_count,
            :contributors_count,
            :section_versions_count,
            :pending_section_draft_content_review_count,
            :pending_section_draft_technical_review_count,
            :approved_section_draft_count
          ]

          label fn -> dgettext("mishka_gervaz", "Stats") end

          ui do
            width "minmax(150px,1.25fr)"
          end

          render fn record ->
            assigns = %{
              version: version_label(record.change_version),
              order: counted(record.order_position),
              words: counted(record.content_word_count),
              contributors: counted(record.contributors_count),
              versions: counted(record.section_versions_count),
              pending:
                counted(record.pending_section_draft_content_review_count) +
                  counted(record.pending_section_draft_technical_review_count),
              approved: counted(record.approved_section_draft_count)
            }

            ~H"""
            <div class="flex flex-wrap items-center gap-x-[11px] gap-y-1.5 text-[11.5px] font-semibold text-[#8a877f]">
              <span
                class="rounded-[5px] bg-[#f2f1fc] px-[6px] py-[2px] font-['Space_Grotesk'] text-[10px] font-bold text-[#4f4bcc]"
                title={dgettext("mishka_gervaz", "Version")}
              >
                {@version}
              </span>
              <span
                class="inline-flex items-center gap-[5px]"
                title={dgettext("mishka_gervaz", "Order position")}
              >
                <.icon name="hero-bars-arrow-down" class="size-[13px] text-[#c3c0b8]" />
                {@order}
              </span>
              <span class="inline-flex items-center gap-[5px]" title={dgettext("mishka_gervaz", "Words")}>
                <.icon name="hero-document-text" class="size-[13px] text-[#c3c0b8]" />
                {@words}
              </span>
              <span
                class="inline-flex items-center gap-[5px]"
                title={dgettext("mishka_gervaz", "Contributors")}
              >
                <.icon name="hero-users" class="size-[13px] text-[#c3c0b8]" />
                {@contributors}
              </span>
              <span class="inline-flex items-center gap-[5px]" title={dgettext("mishka_gervaz", "Versions")}>
                <.icon name="hero-clock" class="size-[13px] text-[#c3c0b8]" />
                {@versions}
              </span>
              <span
                :if={@pending > 0}
                class="inline-flex items-center gap-[5px] text-[#a5691a]"
                title={dgettext("mishka_gervaz", "Drafts pending review")}
              >
                <.icon name="hero-exclamation-circle" class="size-[13px] text-[#a5691a]" />
                {@pending}
              </span>
              <span
                :if={@approved > 0}
                class="inline-flex items-center gap-[5px] text-[#177a53]"
                title={dgettext("mishka_gervaz", "Approved drafts")}
              >
                <.icon name="hero-check-badge" class="size-[13px] text-[#177a53]" />
                {@approved}
              </span>
            </div>
            """
          end
        end

        # The merged cell every other dashboard table ends on: the site only when the reader is a
        # master user, the created date under it either way.
        column :site_datetime do
          static true
          requires [:site_id, :site, :inserted_at]
          label fn -> dgettext("mishka_gervaz", "Site / Date") end
          position :last
          sortable true
          sort_field [:inserted_at]

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
              site_name: site_name,
              date: inserted_on(record.inserted_at),
              master_user?: state.master_user? and !is_nil(site_name)
            }

            ~H"""
            <div class="min-w-0">
              <div :if={@master_user?} class="flex items-center gap-[7px]">
                <svg
                  width="14"
                  height="14"
                  viewBox="0 0 24 24"
                  fill="none"
                  stroke="#a8a5a0"
                  stroke-width="1.7"
                  stroke-linecap="round"
                  stroke-linejoin="round"
                  class="shrink-0"
                >
                  <rect x="4" y="4" width="16" height="6" rx="1.5" />
                  <rect x="4" y="14" width="16" height="6" rx="1.5" />
                  <path d="M8 7h.01M8 17h.01" />
                </svg>
                <span class="truncate text-[12.5px] font-medium text-[#3a382f]">{@site_name}</span>
              </div>
              <div class={[
                "text-[11px] font-medium text-[#a8a5a0]",
                @master_user? && "mt-[3px] ps-[21px]"
              ]}>
                {@date}
              </div>
            </div>
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
            :language,
            :contributor,
            :created_at,
            :updated_at
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
          fields [:title, :content, :slug]

          ui do
            label fn -> dgettext("mishka_gervaz", "Search") end
          end
        end

        filter :workspace_version_id, :select do
          visible false

          ui do
            label fn -> dgettext("mishka_gervaz", "Workspace Version") end
            prompt dgettext_noop("mishka_gervaz", "All Versions")
          end
        end

        filter :content_review_status, :select do
          options fn ->
            [
              {dgettext("mishka_gervaz", "Pending"), :pending},
              {dgettext("mishka_gervaz", "Approved"), :approved},
              {dgettext("mishka_gervaz", "Rejected"), :rejected},
              {dgettext("mishka_gervaz", "Needs Revision"), :needs_revision},
              {dgettext("mishka_gervaz", "Archived"), :archived}
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
              {dgettext("mishka_gervaz", "Needs Revision"), :needs_revision},
              {dgettext("mishka_gervaz", "Archived"), :archived}
            ]
          end

          ui do
            prompt dgettext_noop("mishka_gervaz", "All Technical Statuses")
            label fn -> dgettext("mishka_gervaz", "Technical Review") end
          end
        end

        filter :language, :select do
          options fn ->
            case Ecto.Adapters.SQL.query(
                   @repo,
                   "SELECT DISTINCT language FROM mishka_document_sections WHERE language IS NOT NULL AND archived_at IS NULL ORDER BY language"
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

        filter :contributor, :relation do
          virtual true
          resource MishkaCmsCore.Accounts.User
          display_field :email
          mode :search_multi
          search_field :email
          min_chars 2
          page_size 10
          load_action :users

          load fn query, state ->
            workspace_version_id =
              case state do
                %{path_params: %{workspace_version_id: wv_id}} when is_binary(wv_id) -> wv_id
                _ -> nil
              end

            query =
              case state.current_user do
                %{id: _, site_id: nil} ->
                  query

                %{site_id: site_id} when is_binary(site_id) ->
                  Ash.Query.filter(query, site_id == ^site_id)

                _ ->
                  Ash.Query.filter(query, is_nil(id))
              end

            if workspace_version_id do
              sql = """
              SELECT DISTINCT el.actor_id::text
              FROM mishka_document_event_logs el
              WHERE el.actor_id IS NOT NULL
                AND el.action IN ('create', 'master_create', 'update', 'master_update')
                AND (
                  (el.resource = 'Elixir.MishkaDocument.Section'
                   AND el.metadata->>'workspace_version_id' = $1)
                  OR
                  (el.resource = 'Elixir.MishkaDocument.Note'
                   AND el.metadata->>'workspace_version_id' = $1)
                )
              """

              case Ecto.Adapters.SQL.query(@repo, sql, [workspace_version_id]) do
                {:ok, %{rows: rows}} when rows != [] ->
                  user_ids = Enum.map(rows, fn [id] -> id end)
                  Ash.Query.filter(query, id in ^user_ids)

                _ ->
                  Ash.Query.filter(query, is_nil(id))
              end
            else
              query
            end
          end

          apply fn query, value, state ->
            user_ids =
              case value do
                ids when is_list(ids) -> ids
                id when is_binary(id) -> [id]
              end

            {site_id_clause, extra_params} =
              case state.current_user do
                %{id: _, site_id: nil} ->
                  {"", []}

                %{site_id: site_id} when is_binary(site_id) ->
                  idx = length(user_ids) + 1

                  {" AND el.actor_id IN (SELECT id FROM users WHERE site_id::text = $#{idx})",
                   [site_id]}

                _ ->
                  {" AND FALSE", []}
              end

            placeholders =
              user_ids
              |> Enum.with_index(1)
              |> Enum.map_join(", ", fn {_id, i} -> "$#{i}" end)

            sql = """
            SELECT DISTINCT el.record_id::text
            FROM mishka_document_event_logs el
            WHERE el.actor_id::text IN (#{placeholders})
              AND el.action IN ('create', 'master_create', 'update', 'master_update')
              AND el.resource = 'Elixir.MishkaDocument.Section'#{site_id_clause}
            """

            case Ecto.Adapters.SQL.query(@repo, sql, user_ids ++ extra_params) do
              {:ok, %{rows: rows}} when rows != [] ->
                section_ids = Enum.map(rows, fn [id] -> id end)
                Ash.Query.filter(query, id in ^section_ids)

              _ ->
                Ash.Query.filter(query, is_nil(id))
            end
          end

          ui do
            label fn -> dgettext("mishka_gervaz", "Contributor") end
            placeholder fn -> dgettext("mishka_gervaz", "Search contributors...") end
          end
        end

        filter :created_at, :date_range do
          source :inserted_at

          ui do
            label fn -> dgettext("mishka_gervaz", "Created at") end
          end
        end

        filter :updated_at, :date_range do
          source :updated_at

          ui do
            label fn -> dgettext("mishka_gervaz", "Last Updated") end
          end
        end
      end

      row_actions do
        # Declaring that a row expands, not a button: the plain table draws the caret as its own
        # column, and the card draws its own "Advanced Details" footer, so neither renders this as an
        # action — `MishkaGervaz.Table.Templates.Shared.non_accordion_actions/1` is what keeps it out
        # of both action strips. The panel itself is the page's, pushed back as `expanded_html`.
        action :expand, type: :accordion

        action :edit do
          type :edit
          visible :active
          js fn _record -> MishkaCmsCore.CoreComponents.show_modal("section-form-modal") end

          ui do
            label fn -> dgettext("mishka_gervaz", "Edit") end
            icon "hero-pencil-square"
            class @icon_action_class
          end
        end

        action :notes do
          type :event
          event "manage_notes"
          visible :active

          ui do
            label fn -> dgettext("mishka_gervaz", "Notes") end
            icon "hero-document-text"
            class @notes_action_class
          end
        end

        action :delete do
          type :destroy
          confirm fn _record -> dgettext("mishka_gervaz", "Archive this section?") end
          visible :active
          restricted true

          ui do
            label fn -> dgettext("mishka_gervaz", "Archive") end
            icon "hero-trash"
            class @danger_action_class
          end
        end

        action :unarchive do
          type :unarchive
          restricted true
          confirm fn _record -> dgettext("mishka_gervaz", "Restore this section?") end
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
          restricted true

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
          confirm: dgettext_noop("mishka_gervaz", "Archive selected sections?")

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
        prefix "section"
      end

      url_sync do
        mode :bidirectional
        params [:filters, :sort, :page, :search]
        prefix "sections"
        max_filter_length 500
      end

      hooks do
        on_expand fn id, socket ->
          send(self(), {:expand_row, id})
          {:cont, socket}
        end
      end

      presentation do
        template MishkaDocumentWeb.Templates.DocumentSection
        ui_adapter MishkaCmsCoreWeb.UIAdapters.Admin

        switchable_templates [
          MishkaGervaz.Table.Templates.Table,
          MishkaDocumentWeb.Templates.DocumentSection
        ]
      end

      empty_state message: dgettext_noop("mishka_gervaz", "No sections found"),
                  icon: "hero-document"
    end

    form do
      identity do
        name :section_form
      end

      source do
        preload do
          always [:site]
          master master_workspace_version: :workspace_version, master_tags: :tags
          tenant [:workspace_version, tenant_tags: :tags]
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

        field :workspace, :relation do
          virtual true
          resource MishkaDocument.Workspace
          display_field :name
          search_field :name
          mode :search
          depends_on :site_id

          readonly fn state ->
            state.mode == :create and Map.has_key?(state.defaults || %{}, :workspace)
          end

          derive_value fn record ->
            case Map.get(record, :workspace_version) do
              %{workspace_id: id} -> id
              _ -> nil
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
          display_field :version_name
          search_field :version_name
          mode :search
          depends_on :workspace

          readonly fn state ->
            state.mode == :create and Map.has_key?(state.defaults || %{}, :workspace_version_id)
          end

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
            placeholder "section-slug"
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

        field :front_page, :toggle do
          ui do
            label fn -> dgettext("mishka_gervaz", "Front page") end

            description fn ->
              dgettext(
                "mishka_gervaz",
                "Drawn at the document's own address instead of under it. One page per version, and only a page with no parent."
              )
            end
          end
        end

        field :group_heading, :toggle do
          ui do
            label fn -> dgettext("mishka_gervaz", "Group") end

            description fn ->
              dgettext(
                "mishka_gervaz",
                "Only a heading in the contents: it has no page of its own, and the pages under it keep their address as if it were not there."
              )
            end
          end
        end

        field :source_section_id, :relation do
          display_field :title
          search_field :title
          mode :search
          depends_on :workspace
          include_nil fn -> dgettext("mishka_gervaz", "No source section") end

          load fn query, state ->
            workspace_id = Map.get(state.field_values, :workspace)
            query = Ash.Query.filter(query, workspace_version.workspace_id == ^workspace_id)

            case Map.get(state.field_values, :workspace_version_id) do
              nil -> query
              version_id -> Ash.Query.filter(query, workspace_version_id != ^version_id)
            end
          end

          ui do
            label fn -> dgettext("mishka_gervaz", "Source Section") end
          end
        end

        field :language, :combobox do
          required true

          options fn ->
            case Ecto.Adapters.SQL.query(
                   @repo,
                   "SELECT DISTINCT language FROM mishka_document_sections WHERE language IS NOT NULL AND archived_at IS NULL ORDER BY language"
                 ) do
              {:ok, %{rows: rows}} ->
                Enum.map(rows, fn [lang] -> {String.upcase(lang), lang} end)

              _ ->
                []
            end
          end

          ui do
            label fn -> dgettext("mishka_gervaz", "Language") end
            placeholder "en, fa, ar, ..."

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
          include_nil fn -> dgettext("mishka_gervaz", "New Language Group (auto-generate)") end

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

        field :content, :textarea do
          ui do
            label fn -> dgettext("mishka_gervaz", "Content") end
            placeholder fn -> dgettext("mishka_gervaz", "Section content...") end
            rows 5

            # The rich-text editor, with components placed as blocks; their markers are what is
            # stored. `MishkaCmsCoreWeb.UIAdapters.Admin.textarea/1` is what reads this.
            extra %{content_editor: true}
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

        field :tag_ids, :relation do
          virtual true
          resource MishkaDocument.Tag
          display_field :name
          search_field :name
          mode :search_multi
          depends_on :site_id

          load fn query, state ->
            site_id =
              if state.master_user? do
                Map.get(state.field_values, :site_id)
              else
                Map.get(state.current_user, :site_id)
              end

            Ash.Query.filter_input(query, %{site_id: site_id})
          end

          derive_value fn record ->
            tags =
              case Map.get(record, :tags) do
                list when is_list(list) -> list
                _ -> []
              end

            Enum.map(tags, &to_string(&1.id))
          end

          ui do
            label fn -> dgettext("mishka_gervaz", "Tags") end
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

        # WHO MAY OPEN THE PAGE: any of the permission names that exist, stored by name. Empty, the
        # nearest page above it that names some decides, else its document
        # (`MishkaDocument.Resources.Calculations.EffectivePermissions`).
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
                "Who may open this page: anyone holding one of these. None: as the page above it, else its document."
              )
            end
          end
        end

        # THE SHARE CARD a link to it shows, as drawn, and Regenerate. One being added has none yet.
        # `MishkaCmsCoreWeb.UIAdapters.Admin.text_input/1` is what reads `share_card`.
        field :share_card, :text do
          virtual true
          show_on :update

          ui do
            label fn -> dgettext("mishka_gervaz", "Share image") end
            extra %{share_card: &MishkaDocument.ShareCards.target/1}
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
          fields [
            :workspace,
            :workspace_version_id,
            :parent_section_id,
            :front_page,
            :group_heading,
            :source_section_id
          ]

          ui do
            label fn -> dgettext("mishka_gervaz", "References") end
            columns 2
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
          fields [:content_review_status, :technical_review_status, :order_position]

          ui do
            label fn -> dgettext("mishka_gervaz", "Review & Ordering") end
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

        group :tags do
          fields [:tag_ids]

          ui do
            label fn -> dgettext("mishka_gervaz", "Tags") end
            columns 1
          end
        end

        group :seo do
          fields [:seo_tags, :permissions, :share_card]

          ui do
            label fn -> dgettext("mishka_gervaz", "SEO") end
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
        # While a section is added, its slug follows the title until the author types one.
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
    field :front_page, :boolean, derives: "validate(boolean)"
    field :group_heading, :boolean, derives: "validate(boolean)"

    field :change_version, :string,
      derives: "sanitize(trim) validate(optional=[string, max_len=50, semver])"

    field :content_review_status, :atom,
      derives: "validate(atom, enum=Atom[pending::approved::rejected::needs_revision::archived])"

    field :technical_review_status, :atom,
      derives: "validate(atom, enum=Atom[pending::approved::rejected::needs_revision::archived])"

    field :schema, {:array, :map}, derives: "validate(list)"
    field :seo_tags, {:array, :map}, derives: "validate(list)"

    field :permissions, {:array, :string},
      derives: "sanitize(each=[trim, downcase], reject_empty, uniq) validate(list)"

    field :language, :string,
      derives: "sanitize(trim, downcase) validate(optional=[string, max_len=20, language_code])"

    field :language_group_id, :uuid, derives: "validate(optional=[uuid])"
    field :section_lineage_id, :uuid, derives: "validate(optional=[uuid])"
    field :source_section_id, :uuid, derives: "validate(optional=[uuid])"
  end

  field_policies do
    field_policy [
      :pending_section_draft_content_review_count,
      :pending_section_draft_technical_review_count,
      :approved_section_draft_count,
      :pending_note_draft_content_review_count,
      :pending_note_draft_technical_review_count,
      :contributors_count,
      :breadcrumb_path,
      :section_versions_count
    ] do
      authorize_if {MishkaCmsCore.Accounts.Checks.AccessPermissions,
                    permissions: [
                      "admin:dashboard:document:section",
                      "admin:api:document:section"
                    ]}
    end

    field_policy :* do
      authorize_if always()
    end
  end

  actions do
    defaults [:read]

    default_accept @admin_fields

    create :create do
      primary? true

      # before/reject seam
      change MishkaCmsCore.Runtime.Resources.Changes.PluginBeforeHook
      accept @admin_fields |> List.delete(:site_id)

      argument :tag_ids, {:array, :uuid} do
        description "List of tag IDs to assign to this section"
      end

      validate present(:workspace_version_id)
      validate present(:title)
      validate present(:slug)
      validate present(:language)

      validate {MishkaCmsCore.Runtime.Resources.Validations.TenantContext, require_master: false}

      validate {MishkaCmsCore.Runtime.Resources.Validations.TenantIsolation,
                field: :workspace_version_id, resource: MishkaDocument.WorkspaceVersion}

      validate {MishkaCmsCore.Runtime.Resources.Validations.TenantIsolation,
                field: :parent_section_id, resource: MishkaDocument.Section}

      validate {MishkaCmsCore.Runtime.Resources.Validations.TenantIsolation,
                field: :language_group_id, resource: MishkaDocument.Section}

      validate {MishkaCmsCore.Runtime.Resources.Validations.TenantIsolation,
                field: :source_section_id, resource: MishkaDocument.Section}

      change &Ash.Changeset.force_change_attribute(&1, :site_id, &2.tenant)
      change MishkaCmsCore.Runtime.Resources.Changes.SetLanguageGroupId
      change MishkaDocument.Resources.Changes.SetSectionLineageId
      change slugify(:slug, into: :slug, ignore: [".", "!", "?"])

      change manage_relationship(:tag_ids, :tenant_tags,
               type: :append_and_remove,
               on_no_match: :error,
               on_match: :ignore
             )

      validate fn changeset, _context ->
        parent_id = Ash.Changeset.get_attribute(changeset, :parent_section_id)
        section_id = changeset.data.id

        if !is_nil(parent_id) and parent_id == section_id do
          {:error,
           field: :parent_section_id,
           message: dgettext_noop("errors", "Section cannot be its own parent.")}
        else
          :ok
        end
      end

      # Highlights the code blocks of the sanitized content, before the row is written, and stores
      # the components it names.
      change MishkaDocument.Resources.Changes.HighlightCode
      change MishkaDocument.Resources.Changes.ContentFacts

      change {MishkaDocument.Resources.Changes.SetEventMetadata,
              resource_type: :section, for_action: :create}

      description "Creates section for tenant users - requires tenant context, auto-assigns site_id and language_group_id"
    end

    create :master_create do
      argument :tag_ids, {:array, :uuid} do
        description "List of tag IDs to assign to this section"
      end

      validate present(:workspace_version_id)
      validate present(:title)
      validate present(:slug)
      validate present(:language)
      validate present(:site_id)

      validate {MishkaCmsCore.Runtime.Resources.Validations.TenantContext, require_master: true}

      change fn changeset, _context ->
        site_id = Ash.Changeset.get_attribute(changeset, :site_id)
        Ash.Changeset.set_tenant(changeset, site_id)
      end

      change MishkaCmsCore.Runtime.Resources.Changes.SetLanguageGroupId
      change MishkaDocument.Resources.Changes.SetSectionLineageId
      change slugify(:slug, into: :slug, ignore: [".", "!", "?"])

      change manage_relationship(:tag_ids, :tenant_tags,
               type: :append_and_remove,
               on_no_match: :error,
               on_match: :ignore
             )

      validate fn changeset, _context ->
        parent_id = Ash.Changeset.get_attribute(changeset, :parent_section_id)
        section_id = changeset.data.id

        if !is_nil(parent_id) and parent_id == section_id do
          {:error,
           field: :parent_section_id,
           message: dgettext_noop("errors", "Section cannot be its own parent.")}
        else
          :ok
        end
      end

      change MishkaDocument.Resources.Changes.HighlightCode
      change MishkaDocument.Resources.Changes.ContentFacts

      change {MishkaDocument.Resources.Changes.SetEventMetadata,
              resource_type: :section, for_action: :create}

      description "Creates section for master users - requires explicit site_id, auto-assigns language_group_id and section_lineage_id"
    end

    update :update do
      primary? true
      require_atomic? false
      transaction? true
      accept @admin_fields |> List.delete(:site_id)

      argument :tag_ids, {:array, :uuid} do
        description "List of tag IDs to assign to this section"
      end

      validate {MishkaCmsCore.Runtime.Resources.Validations.TenantContext, require_master: false}

      validate {MishkaCmsCore.Runtime.Resources.Validations.TenantIsolation,
                field: :workspace_version_id, resource: MishkaDocument.WorkspaceVersion},
               where: [changing(:workspace_version_id)]

      validate {MishkaCmsCore.Runtime.Resources.Validations.TenantIsolation,
                field: :parent_section_id, resource: MishkaDocument.Section},
               where: [changing(:parent_section_id)]

      validate {MishkaCmsCore.Runtime.Resources.Validations.TenantIsolation,
                field: :language_group_id, resource: MishkaDocument.Section},
               where: [changing(:language_group_id)]

      validate {MishkaCmsCore.Runtime.Resources.Validations.TenantIsolation,
                field: :source_section_id, resource: MishkaDocument.Section},
               where: [changing(:source_section_id)]

      validate fn changeset, _context ->
        parent_id = Ash.Changeset.get_attribute(changeset, :parent_section_id)
        section_id = changeset.data.id

        if !is_nil(parent_id) and parent_id == section_id do
          {:error,
           field: :parent_section_id,
           message: dgettext_noop("errors", "Section cannot be its own parent.")}
        else
          :ok
        end
      end

      change slugify(:slug, into: :slug, ignore: [".", "!", "?"])

      change manage_relationship(:tag_ids, :tenant_tags,
               type: :append_and_remove,
               on_no_match: :error,
               on_match: :ignore
             )

      change MishkaDocument.Resources.Changes.HighlightCode
      change MishkaDocument.Resources.Changes.ContentFacts

      change {MishkaDocument.Resources.Changes.SetEventMetadata,
              resource_type: :section, for_action: :update}

      description "Updates section for tenant users - requires tenant context, prevents site_id changes"
    end

    update :master_update do
      description "Updates section for master users - bypasses multi-tenancy, prevents site_id changes"
      require_atomic? false
      transaction? true
      accept @admin_fields |> List.delete(:site_id)
      multitenancy :bypass

      argument :tag_ids, {:array, :uuid} do
        description "List of tag IDs to assign to this section"
      end

      validate {MishkaCmsCore.Runtime.Resources.Validations.TenantContext, require_master: true}

      validate fn changeset, _context ->
        parent_id = Ash.Changeset.get_attribute(changeset, :parent_section_id)
        section_id = changeset.data.id

        if !is_nil(parent_id) and parent_id == section_id do
          {:error,
           field: :parent_section_id,
           message: dgettext_noop("errors", "Section cannot be its own parent.")}
        else
          :ok
        end
      end

      change slugify(:slug, into: :slug, ignore: [".", "!", "?"])

      change manage_relationship(:tag_ids, :master_tags,
               type: :append_and_remove,
               on_no_match: :error,
               on_match: :ignore,
               on_lookup: {:relate, :create, :master_get}
             )

      change MishkaDocument.Resources.Changes.HighlightCode
      change MishkaDocument.Resources.Changes.ContentFacts

      change {MishkaDocument.Resources.Changes.SetEventMetadata,
              resource_type: :section, for_action: :update}
    end

    read :master_read do
      description "Reads all sections system-wide, bypassing tenant filtering (master users only)"
      multitenancy :bypass
      pagination offset?: true, default_limit: 20, max_page_size: 100, countable: true

      validate {MishkaCmsCore.Runtime.Resources.Validations.TenantContext, require_master: true}
    end

    read :master_get do
      multitenancy :bypass
      get? true
      description "Retrieves single section by ID, bypassing tenant filtering"

      validate {MishkaCmsCore.Runtime.Resources.Validations.TenantContext, require_master: true}
    end

    read :public_list do
      description "Public endpoint to list approved sections (no authentication required)"
      prepare MishkaCmsCore.Runtime.Resources.Preparations.PluginQueryHook
      filter expr(content_review_status == :approved and technical_review_status == :approved)

      pagination offset?: true,
                 default_limit: 20,
                 max_page_size: 100,
                 countable: true,
                 required?: false

      prepare {MishkaDocument.Resources.Preparations.OpenToActor, kind: :section}
    end

    read :public_get do
      description "Public endpoint to get a single approved section by ID (no authentication required)"
      get? true
      filter expr(content_review_status == :approved and technical_review_status == :approved)
      prepare {MishkaDocument.Resources.Preparations.OpenToActor, kind: :section}
    end

    read :public_list_at_workspace_version do
      description """
      Get approved sections for a specific workspace version.

      Returns all sections that belong to the given workspace version and are fully approved.
      """

      argument :workspace_version_id, :uuid,
        allow_nil?: false,
        description: "The workspace version to filter sections by"

      filter expr(
               workspace_version_id == ^arg(:workspace_version_id) and
                 content_review_status == :approved and
                 technical_review_status == :approved
             )

      pagination offset?: true,
                 default_limit: 20,
                 max_page_size: 100,
                 countable: true,
                 required?: false

      prepare {MishkaDocument.Resources.Preparations.OpenToActor, kind: :section}
    end

    read :read_any do
      multitenancy :bypass
      description "Reads all sections bypassing tenant filtering (for master relationships)"

      pagination offset?: true,
                 default_limit: 20,
                 max_page_size: 100,
                 countable: true,
                 required?: false
    end

    read :archived do
      filter expr(not is_nil(archived_at))
      pagination offset?: true, default_limit: 20, max_page_size: 100, countable: true

      validate {MishkaCmsCore.Runtime.Resources.Validations.TenantContext, require_master: false}

      description "Lists archived sections within current tenant context"
    end

    read :get_archived do
      get? true
      filter expr(not is_nil(archived_at))

      validate {MishkaCmsCore.Runtime.Resources.Validations.TenantContext, require_master: false}

      description "Retrieves single archived section for recovery or inspection (tenant users)"
    end

    read :master_get_archived do
      get? true
      multitenancy :bypass
      filter expr(not is_nil(archived_at))

      validate {MishkaCmsCore.Runtime.Resources.Validations.TenantContext, require_master: true}

      description "Retrieves single archived section for recovery or inspection (master users)"
    end

    read :master_archived do
      multitenancy :bypass
      filter expr(not is_nil(archived_at))
      pagination offset?: true, default_limit: 20, max_page_size: 100, countable: true

      validate {MishkaCmsCore.Runtime.Resources.Validations.TenantContext, require_master: true}

      description "Lists all archived sections system-wide, bypassing tenant filtering"
    end

    destroy :destroy do
      description "Soft deletes section by archiving (tenant users)"
      primary? true
      require_atomic? false

      validate {MishkaCmsCore.Runtime.Resources.Validations.TenantContext, require_master: false}

      validate fn changeset, _context ->
        if changeset.data.archived_at do
          {:error,
           field: :archived_at, message: dgettext_noop("errors", "Section is already archived.")}
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
              resource_type: :section, for_action: :destroy}
    end

    destroy :master_destroy do
      description "Soft deletes section by archiving (master users) - bypasses multi-tenancy"
      require_atomic? false
      multitenancy :bypass

      validate {MishkaCmsCore.Runtime.Resources.Validations.TenantContext, require_master: true}

      validate fn changeset, _context ->
        if changeset.data.archived_at do
          {:error,
           field: :archived_at, message: dgettext_noop("errors", "Section is already archived.")}
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
              resource_type: :section, for_action: :destroy}
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
              resource_type: :section, for_action: :update}

      description "Restores archived section to pending review status (tenant users)"
    end

    update :master_unarchive do
      description "Restores archived section to pending review status (master users) - bypasses multi-tenancy"
      accept []
      require_atomic? false
      multitenancy :bypass

      validate {MishkaCmsCore.Runtime.Resources.Validations.TenantContext, require_master: true}

      validate fn changeset, _context ->
        if is_nil(changeset.data.archived_at) do
          {:error,
           field: :archived_at, message: dgettext_noop("errors", "Section is not archived.")}
        else
          :ok
        end
      end

      change set_attribute(:archived_at, nil)
      change set_attribute(:content_review_status, :pending)
      change set_attribute(:technical_review_status, :pending)

      change {MishkaDocument.Resources.Changes.SetEventMetadata,
              resource_type: :section, for_action: :update}
    end

    destroy :permanent_destroy do
      require_atomic? false

      validate {MishkaCmsCore.Runtime.Resources.Validations.TenantContext, require_master: false}

      change {MishkaDocument.Resources.Changes.SetEventMetadata,
              resource_type: :section, for_action: :destroy}

      description "Permanently removes section from database (tenant users) - use with extreme caution"
    end

    destroy :master_permanent_destroy do
      description "Permanently removes section from database (master users) - bypasses multi-tenancy, irreversible"
      require_atomic? false
      multitenancy :bypass

      validate {MishkaCmsCore.Runtime.Resources.Validations.TenantContext, require_master: true}

      change {MishkaDocument.Resources.Changes.SetEventMetadata,
              resource_type: :section, for_action: :destroy}
    end
  end

  # Authorization policies for section access
  policies do
    # Allow public access to view approved sections
    bypass action(:public_list) do
      authorize_if always()
    end

    bypass action(:public_get) do
      authorize_if always()
    end

    bypass action(:public_list_at_workspace_version) do
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

  pub_sub do
    module Application.compile_env!(:mishka_cms_core, :endpoint)
    prefix "section"

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
              field: :section_lineage_id,
              resource: MishkaDocument.Section,
              label: dgettext_noop("errors", "section"),
              read_action: :master_get},
             where: [changing(:section_lineage_id)]

    validate {MishkaCmsCore.Runtime.Resources.Validations.SameSiteReference,
              field: :source_section_id,
              resource: MishkaDocument.Section,
              label: dgettext_noop("errors", "section"),
              read_action: :master_get},
             where: [changing(:source_section_id)],
             only_when_valid?: true

    # The sections it names are its own workspace version's; the one it was copied from is another's.
    validate {MishkaDocument.Resources.Validations.SameWorkspaceVersion,
              field: :parent_section_id,
              resource: MishkaDocument.Section,
              label: dgettext_noop("errors", "section")},
             only_when_valid?: true

    validate {MishkaDocument.Resources.Validations.SameWorkspaceVersion,
              field: :source_section_id,
              resource: MishkaDocument.Section,
              label: dgettext_noop("errors", "section"),
              in: :other_version},
             only_when_valid?: true

    # A FRONT PAGE IS DRAWN AT ITS DOCUMENT'S OWN ADDRESS (`MishkaDocument.Address`), so it is a page
    # at the top: one filed under another would be drawn in two places.
    validate fn changeset, _context ->
      front_page? = Ash.Changeset.get_attribute(changeset, :front_page) == true
      parent_id = Ash.Changeset.get_attribute(changeset, :parent_section_id)

      if front_page? and not is_nil(parent_id) do
        {:error,
         field: :front_page,
         message:
           dgettext_noop("errors", "Only a page with no parent may be its document's front page.")}
      else
        :ok
      end
    end

    # A GROUP HAS NO PAGE OF ITS OWN, so it cannot be the page a document's address draws.
    validate fn changeset, _context ->
      if Ash.Changeset.get_attribute(changeset, :front_page) == true and
           Ash.Changeset.get_attribute(changeset, :group_heading) == true do
        {:error,
         field: :group_heading,
         message:
           dgettext_noop(
             "errors",
             "A page cannot be both its document's front page and a group."
           )}
      else
        :ok
      end
    end

    # A PAGE'S WHOLE ADDRESS IS ITS OWN in its version, now that a front page's and a group's slugs
    # are in none: two pages under two parents may otherwise meet at one address.
    validate MishkaDocument.Resources.Validations.SectionAddress,
      on: [:create, :update],
      only_when_valid?: true
  end

  # Multi-tenancy configuration - sections are always site-specific
  multitenancy do
    strategy :attribute
    attribute :site_id
    # Sections are NEVER global - always site-specific
    global? false
  end

  attributes do
    uuid_primary_key :id

    attribute :title, :string do
      allow_nil? false
      public? true
      constraints min_length: 1, max_length: 500, trim?: true
      description "Title of the section"
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

    attribute :order_position, :integer do
      allow_nil? true
      public? true
      default 0
      constraints min: 0
      description "Position for ordering sections"
    end

    # DRAWN AT ITS DOCUMENT'S OWN ADDRESS, in place of the document's landing: its own part of the
    # address is empty and the pages under it sit directly under the document's
    # (`MishkaDocument.Address`).
    attribute :front_page, :boolean do
      allow_nil? false
      public? true
      default false
      description "Whether the page is drawn at its document's own address instead of under it"
    end

    # ONLY A HEADING IN THE CONTENTS: no page of its own and no address, and the pages under it are
    # addressed as if it were not there (`MishkaDocument.Address`).
    attribute :group_heading, :boolean do
      allow_nil? false
      public? true
      default false

      description "Whether the page is only a heading over the pages under it, with no page of its own"
    end

    attribute :change_version, :string do
      allow_nil? true
      public? true
      default "0.0.1"
      constraints max_length: 50, trim?: true
      description "Semantic version of this section (e.g., 1.2.0, 2.0.0-beta-1)"
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

    attribute :permissions, {:array, :string} do
      default []
      public? true
      description "Permission strings required to open this section on its page"
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

    attribute :section_lineage_id, :uuid do
      allow_nil? true
      public? true
      description "Shared ID linking all versions of this section across workspace versions"
    end

    attribute :source_section_id, :uuid do
      allow_nil? true
      public? true
      description "The section this was cloned from (in a previous workspace version)"
    end

    create_timestamp :inserted_at
    update_timestamp :updated_at
  end

  relationships do
    belongs_to :site, MishkaCmsCore.Runtime.Site do
      read_action :read_any
      allow_nil? false
      public? true
      description "The site this section belongs to"
    end

    belongs_to :workspace_version, MishkaDocument.WorkspaceVersion do
      allow_nil? false
      public? true
      description "The workspace version this section belongs to"
    end

    # Bypass relationship - for master admin users without tenant
    belongs_to :master_workspace_version, MishkaDocument.WorkspaceVersion do
      public? true
      source_attribute :workspace_version_id
      destination_attribute :id
      define_attribute? false
      read_action :read_any

      description "The workspace version this section belongs to (master admin access, bypass tenant)"

      filter expr(not is_nil(type(^actor(:id), :uuid)) and is_nil(type(^actor(:site_id), :uuid)))
    end

    belongs_to :parent_section, MishkaDocument.Section do
      allow_nil? true
      public? true
      description "Parent section for nested hierarchies"
    end

    # Bypass relationship - for master admin users without tenant
    belongs_to :master_parent_section, MishkaDocument.Section do
      allow_nil? true
      public? true
      source_attribute :parent_section_id
      destination_attribute :id
      define_attribute? false
      read_action :read_any

      description "Parent section for nested hierarchies (master admin access, bypass tenant)"

      filter expr(not is_nil(type(^actor(:id), :uuid)) and is_nil(type(^actor(:site_id), :uuid)))
    end

    has_many :child_sections, MishkaDocument.Section do
      public? true
      destination_attribute :parent_section_id
      description "Child sections nested under this section"
    end

    # Language group section - for selecting which section this is a translation of
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

    has_many :language_variants, MishkaDocument.Section do
      public? true
      destination_attribute :language_group_id
      source_attribute :language_group_id
      description "All language variants (translations) of this section"
    end

    belongs_to :source_section, MishkaDocument.Section do
      allow_nil? true
      public? true
      description "The section this was cloned from"
      filter expr(site_id == parent(site_id))
    end

    # Bypass relationship - for master admin users without tenant
    belongs_to :master_source_section, MishkaDocument.Section do
      public? true
      source_attribute :source_section_id
      destination_attribute :id
      define_attribute? false
      read_action :read_any
      description "The section this was cloned from (master admin access, bypass tenant)"

      filter expr(
               not is_nil(type(^actor(:id), :uuid)) and is_nil(type(^actor(:site_id), :uuid)) and
                 site_id == parent(site_id)
             )
    end

    has_many :lineage_versions, MishkaDocument.Section do
      public? true
      destination_attribute :section_lineage_id
      source_attribute :section_lineage_id
      description "All versions of this section across workspace versions"
    end

    # Relationship - for public users (guests/users without permissions)
    has_many :notes, MishkaDocument.Note do
      public? true
      destination_attribute :section_id
      read_action :public_list
      description "Published approved notes of this section (public access)"
    end

    # Relationship - for admin users with tenant
    has_many :tenant_notes, MishkaDocument.Note do
      public? true
      destination_attribute :section_id
      description "All notes of this section (tenant admin access)"
    end

    # Bypass relationship - for master admin users without tenant
    has_many :master_notes, MishkaDocument.Note do
      public? true
      destination_attribute :section_id
      read_action :read_any
      description "All notes of this section (master admin access, bypass tenant)"

      filter expr(not is_nil(type(^actor(:id), :uuid)) and is_nil(type(^actor(:site_id), :uuid)))
    end

    # Tag relationships - for public approved tags
    many_to_many :tags, MishkaDocument.Tag do
      public? true
      description "Tags categorizing this section (public approved)"
      through MishkaDocument.SectionTag
      source_attribute_on_join_resource :section_id
      destination_attribute_on_join_resource :tag_id
      read_action :public_list
    end

    # Tag relationships - for tenant admin users
    many_to_many :tenant_tags, MishkaDocument.Tag do
      public? true
      description "All tags categorizing this section (tenant admin access)"
      through MishkaDocument.SectionTag
      source_attribute_on_join_resource :section_id
      destination_attribute_on_join_resource :tag_id
    end

    # Tag relationships - for master admin users (bypass tenant)
    many_to_many :master_tags, MishkaDocument.Tag do
      public? true
      description "All tags categorizing this section (master admin access, bypass tenant)"
      through MishkaDocument.SectionTag
      source_attribute_on_join_resource :section_id
      destination_attribute_on_join_resource :tag_id
      read_action :master_read

      filter expr(not is_nil(type(^actor(:id), :uuid)) and is_nil(type(^actor(:site_id), :uuid)))
    end

    # Draft relationships - for tenant admin users
    has_many :section_drafts, MishkaDocument.SectionDraft do
      public? true
      destination_attribute :source_section_id
      description "All drafts for this section (tenant admin access)"
    end

    # Bypass relationship - for master admin users without tenant
    has_many :master_section_drafts, MishkaDocument.SectionDraft do
      public? true
      destination_attribute :source_section_id
      read_action :read_any
      description "All drafts for this section (master admin access, bypass tenant)"

      filter expr(not is_nil(type(^actor(:id), :uuid)) and is_nil(type(^actor(:site_id), :uuid)))
    end

    # Note drafts belonging to this section
    has_many :note_drafts, MishkaDocument.NoteDraft do
      public? true
      destination_attribute :section_id
      description "All note drafts for this section"
    end
  end

  calculations do
    # the_content / onContentPrepare equivalent for section bodies.
    calculate :rendered_content,
              :string,
              {MishkaCmsCore.Runtime.Resources.Calculations.RenderContent, source: :content}

    # Who may open the section: its own permissions, else its nearest parent's, else its document's.
    calculate :effective_permissions,
              {:array, :string},
              MishkaDocument.Resources.Calculations.EffectivePermissions

    calculate :contributors_count,
              :integer,
              MishkaDocument.Resources.Calculations.SectionMaintainers do
      public? true

      description "Returns count of unique maintainers who created/updated this section or its notes (via EventLog)"
    end

    calculate :breadcrumb_path, {:array, :map} do
      public? true

      calculation fn records, _context ->
        parent_ids =
          records
          |> Enum.map(& &1.parent_section_id)
          |> Enum.reject(&is_nil/1)
          |> Enum.uniq()

        breadcrumbs_by_start_id =
          if parent_ids == [] do
            %{}
          else
            placeholders = Enum.map_join(1..length(parent_ids), ", ", fn i -> "$#{i}" end)
            dumped_ids = Enum.map(parent_ids, &Ecto.UUID.dump!/1)

            sql = """
            WITH RECURSIVE ancestors AS (
              SELECT id, title, slug, parent_section_id, site_id, id as start_id, 1 as depth
              FROM mishka_document_sections
              WHERE id IN (#{placeholders})
                AND archived_at IS NULL

              UNION ALL

              SELECT s.id, s.title, s.slug, s.parent_section_id, s.site_id, a.start_id, a.depth + 1
              FROM mishka_document_sections s
              INNER JOIN ancestors a ON s.id = a.parent_section_id AND s.site_id = a.site_id
              WHERE s.archived_at IS NULL
            )
            SELECT start_id, site_id, id, title, slug FROM ancestors ORDER BY start_id, depth DESC
            """

            case Ecto.Adapters.SQL.query(@repo, sql, dumped_ids) do
              {:ok, %{rows: rows}} ->
                Enum.group_by(
                  rows,
                  fn [start_id, site_id | _] ->
                    {Ecto.UUID.load!(start_id), Ecto.UUID.load!(site_id)}
                  end,
                  fn [_, _, id, title, slug] ->
                    %{"id" => Ecto.UUID.load!(id), "title" => title, "slug" => slug}
                  end
                )

              _ ->
                %{}
            end
          end

        Enum.map(records, fn record ->
          if is_nil(record.parent_section_id) do
            []
          else
            Map.get(breadcrumbs_by_start_id, {record.parent_section_id, record.site_id}, [])
          end
        end)
      end

      description "Returns breadcrumb path from root ancestor to immediate parent as list of {id, title, slug} maps, within the section's own site"
    end

    calculate :section_versions_count, :integer do
      public? true

      calculation fn records, _context ->
        lineage_ids =
          records
          |> Enum.map(& &1.section_lineage_id)
          |> Enum.reject(&is_nil/1)
          |> Enum.uniq()

        counts_by_lineage =
          if lineage_ids == [] do
            %{}
          else
            placeholders = Enum.map_join(1..length(lineage_ids), ", ", fn i -> "$#{i}" end)
            dumped_ids = Enum.map(lineage_ids, &Ecto.UUID.dump!/1)

            sql = """
            SELECT section_lineage_id, site_id, COUNT(*)
            FROM mishka_document_sections
            WHERE section_lineage_id IN (#{placeholders})
              AND archived_at IS NULL
            GROUP BY section_lineage_id, site_id
            """

            case Ecto.Adapters.SQL.query(@repo, sql, dumped_ids) do
              {:ok, %{rows: rows}} ->
                Map.new(rows, fn [lid, site_id, count] ->
                  count = if is_float(count), do: trunc(count), else: count
                  {{Ecto.UUID.load!(lid), Ecto.UUID.load!(site_id)}, count}
                end)

              _ ->
                %{}
            end
          end

        Enum.map(records, fn record ->
          if is_nil(record.section_lineage_id) do
            1
          else
            Map.get(counts_by_lineage, {record.section_lineage_id, record.site_id}, 1)
          end
        end)
      end

      description "Returns count of versions of this section across workspace versions of its own site"
    end

    calculate :content_word_count, :integer, MishkaDocument.Resources.Calculations.WordCount do
      public? true
      description "Returns word count of the section content"
    end
  end

  aggregates do
    count :pending_section_draft_content_review_count, :section_drafts do
      public? true
      authorize? false
      multitenancy :bypass
      filter expr(content_review_status == :pending)
      description "Returns count of section drafts pending content review for this section"
    end

    count :pending_section_draft_technical_review_count, :section_drafts do
      public? true
      authorize? false
      multitenancy :bypass
      filter expr(technical_review_status == :pending)
      description "Returns count of section drafts pending technical review for this section"
    end

    count :approved_section_draft_count, :section_drafts do
      public? true
      authorize? false
      multitenancy :bypass
      filter expr(content_review_status == :approved and technical_review_status == :approved)
      description "Returns count of section drafts with both reviews approved for this section"
    end

    count :pending_note_draft_content_review_count, :note_drafts do
      public? true
      authorize? false
      multitenancy :bypass
      filter expr(content_review_status == :pending)
      description "Returns count of note drafts pending content review for this section"
    end

    count :pending_note_draft_technical_review_count, :note_drafts do
      public? true
      authorize? false
      multitenancy :bypass
      filter expr(technical_review_status == :pending)
      description "Returns count of note drafts pending technical review for this section"
    end
  end

  identities do
    # A PAGE'S SLUG IS ITS PART OF THE ADDRESS UNDER ITS PARENT — see `MishkaDocument.Address` — so it
    # is unique among the pages that share that parent, and two parents may each hold a `tabs`.
    identity :unique_slug_per_parent,
             [:slug, :parent_section_id, :workspace_version_id, :site_id] do
      description "Ensures section slugs are unique among the sections sharing a parent, in each workspace version and site"

      message dgettext_noop(
                "errors",
                "Another section under the same parent already has this slug."
              )

      all_tenants? true
      nils_distinct? false
    end

    # ONE FRONT PAGE A VERSION, among its pages not archived — `base_filter_sql` joins the index's
    # `where`.
    identity :unique_front_page_per_version, [:workspace_version_id, :site_id] do
      description "Ensures a workspace version has at most one front page"
      where expr(front_page == true)

      message dgettext_noop(
                "errors",
                "Another page of this version is already its front page."
              )

      all_tenants? true
    end

    identity :unique_language_per_group, [:language, :language_group_id, :site_id] do
      description "Ensures each language appears only once per language group within a site"

      message dgettext_noop(
                "errors",
                "A section with this language already exists in this language group."
              )

      all_tenants? true
      nils_distinct? false
    end
  end

  # A `requires`-selected aggregate or calculation arrives as a truthy `%Ash.NotLoaded{}` or
  # `%Ash.ForbiddenField{}` when the viewer's field policy hides it, so `|| 0` lets the struct
  # through and the row renders it. Matching on the integer is what actually guards the cell.
  @spec counted(term()) :: non_neg_integer()
  defp counted(value) when is_integer(value) and value >= 0, do: value
  defp counted(_unloaded), do: 0

  @doc false
  @spec review_badge(term()) :: %{label: String.t(), class: String.t()}
  def review_badge(status) when is_map_key(@reviews, status),
    do: translate_label(@reviews[status])

  def review_badge(_unknown), do: @unknown_review

  defp translate_label(%{label: label} = badge),
    do: %{badge | label: Gettext.gettext(MishkaCmsCore.Gettext, label)}

  @spec version_label(term()) :: String.t()
  defp version_label(version) when is_binary(version) and version != "", do: "v" <> version
  defp version_label(_missing), do: "v0.0.1"

  @spec inserted_on(term()) :: String.t()
  defp inserted_on(at) when is_struct(at, DateTime) or is_struct(at, NaiveDateTime),
    do: Localized.date(at, :yMMMd)

  defp inserted_on(_missing), do: "—"
end
