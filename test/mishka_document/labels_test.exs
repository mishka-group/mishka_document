# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_document/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaDocument.Resources.Helpers.LabelsTest do
  @moduledoc """
  `MishkaDocument.Resources.Helpers.Labels`: what the document tables draw in a cell, which has to
  survive a field the viewer's policy hid and a record that has none.
  """
  use ExUnit.Case, async: true

  alias MishkaDocument.Resources.Helpers.Labels

  describe "counted/1" do
    test "gives a count as it is, and anything else as 0" do
      assert Labels.counted(7) == 7
      assert Labels.counted(0) == 0
      assert Labels.counted(-1) == 0
      assert Labels.counted(nil) == 0
      assert Labels.counted(%Ash.NotLoaded{}) == 0
      assert Labels.counted(%Ash.ForbiddenField{}) == 0
    end
  end

  describe "version_label/1" do
    test "prefixes a version with v, and reads a missing one as v0.0.1" do
      assert Labels.version_label("1.2.0") == "v1.2.0"
      assert Labels.version_label("") == "v0.0.1"
      assert Labels.version_label(nil) == "v0.0.1"
      assert Labels.version_label(%Ash.NotLoaded{}) == "v0.0.1"
    end
  end

  describe "first_loaded/2" do
    test "gives the first of the fields that is loaded" do
      record = %{master_section: %Ash.NotLoaded{}, section: %{title: "Plain"}}

      assert Labels.first_loaded(record, [:master_section, :section]) == %{title: "Plain"}

      both = %{master_section: %{title: "Master"}, section: %{title: "Plain"}}
      assert Labels.first_loaded(both, [:master_section, :section]) == %{title: "Master"}
    end

    test "gives nil when none is loaded, or the loaded one holds nil" do
      none = %{master_section: %Ash.NotLoaded{}, section: %Ash.NotLoaded{}}
      assert Labels.first_loaded(none, [:master_section, :section]) == nil

      empty = %{master_section: nil, section: %{title: "Plain"}}
      assert Labels.first_loaded(empty, [:master_section, :section]) == nil
    end
  end

  describe "increment_label/1" do
    test "words the five kinds of bump, and prints anything else" do
      assert Enum.map([:major, :minor, :patch, :prerelease, :none], &Labels.increment_label/1) ==
               ["major", "minor", "patch", "prerelease", "none"]

      assert Labels.increment_label(:other) == "other"
    end
  end

  describe "inserted_on/1" do
    test "gives the day of a time, and a dash for anything else" do
      assert Labels.inserted_on(~U[2026-03-04 05:06:07Z]) =~ "2026"
      assert Labels.inserted_on(~N[2026-03-04 05:06:07]) =~ "2026"
      assert Labels.inserted_on(nil) == "—"
      assert Labels.inserted_on(%Ash.NotLoaded{}) == "—"
    end
  end

  describe "review_badge/1" do
    test "gives each of the five statuses its own colours and a label" do
      badges =
        for status <- [:approved, :pending, :rejected, :needs_revision, :archived],
            do: Labels.review_badge(status)

      assert Enum.all?(badges, &(is_binary(&1.label) and &1.label != ""))
      assert badges |> Enum.map(& &1.class) |> Enum.uniq() |> length() == 5
    end

    test "reads an unknown status as a dash" do
      assert %{label: "—"} = Labels.review_badge(:unheard_of)
      assert Labels.review_badge(nil) == Labels.review_badge(:unheard_of)
    end
  end

  describe "translate_label/1" do
    test "translates only the label of a badge" do
      assert %{label: "Approved", class: "x"} =
               Labels.translate_label(%{label: "Approved", class: "x"})
    end
  end
end
