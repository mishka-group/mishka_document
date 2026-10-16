# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_document/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaDocument do
  use Ash.Domain,
    otp_app: :mishka_document,
    validate_config_inclusion?: false,
    extensions: [
      AshJsonApi.Domain,
      MishkaGervaz.Domain
    ]

  use MishkaGervaz.Messages, backend: MishkaCmsCore.Gettext

  json_api do
    open_api do
      tag "MishkaDocument"
      group_by :domain
    end

    routes do
      base_route "/v1/master/admin/mishka-document/workspace", MishkaDocument.Workspace do
        index :master_read
        get :master_read
        index :master_language_variants, route: "/language-variants"
        index :master_archived, route: "/archived"
        get :master_archived, route: "/archived/:id"
        post :master_create
        patch :master_update, read_action: :master_get
        patch :master_unarchive, route: "/:id/unarchive", read_action: :master_get_archived
        delete :master_destroy, route: "/:id/archive", read_action: :master_get
        delete :master_permanent_destroy, route: "/:id/permanent", read_action: :master_get
      end

      base_route "/v1/tenant/admin/mishka-document/workspace", MishkaDocument.Workspace do
        index :read
        get :read
        index :language_variants, route: "/language-variants"
        index :archived, route: "/archived"
        get :archived, route: "/archived/:id"
        post :create
        patch :update
        patch :unarchive, route: "/:id/unarchive", read_action: :get_archived
        delete :destroy, route: "/:id/archive"
        delete :permanent_destroy, route: "/:id/permanent"
      end

      base_route "/v1/master/admin/mishka-document/workspace-version",
                 MishkaDocument.WorkspaceVersion do
        index :master_read
        get :master_get
        index :master_by_workspace, route: "/workspace/:workspace_id"
        post :master_create
        patch :master_update, read_action: :master_get
        delete :master_destroy, read_action: :master_get
      end

      base_route "/v1/tenant/admin/mishka-document/workspace-version",
                 MishkaDocument.WorkspaceVersion do
        index :read
        get :read
        index :by_workspace, route: "/workspace/:workspace_id"
        index :latest_versions, route: "/latest"
        index :by_status, route: "/status/:status"
        post :create
        patch :update
        patch :publish, route: "/:id/publish"
        patch :mark_as_latest, route: "/:id/mark-latest"
        delete :destroy
      end

      base_route "/v1/master/admin/mishka-document/workspace-version-lineage",
                 MishkaDocument.WorkspaceVersionLineage do
        index :master_read
        get :master_get
        index :master_by_new_version, route: "/new-version/:new_version_id"
        index :master_by_source_version, route: "/source-version/:source_version_id"
        index :master_by_date_range, route: "/date-range"
        index :master_recent_clones, route: "/recent"
        post :master_create
        patch :master_update, read_action: :master_get
        delete :master_destroy, read_action: :master_get
      end

      base_route "/v1/tenant/admin/mishka-document/workspace-version-lineage",
                 MishkaDocument.WorkspaceVersionLineage do
        index :read
        get :read
        index :by_new_version, route: "/new-version/:new_version_id"
        index :by_source_version, route: "/source-version/:source_version_id"
        index :by_date_range, route: "/date-range"
        index :recent_clones, route: "/recent"
        post :create
        patch :update
        delete :destroy
      end

      base_route "/v1/master/admin/mishka-document/section", MishkaDocument.Section do
        index :master_read
        get :master_get
        index :master_archived, route: "/archived"
        get :master_get_archived, route: "/archived/:id"
        post :master_create
        patch :master_update, read_action: :master_get
        patch :master_unarchive, route: "/:id/unarchive", read_action: :master_get_archived
        delete :master_destroy, route: "/:id/archive", read_action: :master_get
        delete :master_permanent_destroy, route: "/:id/permanent", read_action: :master_get
      end

      base_route "/v1/tenant/admin/mishka-document/section", MishkaDocument.Section do
        index :read
        get :read
        index :archived, route: "/archived"
        get :get_archived, route: "/archived/:id"
        post :create
        patch :update
        patch :unarchive, route: "/:id/unarchive", read_action: :get_archived
        delete :destroy, route: "/:id/archive"
        delete :permanent_destroy, route: "/:id/permanent"
      end

      base_route "/v1/master/admin/mishka-document/note", MishkaDocument.Note do
        index :master_read
        get :master_get
        index :master_archived, route: "/archived"
        get :master_get_archived, route: "/archived/:id"
        post :master_create
        patch :master_update, read_action: :master_get
        patch :master_unarchive, route: "/:id/unarchive", read_action: :master_get_archived
        delete :master_destroy, route: "/:id/archive", read_action: :master_get
        delete :master_permanent_destroy, route: "/:id/permanent", read_action: :master_get
      end

      base_route "/v1/tenant/admin/mishka-document/note", MishkaDocument.Note do
        index :read
        get :read
        index :archived, route: "/archived"
        get :get_archived, route: "/archived/:id"
        post :create
        patch :update
        patch :unarchive, route: "/:id/unarchive", read_action: :get_archived
        delete :destroy, route: "/:id/archive"
        delete :permanent_destroy, route: "/:id/permanent"
      end

      base_route "/v1/master/admin/mishka-document/section-draft", MishkaDocument.SectionDraft do
        index :master_read
        get :master_get
        index :master_archived, route: "/archived"
        get :master_get_archived, route: "/archived/:id"
        post :master_create
        patch :master_update, read_action: :master_get
        patch :master_unarchive, route: "/:id/unarchive", read_action: :master_get_archived
        delete :master_destroy, route: "/:id/archive", read_action: :master_get
        delete :master_permanent_destroy, route: "/:id/permanent", read_action: :master_get
      end

      base_route "/v1/tenant/admin/mishka-document/section-draft", MishkaDocument.SectionDraft do
        index :read
        get :read
        index :archived, route: "/archived"
        get :get_archived, route: "/archived/:id"
        post :create
        patch :update
        patch :unarchive, route: "/:id/unarchive", read_action: :get_archived
        delete :destroy, route: "/:id/archive"
        delete :permanent_destroy, route: "/:id/permanent"
      end

      base_route "/v1/master/admin/mishka-document/note-draft", MishkaDocument.NoteDraft do
        index :master_read
        get :master_get
        index :master_archived, route: "/archived"
        get :master_get_archived, route: "/archived/:id"
        post :master_create
        patch :master_update, read_action: :master_get
        patch :master_unarchive, route: "/:id/unarchive", read_action: :master_get_archived
        delete :master_destroy, route: "/:id/archive", read_action: :master_get
        delete :master_permanent_destroy, route: "/:id/permanent", read_action: :master_get
      end

      base_route "/v1/tenant/admin/mishka-document/note-draft", MishkaDocument.NoteDraft do
        index :read
        get :read
        index :archived, route: "/archived"
        get :get_archived, route: "/archived/:id"
        post :create
        patch :update
        patch :unarchive, route: "/:id/unarchive", read_action: :get_archived
        delete :destroy, route: "/:id/archive"
        delete :permanent_destroy, route: "/:id/permanent"
      end

      base_route "/v1/master/admin/mishka-document/tag", MishkaDocument.Tag do
        index :master_read
        get :master_get
        index :master_archived, route: "/archived"
        get :master_get_archived, route: "/archived/:id"
        post :master_create
        patch :master_update, read_action: :master_get
        patch :master_unarchive, route: "/:id/unarchive", read_action: :master_get_archived
        delete :master_destroy, route: "/:id/archive", read_action: :master_get
        delete :master_permanent_destroy, route: "/:id/permanent", read_action: :master_get
      end

      base_route "/v1/tenant/admin/mishka-document/tag", MishkaDocument.Tag do
        index :read
        get :read
        index :archived, route: "/archived"
        get :get_archived, route: "/archived/:id"
        post :create
        patch :update
        patch :unarchive, route: "/:id/unarchive", read_action: :get_archived
        delete :destroy, route: "/:id/archive"
        delete :permanent_destroy, route: "/:id/permanent"
      end

      base_route "/v1/master/admin/mishka-document/issue", MishkaDocument.Issue do
        index :master_read
        get :master_get
        index :master_archived, route: "/archived"
        get :master_get_archived, route: "/archived/:id"
        post :master_create
        patch :master_update, read_action: :master_get
        patch :master_unarchive, route: "/:id/unarchive", read_action: :master_get_archived
        delete :master_destroy, route: "/:id/archive", read_action: :master_get
        delete :master_permanent_destroy, route: "/:id/permanent", read_action: :master_get
      end

      base_route "/v1/tenant/admin/mishka-document/issue", MishkaDocument.Issue do
        index :read
        get :read
        index :archived, route: "/archived"
        get :get_archived, route: "/archived/:id"
        post :create
        patch :update
        patch :mark_in_progress, route: "/:id/mark-in-progress"
        patch :mark_resolved, route: "/:id/mark-resolved"
        patch :mark_closed, route: "/:id/mark-closed"
        patch :reopen, route: "/:id/reopen"
        patch :unarchive, route: "/:id/unarchive", read_action: :get_archived
        delete :destroy, route: "/:id/archive"
        delete :permanent_destroy, route: "/:id/permanent"
      end

      base_route "/v1/master/admin/mishka-document/issue-comment", MishkaDocument.IssueComment do
        index :master_read
        get :master_get
        index :master_archived, route: "/archived"
        get :master_get_archived, route: "/archived/:id"
        post :master_create
        patch :master_update, read_action: :master_get
        patch :master_unarchive, route: "/:id/unarchive", read_action: :master_get_archived
        delete :master_destroy, route: "/:id/archive", read_action: :master_get
        delete :master_permanent_destroy, route: "/:id/permanent", read_action: :master_get
      end

      base_route "/v1/tenant/admin/mishka-document/issue-comment", MishkaDocument.IssueComment do
        index :read
        get :read
        index :archived, route: "/archived"
        get :get_archived, route: "/archived/:id"
        index :by_issue, route: "/by-issue/:issue_id"
        index :by_contributor, route: "/by-contributor/:contributor_id"
        post :create
        patch :update
        patch :unarchive, route: "/:id/unarchive", read_action: :get_archived
        delete :destroy, route: "/:id/archive"
        delete :permanent_destroy, route: "/:id/permanent"
      end

      base_route "/v1/user/mishka-document/workspace", MishkaDocument.Workspace do
        index :public_list
        get :public_get, route: "/:id"
      end

      base_route "/v1/user/mishka-document/workspace-follow", MishkaDocument.WorkspaceFollower do
        index :my_following, route: "/my-following"
        post :create
        patch :toggle_notifications
        delete :unfollow
      end

      base_route "/v1/user/mishka-document/workspace-version", MishkaDocument.WorkspaceVersion do
        index :public_list
        get :public_get, route: "/:id"
      end

      base_route "/v1/user/mishka-document/workspace-version-lineage",
                 MishkaDocument.WorkspaceVersionLineage do
        get :public_get, route: "/:id"
        index :public_by_new_version, route: "/new-version/:new_version_id"
        index :public_by_source_version, route: "/source-version/:source_version_id"
        index :public_recent_clones, route: "/recent"
      end

      base_route "/v1/user/mishka-document/section", MishkaDocument.Section do
        index :public_list
        get :public_get, route: "/:id"

        index :public_list_at_workspace_version,
          route: "/workspace/:workspace_version_id/version/:version_number"
      end

      base_route "/v1/user/mishka-document/section-bookmark", MishkaDocument.SectionBookmark do
        index :my_bookmarks, route: "/my-bookmarks"
        post :create
        delete :remove
      end

      base_route "/v1/user/mishka-document/tag", MishkaDocument.Tag do
        index :public_list
        get :public_get, route: "/:id"
      end
    end
  end

  mishka_gervaz do
    table do
      actor_key :current_user
      ui_adapter MishkaGervaz.UIAdapters.Tailwind

      pagination do
        type :numbered
        page_size 20
        page_size_options [20, 50, 100]
      end

      realtime do
        pubsub MishkaCmsCore.PubSub
      end

      actions do
        read {:master_read, :read}
        get {:master_get, :read}
        destroy {:master_destroy, :destroy}
      end

      archive do
        read_action {:master_archived, :archived}
        get_action {:master_get_archived, :get_archived}
        restore_action {:master_unarchive, :unarchive}
        destroy_action {:master_permanent_destroy, :permanent_destroy}
      end
    end

    form do
      actions do
        create {:master_create, :create}
        update {:master_update, :update}
        read {:master_get, :read}
      end

      submit do
        create label: fn -> dgettext("mishka_gervaz", "Create") end
        update label: fn -> dgettext("mishka_gervaz", "Save Changes") end
        cancel label: fn -> dgettext("mishka_gervaz", "Cancel") end
        position :bottom
      end
    end
  end

  resources do
    resource MishkaDocument.Workspace
    resource MishkaDocument.WorkspaceVersion
    resource MishkaDocument.WorkspaceVersionLineage
    resource MishkaDocument.Section
    resource MishkaDocument.Note
    resource MishkaDocument.SectionDraft
    resource MishkaDocument.NoteDraft
    resource MishkaDocument.Tag
    resource MishkaDocument.SectionTag
    resource MishkaDocument.Issue
    resource MishkaDocument.IssueComment
    resource MishkaDocument.SectionBookmark
    resource MishkaDocument.SectionView
    resource MishkaDocument.WorkspaceFollower
    resource MishkaDocument.EventLog
  end
end
