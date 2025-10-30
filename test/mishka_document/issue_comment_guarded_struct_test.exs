defmodule MishkaDocument.Test.IssueCommentGuardedStructTest do
  @moduledoc """
  GuardedStruct.AshResource coverage for `MishkaDocument.IssueComment`.
  """

  use MishkaDocument.DataCase, async: false
  @moduletag :unit

  if Code.ensure_loaded?(MishkaDocument) do
    alias MishkaDocument.IssueComment

    describe "guardedstruct wiring" do
      test "GS covers every Ash attribute" do
        assert MapSet.new([:content]) ==
                 IssueComment.__guarded_field_name_set__()
      end
    end

    describe "direct __guarded_change__/1" do
      test "content keeps safe HTML, strips scripts" do
        assert {:ok, %{content: out}} =
                 IssueComment.__guarded_change__(%{
                   content: "Replying with <b>details</b><script>alert(1)</script>"
                 })

        assert out =~ "<b>details</b>"
        refute out =~ "<script"
      end

      test "content empty rejected" do
        assert {:error, errs} = IssueComment.__guarded_change__(%{content: ""})
        assert Enum.any?(errs, &match?(%{field: :content, action: :not_empty}, &1))
      end
    end
  end
end
