defmodule MishkaDocument.Test.SectionDraftGuardedStructTest do
  @moduledoc """
  GuardedStruct.AshResource coverage for `MishkaDocument.SectionDraft`.
  """

  use MishkaDocument.DataCase, async: false
  @moduletag :unit

  if Code.ensure_loaded?(MishkaDocument) do
    alias MishkaDocument.SectionDraft

    describe "guardedstruct wiring" do
      test "GS covers every Ash attribute" do
        assert MapSet.new([
                 :title,
                 :slug,
                 :content,
                 :order_position,
                 :change_version,
                 :version_increment_type,
                 :content_review_status,
                 :technical_review_status,
                 :applied_at,
                 :schema,
                 :seo_tags,
                 :permissions,
                 :language,
                 :language_group_id
               ]) == SectionDraft.__guarded_field_name_set__()
      end
    end

    describe "direct __guarded_change__/1" do
      test "version_increment_type accepts all 5 members" do
        for vit <- [:major, :minor, :patch, :prerelease, :none] do
          assert {:ok, %{version_increment_type: ^vit}} =
                   SectionDraft.__guarded_change__(%{version_increment_type: vit})
        end
      end

      test "version_increment_type outside enum rejected" do
        assert {:error,
                [
                  %{
                    field: :version_increment_type,
                    action: :enum,
                    message:
                      "Your sent data form version_increment_type field is not in the allowed list"
                  }
                ]} = SectionDraft.__guarded_change__(%{version_increment_type: :bogus})
      end

      test "title as plain text, trimmed; slug trim; content basic_html" do
        assert {:ok,
                %{
                  title: "API Refs",
                  slug: "api-refs",
                  content: content
                }} =
                 SectionDraft.__guarded_change__(%{
                   title: "  <em>API Refs</em>  ",
                   slug: "  api-refs  ",
                   content: "<p>section <b>content</b></p><script>x</script>"
                 })

        assert content =~ "<p>section <b>content</b></p>"
        refute content =~ "<script"
      end
    end
  end
end
