# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_document/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaDocument.Resources.Changes.StartFromSource do
  @moduledoc """
  A draft of an existing record — a page (`MishkaDocument.SectionDraft`) or a note
  (`MishkaDocument.NoteDraft`) — names in its `changed_fields` which of the record's `fields` it
  changes. Applying the draft writes those and no other
  (`MishkaDocument.Resources.Changes.AutoApplySectionDraft`,
  `MishkaDocument.Resources.Changes.AutoApplyNoteDraft`), so a field its editor did not change is
  never written over, whatever the record holds by the time the draft is applied.

  A draft added with a field left empty — `nil`, `""`, `[]`, or an order of `0` — starts with the
  record's value for it, so the draft shows what the record holds and changes none of it. Each
  field it is given that differs from the record's is a change.

  A draft edited later changes a field by setting it: to a value the record does not hold, it is a
  change; back to the record's own, it is none. A draft edited to name no permission opens its page
  to everyone once it is applied. A draft moved to another record is measured against that one.

  A draft with no record — one that adds a page or a note — names none: applying it writes all of
  it, as the new record.

      create :create do
        change {MishkaDocument.Resources.Changes.StartFromSource,
                source: :source_section_id,
                resource: MishkaDocument.Section,
                fields: [:title, :slug, :content, :permissions]}
      end

  The record is read as the action's caller — its actor, and the surface it came from — on the
  draft's site. A record it cannot read is never written over by a field the draft leaves empty:
  each field a draft added is given, and each one an edit sets, is taken as a change.

  ## Options

  * `:source` - Required. The draft's attribute naming the record.
  * `:resource` - Required. The record's resource.
  * `:fields` - Required. The record's fields the draft holds, by the same name on both.
  """
  use Ash.Resource.Change

  @empty [nil, "", [], 0]

  @impl true
  def init(opts) do
    if is_atom(opts[:source]) and is_atom(opts[:resource]) and is_list(opts[:fields]) and
         opts[:fields] != [],
       do: {:ok, opts},
       else: {:error, "source, resource and fields are required"}
  end

  @impl true
  def change(changeset, opts, context),
    do: Ash.Changeset.before_action(changeset, &measure(&1, Map.new(opts), context))

  defp measure(changeset, opts, context) do
    cond do
      not is_binary(Ash.Changeset.get_attribute(changeset, opts.source)) ->
        Ash.Changeset.force_change_attribute(changeset, :changed_fields, [])

      untouched?(changeset, opts) ->
        changeset

      true ->
        against_record(changeset, opts, context)
    end
  end

  # An edit that sets none of the record's fields, and keeps the record, changes nothing on it.
  defp untouched?(%{action_type: :update} = changeset, opts),
    do:
      not Enum.any?(
        [opts.source | opts.fields],
        &Ash.Changeset.changing_attribute?(changeset, &1)
      )

  defp untouched?(_changeset, _opts), do: false

  defp against_record(changeset, opts, context) do
    id = Ash.Changeset.get_attribute(changeset, opts.source)

    read_opts =
      Ash.Context.to_opts(context,
        tenant: Ash.Changeset.get_attribute(changeset, :site_id) || changeset.tenant
      )

    case Ash.get(opts.resource, id, read_opts) do
      {:ok, record} ->
        changeset = carry(changeset, record, opts)

        Ash.Changeset.force_change_attribute(
          changeset,
          :changed_fields,
          changed(changeset, record, opts)
        )

      {:error, _unreadable} ->
        Ash.Changeset.force_change_attribute(changeset, :changed_fields, set(changeset, opts))
    end
  end

  defp carry(%{action_type: :create} = changeset, record, opts) do
    Enum.reduce(opts.fields, changeset, fn field, changeset ->
      if Ash.Changeset.get_attribute(changeset, field) in @empty,
        do: Ash.Changeset.force_change_attribute(changeset, field, Map.get(record, field)),
        else: changeset
    end)
  end

  defp carry(changeset, _record, _opts), do: changeset

  # Measured whole on a draft being added or moved to another record. On one edited: what it
  # changed before, with each field this edit sets that differs from the record's, and without each
  # it sets back to the record's own.
  defp changed(changeset, record, opts) do
    whole? =
      changeset.action_type == :create or
        Ash.Changeset.changing_attribute?(changeset, opts.source)

    {before, measured} =
      if whole?,
        do: {[], opts.fields},
        else:
          {List.wrap(changeset.data.changed_fields),
           Enum.filter(opts.fields, &Ash.Changeset.changing_attribute?(changeset, &1))}

    differs =
      Enum.reject(
        measured,
        &same?(Ash.Changeset.get_attribute(changeset, &1), Map.get(record, &1))
      )

    Enum.filter(opts.fields, &(&1 in differs or (&1 in before and &1 not in measured)))
  end

  # With no record to measure against, what the draft sets is what it changes: on a draft being
  # added or moved, each field it is given a value; on one edited, what it changed before and each
  # field this edit sets.
  defp set(changeset, opts) do
    if changeset.action_type == :create or
         Ash.Changeset.changing_attribute?(changeset, opts.source) do
      Enum.reject(opts.fields, &(Ash.Changeset.get_attribute(changeset, &1) in @empty))
    else
      before = List.wrap(changeset.data.changed_fields)

      Enum.filter(
        opts.fields,
        &(&1 in before or Ash.Changeset.changing_attribute?(changeset, &1))
      )
    end
  end

  defp same?(value, other), do: normal(value) == normal(other)

  defp normal(""), do: nil

  defp normal(map) when is_map(map) and not is_struct(map),
    do: Map.new(map, fn {key, value} -> {to_string(key), normal(value)} end)

  defp normal(list) when is_list(list), do: Enum.map(list, &normal/1)
  defp normal(value), do: value
end
