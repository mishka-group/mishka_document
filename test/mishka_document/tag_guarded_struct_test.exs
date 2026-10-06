defmodule MishkaDocument.Test.TagGuardedStructTest do
  @moduledoc """
  GuardedStruct.AshResource coverage for `MishkaDocument.Tag`.
  """

  use MishkaDocument.DataCase, async: false
  @moduletag :unit

  if Code.ensure_loaded?(MishkaDocument) do
    alias MishkaDocument.Tag

    describe "guardedstruct wiring" do
      test "GS covers every Ash attribute" do
        assert MapSet.new([:name, :slug, :language, :language_group_id]) ==
                 Tag.__guarded_field_name_set__()
      end
    end

    describe "direct __guarded_change__/1" do
      test "name + slug trim; language trim+downcase" do
        assert {:ok,
                %{
                  name: "Tutorial",
                  slug: "tutorial",
                  language: "en"
                }} =
                 Tag.__guarded_change__(%{
                   name: "  Tutorial  ",
                   slug: "  tutorial  ",
                   language: "  EN  "
                 })
      end

      test "name empty rejected" do
        assert {:error, errs} = Tag.__guarded_change__(%{name: ""})
        assert Enum.any?(errs, &match?(%{field: :name, action: :min_len}, &1))
        assert Enum.any?(errs, &match?(%{field: :name, action: :not_empty}, &1))
      end
    end
  end
end
