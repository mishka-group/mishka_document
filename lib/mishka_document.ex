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
    resource MishkaDocument.EventLog
  end
end
