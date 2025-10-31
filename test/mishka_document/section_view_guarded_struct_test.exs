defmodule MishkaDocument.Test.SectionViewGuardedStructTest do
  @moduledoc """
  GuardedStruct.AshResource coverage for `MishkaDocument.SectionView`.
  """

  use MishkaDocument.DataCase, async: false
  @moduletag :unit

  if Code.ensure_loaded?(MishkaDocument) do
    alias MishkaDocument.SectionView

    describe "guardedstruct wiring" do
      test "GS covers every Ash attribute" do
        assert MapSet.new([:ip_address, :user_agent, :referer]) ==
                 SectionView.__guarded_field_name_set__()
      end
    end

    describe "direct __guarded_change__/1" do
      test "ip + ua + referer trimmed; ua zero-width strip" do
        assert {:ok,
                %{
                  ip_address: "10.0.0.1",
                  user_agent: "Mozilla/5.0",
                  referer: "https://google.com"
                }} =
                 SectionView.__guarded_change__(%{
                   ip_address: "  10.0.0.1  ",
                   user_agent: "Mozil​la/5.0",
                   referer: "  https://google.com  "
                 })
      end

      test "ip empty rejected (required)" do
        assert {:error, errs} = SectionView.__guarded_change__(%{ip_address: ""})
        assert Enum.any?(errs, &match?(%{field: :ip_address, action: :not_empty}, &1))
      end
    end
  end
end
