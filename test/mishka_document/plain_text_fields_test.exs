# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_document/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaDocument.Test.PlainTextFieldsTest do
  @moduledoc """
  The documentation's plain-text fields — a document's name and description, a version's name and
  notes, a page's, a draft's, an issue's and a note's title, a tag's name — store what was typed,
  without its markup and with nothing escaped (`MishkaCmsCore.PlainText`). Escaping is the page's
  and the head's job.
  """
  use MishkaDocument.DataCase, async: false

  alias MishkaCmsCore.PlainText
  alias MishkaDocument.Workspace

  @moduletag :integration

  @typed ~s(Tom & Jerry's <b>"cat"</b>)
  @kept ~s(Tom & Jerry's "cat")

  # Read off the resources rather than listed, so a field declared tomorrow is covered too.
  defp guarded_fields do
    for resource <- Ash.Domain.Info.resources(MishkaDocument),
        function_exported?(resource, :__guarded_fields__, 0),
        field <- resource.__guarded_fields__(),
        do: {resource, field}
  end

  defp plain_text_fields do
    for {resource, %{name: name, validator: {PlainText, :field}}} <- guarded_fields(),
        do: {resource, name}
  end

  describe "every plain-text field" do
    test "is one the documentation shows as text" do
      assert MapSet.new(plain_text_fields()) ==
               MapSet.new([
                 {MishkaDocument.Issue, :title},
                 {MishkaDocument.Note, :title},
                 {MishkaDocument.NoteDraft, :title},
                 {MishkaDocument.Section, :title},
                 {MishkaDocument.SectionDraft, :title},
                 {MishkaDocument.Tag, :name},
                 {MishkaDocument.Workspace, :description},
                 {MishkaDocument.Workspace, :name},
                 {MishkaDocument.WorkspaceVersion, :description},
                 {MishkaDocument.WorkspaceVersion, :version_name}
               ])
    end

    test "keeps what was typed without its markup, and keeping it again changes nothing" do
      for {resource, field} <- plain_text_fields() do
        label = "#{inspect(resource)}.#{field}"

        assert {:ok, %{^field => @kept}} = resource.__guarded_change__(%{field => @typed}), label
        assert {:ok, %{^field => @kept}} = resource.__guarded_change__(%{field => @kept}), label

        assert {:ok, %{^field => "alert(1)Hi"}} =
                 resource.__guarded_change__(%{field => "<script>alert(1)</script>Hi"}),
               label
      end
    end

    # `strip_tags` escapes the text it leaves, so a field sanitized with it stores `&amp;`.
    test "no field is stripped of its tags the escaping way" do
      escaping =
        for {resource, %{name: name, __derive_ops__: %{sanitize: ops}}} <- guarded_fields(),
            :strip_tags in List.wrap(ops),
            do: {resource, name}

      assert escaping == []
    end
  end

  describe "a document written through its actions" do
    setup do
      site = create_site!()
      %{site: site, actor: create_user_with_permissions!(["*"], site_id: site.id)}
    end

    defp update!(record, ctx, attrs) do
      record
      |> Ash.Changeset.for_update(:update, attrs, actor: ctx.actor, tenant: ctx.site.id)
      |> Ash.update!()
    end

    test "stores its name and description as typed, and saving them again changes nothing",
         ctx do
      document =
        create_workspace!(site_id: ctx.site.id, skip_version: true, name: "Guide")
        |> update!(ctx, %{name: @typed, description: "<i>Why</i> & how"})

      assert document.name == @kept
      assert document.description == "Why & how"

      saved = update!(document, ctx, %{name: document.name, description: document.description})
      assert {saved.name, saved.description} == {@kept, "Why & how"}

      again = update!(saved, ctx, %{name: saved.name, description: saved.description})
      assert {again.name, again.description} == {@kept, "Why & how"}

      assert %Workspace{name: @kept} =
               Ash.get!(Workspace, document.id, actor: ctx.actor, tenant: ctx.site.id)
    end

    test "never stores a script", ctx do
      document =
        create_workspace!(site_id: ctx.site.id, skip_version: true)
        |> update!(ctx, %{name: "<script>alert(1)</script>Hi", description: "<<script>script>x"})

      refute document.name =~ "<script"
      refute document.description =~ "<script"
      assert document.name == "alert(1)Hi"
    end
  end
end
