# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_document/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaDocument.Test.SlugTest do
  @moduledoc """
  The public slug of a tag, section and section draft comes from `MishkaSlug.Change`: it keeps the
  script of the site's languages and turns Latin accents into ASCII.
  """
  use MishkaDocument.DataCase, async: false

  alias MishkaCmsCore.Settings
  alias MishkaDocument.Tag

  defp site_with(languages) do
    site = create_site!()
    {:ok, _setting} = Settings.put("site.languages", languages, site_id: site.id)
    site
  end

  defp create_tag(site, slug, language \\ "en") do
    Tag
    |> Ash.Changeset.for_create(
      :create,
      %{name: "Tag", slug: slug, language: language},
      tenant: site.id,
      authorize?: false
    )
    |> Ash.create()
  end

  describe "tag slug" do
    test "a Persian title keeps Persian on a fa and en site" do
      site = site_with(["fa", "en"])

      assert {:ok, %{slug: "راهنمای-شروع"}} = create_tag(site, "راهنمای شروع", "fa")
    end

    test "a Persian title is an error on an en-only site" do
      site = site_with(["en"])

      assert {:error, %Ash.Error.Invalid{errors: [%{field: :slug}]}} =
               create_tag(site, "راهنمای شروع", "fa")
    end

    test "English accents become ASCII" do
      site = site_with(["en"])

      assert {:ok, %{slug: "cafe-creme-brulee"}} = create_tag(site, "Café Crème brûlée")
    end

    test "an underscore stays and punctuation goes" do
      site = site_with(["en"])

      assert {:ok, %{slug: "my_post"}} = create_tag(site, "My_Post!")
    end
  end

  describe "section and section draft slug" do
    test "the draft makes the same slug as the published section" do
      site = site_with(["fa", "en"])
      title = "راهنمای شروع Café"

      section = create_section!(site_id: site.id, slug: title)
      draft = create_section_draft!(site_id: site.id, slug: title)

      assert section.slug == draft.slug
    end
  end
end
