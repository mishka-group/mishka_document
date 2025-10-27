defmodule MishkaDocument.Test.WorkspaceVersionLineageGuardedStructTest do
  @moduledoc """
  GuardedStruct.AshResource coverage for `MishkaDocument.WorkspaceVersionLineage`.
  """

  use MishkaDocument.DataCase, async: false
  @moduletag :unit

  if Code.ensure_loaded?(MishkaDocument) do
    alias MishkaDocument.WorkspaceVersionLineage

    describe "guardedstruct wiring" do
      test "GS covers every Ash attribute" do
        assert MapSet.new([:cloned_at]) ==
                 WorkspaceVersionLineage.__guarded_field_name_set__()
      end
    end

    describe "direct __guarded_change__/1" do
      test "cloned_at struct round-trips (Ash handles parsing)" do
        now = DateTime.utc_now()

        assert {:ok, %{cloned_at: ^now}} =
                 WorkspaceVersionLineage.__guarded_change__(%{cloned_at: now})
      end

      test "empty input is a no-op" do
        assert {:ok, %{}} = WorkspaceVersionLineage.__guarded_change__(%{})
      end
    end
  end
end
