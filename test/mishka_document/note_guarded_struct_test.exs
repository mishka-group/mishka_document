defmodule MishkaDocument.Test.NoteGuardedStructTest do
  @moduledoc """
  GuardedStruct.AshResource coverage for `MishkaDocument.Note`.
  """

  use MishkaDocument.DataCase, async: false
  @moduletag :unit

  if Code.ensure_loaded?(MishkaDocument) do
    alias MishkaDocument.Note

    describe "guardedstruct wiring" do
      test "GS covers every Ash attribute" do
        assert MapSet.new([
                 :title,
                 :content,
                 :order_position,
                 :change_version,
                 :content_review_status,
                 :technical_review_status,
                 :schema,
                 :seo_tags
               ]) == Note.__guarded_field_name_set__()
      end
    end

    describe "direct __guarded_change__/1" do
      test "title strip_tags+trim; content basic_html; review status accept" do
        assert {:ok,
                %{
                  title: "Side Note",
                  content: content,
                  content_review_status: :approved
                }} =
                 Note.__guarded_change__(%{
                   title: "  <strong>Side Note</strong>  ",
                   content: "<p>Note <em>body</em></p><script>x</script>",
                   content_review_status: :approved
                 })

        assert content =~ "<p>Note <em>body</em></p>"
        refute content =~ "<script"
      end

      test "content empty → not_empty error" do
        assert {:error, errs} = Note.__guarded_change__(%{content: ""})
        assert Enum.any?(errs, &match?(%{field: :content, action: :not_empty}, &1))
      end
    end
  end
end
