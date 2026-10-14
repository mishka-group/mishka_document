defmodule MishkaDocument.Resources.Changes.CloneVersion do
  @moduledoc """
  Writes a new version of a document as a copy of one of its versions: every page of the source
  with its notes and tags, in the source's tree, in one transaction with the new version itself.

  The version to copy is the action's `source_version_id` argument, read with the action's actor:
  under the action's tenant, or on any site for a master's action (`:master_get`). The new version
  is of the source's workspace and site, a draft, not the latest, and names the source as
  `source_version_id`; a `MishkaDocument.WorkspaceVersionLineage` row records the copy.

  ## What is copied

    * Every page the source's readers reach (`MishkaDocument.Section`'s `:copy`): its title, slug,
      content, order, the front page and group flags, its language, permissions, SEO tags,
      structured data, review statuses and change version, under the copy of its parent. The
      content facts are worked out again by the page's own changes. Each copy names the page it
      came from (`source_section_id`) and keeps that page's lineage (`section_lineage_id`). A page
      under an archived page is not reached by a reader of the source, and is not copied.
    * The language groups, remapped: each copy starts a group of its own, and once every page is
      written a copy whose source was grouped with another page of the source joins that page's
      copy's group (`MishkaDocument.Section`'s `:copy_language_group`). The copies of a group led
      from another version are grouped under one of them.
    * Every note of each copied page (`MishkaDocument.Note`'s `:copy`) and every tag on it
      (`MishkaDocument.SectionTag`'s `:assign`).
    * Drafts of pages and notes are not copied.

  The pages are read and written a tree level at a time, 50 rows a batch, through
  `Ash.bulk_create/4`; the notes and tags of 25 pages a batch. Every write is made with the
  action's actor, so it needs the section area as well as the workspace area. Any refusal or
  failure rolls the whole copy back.

  The returned version carries `cloned: %{pages: n, notes: n, tags: n}` in its metadata.

  ## The event

  Once the transaction is committed, `"document:version:cloned"` is fired through
  `MishkaInstaller.Event.Hook.call/3` with

      %{
        version_id: "…",
        source_version_id: "…",
        workspace_id: "…",
        site_id: "…",
        pages: 172,
        notes: 1004,
        tags: 30
      }

  and `meta: %{actor: actor, site_id: site_id}`. What a plugin answers is not used.

  ## Usage

      create :clone do
        accept [:version_number, :version_name, :description]
        argument :source_version_id, :uuid, allow_nil?: false
        change MishkaDocument.Resources.Changes.CloneVersion
      end
  """
  use Ash.Resource.Change
  use Gettext, backend: MishkaCmsCore.Gettext

  require Ash.Query

  alias MishkaDocument.{Note, Section, SectionTag, Tag, WorkspaceVersion, WorkspaceVersionLineage}
  alias MishkaInstaller.Event.Hook

  @event "document:version:cloned"

  @page_batch 50

  @note_pages 25

  @page_fields [
    :id,
    :parent_section_id,
    :front_page,
    :group_heading,
    :group_page,
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
    :section_lineage_id
  ]

  @copied_page_fields @page_fields -- [:id, :parent_section_id, :section_lineage_id]

  @note_fields [
    :id,
    :section_id,
    :title,
    :content,
    :order_position,
    :change_version,
    :content_review_status,
    :technical_review_status,
    :schema,
    :seo_tags
  ]

  @copied_note_fields @note_fields -- [:id, :section_id]

  @doc "The event fired after a version is cloned."
  @spec event() :: String.t()
  def event, do: @event

  @impl true
  def change(changeset, _opts, context) do
    case Ash.Changeset.get_argument(changeset, :source_version_id) do
      nil -> changeset
      source_id -> from_source(changeset, read_source(source_id, changeset, context), context)
    end
  end

  # The version to copy, read as the caller: under its tenant, or on any site for a master's action.
  defp read_source(id, %{tenant: nil}, context),
    do: version(Ash.get(WorkspaceVersion, id, [action: :master_get] ++ as_caller(context)))

  defp read_source(id, %{tenant: tenant}, context),
    do:
      version(
        Ash.get(WorkspaceVersion, id, [action: :read, tenant: tenant] ++ as_caller(context))
      )

  defp version({:ok, %WorkspaceVersion{} = source}), do: {:ok, source}
  defp version(_missing_or_refused), do: :error

  defp as_caller(context), do: [actor: context.actor, authorize?: context.authorize? != false]

  defp from_source(changeset, {:ok, source}, context) do
    changeset
    |> Ash.Changeset.force_change_attributes(%{
      workspace_id: source.workspace_id,
      source_version_id: source.id,
      site_id: source.site_id,
      status: :draft,
      is_latest_for_version: false,
      published_at: nil
    })
    |> Ash.Changeset.set_tenant(source.site_id)
    |> Ash.Changeset.put_context(:ash_events_metadata, %{
      site_id: source.site_id,
      title: Ash.Changeset.get_attribute(changeset, :version_number)
    })
    |> Ash.Changeset.after_action(fn _changeset, version ->
      copy(version, source, context)
    end)
    |> Ash.Changeset.after_transaction(fn _changeset, result ->
      announce(result, source, context.actor)
    end)
  end

  defp from_source(changeset, :error, _context) do
    Ash.Changeset.add_error(changeset,
      field: :source_version_id,
      message: dgettext_noop("errors", "The version to copy is not here.")
    )
  end

  defp copy(version, source, context) do
    opts = [tenant: version.site_id] ++ as_caller(context)

    with {:ok, outline} <- outline(source.id, opts),
         plan = plan(outline),
         {:ok, pages} <- copy_pages(plan, version, opts),
         :ok <- regroup(plan, opts),
         {:ok, notes} <- copy_notes(plan, opts),
         {:ok, tags} <- copy_tags(plan, opts),
         {:ok, _lineage} <- lineage(version, source, opts) do
      {:ok,
       Ash.Resource.put_metadata(version, :cloned, %{pages: pages, notes: notes, tags: tags})}
    end
  end

  # Every page of the source, as its id, its parent and its language group.
  defp outline(source_id, opts) do
    Section
    |> Ash.Query.for_read(:read, %{}, opts)
    |> Ash.Query.filter(workspace_version_id == ^source_id)
    |> Ash.Query.select([:id, :parent_section_id, :language_group_id])
    |> Ash.read(opts)
  end

  # The pages to copy a tree level at a time, top first, each with the id of its copy and the
  # language group its copy joins.
  defp plan(outline) do
    by_parent = Enum.group_by(outline, & &1.parent_section_id)
    levels = levels(Map.get(by_parent, nil, []), by_parent, [])
    kept = List.flatten(levels)
    copies = Map.new(kept, &{&1.id, Ash.UUID.generate()})

    %{
      levels: Enum.map(levels, fn level -> Enum.map(level, & &1.id) end),
      pages: Enum.map(kept, & &1.id),
      copies: copies,
      groups: groups(kept, copies)
    }
  end

  defp levels([], _by_parent, levels), do: Enum.reverse(levels)

  defp levels(level, by_parent, levels),
    do:
      level
      |> Enum.flat_map(&Map.get(by_parent, &1.id, []))
      |> levels(by_parent, [level | levels])

  # The group each copy joins, for the copies that join another's: a group led by a page of the
  # source is led by that page's copy. The copies of a group led from another version are led by
  # one of them that leads no group of the source, so no two groups meet in one; with none, each
  # keeps its own.
  defp groups(kept, copies) do
    leading =
      kept
      |> Enum.map(& &1.language_group_id)
      |> Enum.filter(&Map.has_key?(copies, &1))
      |> MapSet.new()

    led_elsewhere =
      kept
      |> Enum.reject(
        &(is_nil(&1.language_group_id) or Map.has_key?(copies, &1.language_group_id))
      )
      |> Enum.group_by(& &1.language_group_id)
      |> Map.new(fn {group, members} -> {group, lead(members, leading, copies)} end)

    kept
    |> Enum.map(fn page ->
      {Map.fetch!(copies, page.id), group_of(page, copies, led_elsewhere)}
    end)
    |> Enum.reject(fn {copy, group} -> is_nil(group) or group == copy end)
    |> Enum.group_by(fn {_copy, group} -> group end, fn {copy, _group} -> copy end)
  end

  defp lead(members, leading, copies) do
    case Enum.find(members, &(not MapSet.member?(leading, &1.id))) do
      nil -> nil
      lead -> Map.fetch!(copies, lead.id)
    end
  end

  defp group_of(%{language_group_id: nil}, _copies, _led_elsewhere), do: nil

  defp group_of(%{language_group_id: group}, copies, led_elsewhere),
    do: Map.get(copies, group) || Map.fetch!(led_elsewhere, group)

  # Moves each copy into its group, one update of the copies of each group that has any.
  defp regroup(plan, opts) do
    Enum.reduce_while(plan.groups, :ok, fn {group, members}, :ok ->
      Section
      |> Ash.Query.for_read(:read, %{}, opts)
      |> Ash.Query.filter(id in ^members)
      |> Ash.bulk_update(
        :copy_language_group,
        %{language_group_id: group},
        opts ++
          [
            strategy: [:stream],
            transaction: false,
            return_errors?: true,
            stop_on_error?: true,
            notify?: false
          ]
      )
      |> case do
        %Ash.BulkResult{status: :success} -> {:cont, :ok}
        %Ash.BulkResult{} = result -> {:halt, {:error, refusal(result)}}
      end
    end)
  end

  defp copy_pages(plan, version, opts) do
    plan.levels
    |> Enum.flat_map(&Enum.chunk_every(&1, @page_batch))
    |> in_batches(fn ids ->
      with {:ok, rows} <- read_in(Section, :id, ids, @page_fields, opts) do
        rows
        |> Enum.map(&page(&1, version, plan))
        |> write(Section, :copy, opts)
      end
    end)
  end

  defp page(row, version, plan) do
    row
    |> Map.take(@copied_page_fields)
    |> Map.merge(%{
      copy_id: Map.fetch!(plan.copies, row.id),
      workspace_version_id: version.id,
      parent_section_id: row.parent_section_id && Map.fetch!(plan.copies, row.parent_section_id),
      source_section_id: row.id,
      section_lineage_id: row.section_lineage_id || row.id
    })
  end

  defp copy_notes(plan, opts) do
    plan.pages
    |> Enum.chunk_every(@note_pages)
    |> in_batches(fn ids ->
      with {:ok, rows} <- read_in(Note, :section_id, ids, @note_fields, opts) do
        rows
        |> Enum.map(fn row ->
          row
          |> Map.take(@copied_note_fields)
          |> Map.put(:section_id, Map.fetch!(plan.copies, row.section_id))
        end)
        |> write(Note, :copy, opts)
      end
    end)
  end

  # The tags on the copied pages that are still in use: an archived tag stays on the source only.
  defp copy_tags(plan, opts) do
    plan.pages
    |> Enum.chunk_every(@note_pages)
    |> in_batches(fn ids ->
      with {:ok, rows} <- read_in(SectionTag, :section_id, ids, [:section_id, :tag_id], opts),
           {:ok, tags} <-
             read_in(Tag, :id, rows |> Enum.map(& &1.tag_id) |> Enum.uniq(), [:id], opts) do
        live = MapSet.new(tags, & &1.id)

        rows
        |> Enum.filter(&MapSet.member?(live, &1.tag_id))
        |> Enum.map(&%{section_id: Map.fetch!(plan.copies, &1.section_id), tag_id: &1.tag_id})
        |> write(SectionTag, :assign, opts ++ [upsert_fields: [:updated_at]])
      end
    end)
  end

  # Runs `fun` on each batch in turn, stopping at the first that fails, and counts the rows written.
  defp in_batches(batches, fun) do
    Enum.reduce_while(batches, {:ok, 0}, fn batch, {:ok, written} ->
      case fun.(batch) do
        {:ok, count} -> {:cont, {:ok, written + count}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp read_in(resource, field, ids, fields, opts) do
    resource
    |> Ash.Query.for_read(:read, %{}, opts)
    |> Ash.Query.filter(^ref(field) in ^ids)
    |> Ash.Query.select(fields)
    |> Ash.read(opts)
  end

  defp write([], _resource, _action, _opts), do: {:ok, 0}

  defp write(inputs, resource, action, opts) do
    inputs
    |> Ash.bulk_create(
      resource,
      action,
      opts ++
        [
          batch_size: @page_batch,
          transaction: false,
          return_errors?: true,
          stop_on_error?: true,
          return_records?: false,
          notify?: false
        ]
    )
    |> case do
      %Ash.BulkResult{status: :success} -> {:ok, length(inputs)}
      %Ash.BulkResult{} = result -> {:error, refusal(result)}
    end
  end

  defp refusal(%Ash.BulkResult{errors: [_ | _] = errors}) do
    %{errors: refused} = Ash.Error.to_error_class(errors)
    refused |> Enum.map(&refused_field/1) |> Ash.Error.to_error_class()
  end

  defp refusal(%Ash.BulkResult{}),
    do: Ash.Error.to_error_class(dgettext_noop("errors", "The copy was not written."))

  # A bulk write hands a validation's `field:`/`message:` refusal back unknown; it is the field's.
  defp refused_field(
         %Ash.Error.Unknown.UnknownError{value: [{_key, _value} | _rest] = refusal} = error
       ),
       do: invalid(refusal, error)

  defp refused_field([{_key, _value} | _rest] = refusal), do: invalid(refusal, refusal)
  defp refused_field(error), do: error

  defp invalid(refusal, otherwise) do
    case Keyword.fetch(refusal, :message) do
      {:ok, message} when is_binary(message) ->
        Ash.Error.Changes.InvalidAttribute.exception(
          field: Keyword.get(refusal, :field),
          message: message
        )

      _no_message ->
        otherwise
    end
  end

  defp lineage(version, source, opts) do
    WorkspaceVersionLineage
    |> Ash.Changeset.for_create(
      :create,
      %{new_version_id: version.id, source_version_id: source.id},
      opts
    )
    |> Ash.create(opts)
  end

  defp announce({:ok, version} = result, source, actor) do
    cloned = Map.get(version.__metadata__, :cloned, %{})

    Hook.call(
      @event,
      %{
        version_id: version.id,
        source_version_id: source.id,
        workspace_id: version.workspace_id,
        site_id: version.site_id,
        pages: Map.get(cloned, :pages, 0),
        notes: Map.get(cloned, :notes, 0),
        tags: Map.get(cloned, :tags, 0)
      },
      meta: %{actor: actor, site_id: version.site_id},
      return: false
    )

    result
  end

  defp announce(result, _source, _actor), do: result
end
