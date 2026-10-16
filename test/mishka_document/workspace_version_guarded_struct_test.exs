# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_document/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaDocument.Test.WorkspaceVersionGuardedStructTest do
  @moduledoc """
  GuardedStruct.AshResource coverage for `MishkaDocument.WorkspaceVersion`.
  """

  use MishkaDocument.DataCase, async: false
  @moduletag :unit

  if Code.ensure_loaded?(MishkaDocument) do
    alias MishkaDocument.WorkspaceVersion

    describe "guardedstruct wiring" do
      test "GS covers every Ash attribute" do
        assert MapSet.new([
                 :version_number,
                 :version_name,
                 :description,
                 :status,
                 :is_latest_for_version,
                 :published_at
               ]) == WorkspaceVersion.__guarded_field_name_set__()
      end
    end

    describe "direct __guarded_change__/1" do
      test "all status enum members accepted" do
        for s <- [:draft, :alpha, :beta, :rc, :stable, :archived] do
          assert {:ok, %{status: ^s}} = WorkspaceVersion.__guarded_change__(%{status: s})
        end
      end

      test "status outside enum rejected" do
        assert {:error,
                [
                  %{
                    field: :status,
                    action: :enum,
                    message: "Your sent data form status field is not in the allowed list"
                  }
                ]} = WorkspaceVersion.__guarded_change__(%{status: :bogus})
      end

      test "version_number over max_len=50 → both max_len + semver fire" do
        long = String.duplicate("v", 51)

        assert {:error, errs} = WorkspaceVersion.__guarded_change__(%{version_number: long})

        assert Enum.any?(errs, &match?(%{field: :version_number, action: :max_len}, &1))
        assert Enum.any?(errs, &match?(%{field: :version_number, action: :semver}, &1))
      end

      test "version_number accepts SemVer 2.0.0 shapes (canonical + prerelease + build)" do
        for v <- ["1.0.0", "0.0.1", "1.2.3-alpha.1", "2.0.0-rc.1+build.42"] do
          assert {:ok, %{version_number: ^v}} =
                   WorkspaceVersion.__guarded_change__(%{version_number: v})
        end
      end

      test "version_number rejects non-SemVer shapes" do
        for bad <- ["v1.0", "1", "1.2", "1.2.3.4", "release-1"] do
          assert {:error, errs} = WorkspaceVersion.__guarded_change__(%{version_number: bad})

          assert Enum.any?(errs, &match?(%{field: :version_number, action: :semver}, &1)),
                 "expected :semver error for #{inspect(bad)}, got #{inspect(errs)}"
        end
      end
    end
  end
end
