# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_document/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaDocument.ForeignTenantJoinRowsTest do
  @moduledoc """
  A site user writes join, bookmark, follow and view rows for its own site only, even when the
  caller hands it another site as the tenant. These resources have no multitenancy of their own, so
  the tenant is only a claim, and `MishkaCmsCore.Runtime.Resources.Validations.TenantIsolation`
  is what holds the named records to the writer's site.
  """
  use MishkaDocument.DataCase, async: false

  alias MishkaDocument.{SectionBookmark, SectionTag, SectionView, WorkspaceFollower}

  defp create_as(resource, action, attrs, opts) do
    resource
    |> Ash.Changeset.for_create(action, attrs, opts)
    |> Ash.create()
  end

  setup do
    site_a = create_site!()
    site_b = create_site!()

    %{
      site_a: site_a,
      site_b: site_b,
      section_b: create_section!(site_id: site_b.id),
      tag_b: create_document_tag!(site_id: site_b.id),
      workspace_b: create_workspace!(site_id: site_b.id, skip_version: true)
    }
  end

  test "a site admin cannot tag another site's section by naming that site as the tenant", ctx do
    admin = create_user_with_permissions!(["*"], site_id: ctx.site_a.id)

    assert {:error, _} =
             create_as(SectionTag, :assign, %{section_id: ctx.section_b.id, tag_id: ctx.tag_b.id},
               actor: admin,
               tenant: ctx.site_b.id
             )
  end

  test "a site user cannot bookmark, follow or view another site's records by naming that site as the tenant",
       ctx do
    user = create_user!(site_id: ctx.site_a.id)

    assert {:error, _} =
             create_as(SectionBookmark, :create, %{section_id: ctx.section_b.id},
               actor: user,
               tenant: ctx.site_b.id
             )

    assert {:error, _} =
             create_as(WorkspaceFollower, :create, %{workspace_id: ctx.workspace_b.id},
               actor: user,
               tenant: ctx.site_b.id
             )

    assert {:error, _} =
             create_as(
               SectionView,
               :create,
               %{section_id: ctx.section_b.id, ip_address: "203.0.113.7"},
               actor: user,
               tenant: ctx.site_b.id
             )
  end

  test "a master still writes them for any site it names", ctx do
    master = create_user_with_permissions!(["*"])

    assert {:ok, _} =
             create_as(SectionTag, :assign, %{section_id: ctx.section_b.id, tag_id: ctx.tag_b.id},
               actor: master,
               tenant: ctx.site_b.id
             )
  end
end
