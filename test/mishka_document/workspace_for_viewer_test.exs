# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_document/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaDocument.WorkspaceForViewerTest do
  @moduledoc """
  `MishkaDocument.Workspace.for_viewer/2`: one workspace as the admin looking at it may read it.
  """
  use MishkaDocument.DataCase, async: false

  alias MishkaDocument.Workspace

  setup do
    site = create_site!()
    workspace = create_workspace!(site_id: site.id)

    %{
      workspace: workspace,
      master: create_user_with_permissions!(["admin:dashboard:*"]),
      admin: create_user_with_permissions!(["admin:dashboard:*"], site_id: site.id),
      outsider: create_user_with_permissions!(["admin:dashboard:*"], site_id: create_site!().id),
      nobody: create_user_with_permissions!(["admin:dashboard:runtime:page"], site_id: site.id)
    }
  end

  test "a master reads any site's workspace", %{workspace: workspace, master: master} do
    assert %Workspace{id: id} = Workspace.for_viewer(master, workspace.id)
    assert id == workspace.id
  end

  test "a site admin reads its own site's workspace and no other site's", ctx do
    assert %Workspace{} = Workspace.for_viewer(ctx.admin, ctx.workspace.id)
    assert Workspace.for_viewer(ctx.outsider, ctx.workspace.id) == nil
  end

  test "a viewer holding no document area reads none", %{workspace: workspace, nobody: nobody} do
    assert Workspace.for_viewer(nobody, workspace.id) == nil
  end

  test "an id that names nothing, or no viewer, is nil", %{master: master, workspace: workspace} do
    assert Workspace.for_viewer(master, Ecto.UUID.generate()) == nil
    assert Workspace.for_viewer(nil, workspace.id) == nil
  end
end
