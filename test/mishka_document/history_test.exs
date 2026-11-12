# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_document/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaDocument.Test.HistoryTest do
  @moduledoc """
  A page, a note and a draft of either keep a version of every write, and an admin of the section
  area can roll one back to any of its own versions: a site's admin on their site, a master on
  every site. Nobody else reads the history or restores it.
  """
  use MishkaDocument.DataCase, async: false

  require Ash.Query

  alias MishkaDocument.Test.Factory

  @section "admin:dashboard:document:section"

  @kinds [
    {MishkaDocument.Section, &Factory.create_section!/1},
    {MishkaDocument.Note, &Factory.create_note!/1},
    {MishkaDocument.SectionDraft, &Factory.create_section_draft!/1},
    {MishkaDocument.NoteDraft, &Factory.create_note_draft!/1}
  ]

  setup do
    site = create_site!()
    %{site: site, admin: create_user_with_permissions!([@section], site_id: site.id)}
  end

  for {resource, factory} <- @kinds do
    describe inspect(resource) do
      setup %{site: site, admin: admin} do
        record = unquote(factory).(site_id: site.id, title: "First words")
        %{resource: unquote(resource), record: edit!(record, admin, "Second words")}
      end

      test "is stored in its own version table, global across sites", %{resource: resource} do
        version = Module.concat(resource, Version)

        assert AshPaperTrail.Resource.Info.version_resource(resource) == version
        assert Ash.Resource.Info.multitenancy_global?(version)
      end

      test "an edit keeps a version and a restore brings the old words back", ctx do
        assert ctx.record.title == "Second words"
        first = version_with_title!(ctx.record, "First words")

        assert {:ok, restored} = restore(ctx.resource, ctx.admin, ctx.record, first.id)
        assert restored.title == "First words"
        assert restored.site_id == ctx.site.id
        assert version_with_title!(ctx.record, "Second words").version_source_id == ctx.record.id
        assert length(versions(ctx.record)) == 3
      end

      test "a master restores it from any site", ctx do
        master = create_user_with_permissions!([@section])
        first = version_with_title!(ctx.record, "First words")

        assert {:ok, %{title: "First words"}} =
                 ctx.resource
                 |> Ash.ActionInput.for_action(
                   :master_restore_version_api,
                   %{id: ctx.record.id, version_id: first.id},
                   actor: master
                 )
                 |> Ash.run_action(actor: master)
      end

      test "a version of another record is refused", ctx do
        other = edit!(unquote(factory).(site_id: ctx.site.id, title: "Elsewhere"), ctx.admin, "x")
        foreign = version_with_title!(other, "Elsewhere")

        assert {:error, error} = restore(ctx.resource, ctx.admin, ctx.record, foreign.id)
        assert Exception.message(error) =~ "Version does not belong to this"
        assert current_title(ctx.record) == "Second words"
      end

      test "an account without the section area neither reads nor restores the history", ctx do
        outsider =
          create_user_with_permissions!(["admin:dashboard:document:workspace"],
            site_id: ctx.site.id
          )

        first = version_with_title!(ctx.record, "First words")

        assert {:error, %Ash.Error.Forbidden{}} =
                 restore(ctx.resource, outsider, ctx.record, first.id)

        assert {:error, %Ash.Error.Forbidden{}} =
                 ctx.resource
                 |> Ash.Query.for_read(:get_with_versions, %{},
                   actor: outsider,
                   tenant: ctx.site.id
                 )
                 |> Ash.Query.filter(id == ^ctx.record.id)
                 |> Ash.read_one(actor: outsider, tenant: ctx.site.id)

        assert current_title(ctx.record) == "Second words"
      end

      test "another site's admin reads none of its versions", ctx do
        stranger_site = create_site!()
        stranger = create_user_with_permissions!([@section], site_id: stranger_site.id)

        assert {:ok, []} =
                 ctx.resource
                 |> AshPaperTrail.Resource.Info.version_resource()
                 |> Ash.Query.for_read(:read_any, %{}, actor: stranger)
                 |> Ash.Query.filter(version_source_id == ^ctx.record.id)
                 |> Ash.read(actor: stranger)

        assert {:ok, [_ | _]} =
                 ctx.resource
                 |> AshPaperTrail.Resource.Info.version_resource()
                 |> Ash.Query.for_read(:read_any, %{}, actor: ctx.admin)
                 |> Ash.Query.filter(version_source_id == ^ctx.record.id)
                 |> Ash.read(actor: ctx.admin)
      end

      test "the admin's history read lists the versions newest first", ctx do
        assert {:ok, %{sorted_versions: [newest, oldest]}} =
                 ctx.resource
                 |> Ash.Query.for_read(:get_with_versions, %{},
                   actor: ctx.admin,
                   tenant: ctx.site.id
                 )
                 |> Ash.Query.filter(id == ^ctx.record.id)
                 |> Ash.read_one(actor: ctx.admin, tenant: ctx.site.id)

        assert title_of(newest) == "Second words"
        assert title_of(oldest) == "First words"
      end
    end
  end

  defp edit!(record, actor, title) do
    record
    |> Ash.Changeset.for_update(:update, %{title: title},
      actor: actor,
      tenant: record.site_id,
      authorize?: false
    )
    |> Ash.update!()
  end

  defp restore(resource, actor, record, version_id) do
    resource
    |> Ash.ActionInput.for_action(
      :restore_version_api,
      %{id: record.id, version_id: version_id},
      actor: actor,
      tenant: record.site_id
    )
    |> Ash.run_action(actor: actor, tenant: record.site_id)
  end

  defp versions(record) do
    record.__struct__
    |> AshPaperTrail.Resource.Info.version_resource()
    |> Ash.Query.for_read(:sorted_versions, %{}, authorize?: false)
    |> Ash.Query.filter(version_source_id == ^record.id)
    |> Ash.read!(authorize?: false)
  end

  defp version_with_title!(record, title),
    do:
      record |> versions() |> Enum.find(&(title_of(&1) == title)) || flunk("no #{title} version")

  defp title_of(%{changes: changes}), do: changes["title"]

  defp current_title(record) do
    record.__struct__
    |> Ash.get!(record.id, action: :master_get, authorize?: false)
    |> Map.fetch!(:title)
  end
end
