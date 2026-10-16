# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_document/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaDocument.Dashboard.WidgetsTest do
  @moduledoc """
  Each document dashboard widget is its own `dashboard:widgets` plugin. These call each plugin's
  `call/1` (it appends its descriptor) and run its real `load/1` + render through `Widget.card/1`
  against the test DB — a wrong cross-tenant read action or field would raise here. The seeded
  tests also pin the tenant contract against three actors: a MASTER with roles (`site_id: nil`) sees
  every site's rows, a TENANT with roles only its own site's, and a user with no roles is not
  offered the widget at all.
  """
  use MishkaDocument.DataCase, async: false

  import Phoenix.LiveViewTest
  import MishkaDocument.Test.Factory

  alias MishkaCmsCore.Dashboard.Widget

  alias MishkaDocument.Dashboard.Widgets.{
    RecentDocuments,
    VersionActivity,
    OpenIssues,
    WorkspacesSummary
  }

  @widgets [
    {RecentDocuments, "doc-recent", nil},
    {VersionActivity, "doc-version-activity", nil},
    {OpenIssues, "doc-open-issues", "Open"},
    {WorkspacesSummary, "doc-workspaces-summary", "Versions"}
  ]

  for {module, id, marker} <- @widgets do
    test "#{id}: call/1 appends a valid descriptor" do
      assert {:reply,
              %{widgets: [%Widget{id: unquote(id), component: {unquote(module), :render}}]}} =
               unquote(module).call(%{widgets: []})
    end

    test "#{id}: load/1 runs and renders without the failure placeholder" do
      data = apply(unquote(module), :load, [master()])

      html =
        render_component(&Widget.card/1,
          widget: unquote(module).widget(),
          state: {:ok, data},
          current_user: master()
        )

      refute html =~ "could not load"
      assert_marker(html, unquote(marker))
    end

    test "#{id}: is not offered to a user without roles" do
      widget = unquote(module).widget()

      assert Widget.permitted?(widget, master())
      refute Widget.permitted?(widget, create_user!(site_id: create_site!().id))
    end
  end

  # EACH WIDGET READS ITS DATA WITH NO POLICY IN THE WAY, so the area it names is the only gate on
  # that data: the issue and document lists are the section area's, the version timeline and the
  # summary the workspace area's. Its settings carry the same gate.
  @areas [
    {RecentDocuments, "admin:dashboard:document:section", "admin:dashboard:document:workspace"},
    {OpenIssues, "admin:dashboard:document:section", "admin:dashboard:document:workspace"},
    {VersionActivity, "admin:dashboard:document:workspace", "admin:dashboard:document:section"},
    {WorkspacesSummary, "admin:dashboard:document:workspace", "admin:dashboard:document:section"}
  ]

  for {module, own, other} <- @areas do
    test "#{inspect(module)}: is offered to its own area and to no other" do
      widget = unquote(module).widget()
      site = create_site!()

      assert Widget.permitted?(
               widget,
               create_user_with_permissions!([unquote(own)], site_id: site.id)
             )

      assert Widget.permitted?(
               widget,
               create_user_with_permissions!(["admin:dashboard:document:*"])
             )

      for names <- [[unquote(other)], ["admin:dashboard:runtime:page"], ["admin:api:document:*"]] do
        refute Widget.permitted?(widget, create_user_with_permissions!(names, site_id: site.id)),
               "#{inspect(names)} was offered #{widget.id}"
      end

      for definition <- Widget.settings_definitions(widget) do
        assert definition.permission == widget.permission
      end
    end
  end

  # A master is a user whose `site_id` is nil — not a missing user, which `Widget.scope/1` refuses.
  defp master, do: create_user_with_permissions!(["admin:dashboard:*"])

  defp tenant(site), do: create_user_with_permissions!(["admin:dashboard:*"], site_id: site.id)

  # The test database is seeded, so absolute totals are meaningless here — what has to hold is the
  # relationship between the two views: a tenant counts ONLY its own site, and a master counts at
  # least everything the tenant can see plus the neighbour's row.
  test "doc-workspaces-summary: counts workspaces and versions, tenant-scoped" do
    site = create_site!()
    other = create_site!()
    create_workspace!(site_id: site.id, status: :active)
    create_workspace!(site_id: other.id, status: :draft)

    master_view = WorkspacesSummary.load(master())
    tenant_view = WorkspacesSummary.load(tenant(site))

    assert %{total: 1, versions: 1} = tenant_view
    assert master_view.total > tenant_view.total
    assert master_view.versions > tenant_view.versions
  end

  test "doc-recent: rows show the workspace name with a status badge, tenant-scoped" do
    site = create_site!()
    other = create_site!()

    create_workspace!(
      site_id: site.id,
      name: "Handbook Alpha",
      status: :active,
      skip_version: true
    )

    create_workspace!(
      site_id: other.id,
      name: "Handbook Beta",
      status: :draft,
      skip_version: true
    )

    master_html = render_widget(RecentDocuments, RecentDocuments.load(master()))
    assert master_html =~ "Handbook Alpha"
    assert master_html =~ "Handbook Beta"
    assert master_html =~ "active"
    assert master_html =~ "draft"

    tenant_html = render_widget(RecentDocuments, RecentDocuments.load(tenant(site)))
    assert tenant_html =~ "Handbook Alpha"
    refute tenant_html =~ "Handbook Beta"
  end

  test "doc-version-activity: rows show workspace name, version and status badge, tenant-scoped" do
    site = create_site!()
    other = create_site!()
    workspace = create_workspace!(site_id: site.id, name: "Docs Gamma", skip_version: true)
    other_workspace = create_workspace!(site_id: other.id, name: "Docs Delta", skip_version: true)

    create_workspace_version!(
      workspace_id: workspace.id,
      site_id: site.id,
      version_number: "1.0.0",
      status: :beta
    )

    create_workspace_version!(
      workspace_id: other_workspace.id,
      site_id: other.id,
      version_number: "2.0.0",
      status: :draft
    )

    master_html = render_widget(VersionActivity, VersionActivity.load(master()))
    assert master_html =~ "Docs Gamma"
    assert master_html =~ "v1.0.0"
    assert master_html =~ "Beta"
    assert master_html =~ "v2.0.0"

    tenant_html = render_widget(VersionActivity, VersionActivity.load(tenant(site)))
    assert tenant_html =~ "Docs Gamma"
    assert tenant_html =~ "v1.0.0"
    refute tenant_html =~ "Docs Delta"
    refute tenant_html =~ "v2.0.0"
  end

  test "doc-recent: each row names its latest version, for a master and for a tenant" do
    site = create_site!()
    other = create_site!()
    workspace = create_workspace!(site_id: site.id, name: "Manual Epsilon", skip_version: true)

    other_workspace =
      create_workspace!(site_id: other.id, name: "Manual Zeta", skip_version: true)

    create_workspace_version!(
      workspace_id: workspace.id,
      site_id: site.id,
      version_number: "3.1.0"
    )

    create_workspace_version!(
      workspace_id: other_workspace.id,
      site_id: other.id,
      version_number: "4.2.0"
    )

    master_html = render_widget(RecentDocuments, RecentDocuments.load(master()))
    assert master_html =~ "v3.1.0"
    assert master_html =~ "v4.2.0"

    tenant_html = render_widget(RecentDocuments, RecentDocuments.load(tenant(site)))
    assert tenant_html =~ "Manual Epsilon"
    assert tenant_html =~ "v3.1.0"
    refute tenant_html =~ "v4.2.0"
  end

  test "doc-open-issues: counts open issues and badges the issue type, tenant-scoped" do
    site = create_site!()
    other = create_site!()
    create_issue!(site_id: site.id, title: "Broken anchor in guide", issue_type: :broken_link)
    create_issue!(site_id: other.id, title: "Misspelled heading", issue_type: :typo)

    master_view = OpenIssues.load(master())
    tenant_view = OpenIssues.load(tenant(site))

    assert tenant_view.count == 1
    assert master_view.count > tenant_view.count

    tenant_html = render_widget(OpenIssues, tenant_view)
    assert tenant_html =~ "Broken anchor in guide"
    assert tenant_html =~ "Broken link"
    refute tenant_html =~ "Misspelled heading"
  end

  defp render_widget(module, data) do
    render_component(&Widget.card/1,
      widget: module.widget(),
      state: {:ok, data},
      current_user: master()
    )
  end

  # A widget listed with a `nil` marker has no text of its own to look for.
  defp assert_marker(_html, nil), do: :ok
  defp assert_marker(html, marker), do: assert(html =~ marker)
end
