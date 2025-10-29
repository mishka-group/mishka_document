defmodule MishkaDocument.WorkspaceVersionLinksTest do
  @moduledoc """
  A section, a section draft and a note draft live in one workspace version and name the records
  around them by id. Those records are the same version's: a section's parent, a section draft's
  parent and the section it changes, a note draft's section, section draft and note (a note is in its
  section's version). A section's source is the section it was copied from, so it is in another
  version of the same workspace.

  A link that breaks this is refused, on create and on update, by the site's actions and the master's,
  including an update that moves the record to another version and leaves the link behind. A link to
  a record that no read finds is refused too, saying it is no longer here.

  Every link a versioned record makes to another versioned record is one of these, or one that spans
  versions on purpose: a language group joins translations, which live in other workspaces, and a
  section's lineage joins its copies across versions.
  """
  use MishkaDocument.DataCase, async: false

  alias MishkaCmsCore.Runtime.Resources.Validations.SameSiteReference
  alias MishkaDocument.{Note, NoteDraft, Section, SectionDraft}
  alias MishkaDocument.Resources.Validations.SameWorkspaceVersion

  @spans_versions [:language_group_id, :section_lineage_id]

  setup do
    site = create_site!()
    workspace = create_workspace!(site_id: site.id, skip_version: true)
    here = create_workspace_version!(workspace_id: workspace.id, site_id: site.id)
    earlier = create_workspace_version!(workspace_id: workspace.id, site_id: site.id)
    elsewhere = create_workspace_version!(site_id: site.id)

    section = fn version ->
      create_section!(site_id: site.id, workspace_version_id: version.id)
    end

    draft = fn version ->
      create_section_draft!(site_id: site.id, workspace_version_id: version.id)
    end

    %{
      site: site,
      here: here,
      earlier: earlier,
      elsewhere: elsewhere,
      section: %{here: section.(here), earlier: section.(earlier), elsewhere: section.(elsewhere)},
      draft: %{here: draft.(here), earlier: draft.(earlier)}
    }
  end

  defp note_in(ctx, section), do: create_note!(site_id: ctx.site.id, section_id: section.id)

  defp section_attrs(ctx, extra),
    do:
      Map.merge(
        %{
          workspace_version_id: ctx.here.id,
          title: "Linked",
          slug: "linked-#{System.unique_integer([:positive])}",
          language: "en"
        },
        extra
      )

  defp draft_attrs(ctx, extra),
    do:
      Map.merge(
        %{
          workspace_version_id: ctx.here.id,
          title: "Linked Draft",
          slug: "linked-draft-#{System.unique_integer([:positive])}",
          language: "en",
          change_version: "0.0.1",
          version_increment_type: :patch
        },
        extra
      )

  defp note_draft_attrs(ctx, extra),
    do:
      Map.merge(
        %{
          workspace_version_id: ctx.here.id,
          section_id: ctx.section.here.id,
          title: "Linked Note Draft",
          content: "Body",
          change_version: "0.0.1",
          version_increment_type: :patch
        },
        extra
      )

  # {resource, attrs, field}: the attrs name a record for the field; the second list names one of the
  # right version.
  defp wrong_links(ctx) do
    [
      {Section, section_attrs(ctx, %{parent_section_id: ctx.section.earlier.id}),
       :parent_section_id},
      {Section, section_attrs(ctx, %{source_section_id: ctx.section.here.id}),
       :source_section_id},
      {Section, section_attrs(ctx, %{source_section_id: ctx.section.elsewhere.id}),
       :source_section_id},
      {SectionDraft, draft_attrs(ctx, %{parent_section_id: ctx.section.earlier.id}),
       :parent_section_id},
      {SectionDraft, draft_attrs(ctx, %{source_section_id: ctx.section.earlier.id}),
       :source_section_id},
      {NoteDraft, note_draft_attrs(ctx, %{section_id: ctx.section.earlier.id}), :section_id},
      {NoteDraft,
       note_draft_attrs(ctx, %{
         section_id: nil,
         section_draft_id: ctx.draft.earlier.id,
         change_version: ctx.draft.earlier.change_version
       }), :section_draft_id},
      {NoteDraft, note_draft_attrs(ctx, %{source_note_id: note_in(ctx, ctx.section.earlier).id}),
       :source_note_id}
    ]
  end

  defp right_links(ctx) do
    [
      {Section, section_attrs(ctx, %{parent_section_id: ctx.section.here.id})},
      {Section, section_attrs(ctx, %{source_section_id: ctx.section.earlier.id})},
      {SectionDraft,
       draft_attrs(ctx, %{
         parent_section_id: ctx.section.here.id,
         source_section_id: ctx.section.here.id
       })},
      {NoteDraft, note_draft_attrs(ctx, %{source_note_id: note_in(ctx, ctx.section.here).id})},
      {NoteDraft,
       note_draft_attrs(ctx, %{
         section_id: nil,
         section_draft_id: ctx.draft.here.id,
         change_version: ctx.draft.here.change_version
       })}
    ]
  end

  defp site_create(resource, attrs, ctx),
    do:
      resource
      |> Ash.Changeset.for_create(:create, attrs, tenant: ctx.site.id, authorize?: false)
      |> Ash.create()

  defp master_create(resource, attrs, ctx),
    do:
      resource
      |> Ash.Changeset.for_create(:master_create, Map.put(attrs, :site_id, ctx.site.id),
        authorize?: false
      )
      |> Ash.create()

  defp refused_on?({:error, %Ash.Error.Invalid{errors: errors}}, field),
    do: Enum.any?(errors, &(Map.get(&1, :field) == field))

  defp refused_on?(_result, _field), do: false

  describe "creating a record" do
    test "that names a record of the wrong version is refused, by the site and by a master",
         ctx do
      for create <- [&site_create/3, &master_create/3],
          {resource, attrs, field} <- wrong_links(ctx) do
        result = create.(resource, attrs, ctx)

        assert refused_on?(result, field),
               "#{inspect(resource)} took #{field} from the wrong version: #{inspect(result, limit: 4)}"
      end
    end

    test "that names records of the right version is taken, by the site and by a master", ctx do
      for create <- [&site_create/3, &master_create/3], {resource, attrs} <- right_links(ctx) do
        assert {:ok, _} = create.(resource, attrs, ctx)
      end
    end

    test "says in plain words why it is refused", ctx do
      assert {:error, %Ash.Error.Invalid{errors: errors}} =
               site_create(
                 Section,
                 section_attrs(ctx, %{parent_section_id: ctx.section.earlier.id}),
                 ctx
               )

      assert Enum.any?(
               errors,
               &(&1.field == :parent_section_id and
                   &1.message ==
                     "That section belongs to another workspace version. Choose one from the same version.")
             )

      assert {:error, %Ash.Error.Invalid{errors: errors}} =
               site_create(
                 Section,
                 section_attrs(ctx, %{source_section_id: ctx.section.here.id}),
                 ctx
               )

      assert Enum.any?(
               errors,
               &(&1.field == :source_section_id and
                   &1.message == "That section is not in another version of this workspace.")
             )
    end
  end

  describe "a refused link, in the admin's language" do
    setup do
      Gettext.put_locale(MishkaCmsCore.Gettext, "fa")
      :ok
    end

    test "names the record in the reader's language", ctx do
      assert {:error, %Ash.Error.Invalid{errors: errors}} =
               site_create(
                 Section,
                 section_attrs(ctx, %{parent_section_id: ctx.section.earlier.id}),
                 ctx
               )

      assert Enum.any?(
               errors,
               &(&1.field == :parent_section_id and
                   &1.message ==
                     "[fa] That [fa] section belongs to another workspace version. Choose one from the same version.")
             )

      assert {:error, %Ash.Error.Invalid{errors: errors}} =
               site_create(
                 Section,
                 section_attrs(ctx, %{source_section_id: ctx.section.here.id}),
                 ctx
               )

      assert Enum.any?(
               errors,
               &(&1.field == :source_section_id and
                   &1.message ==
                     "[fa] That [fa] section is not in another version of this workspace.")
             )
    end

    test "says a record no read finds is gone, in the reader's language", ctx do
      {:ok, opts} =
        SameWorkspaceVersion.init(field: :parent_section_id, resource: Section, label: "section")

      changeset =
        ctx.section.here
        |> Ash.Changeset.new()
        |> Ash.Changeset.force_change_attribute(:parent_section_id, Ash.UUID.generate())

      assert SameWorkspaceVersion.validate(changeset, opts, %{}) ==
               {:error,
                field: :parent_section_id, message: "[fa] That [fa] section is no longer here."}
    end
  end

  describe "updating a record" do
    test "to name a record of the wrong version is refused, by the site and by a master", ctx do
      child = create_section!(site_id: ctx.site.id, workspace_version_id: ctx.here.id)

      assert refused_on?(
               child
               |> Ash.Changeset.for_update(
                 :update,
                 %{parent_section_id: ctx.section.earlier.id},
                 tenant: ctx.site.id,
                 authorize?: false
               )
               |> Ash.update(),
               :parent_section_id
             )

      assert refused_on?(
               child
               |> Ash.Changeset.for_update(
                 :master_update,
                 %{parent_section_id: ctx.section.earlier.id},
                 authorize?: false
               )
               |> Ash.update(),
               :parent_section_id
             )
    end

    test "that moves it to another version and leaves a link behind is refused", ctx do
      child =
        create_section!(
          site_id: ctx.site.id,
          workspace_version_id: ctx.here.id,
          parent_section_id: ctx.section.here.id
        )

      for {action, opts} <- [update: [tenant: ctx.site.id], master_update: []] do
        assert refused_on?(
                 child
                 |> Ash.Changeset.for_update(
                   action,
                   %{workspace_version_id: ctx.earlier.id},
                   [authorize?: false] ++ opts
                 )
                 |> Ash.update(),
                 :parent_section_id
               )
      end

      assert {:ok, %{workspace_version_id: moved}} =
               child
               |> Ash.Changeset.for_update(
                 :update,
                 %{
                   workspace_version_id: ctx.earlier.id,
                   parent_section_id: ctx.section.earlier.id
                 },
                 tenant: ctx.site.id,
                 authorize?: false
               )
               |> Ash.update()

      assert moved == ctx.earlier.id
    end
  end

  test "a link to a record no read finds is refused, and says the record is gone", ctx do
    records = %{
      Section => ctx.section.here,
      SectionDraft => ctx.draft.here,
      NoteDraft =>
        create_note_draft!(
          site_id: ctx.site.id,
          section_id: ctx.section.here.id,
          workspace_version_id: ctx.here.id
        )
    }

    declaring =
      for resource <- Ash.Domain.Info.resources(MishkaDocument),
          placed(resource) != [],
          do: resource

    assert Enum.sort(declaring) == Enum.sort(Map.keys(records))

    for {resource, record} <- records,
        %{validation: {SameWorkspaceVersion, declared}} <- Ash.Resource.Info.validations(resource) do
      {:ok, opts} = SameWorkspaceVersion.init(declared)

      changeset =
        record
        |> Ash.Changeset.new()
        |> Ash.Changeset.force_change_attribute(opts[:field], Ash.UUID.generate())

      assert SameWorkspaceVersion.validate(changeset, opts, %{}) ==
               {:error, field: opts[:field], message: "That #{opts[:label]} is no longer here."}
    end
  end

  test "every link between records of a workspace version says which version it names" do
    versioned? = fn resource ->
      resource == Note or not is_nil(Ash.Resource.Info.attribute(resource, :workspace_version_id))
    end

    unplaced =
      for resource <- Ash.Domain.Info.resources(MishkaDocument),
          Ash.Resource.Info.attribute(resource, :workspace_version_id),
          %{validation: {SameSiteReference, opts}} <- Ash.Resource.Info.validations(resource),
          is_atom(opts[:resource]) and versioned?.(opts[:resource]),
          opts[:field] not in [:workspace_version_id | @spans_versions],
          opts[:field] not in placed(resource),
          do: {resource, opts[:field]}

    assert unplaced == []
  end

  defp placed(resource) do
    for %{validation: {SameWorkspaceVersion, opts}} <- Ash.Resource.Info.validations(resource),
        do: opts[:field]
  end
end
