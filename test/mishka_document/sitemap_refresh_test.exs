# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_document/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaDocument.SitemapRefreshTest do
  @moduledoc """
  A write of a workspace, a version or a section schedules its site's `"sitemap"` job, tenant and
  master alike: the three list `MishkaCmsCore.Runtime.Resources.Notifiers.SitemapRefresh`. What the
  job then lists for the documentation is pinned in `MishkaDocument.Plugins.SitemapUrlsTest`.

  `MishkaCmsCore.Runtime.Compilers.SitemapCompiler.schedule/1` does nothing while `:env_test?` is
  set, so the setup switches it off once every row exists: a job found here was enqueued by the
  write under test.

  `async: false` — `SiteState` and the `:env_test?` flag are process-global.
  """
  use MishkaDocument.DataCase, async: false
  use Oban.Testing, repo: MishkaDocument.Repo

  alias MishkaCmsCore.Runtime.States.SiteState
  alias MishkaCmsCore.Runtime.Workers.RuntimeCompilerWorker

  setup do
    [site, other] = [docs_site!(), docs_site!()]

    workspace = create_workspace!(site_id: site.id, skip_version: true)

    version =
      create_workspace_version!(workspace_id: workspace.id, site_id: site.id, status: :draft)

    section = create_section!(site_id: site.id, workspace_version_id: version.id)
    other_section = create_section!(site_id: other.id)

    Application.put_env(:mishka_cms_core, :env_test?, false)
    on_exit(fn -> Application.put_env(:mishka_cms_core, :env_test?, true) end)

    {:ok,
     site: site,
     other: other,
     workspace: workspace,
     version: version,
     section: section,
     other_section: other_section}
  end

  # `:create` caches an active site in `SiteState`; `schedule/1` enqueues only for such a one.
  defp docs_site! do
    name = "sitemaprefresh#{System.unique_integer([:positive])}"
    site = create_site!(name: name, host: "#{name}.test", active: true)
    on_exit(fn -> SiteState.delete(site.id) end)
    site
  end

  defp sitemap_jobs(site) do
    all_enqueued(worker: RuntimeCompilerWorker)
    |> Enum.filter(fn job ->
      get_in(job.args, ["data", "type"]) == "sitemap" and
        get_in(job.args, ["data", "site_id"]) == site.id
    end)
  end

  defp update_section!(section, attrs) do
    section
    |> Ash.Changeset.for_update(:update, attrs, tenant: section.site_id, authorize?: false)
    |> Ash.update!()
  end

  test "a section updated schedules its site's sitemap job", %{site: site, section: section} do
    assert sitemap_jobs(site) == []

    update_section!(section, %{content_review_status: :approved})

    site_name = site.name

    assert [%{queue: "sitemaps", args: %{"data" => %{"site_name" => ^site_name}}}] =
             sitemap_jobs(site)
  end

  test "a version published schedules its site's sitemap job", %{site: site, version: version} do
    version
    |> Ash.Changeset.for_update(:publish, %{}, tenant: site.id, authorize?: false)
    |> Ash.update!()

    assert [_job] = sitemap_jobs(site)
  end

  test "a version marked latest schedules its site's sitemap job",
       %{site: site, version: version} do
    version
    |> Ash.Changeset.for_update(:mark_as_latest, %{}, tenant: site.id, authorize?: false)
    |> Ash.update!()

    assert [_job] = sitemap_jobs(site)
  end

  test "a master updating a workspace schedules the workspace's own site's sitemap job",
       %{site: site, other: other, workspace: workspace} do
    workspace
    |> Ash.Changeset.for_update(:master_update, %{name: "Renamed by a master"}, authorize?: false)
    |> Ash.update!()

    assert [_job] = sitemap_jobs(site)
    assert sitemap_jobs(other) == []
  end

  test "a workspace archived schedules its site's sitemap job",
       %{site: site, workspace: workspace} do
    workspace
    |> Ash.Changeset.for_destroy(:destroy, %{}, tenant: site.id, authorize?: false)
    |> Ash.destroy!()

    assert [_job] = sitemap_jobs(site)
  end

  test "a burst of section updates on one site is one job", %{site: site, section: section} do
    Enum.reduce(1..5, section, &update_section!(&2, %{title: "Burst #{&1}"}))

    assert [_job] = sitemap_jobs(site)
  end

  test "another site's section updated schedules that site's job and not this site's",
       %{site: site, other: other, other_section: other_section} do
    update_section!(other_section, %{title: "Another site's page"})

    assert [_job] = sitemap_jobs(other)
    assert sitemap_jobs(site) == []
  end
end
