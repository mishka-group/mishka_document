defmodule MishkaDocument.Workspace do
  @moduledoc """
  Manages document workspaces in the MishkaDocument plugin.

  This resource represents workspaces that can organize documents and notes.
  Each workspace belongs to a specific site and supports various statuses (active, archived, draft)
  with metadata tracking including SEO tags, Schema.org structured data, and display ordering.

  The resource implements soft deletion via archival and provides comprehensive metadata management
  including SEO optimization and structured data support.

  Database-level constraints ensure data integrity with slug validation and prevention
  of modifications to archived workspaces. Multi-tenant isolation ensures workspaces
  are properly segregated between sites. The resource provides extensive API actions
  for external integrations.
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

  use MishkaGervaz.Messages, backend: MishkaCmsCore.Gettext
  import Phoenix.Component, only: [sigil_H: 2]
  import MishkaGervaz.UIAdapters.Tailwind, only: [cell_stacked: 1, cell_stats: 1]

  @admin_fields [
    :name,
    :slug,
    :description,
    :status,
    :schema,
    :seo_tags,
    :permissions,
    :featured,
    :display_order,
    :language,
    :language_group_id,
    :site_id
  ]

  # The card's button row: one labelled primary, then icon-only squares, then the destructive one.
  # An icon-only action still carries its label — it becomes the button's `title`, so the row stays
  # readable to a screen reader and on hover.
  # The primary takes the width the icon squares leave it, so it carries no padding of its own —
  # "Open workspace" wraps to two lines the moment it does. `min-w-0` is what lets it give that width
  # back on a narrow card: a flex item defaults to `min-width: auto`, so without it the button refuses
  # to shrink below its own text and shoves the last icon off the card.
  @primary_action_class "inline-flex h-9 min-w-0 flex-1 items-center justify-center gap-1.5 " <>
                          "whitespace-nowrap rounded-[9px] bg-[#5b57d6] px-2 text-[12px] " <>
                          "font-semibold text-white transition-colors hover:bg-[#4f4bcc] " <>
                          "[&_.lbl]:truncate"

  @icon_action_class "inline-flex size-9 flex-none items-center justify-center rounded-[9px] border " <>
                       "border-[#edece7] bg-[#faf9f6] text-[#8a877f] transition-colors " <>
                       "hover:bg-[#eeedfb] hover:text-[#5b57d6] [&_.lbl]:hidden"

  @danger_action_class "inline-flex size-9 flex-none items-center justify-center rounded-[9px] border " <>
                         "border-[#f0dcd8] bg-[#fdf3f1] text-[#c0473d] transition-colors " <>
                         "hover:bg-[#fbe9e7] [&_.lbl]:hidden"

  @repo Application.compile_env!(:mishka_cms_core, :repo)

  # Database configuration for workspaces storage with indexing
  postgres do
    table "mishka_document_workspaces"
    repo @repo

    references do
      reference :site, on_delete: :delete
    end

    # Database-level optimization for archived records
    base_filter_sql "(archived_at IS NULL)"

    custom_indexes do
      index [:status]
      index [:featured]
      index [:display_order]
      index [:language]
      index [:language_group_id]
    end

    check_constraints do
      check_constraint :slug, "slug_length_check",
        check: "length(slug) >= 1 AND length(slug) <= 255",
        message: dgettext_noop("errors", "Slug must be between 1 and 255 characters.")

      check_constraint :slug, "no_empty_slug",
        check: "slug != ''",
        message: dgettext_noop("errors", "Slug cannot be empty.")

      check_constraint :display_order, "display_order_positive",
        check: "display_order >= 0",
        message: dgettext_noop("errors", "Display order must be non-negative.")
    end

    # Database-level trigger to prevent updates on archived records
    custom_statements do
      statement :prevent_archived_workspace_updates_function do
        up """
        CREATE OR REPLACE FUNCTION prevent_archived_workspace_updates()
        RETURNS TRIGGER AS $$
        BEGIN
          -- Allow unarchiving (archived_at: NOT NULL -> NULL)
          IF OLD.archived_at IS NOT NULL AND NEW.archived_at IS NULL THEN
            RETURN NEW;
          END IF;

          -- Prevent other updates on archived records
          IF OLD.archived_at IS NOT NULL THEN
            RAISE EXCEPTION 'Cannot update archived workspace'
              USING ERRCODE = 'check_violation';
          END IF;

          RETURN NEW;
        END;
        $$ LANGUAGE plpgsql;
        """

        down "DROP FUNCTION IF EXISTS prevent_archived_workspace_updates();"
      end

      statement :prevent_archived_workspace_updates_trigger do
        up """
        CREATE TRIGGER prevent_archived_workspace_updates_trigger
          BEFORE UPDATE ON mishka_document_workspaces
          FOR EACH ROW
          EXECUTE FUNCTION prevent_archived_workspace_updates();
        """

        down "DROP TRIGGER IF EXISTS prevent_archived_workspace_updates_trigger ON mishka_document_workspaces;"
      end
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
    type "workspace"

    includes [:versions, :tenant_versions, :master_versions]

    paginated_includes [:versions, :tenant_versions, :master_versions]
  end

  # Event tracking configuration for activity logging
  events do
    event_log MishkaDocument.EventLog

    only_actions [
      :create,
      :update,
      :master_update,
      :unarchive,
      :master_unarchive,
      :master_create,
      :destroy,
      :master_destroy,
      :permanent_destroy,
      :master_permanent_destroy
    ]
  end

  mishka_gervaz do
    table do
      identity do
        name :workspaces
        route "/admin/dashboard/document"
        stream_name :workspaces
      end

      source do
        preload do
          always [:site, :health_metrics, :maintainers_info]

          # A workspace's siblings, and its versions, are themselves tenant-scoped, so a master has to
          # reach both through the bypass relationships — their own reads require a tenant it does not
          # have. Each aliases to the same key so the card never asks who is looking.
          #
          # `versions_count` is an aggregate: left out of here it arrives unloaded and the card reads a
          # truthful-looking 0.
          master [
            {:master_language_variants, :language_variants},
            {:master_versions_count, :versions_count},
            {:master_tag_names, :tag_names}
          ]

          tenant [:language_variants, :versions_count, :tag_names]
        end
      end

      columns do
        # The flagship card leads the grid, as the design has it, then newest first.
        default_sort featured: :desc, inserted_at: :desc

        auto_columns do
          except [
            :id,
            :name,
            :slug,
            :description,
            :status,
            :schema,
            :seo_tags,
            :permissions,
            :featured,
            :display_order,
            :language,
            :language_group_id,
            :inserted_at,
            :updated_at,
            :archived_at,
            :site_id
          ]
        end

        # The row's headline: the workspace name over its slug, the slug carrying a copy button. The
        # wider of the two open shares, since a name grows with its content.
        column :workspace_title do
          static true
          requires [:id, :name, :slug]
          label fn -> dgettext("mishka_gervaz", "Workspace") end
          position :first
          sortable true
          sort_field [:name]

          ui do
            width "minmax(180px,1.7fr)"
          end

          render fn record ->
            assigns = %{id: record.id, name: record.name, slug: record.slug}

            ~H"""
            <.cell_stacked
              variant={:title}
              icon="hero-document-text"
              primary={@name}
              secondary={"/" <> @slug}
              copy={%{id: "workspace-slug-copy-#{@id}", value: @slug, label: gettext("Copy slug")}}
            />
            """
          end
        end

        # The card's status pill, drawn by the `:badge` type so the row keeps one badge shape with
        # every other table.
        column :status do
          label fn -> dgettext("mishka_gervaz", "Status") end
          sortable true
          sort_field [:status]

          ui do
            type :badge
            width "minmax(105px,0.85fr)"

            extra %{
              colors: %{
                "active" => "bg-[#e6f6ee] text-[#177a53]",
                "draft" => "bg-[#fbf1df] text-[#a5691a]",
                "archived" => "bg-[#fbe9e7] text-[#b3433a]"
              },
              labels: %{
                "active" => dgettext_noop("mishka_gervaz", "Active"),
                "draft" => dgettext_noop("mishka_gervaz", "Draft"),
                "archived" => dgettext_noop("mishka_gervaz", "Archived")
              },
              default_color: "bg-[#f2f1ec] text-[#8a877f]"
            }
          end
        end

        # Every figure the row used to scatter — sections, versions, maintainers, completion — folded
        # into one wrapping cell, the language and a featured flag riding alongside as chips.
        # `counted/1` and `metric/2` keep an aggregate or calculation the viewer's field policy hides
        # from reaching the DOM as a struct.
        column :workspace_stats do
          static true
          requires [:health_metrics, :maintainers_info, :versions_count, :language, :featured]
          label fn -> dgettext("mishka_gervaz", "Stats") end

          ui do
            width "minmax(155px,1.3fr)"
          end

          render fn record ->
            metrics = record.health_metrics

            items = [
              %{
                icon: "hero-bars-3-bottom-left",
                value: metric(metrics, :sections_count),
                label: dgettext("mishka_gervaz", "Sections")
              },
              %{
                icon: "hero-share",
                value: counted(record.versions_count),
                label: dgettext("mishka_gervaz", "Versions")
              },
              %{
                icon: "hero-users",
                value: maintainer_count(record.maintainers_info),
                label: dgettext("mishka_gervaz", "Maintainers")
              },
              %{
                icon: "hero-chart-bar",
                value: "#{metric(metrics, :completion)}%",
                label: dgettext("mishka_gervaz", "Completion")
              }
            ]

            chips =
              [
                record.language &&
                  %{
                    text: String.upcase(record.language),
                    label: dgettext("mishka_gervaz", "Language")
                  },
                record.featured &&
                  %{
                    text: dgettext("mishka_gervaz", "Featured"),
                    class: "bg-[#fbf1df] text-[#a5691a]",
                    label: dgettext("mishka_gervaz", "Featured")
                  }
              ]
              |> Enum.filter(& &1)

            assigns = %{items: items, chips: chips}

            ~H"""
            <.cell_stats items={@items} chips={@chips} />
            """
          end
        end

        # The one cell that grows with its content, so it takes the slack every fixed-length cell
        # gives up. Two clamped lines stop a long description owning the row.
        column :description do
          label fn -> dgettext("mishka_gervaz", "Description") end

          ui do
            width "minmax(160px,2.2fr)"
          end

          render fn value ->
            preview =
              case value do
                text when is_binary(text) -> String.trim(text)
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

        # The merged cell every dashboard table ends on: the site only when the reader is a master
        # user, the created date under it either way.
        column :site_datetime do
          static true
          requires [:site, :inserted_at]
          label fn -> dgettext("mishka_gervaz", "Site / Date") end
          position :last
          sortable true
          sort_field [:inserted_at]

          ui do
            width "minmax(130px,1.1fr)"
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
          filters [:status, :featured, :site_id, :created_at]
          collapsible true

          ui do
            label fn -> dgettext("mishka_gervaz", "Filter") end
            icon "hero-funnel"
            columns 4
          end
        end
      end

      filters do
        filter :search, :text do
          fields [:name, :description]

          ui do
            label fn -> dgettext("mishka_gervaz", "Search") end
          end
        end

        filter :status, :select do
          options fn ->
            [
              {dgettext("mishka_gervaz", "Active"), :active},
              {dgettext("mishka_gervaz", "Draft"), :draft}
            ]
          end

          ui do
            prompt dgettext_noop("mishka_gervaz", "All Statuses")
            label fn -> dgettext("mishka_gervaz", "Status") end
          end
        end

        filter :featured, :boolean do
          ui do
            label fn -> dgettext("mishka_gervaz", "Featured") end
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

      # The card draws these as the design's button row: one labelled primary, then icon-only squares.
      # `@primary_action_class` / `@icon_action_class` are in `MishkaDocument.Workspace`. Each is drawn
      # for the area whose page or write it leads to (`MishkaDocument.WorkspaceScope.shown?/3`).
      row_actions do
        # The card's labelled primary — the design leads the row with "open this workspace".
        action :open do
          type :link
          path fn record -> "/admin/dashboard/document/sections/workspace/#{record.id}" end

          visible fn _record, state ->
            MishkaDocument.WorkspaceScope.shown?(
              state,
              :active,
              "admin:dashboard:document:section"
            )
          end

          ui do
            label fn -> dgettext("mishka_gervaz", "Open workspace") end
            icon "hero-arrow-right"
            class @primary_action_class
          end
        end

        # Links to sections page
        action :sections do
          type :link
          path fn record -> "/admin/dashboard/document/sections/workspace/#{record.id}" end

          visible fn _record, state ->
            MishkaDocument.WorkspaceScope.shown?(
              state,
              :active,
              "admin:dashboard:document:section"
            )
          end

          ui do
            label fn -> dgettext("mishka_gervaz", "Sections") end
            icon "hero-bars-3-bottom-left"
            class @icon_action_class
          end
        end

        # Link to workspace versions page
        action :versions do
          type :link
          path fn record -> "/admin/dashboard/document/workspace-version/#{record.id}" end

          visible fn _record, state ->
            MishkaDocument.WorkspaceScope.shown?(
              state,
              :active,
              "admin:dashboard:document:workspace"
            )
          end

          ui do
            label fn -> dgettext("mishka_gervaz", "Versions") end
            icon "hero-share"
            class @icon_action_class
          end
        end

        action :edit do
          type :edit

          visible fn _record, state ->
            MishkaDocument.WorkspaceScope.shown?(
              state,
              :active,
              "admin:dashboard:document:workspace"
            )
          end

          js fn _record -> MishkaCmsCore.CoreComponents.show_modal("workspace-form-modal") end

          ui do
            label fn -> dgettext("mishka_gervaz", "Edit") end
            icon "hero-pencil"
            class @icon_action_class
          end
        end

        action :delete do
          type :destroy

          confirm fn _record ->
            dgettext("mishka_gervaz", "Archive this workspace?")
          end

          visible fn _record, state ->
            MishkaDocument.WorkspaceScope.shown?(
              state,
              :active,
              "admin:dashboard:document:workspace"
            )
          end

          ui do
            label fn -> dgettext("mishka_gervaz", "Archive") end
            icon "hero-trash"
            class @danger_action_class
          end
        end

        action :unarchive do
          type :unarchive

          confirm fn _record ->
            dgettext("mishka_gervaz", "Restore this workspace?")
          end

          visible fn _record, state ->
            MishkaDocument.WorkspaceScope.shown?(
              state,
              :archived,
              "admin:dashboard:document:workspace"
            )
          end

          ui do
            label fn -> dgettext("mishka_gervaz", "Restore") end
            icon "hero-arrow-path"
            class @primary_action_class
          end
        end

        action :permanent_destroy do
          type :permanent_destroy

          confirm fn _record ->
            dgettext("mishka_gervaz", "Permanently delete? This cannot be undone.")
          end

          visible fn _record, state ->
            MishkaDocument.WorkspaceScope.shown?(
              state,
              :archived,
              "admin:dashboard:document:workspace"
            )
          end

          ui do
            label fn -> dgettext("mishka_gervaz", "Delete") end
            icon "hero-trash"
            class @danger_action_class
          end
        end
      end

      row do
        selectable true
      end

      # Writing a workspace is the workspace area's; a section admin opens the table to reach sections.
      bulk_actions do
        action :archive,
          type: :destroy,
          confirm: dgettext_noop("mishka_gervaz", "Archive selected workspaces?"),
          visible:
            &MishkaDocument.WorkspaceScope.shown?(
              &1,
              :active,
              "admin:dashboard:document:workspace"
            )

        action :unarchive,
          type: :unarchive,
          confirm: dgettext_noop("mishka_gervaz", "Restore selected?"),
          visible:
            &MishkaDocument.WorkspaceScope.shown?(
              &1,
              :archived,
              "admin:dashboard:document:workspace"
            )

        action :permanent_destroy,
          type: :permanent_destroy,
          confirm: dgettext_noop("mishka_gervaz", "Permanently delete?"),
          visible:
            &MishkaDocument.WorkspaceScope.shown?(
              &1,
              :archived,
              "admin:dashboard:document:workspace"
            )
      end

      events do
        bulk_action MishkaCmsCore.LanguageEditions.BulkActionHandler
      end

      hooks do
        # One row per document, not one per translation — see `MishkaDocument.WorkspaceScope`. This
        # belongs here rather than on the read action because only a hook runs late enough to see
        # whether a search is active, and a search must reach every language. A live update is asked
        # of the same read, and `on_realtime` redraws a translation's master.
        on_load fn query, state ->
          {:cont,
           query
           |> MishkaDocument.WorkspaceScope.scope_to_masters(state)
           |> MishkaDocument.WorkspaceScope.load_edition_progress(state)}
        end

        on_realtime fn notification, socket ->
          MishkaCmsCore.LanguageEditions.on_realtime(notification, socket)
        end

        # A delete refused because the workspace's translations are live answers with an alert that
        # offers to archive — or delete for good — those translations at once. See
        # `MishkaCmsCore.LanguageEditions`.
        on_row_action_error [:delete, :permanent_destroy],
                            &MishkaCmsCore.LanguageEditions.on_delete_refused/3

        on_bulk_action_error [:archive, :permanent_destroy],
                             &MishkaCmsCore.LanguageEditions.on_delete_refused/3

        on_bulk_action_success [:archive, :permanent_destroy],
                               &MishkaCmsCore.LanguageEditions.on_delete_refused/3
      end

      realtime do
        prefix "workspace"
      end

      url_sync do
        mode :bidirectional
        params [:filters, :sort, :page, :search]
        prefix "workspaces"
        max_filter_length 500
      end

      presentation do
        template MishkaDocumentWeb.Templates.DocumentCard
        ui_adapter MishkaCmsCoreWeb.UIAdapters.Admin
      end

      empty_state message: dgettext_noop("mishka_gervaz", "No workspaces found"),
                  icon: "hero-folder-open"
    end

    form do
      identity do
        name :workspace_form
      end

      fields do
        field :site_id, :relation do
          display_field :name
          search_field :name
          mode :search
          min_chars 1
          page_size 15
          required true
          restricted true
          show_on :create

          ui do
            label fn -> dgettext("mishka_gervaz", "Site") end
          end
        end

        field :name do
          required true

          ui do
            label fn -> dgettext("mishka_gervaz", "Name") end
          end
        end

        field :slug do
          required true

          ui do
            label fn -> dgettext("mishka_gervaz", "Slug") end
          end
        end

        field :status, :select do
          required true

          options fn ->
            [
              {dgettext("mishka_gervaz", "Active"), :active},
              {dgettext("mishka_gervaz", "Draft"), :draft}
            ]
          end

          ui do
            label fn -> dgettext("mishka_gervaz", "Status") end
          end
        end

        field :language, :combobox do
          required true

          options fn ->
            case Ecto.Adapters.SQL.query(
                   @repo,
                   "SELECT DISTINCT language FROM mishka_document_workspaces WHERE language IS NOT NULL ORDER BY language"
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
          value_field :language_group_id
          display_field fn record -> "#{record.name} (#{record.language})" end
          search_field :name
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

        field :description, :textarea do
          ui do
            label fn -> dgettext("mishka_gervaz", "Description") end
            rows 3
          end
        end

        field :display_order, :number do
          ui do
            label fn -> dgettext("mishka_gervaz", "Display Order") end
          end
        end

        field :featured, :toggle do
          ui do
            label fn -> dgettext("mishka_gervaz", "Featured") end
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

        field :schema do
          ui do
            label fn -> dgettext("mishka_gervaz", "Schema (JSON)") end
            placeholder ~s([{"@type": "CollectionPage", "name": "My Workspace"}])
          end
        end

        # WHO MAY OPEN THE DOCUMENT: any of the permission names that exist, stored by name. Empty,
        # it is public. The page that shows it, and each page of it that names none of its own, opens
        # only for whoever holds one (`MishkaDocument.Plugins.PageSeo`).
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
                "Who may open this document: anyone holding one of these. None: everyone."
              )
            end
          end
        end
      end

      groups do
        group :basic_info do
          fields [:site_id, :name, :slug, :status]

          ui do
            label fn -> dgettext("mishka_gervaz", "Basic Information") end
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

        group :details do
          fields [:description]

          ui do
            label fn -> dgettext("mishka_gervaz", "Details") end
            columns 1
          end
        end

        group :settings do
          fields [:display_order, :featured, :seo_tags, :permissions]

          ui do
            label fn -> dgettext("mishka_gervaz", "Settings") end
            columns 2
          end
        end
      end

      hooks do
        # While a workspace is added, its slug follows the name until the author types one.
        on_validate fn params, state ->
          MishkaCmsCore.Runtime.Helpers.follow_slug(params, state, :name)
        end

        on_cancel fn state -> state end
      end
    end
  end

  guardedstruct do
    auto_wire true

    field :name, :string,
      validator: {MishkaCmsCore.PlainText, :field},
      derives: "sanitize(trim) validate(string, not_empty, min_len=1, max_len=255)"

    field :slug, :string,
      derives: "sanitize(trim) validate(string, not_empty, min_len=1, max_len=255)"

    field :description, :string,
      validator: {MishkaCmsCore.PlainText, :field},
      derives: "sanitize(trim) validate(optional=[string, max_len=2000])"

    field :status, :atom, derives: "validate(atom, enum=Atom[active::archived::draft])"

    field :schema, {:array, :map}, derives: "validate(list)"
    field :seo_tags, {:array, :map}, derives: "validate(list)"

    field :permissions, {:array, :string},
      derives: "sanitize(each=[trim, downcase], reject_empty, uniq) validate(list)"

    field :featured, :boolean, derives: "validate(boolean)"
    field :display_order, :integer, derives: "validate(optional=[integer, min_len=0])"

    field :language, :string,
      derives: "sanitize(trim, downcase) validate(optional=[string, max_len=20, language_code])"

    field :language_group_id, :uuid, derives: "validate(optional=[uuid])"
  end

  # Field-level authorization policies
  field_policies do
    # Admin-only fields. `maintainers_info` names the accounts that wrote the workspace by their
    # email addresses, and the public workspace routes are anonymous. Either document area reads
    # them, as it reads the workspace.
    field_policy [:health_metrics, :maintainers_info] do
      authorize_if {MishkaCmsCore.Accounts.Checks.AccessPermissions,
                    permissions: [
                      "admin:dashboard:document:workspace",
                      "admin:api:document:workspace",
                      "admin:dashboard:document:section",
                      "admin:api:document:section"
                    ]}
    end

    # All other fields are publicly accessible
    field_policy :* do
      authorize_if always()
    end
  end

  actions do
    read :read do
      primary? true

      pagination offset?: true,
                 default_limit: 20,
                 max_page_size: 100,
                 countable: true,
                 required?: false
    end

    default_accept @admin_fields

    create :create do
      primary? true
      accept List.delete(@admin_fields, :site_id)

      validate present(:name)
      validate present(:slug)
      validate present(:status)
      validate present(:language)

      validate {MishkaCmsCore.Runtime.Resources.Validations.TenantContext, require_master: false}

      validate {MishkaCmsCore.Runtime.Resources.Validations.TenantIsolation,
                field: :language_group_id, resource: MishkaDocument.Workspace}

      change &Ash.Changeset.force_change_attribute(&1, :site_id, &2.tenant)
      change MishkaCmsCore.Runtime.Resources.Changes.SetLanguageGroupId
      change slugify(:slug, into: :slug, ignore: [".", "!", "?"])

      # Add metadata for event tracking
      change fn changeset, context ->
        Ash.Changeset.put_context(changeset, :ash_events_metadata, %{
          site_id: context.tenant,
          title: Ash.Changeset.get_attribute(changeset, :name)
        })
      end

      description "Creates workspace for tenant users - requires tenant context, auto-assigns site_id and language_group_id. Versions are added by creating WorkspaceVersion records with workspace_id."
    end

    create :master_create do
      validate present(:name)
      validate present(:slug)
      validate present(:status)
      validate present(:language)
      validate present(:site_id)

      validate {MishkaCmsCore.Runtime.Resources.Validations.TenantContext, require_master: true}

      change fn changeset, _context ->
        site_id = Ash.Changeset.get_attribute(changeset, :site_id)
        Ash.Changeset.set_tenant(changeset, site_id)
      end

      change MishkaCmsCore.Runtime.Resources.Changes.SetLanguageGroupId
      change slugify(:slug, into: :slug, ignore: [".", "!", "?"])

      # Add metadata for event tracking
      change fn changeset, _context ->
        Ash.Changeset.put_context(changeset, :ash_events_metadata, %{
          site_id: Ash.Changeset.get_attribute(changeset, :site_id),
          title: Ash.Changeset.get_attribute(changeset, :name)
        })
      end

      description "Creates workspace for master users - bypasses multi-tenancy, requires explicit site_id, auto-assigns language_group_id. Versions are added by creating WorkspaceVersion records with workspace_id."
    end

    update :update do
      primary? true
      require_atomic? false
      transaction? true
      accept List.delete(@admin_fields, :site_id)

      validate {MishkaCmsCore.Runtime.Resources.Validations.TenantContext, require_master: false}

      validate {MishkaCmsCore.Runtime.Resources.Validations.TenantIsolation,
                field: :language_group_id, resource: MishkaDocument.Workspace},
               where: [changing(:language_group_id)]

      validate absent(:archived_at) do
        message dgettext_noop(
                  "errors",
                  "Cannot edit archived workspace. Please unarchive it first."
                )
      end

      change slugify(:slug, into: :slug, ignore: [".", "!", "?"])

      # Add metadata for event tracking
      change fn changeset, context ->
        Ash.Changeset.put_context(changeset, :ash_events_metadata, %{
          site_id: context.tenant || changeset.data.site_id,
          title: Ash.Changeset.get_attribute(changeset, :name) || changeset.data.name
        })
      end

      description "Updates workspace for tenant users - requires tenant context, prevents site_id changes. Versions are managed through WorkspaceVersion records."
    end

    update :master_update do
      description "Updates workspace for master users - bypasses multi-tenancy, prevents site_id changes. Versions are managed through WorkspaceVersion records."
      require_atomic? false
      transaction? true
      accept List.delete(@admin_fields, :site_id)
      multitenancy :bypass

      validate {MishkaCmsCore.Runtime.Resources.Validations.TenantContext, require_master: true}

      validate absent(:archived_at) do
        message dgettext_noop(
                  "errors",
                  "Cannot edit archived workspace. Please unarchive it first."
                )
      end

      change slugify(:slug, into: :slug, ignore: [".", "!", "?"])

      # Add metadata for event tracking
      change fn changeset, _context ->
        Ash.Changeset.put_context(changeset, :ash_events_metadata, %{
          site_id: changeset.data.site_id,
          title: Ash.Changeset.get_attribute(changeset, :name) || changeset.data.name
        })
      end
    end

    read :master_read do
      description "Reads all workspaces system-wide, bypassing tenant filtering (master users only)"
      multitenancy :bypass
      pagination offset?: true, default_limit: 20, max_page_size: 100, countable: true

      validate {MishkaCmsCore.Runtime.Resources.Validations.TenantContext, require_master: true}
    end

    read :master_get do
      multitenancy :bypass
      get? true
      description "Retrieves single workspace by ID, bypassing tenant filtering"

      validate {MishkaCmsCore.Runtime.Resources.Validations.TenantContext, require_master: true}
    end

    read :read_any do
      multitenancy :bypass
      description "Reads all workspaces bypassing tenant filtering (for master relationships)"

      pagination offset?: true,
                 default_limit: 20,
                 max_page_size: 100,
                 countable: true,
                 required?: false
    end

    read :language_variants do
      description "Retrieves all language variants of a workspace for hreflang tag generation"
      argument :language_group_id, :uuid, allow_nil?: false
      filter expr(language_group_id == ^arg(:language_group_id))

      validate {MishkaCmsCore.Runtime.Resources.Validations.TenantContext, require_master: false}
    end

    read :master_language_variants do
      multitenancy :bypass
      description "Retrieves all language variants system-wide (master users only)"
      argument :language_group_id, :uuid, allow_nil?: false
      filter expr(language_group_id == ^arg(:language_group_id))

      validate {MishkaCmsCore.Runtime.Resources.Validations.TenantContext, require_master: true}
    end

    read :public_list do
      description "Public endpoint to list all active workspaces (no authentication required)"
      filter expr(status == :active)

      pagination offset?: true,
                 default_limit: 20,
                 max_page_size: 100,
                 countable: true,
                 required?: false

      prepare {MishkaDocument.Resources.Preparations.OpenToActor, kind: :workspace}
    end

    read :public_get do
      description "Public endpoint to get a single active workspace by ID (no authentication required)"
      get? true
      filter expr(status == :active)
      prepare {MishkaDocument.Resources.Preparations.OpenToActor, kind: :workspace}
    end

    read :archived do
      filter expr(not is_nil(archived_at))
      pagination offset?: true, default_limit: 20, max_page_size: 100, countable: true

      validate {MishkaCmsCore.Runtime.Resources.Validations.TenantContext, require_master: false}

      description "Lists archived workspaces within current tenant context"
    end

    read :master_archived do
      multitenancy :bypass
      filter expr(not is_nil(archived_at))
      pagination offset?: true, default_limit: 20, max_page_size: 100, countable: true

      validate {MishkaCmsCore.Runtime.Resources.Validations.TenantContext, require_master: true}

      description "Lists all archived workspaces system-wide, bypassing tenant filtering"
    end

    read :get_archived do
      get? true
      filter expr(not is_nil(archived_at))

      validate {MishkaCmsCore.Runtime.Resources.Validations.TenantContext, require_master: false}

      description "Retrieves single archived workspace for recovery or inspection (tenant users)"
    end

    read :master_get_archived do
      get? true
      multitenancy :bypass
      filter expr(not is_nil(archived_at))

      validate {MishkaCmsCore.Runtime.Resources.Validations.TenantContext, require_master: true}

      description "Retrieves single archived workspace for recovery or inspection (master users)"
    end

    destroy :destroy do
      description "Soft deletes workspace by archiving (tenant users)"
      primary? true
      require_atomic? false

      validate {MishkaCmsCore.Runtime.Resources.Validations.TenantContext, require_master: false}

      validate fn changeset, _context ->
        if changeset.data.archived_at do
          {:error,
           field: :archived_at, message: dgettext_noop("errors", "Workspace is already archived.")}
        else
          :ok
        end
      end

      validate MishkaCmsCore.Runtime.Resources.Validations.PreventMasterLanguageDeletion

      change before_action(fn changeset, _context ->
               Ash.Changeset.force_change_attribute(changeset, :status, :archived)
             end)

      # Add metadata for event tracking
      change fn changeset, context ->
        Ash.Changeset.put_context(changeset, :ash_events_metadata, %{
          site_id: context.tenant || changeset.data.site_id,
          title: changeset.data.name
        })
      end
    end

    destroy :master_destroy do
      description "Soft deletes workspace by archiving (master users) - bypasses multi-tenancy"
      require_atomic? false
      multitenancy :bypass

      validate {MishkaCmsCore.Runtime.Resources.Validations.TenantContext, require_master: true}

      validate fn changeset, _context ->
        if changeset.data.archived_at do
          {:error,
           field: :archived_at, message: dgettext_noop("errors", "Workspace is already archived.")}
        else
          :ok
        end
      end

      validate MishkaCmsCore.Runtime.Resources.Validations.PreventMasterLanguageDeletion

      change before_action(fn changeset, _context ->
               Ash.Changeset.force_change_attribute(changeset, :status, :archived)
             end)

      # Add metadata for event tracking
      change fn changeset, _context ->
        Ash.Changeset.put_context(changeset, :ash_events_metadata, %{
          site_id: changeset.data.site_id,
          title: changeset.data.name
        })
      end
    end

    update :unarchive do
      accept []
      require_atomic? false

      validate {MishkaCmsCore.Runtime.Resources.Validations.TenantContext, require_master: false}

      change set_attribute(:archived_at, nil)
      change set_attribute(:status, :active)

      change MishkaCmsCore.Runtime.Resources.Changes.PreventOrphanedTranslationRestore

      # Add metadata for event tracking
      change fn changeset, context ->
        Ash.Changeset.put_context(changeset, :ash_events_metadata, %{
          site_id: context.tenant || changeset.data.site_id,
          title: changeset.data.name
        })
      end

      atomic_upgrade_with :archived

      description "Restores archived workspace to active status (tenant users)"
    end

    update :master_unarchive do
      description "Restores archived workspace to active status (master users) - bypasses multi-tenancy"
      accept []
      require_atomic? false
      multitenancy :bypass

      validate {MishkaCmsCore.Runtime.Resources.Validations.TenantContext, require_master: true}

      validate fn changeset, _context ->
        if is_nil(changeset.data.archived_at) do
          {:error,
           field: :archived_at, message: dgettext_noop("errors", "Workspace is not archived.")}
        else
          :ok
        end
      end

      change set_attribute(:archived_at, nil)
      change set_attribute(:status, :active)

      change MishkaCmsCore.Runtime.Resources.Changes.PreventOrphanedTranslationRestore

      # Add metadata for event tracking
      change fn changeset, _context ->
        Ash.Changeset.put_context(changeset, :ash_events_metadata, %{
          site_id: changeset.data.site_id,
          title: changeset.data.name
        })
      end
    end

    destroy :permanent_destroy do
      require_atomic? false

      validate {MishkaCmsCore.Runtime.Resources.Validations.TenantContext, require_master: false}

      validate MishkaCmsCore.Runtime.Resources.Validations.PreventMasterLanguageDeletion

      change fn changeset, context ->
        Ash.Changeset.put_context(changeset, :ash_events_metadata, %{
          site_id: context.tenant || changeset.data.site_id,
          title: changeset.data.name
        })
      end

      description "Permanently removes workspace from database (tenant users) - use with extreme caution"
    end

    destroy :master_permanent_destroy do
      description "Permanently removes workspace from database (master users) - bypasses multi-tenancy, irreversible"
      require_atomic? false
      multitenancy :bypass

      validate {MishkaCmsCore.Runtime.Resources.Validations.TenantContext, require_master: true}

      validate MishkaCmsCore.Runtime.Resources.Validations.PreventMasterLanguageDeletion

      change fn changeset, _context ->
        Ash.Changeset.put_context(changeset, :ash_events_metadata, %{
          site_id: changeset.data.site_id,
          title: changeset.data.name
        })
      end
    end
  end

  # Authorization policies for workspace access
  policies do
    # Allow public access to view active workspaces
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

    # The workspace area reads and writes workspaces. A section admin reads them on the dashboard,
    # where every section screen is drawn inside one; the admin API's workspace routes are the
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
  end

  pub_sub do
    module Application.compile_env!(:mishka_cms_core, :endpoint)
    prefix "workspace"

    publish :create, [[nil, :site_id], "created"]
    publish :update, [[nil, :site_id], "updated"]
    publish :unarchive, [[nil, :site_id], "updated"]
    publish :destroy, [[nil, :site_id], "destroyed"]
    publish :permanent_destroy, [[nil, :site_id], "destroyed"]

    # Master actions (same topics, different actions)
    publish :master_create, [[nil, :site_id], "created"]
    publish :master_update, [[nil, :site_id], "updated"]
    publish :master_unarchive, [[nil, :site_id], "updated"]
    publish :master_destroy, [[nil, :site_id], "destroyed"]
    publish :master_permanent_destroy, [[nil, :site_id], "destroyed"]
  end

  # Every id this record holds names a record of its own site, whoever writes it.
  validations do
    validate {MishkaCmsCore.Runtime.Resources.Validations.SameSiteReference,
              field: :language_group_id,
              resource: MishkaDocument.Workspace,
              label: dgettext_noop("errors", "language group"),
              read_action: :master_get},
             where: [changing(:language_group_id)],
             only_when_valid?: true
  end

  # Multi-tenancy configuration - workspaces are always site-specific
  multitenancy do
    strategy :attribute
    attribute :site_id
    # Workspaces are NEVER global - always site-specific
    global? false
  end

  attributes do
    uuid_primary_key :id

    attribute :name, :string do
      allow_nil? false
      public? true
      constraints min_length: 1, max_length: 255, trim?: true
      description "Name of the workspace"
    end

    attribute :slug, :string do
      allow_nil? false
      public? true
      constraints min_length: 1, max_length: 255, trim?: true
      description "URL-friendly slug for the workspace"
    end

    attribute :description, :string do
      allow_nil? true
      public? true
      constraints max_length: 2000, trim?: true
      description "Optional description of the workspace"
    end

    attribute :status, :atom do
      allow_nil? false
      public? true
      default :draft
      constraints one_of: [:active, :archived, :draft]
      description "Status of the workspace (active, archived, draft)"
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
      description "Permission strings required to open this document on its page"
    end

    attribute :featured, :boolean do
      default false
      public? true
      description "Whether the workspace is featured"
    end

    attribute :display_order, :integer do
      allow_nil? true
      public? true
      default 0
      constraints min: 0
      description "Sorting position for display ordering"
    end

    attribute :language, :string do
      allow_nil? false
      public? true
      default "en"
      constraints trim?: true, max_length: 10
      description "Primary language of the workspace (ISO 639-1 code, e.g., en, fa, ar, ru)"
    end

    attribute :language_group_id, :uuid do
      allow_nil? true
      public? true
      description "Shared ID linking all language variants of this workspace together"
    end

    create_timestamp :inserted_at
    update_timestamp :updated_at
  end

  relationships do
    belongs_to :site, MishkaCmsCore.Runtime.Site do
      read_action :read_any
      allow_nil? false
      public? true
      description "The site this workspace belongs to"
    end

    # Relationship - for admin users with tenant
    has_many :language_variants, MishkaDocument.Workspace do
      public? true
      destination_attribute :language_group_id
      source_attribute :language_group_id
      description "All language variants (translations) of this workspace"
    end

    # Bypass relationship - for master admin users without tenant
    has_many :master_language_variants, MishkaDocument.Workspace do
      public? true
      destination_attribute :language_group_id
      source_attribute :language_group_id
      read_action :read_any

      description "All language variants of this workspace (master admin access, bypass tenant)"

      filter expr(not is_nil(type(^actor(:id), :uuid)) and is_nil(type(^actor(:site_id), :uuid)))
    end

    # Relationship - for public users (guests/users without permissions)
    has_many :versions, MishkaDocument.WorkspaceVersion do
      public? true
      destination_attribute :workspace_id
      read_action :public_list
      description "Published stable versions of this workspace (public access)"
    end

    # Relationship - for admin users with tenant
    has_many :tenant_versions, MishkaDocument.WorkspaceVersion do
      public? true
      destination_attribute :workspace_id
      description "All versions of this workspace (tenant admin access)"
    end

    # Bypass relationship - for master admin users without tenant
    has_many :master_versions, MishkaDocument.WorkspaceVersion do
      public? true
      destination_attribute :workspace_id
      read_action :read_any
      description "All versions of this workspace (master admin access, bypass tenant)"

      filter expr(not is_nil(type(^actor(:id), :uuid)) and is_nil(type(^actor(:site_id), :uuid)))
    end
  end

  calculations do
    calculate :health_metrics, :map do
      public? true

      calculation fn records, _context ->
        to_int = fn
          nil -> 0
          %Decimal{} = decimal -> Decimal.to_integer(decimal)
          value when is_integer(value) -> value
        end

        Enum.map(records, fn record ->
          sql = """
          WITH section_count AS (
            SELECT
              COUNT(*) as sections_count
            FROM mishka_document_sections s
            JOIN mishka_document_workspace_versions wv ON s.workspace_version_id = wv.id
            WHERE wv.workspace_id = $1
              AND s.site_id = $2
              AND s.archived_at IS NULL
          ),
          current_month AS (
            SELECT
              -- Count total active items (sections + notes)
              COUNT(*) FILTER (WHERE entity_type IN ('section', 'note')) as total_items,
              -- Count approved items (both content and technical review approved)
              COUNT(*) FILTER (
                WHERE entity_type IN ('section', 'note')
                AND content_review_status = 'approved'
                AND technical_review_status = 'approved'
              ) as approved_items
            FROM (
              -- Sections
              SELECT
                'section' as entity_type,
                content_review_status,
                technical_review_status
              FROM mishka_document_sections s
              JOIN mishka_document_workspace_versions wv ON s.workspace_version_id = wv.id
              WHERE wv.workspace_id = $1
                AND s.site_id = $2
                AND s.archived_at IS NULL

              UNION ALL

              -- Notes (through sections)
              SELECT
                'note' as entity_type,
                n.content_review_status,
                n.technical_review_status
              FROM mishka_document_notes n
              JOIN mishka_document_sections s ON n.section_id = s.id
              JOIN mishka_document_workspace_versions wv ON s.workspace_version_id = wv.id
              WHERE wv.workspace_id = $1
                AND n.site_id = $2
                AND n.archived_at IS NULL

              UNION ALL

              -- Section Drafts (count as items needing review)
              SELECT
                'section' as entity_type,
                sd.content_review_status,
                sd.technical_review_status
              FROM mishka_document_section_drafts sd
              JOIN mishka_document_sections s ON sd.source_section_id = s.id
              JOIN mishka_document_workspace_versions wv ON s.workspace_version_id = wv.id
              WHERE wv.workspace_id = $1
                AND sd.site_id = $2
                AND sd.archived_at IS NULL

              UNION ALL

              -- Note Drafts (count as items needing review)
              SELECT
                'note' as entity_type,
                content_review_status,
                technical_review_status
              FROM mishka_document_note_drafts nd
              JOIN mishka_document_workspace_versions wv ON nd.workspace_version_id = wv.id
              WHERE wv.workspace_id = $1
                AND nd.site_id = $2
                AND nd.archived_at IS NULL
            ) all_items
          ),
          last_month AS (
            SELECT
              COUNT(*) FILTER (WHERE entity_type IN ('section', 'note')) as total_items,
              COUNT(*) FILTER (
                WHERE entity_type IN ('section', 'note')
                AND content_review_status = 'approved'
                AND technical_review_status = 'approved'
              ) as approved_items
            FROM (
              -- Sections updated before this month
              SELECT
                'section' as entity_type,
                content_review_status,
                technical_review_status
              FROM mishka_document_sections s
              JOIN mishka_document_workspace_versions wv ON s.workspace_version_id = wv.id
              WHERE wv.workspace_id = $1
                AND s.site_id = $2
                AND s.archived_at IS NULL
                AND s.updated_at < date_trunc('month', CURRENT_DATE)

              UNION ALL

              -- Notes updated before this month (through sections)
              SELECT
                'note' as entity_type,
                n.content_review_status,
                n.technical_review_status
              FROM mishka_document_notes n
              JOIN mishka_document_sections s ON n.section_id = s.id
              JOIN mishka_document_workspace_versions wv ON s.workspace_version_id = wv.id
              WHERE wv.workspace_id = $1
                AND n.site_id = $2
                AND n.archived_at IS NULL
                AND n.updated_at < date_trunc('month', CURRENT_DATE)
            ) last_month_items
          ),
          issue_stats AS (
            SELECT
              COUNT(*) as total_issues,
              COUNT(*) FILTER (WHERE status = 'open') as open_issues,
              COUNT(*) FILTER (WHERE status = 'resolved') as resolved_issues
            FROM mishka_document_issues
            WHERE site_id = $2
            AND (
              section_id IN (
                SELECT s.id
                FROM mishka_document_sections s
                JOIN mishka_document_workspace_versions wv ON s.workspace_version_id = wv.id
                WHERE wv.workspace_id = $1 AND s.site_id = $2
              )
              OR note_id IN (
                SELECT n.id
                FROM mishka_document_notes n
                JOIN mishka_document_sections s ON n.section_id = s.id
                JOIN mishka_document_workspace_versions wv ON s.workspace_version_id = wv.id
                WHERE wv.workspace_id = $1 AND n.site_id = $2
              )
            )
            AND archived_at IS NULL
          ),
          contributor_stats AS (
            SELECT
              COUNT(DISTINCT created_by_user_id) as total_contributors,
              COUNT(DISTINCT created_by_user_id) FILTER (
                WHERE updated_at >= NOW() - INTERVAL '24 hours'
              ) as active_today
            FROM (
              -- Section Drafts contributors
              SELECT sd.created_by_user_id, sd.updated_at
              FROM mishka_document_section_drafts sd
              JOIN mishka_document_workspace_versions wv ON sd.workspace_version_id = wv.id
              WHERE wv.workspace_id = $1
                AND sd.site_id = $2
                AND sd.archived_at IS NULL
                AND sd.content_review_status = 'approved'
                AND sd.technical_review_status = 'approved'
                AND sd.created_by_user_id IS NOT NULL

              UNION ALL

              -- Note Drafts contributors
              SELECT nd.created_by_user_id, nd.updated_at
              FROM mishka_document_note_drafts nd
              JOIN mishka_document_workspace_versions wv ON nd.workspace_version_id = wv.id
              WHERE wv.workspace_id = $1
                AND nd.site_id = $2
                AND nd.archived_at IS NULL
                AND nd.content_review_status = 'approved'
                AND nd.technical_review_status = 'approved'
                AND nd.created_by_user_id IS NOT NULL
            ) all_contributors
          )
          SELECT
            -- Current completion percentage
            CASE
              WHEN cm.total_items = 0 THEN 0
              ELSE ROUND((cm.approved_items::numeric / cm.total_items::numeric) * 100)
            END as completion,

            -- Last month completion percentage
            CASE
              WHEN lm.total_items = 0 THEN 0
              ELSE ROUND((lm.approved_items::numeric / lm.total_items::numeric) * 100)
            END as last_month_completion,

            -- Trend (difference between current and last month)
            CASE
              WHEN cm.total_items = 0 THEN 0
              WHEN lm.total_items = 0 THEN
                ROUND((cm.approved_items::numeric / cm.total_items::numeric) * 100)
              ELSE
                ROUND((cm.approved_items::numeric / cm.total_items::numeric) * 100) -
                ROUND((lm.approved_items::numeric / lm.total_items::numeric) * 100)
            END as trend,

            -- Quality score (sections/notes without open issues)
            CASE
              WHEN cm.total_items = 0 THEN 100
              WHEN ist.total_issues = 0 THEN 100
              ELSE ROUND(((cm.total_items - ist.open_issues)::numeric / cm.total_items::numeric) * 100)
            END as quality,

            -- Additional metrics
            cm.total_items as total_items,
            cm.approved_items as approved_items,
            ist.open_issues as open_issues,
            ist.resolved_issues as resolved_issues,

            -- Contributor metrics
            cs.total_contributors as contributors_count,
            cs.active_today as active_contributors_today,

            -- Section count
            sc.sections_count as sections_count
          FROM current_month cm, last_month lm, issue_stats ist, contributor_stats cs, section_count sc
          """

          {:ok, workspace_id_bin} = Ecto.UUID.dump(record.id)
          {:ok, site_id_bin} = Ecto.UUID.dump(record.site_id)
          result = Ecto.Adapters.SQL.query(@repo, sql, [workspace_id_bin, site_id_bin])

          case result do
            {:ok,
             %{
               rows: [
                 [
                   completion,
                   _last_month,
                   trend,
                   quality,
                   total,
                   approved,
                   open_issues,
                   resolved,
                   contributors,
                   active_today,
                   sections_count
                 ]
               ]
             }} ->
              %{
                completion: to_int.(completion) || 0,
                trend: to_int.(trend) || 0,
                quality: to_int.(quality) || 100,
                total_items: to_int.(total) || 0,
                approved_items: to_int.(approved) || 0,
                open_issues: to_int.(open_issues) || 0,
                resolved_issues: to_int.(resolved) || 0,
                contributors_count: to_int.(contributors) || 0,
                active_contributors_today: to_int.(active_today) || 0,
                sections_count: to_int.(sections_count) || 0
              }

            _ ->
              %{
                completion: 0,
                trend: 0,
                quality: 100,
                total_items: 0,
                approved_items: 0,
                open_issues: 0,
                resolved_issues: 0,
                contributors_count: 0,
                active_contributors_today: 0,
                sections_count: 0
              }
          end
        end)
      end

      description """
      Returns workspace health metrics including:
      - completion: Percentage of sections/notes fully approved (0-100)
      - trend: Change in completion from last month (+/- percentage points)
      - quality: Percentage of items without open issues (0-100)
      - total_items: Total sections + notes (including drafts)
      - approved_items: Count of fully approved items
      - open_issues: Count of unresolved issues
      - resolved_issues: Count of resolved issues
      - contributors_count: Total unique contributors with approved drafts
      - active_contributors_today: Contributors with drafts approved in the last 24 hours
      - sections_count: Total count of all sections in the workspace
      """
    end

    calculate :maintainers_info,
              :map,
              MishkaDocument.Resources.Calculations.WorkspaceMaintainers do
      public? true

      description """
      Returns maintainer information based on EventLog.
      Maintainers are users who have successfully created or updated Sections/Notes.
      Returns: %{count: integer, maintainers: [%{user_id: uuid, email: string}]}
      """
    end
  end

  aggregates do
    # The card shows a version count beside its section count. An aggregate joins it into the page's
    # own query — `health_metrics` already costs one multi-CTE query per row, so this must not add
    # another.
    count :versions_count, :tenant_versions do
      public? true
      description "How many versions this workspace has"
    end

    # Versions are themselves tenant-scoped, so a master counting through `tenant_versions` asks for a
    # tenant it does not have. Same split as the relationships above, aliased back to one key.
    count :master_versions_count, :master_versions do
      public? true
      description "How many versions this workspace has (master admin access, bypass tenant)"
    end

    # The card's tag chips. A workspace has no tags of its own — its sections carry them — so this
    # gathers the names three relationships away. A `list` aggregate joins them into the page's own
    # query rather than costing a read per card.
    list :tag_names, [:tenant_versions, :tenant_sections, :tenant_tags], :name do
      public? true
      uniq? true
      description "Names of every tag on this workspace's sections"
    end

    list :master_tag_names, [:master_versions, :master_sections, :master_tags], :name do
      public? true
      uniq? true
      description "Names of every tag on this workspace's sections (master access, bypass tenant)"
    end
  end

  identities do
    identity :unique_slug_per_site, [:slug, :site_id] do
      description "Ensures workspace slugs are unique within each site for clear identification"
      message dgettext_noop("errors", "Workspace slug must be unique within a site.")
      all_tenants? true
      nils_distinct? false
    end

    identity :unique_language_per_group, [:language, :language_group_id, :site_id] do
      description "Ensures each language appears only once per language group within a site"

      message dgettext_noop(
                "errors",
                "A workspace with this language already exists in this language group."
              )

      all_tenants? true
      nils_distinct? false
    end
  end

  # A `requires`-selected aggregate or calculation arrives as a truthy `%Ash.NotLoaded{}` or
  # `%Ash.ForbiddenField{}` when the viewer's field policy hides it, so `|| 0` lets the struct
  # through. Matching on the integer is what actually guards the cell.
  @spec counted(term()) :: non_neg_integer()
  defp counted(value) when is_integer(value) and value >= 0, do: value
  defp counted(_unloaded), do: 0

  # `health_metrics` is field-policy gated, so a viewer who cannot see it gets a struct rather than
  # the map — reading a figure off it has to survive that.
  @spec metric(term(), atom()) :: non_neg_integer()
  defp metric(metrics, key) when is_map(metrics) and not is_struct(metrics),
    do: counted(Map.get(metrics, key))

  defp metric(_unloaded, _key), do: 0

  @spec maintainer_count(term()) :: non_neg_integer()
  defp maintainer_count(%{"count" => count}) when is_integer(count) and count >= 0, do: count
  defp maintainer_count(_unavailable), do: 0

  @spec inserted_on(term()) :: String.t()
  defp inserted_on(at) when is_struct(at, DateTime) or is_struct(at, NaiveDateTime),
    do: Calendar.strftime(at, "%b %d, %Y", abbreviated_month_names: &short_month_name/1)

  defp inserted_on(_missing), do: "—"

  defp short_month_name(1), do: gettext("Jan")
  defp short_month_name(2), do: gettext("Feb")
  defp short_month_name(3), do: gettext("Mar")
  defp short_month_name(4), do: gettext("Apr")
  defp short_month_name(5), do: gettext("May")
  defp short_month_name(6), do: gettext("Jun")
  defp short_month_name(7), do: gettext("Jul")
  defp short_month_name(8), do: gettext("Aug")
  defp short_month_name(9), do: gettext("Sep")
  defp short_month_name(10), do: gettext("Oct")
  defp short_month_name(11), do: gettext("Nov")
  defp short_month_name(12), do: gettext("Dec")
end
