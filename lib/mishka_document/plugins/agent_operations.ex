# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_document/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaDocument.Plugins.AgentOperations do
  @moduledoc """
  The document extension's operations an agent receipt can be kept for, on the core's
  `agent:operations` event (`MishkaCmsCore.Agent.Operation`). Run one with
  `MishkaCmsCore.Agent.Receipts.run/3`:

      version
      |> Ash.Changeset.for_update(:publish, %{}, actor: admin, tenant: site.id)
      |> MishkaCmsCore.Agent.Receipts.run("document:workspace_version:publish", source: :agent)

  Each operation is one action and its master twin (a version's publish has none). A receipt is
  read by whoever holds the area on that site: workspaces and versions under
  `admin:<surface>:document:workspace`, pages, notes and their drafts under
  `admin:<surface>:document:section`. It is `:verified` when the action committed and a separate
  read of the row finds what the action is for.

  | Operation | Read back from the table | Also checked |
  |---|---|---|
  | `document:workspace_version:publish` | `stable`, with a publication time | broadcast, sitemap job |
  | `document:section_draft:update` | the review statuses and the applied time the action returned | the page the draft wrote, read back when both reviews approve it; broadcast |
  | `document:note_draft:update` | the review statuses and the applied time the action returned | the note the draft wrote, read back when both reviews approve it; broadcast |
  | `document:section:*`, `document:note:*` | `create`, `update`, `restore_version`: the title (and slug) the action returned; `destroy`: archived; `unarchive`: not archived; `permanent_destroy`: gone | broadcast, sitemap job for pages |
  | `document:workspace:*` | `create`, `update`: the name, slug and status the action returned; `destroy`, `unarchive`, `permanent_destroy` as above | broadcast, sitemap job |

  ## A draft's approval

  Approving a draft (both reviews `approved`) writes its page or note in the same action
  (`MishkaDocument.Resources.Changes.AutoApplySectionDraft`, `AutoApplyNoteDraft`). The
  `:page_written` and `:note_written` stages read the written row back: by its id for a draft of an
  existing one, by its version, slug and language for a new page, by its page and title for a new
  note. A draft that is not approved yet is skipped there (`:not_approved`); an approved one that
  was not applied is unverified (`:not_applied`), which is what a note draft waiting for its new
  page's draft shows, and a note whose new page is itself a draft is unverified
  (`:new_page_note`), since nothing names the note's row yet.
  """
  use MishkaCmsCore.Agent.Operation

  alias MishkaCmsCore.Agent.Operation
  alias MishkaCmsCore.Agent.Stages.{DbReadBack, JobEnqueued}

  alias MishkaDocument.{
    Note,
    NoteDraft,
    Section,
    SectionDraft,
    Workspace,
    WorkspaceVersion
  }

  @workspace_area ["admin:dashboard:document:workspace", "admin:api:document:workspace"]
  @section_area ["admin:dashboard:document:section", "admin:api:document:section"]
  @required [:action_committed, :db_read_back]
  @written [:dispatched, :validated, :action_committed]

  @archival %{
    destroy: [{:db_read_back, expect: [archived_at: :present]}],
    unarchive: [{:db_read_back, expect: [archived_at: :absent]}],
    permanent_destroy: [{:db_read_back, gone: true}]
  }

  @rows [
    {Section, "section", @section_area, [title: :claimed, slug: :claimed], true,
     [:create, :update, :restore_version]},
    {Note, "note", @section_area, [title: :claimed], false, [:create, :update, :restore_version]},
    {Workspace, "workspace", @workspace_area, [name: :claimed, slug: :claimed, status: :claimed],
     true, [:create, :update]}
  ]

  @operations [
                Operation.new!(%{
                  name: "document:workspace_version:publish",
                  description: "A workspace version published.",
                  resource: WorkspaceVersion,
                  action: :publish,
                  visibility: @workspace_area,
                  stages:
                    @written ++
                      [
                        {:db_read_back, expect: [status: :stable, published_at: :present]},
                        :broadcast_published,
                        JobEnqueued.sitemap()
                      ],
                  required: @required
                }),
                Operation.new!(%{
                  name: "document:section_draft:update",
                  description:
                    "A page draft edited or reviewed; approved twice, it writes its page.",
                  resource: SectionDraft,
                  action: :update,
                  master_action: :master_update,
                  visibility: @section_area,
                  stages:
                    @written ++
                      [
                        {:db_read_back,
                         expect: [
                           content_review_status: :claimed,
                           technical_review_status: :claimed,
                           applied_at: :claimed
                         ]},
                        {:side_effect, :page_written,
                         layer: :db, check: &__MODULE__.page_written/1},
                        :broadcast_published
                      ],
                  required: @required
                }),
                Operation.new!(%{
                  name: "document:note_draft:update",
                  description:
                    "A note draft edited or reviewed; approved twice, it writes its note.",
                  resource: NoteDraft,
                  action: :update,
                  master_action: :master_update,
                  visibility: @section_area,
                  stages:
                    @written ++
                      [
                        {:db_read_back,
                         expect: [
                           content_review_status: :claimed,
                           technical_review_status: :claimed,
                           applied_at: :claimed
                         ]},
                        {:side_effect, :note_written,
                         layer: :db, check: &__MODULE__.note_written/1},
                        :broadcast_published
                      ],
                  required: @required
                })
              ] ++
                for(
                  {resource, segment, area, claimed, sitemap?, writes} <- @rows,
                  {action, read_back} <-
                    Enum.map(writes, &{&1, [{:db_read_back, expect: claimed}]}) ++
                      Map.to_list(@archival),
                  do:
                    Operation.new!(%{
                      name: "document:#{segment}:#{action}",
                      resource: resource,
                      action: action,
                      master_action: :"master_#{action}",
                      visibility: area,
                      stages:
                        @written ++
                          read_back ++
                          [:broadcast_published] ++
                          if(sitemap?, do: [JobEnqueued.sitemap()], else: []),
                      required: @required
                    })
                )

  @impl MishkaCmsCore.Agent.Operation
  def operations, do: @operations

  @doc false
  # The page an approved page draft wrote, read back from the table.
  def page_written(%{result: {:ok, %SectionDraft{} = draft}} = ctx) do
    with :ok <- applied(draft) do
      by =
        case draft.source_section_id do
          nil ->
            [
              workspace_version_id: draft.workspace_version_id,
              slug: draft.slug,
              language: draft.language
            ]

          id ->
            [id: id]
        end

      DbReadBack.verify(%{ctx | result: nil},
        resource: Section,
        by: by,
        expect: [title: draft.title]
      )
    end
  end

  def page_written(_ctx), do: {:skip, :not_applicable}

  @doc false
  # The note an approved note draft wrote, read back from the table.
  def note_written(%{result: {:ok, %NoteDraft{} = draft}} = ctx) do
    with :ok <- applied(draft) do
      case {draft.source_note_id, draft.section_id} do
        {nil, nil} ->
          {:unverified, :new_page_note}

        {nil, section_id} ->
          DbReadBack.verify(%{ctx | result: nil},
            resource: Note,
            by: [section_id: section_id, title: draft.title],
            expect: [title: draft.title]
          )

        {id, _section_id} ->
          DbReadBack.verify(%{ctx | result: nil},
            resource: Note,
            by: [id: id],
            expect: [title: draft.title]
          )
      end
    end
  end

  def note_written(_ctx), do: {:skip, :not_applicable}

  defp applied(%{
         content_review_status: :approved,
         technical_review_status: :approved,
         applied_at: nil
       }),
       do: {:unverified, :not_applied}

  defp applied(%{content_review_status: :approved, technical_review_status: :approved}), do: :ok
  defp applied(_draft), do: {:skip, :not_approved}
end
