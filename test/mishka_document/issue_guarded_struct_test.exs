defmodule MishkaDocument.Test.IssueGuardedStructTest do
  @moduledoc """
  GuardedStruct.AshResource coverage for `MishkaDocument.Issue`.
  """

  use MishkaDocument.DataCase, async: false
  @moduletag :unit

  if Code.ensure_loaded?(MishkaDocument) do
    alias MishkaDocument.Issue

    describe "guardedstruct wiring" do
      test "GS covers every Ash attribute" do
        assert MapSet.new([:title, :description, :issue_type, :status]) ==
                 Issue.__guarded_field_name_set__()
      end
    end

    describe "direct __guarded_change__/1" do
      test "title strip_tags+trim; description basic_html; enums accept" do
        assert {:ok,
                %{
                  title: "Broken link",
                  description: description,
                  issue_type: :broken_link,
                  status: :open
                }} =
                 Issue.__guarded_change__(%{
                   title: "  <code>Broken</code> link  ",
                   description: "<p>On the <b>install</b> page.</p><script>x</script>",
                   issue_type: :broken_link,
                   status: :open
                 })

        assert description =~ "<p>On the <b>install</b> page.</p>"
        refute description =~ "<script"
      end

      test "issue_type outside enum rejected" do
        assert {:error,
                [
                  %{
                    field: :issue_type,
                    action: :enum,
                    message: "Your sent data form issue_type field is not in the allowed list"
                  }
                ]} = Issue.__guarded_change__(%{issue_type: :bogus})
      end

      test "status outside enum rejected" do
        assert {:error,
                [
                  %{
                    field: :status,
                    action: :enum,
                    message: "Your sent data form status field is not in the allowed list"
                  }
                ]} = Issue.__guarded_change__(%{status: :archived})
      end
    end
  end
end
