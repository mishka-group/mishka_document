defmodule MishkaDocument.Test.WorkspaceGuardedStructTest do
  @moduledoc """
  GuardedStruct.AshResource coverage for `MishkaDocument.Workspace`.
  """

  use MishkaDocument.DataCase, async: false
  @moduletag :unit

  if Code.ensure_loaded?(MishkaDocument) do
    alias MishkaDocument.Workspace

    describe "guardedstruct wiring" do
      test "GS covers every Ash attribute" do
        assert MapSet.new([
                 :name,
                 :slug,
                 :description,
                 :status,
                 :schema,
                 :seo_tags,
                 :permissions,
                 :featured,
                 :display_order,
                 :language,
                 :language_group_id
               ]) == Workspace.__guarded_field_name_set__()
      end
    end

    describe "direct __guarded_change__/1" do
      test "name trim, status enum accept" do
        assert {:ok, %{name: "Docs", status: :active}} =
                 Workspace.__guarded_change__(%{name: "  Docs  ", status: :active})
      end

      test "status outside enum rejected" do
        assert {:error,
                [
                  %{
                    field: :status,
                    action: :enum,
                    message: "Your sent data form status field is not in the allowed list"
                  }
                ]} = Workspace.__guarded_change__(%{status: :bogus})
      end

      test "language trim+downcase" do
        assert {:ok, %{language: "fa"}} = Workspace.__guarded_change__(%{language: "  FA  "})
      end

      test "permissions: per-element clean + dedupe" do
        assert {:ok, %{permissions: ["docs:read", "docs:write"]}} =
                 Workspace.__guarded_change__(%{
                   permissions: ["  DOCS:READ  ", "Docs:Read", "DOCS:WRITE", ""]
                 })
      end

      test "permissions: non-list is rejected" do
        assert {:error, [%{field: :permissions, action: :list}]} =
                 Workspace.__guarded_change__(%{permissions: "not a list"})
      end
    end
  end
end
