defmodule MishkaDocument.Test.SectionGuardedStructTest do
  @moduledoc """
  GuardedStruct.AshResource coverage for `MishkaDocument.Section`.
  """

  use MishkaDocument.DataCase, async: false
  @moduletag :unit

  if Code.ensure_loaded?(MishkaDocument) do
    alias MishkaDocument.Section

    describe "guardedstruct wiring" do
      test "GS covers every Ash attribute" do
        assert MapSet.new([
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
                 :source_section_id
               ]) == Section.__guarded_field_name_set__()
      end
    end

    describe "direct __guarded_change__/1" do
      test "title strip_tags+trim; content basic_html; review status enums" do
        assert {:ok,
                %{
                  title: "Intro",
                  content: content,
                  content_review_status: :approved,
                  technical_review_status: :rejected
                }} =
                 Section.__guarded_change__(%{
                   title: "  <i>Intro</i>  ",
                   content: "<p>Welcome</p><script>alert(1)</script>",
                   content_review_status: :approved,
                   technical_review_status: :rejected
                 })

        assert content =~ "<p>Welcome</p>"
        refute content =~ "<script"
      end

      test "title empty → min_len + not_empty fire" do
        assert {:error, errs} = Section.__guarded_change__(%{title: ""})
        assert Enum.any?(errs, &match?(%{field: :title, action: :min_len}, &1))
        assert Enum.any?(errs, &match?(%{field: :title, action: :not_empty}, &1))
      end

      test "content_review_status outside enum rejected" do
        assert {:error,
                [
                  %{
                    field: :content_review_status,
                    action: :enum,
                    message:
                      "Your sent data form content_review_status field is not in the allowed list"
                  }
                ]} = Section.__guarded_change__(%{content_review_status: :bogus})
      end

      test "permissions: per-element clean + dedupe" do
        assert {:ok, %{permissions: ["docs:read", "docs:write"]}} =
                 Section.__guarded_change__(%{
                   permissions: ["  DOCS:READ  ", "Docs:Read", "DOCS:WRITE", ""]
                 })
      end

      test "permissions: non-list is rejected" do
        assert {:error, [%{field: :permissions, action: :list}]} =
                 Section.__guarded_change__(%{permissions: "not a list"})
      end
    end
  end
end
