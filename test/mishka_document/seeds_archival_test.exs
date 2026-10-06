defmodule MishkaDocument.SeedsArchivalTest do
  @moduledoc """
  The one archival rule this extension's seeds have to respect.

  Several resources carry BOTH an `:archived` value in their status enum and an `archived_at`
  soft-delete timestamp, and only the timestamp decides which tab the admin shows a row in. A row
  holding the archived LABEL while staying live therefore reads, to anyone using the admin, as an
  archived record sitting in the Active tab — and a row soft-deleted WITHOUT the label reads the
  other way round in any list that colours by status.

  So for seeded data the two must agree: **status `:archived` if and only if `archived_at` is set.**

  Resources are discovered from the configured domains rather than listed, so a resource that later
  gains the second axis is covered the day it does. Comparison is raw SQL on purpose: these resources
  declare `base_filter_sql "(archived_at IS NULL)"`, so no Ash read can see both sides at once.

  Each extension owns this check for its own seeds; see `MishkaBlog.SeedsArchivalTest`.

  The seeded site is also asked one thing that is not about archival, because a second full seed
  would double this file's run time: the users handed to the seed include a master, as
  `priv/repo/dev_seeds.exs` hands them, and some of the issue comments must be that master's — a
  tenant admin can read those but not edit or delete them, and a seed without any never shows it.
  It is also asked whether some of the section views it tracks belong to a signed-in reader, and
  whether the two permission examples are written beside the products.

  The permission examples are asked on their own on a site that already has documentation, the way
  a database seeded before they existed meets them, so that run writes nothing else.
  """
  use MishkaDocument.DataCase, async: false

  import MishkaDocument.Test.Factory

  alias MishkaCmsCore.Runtime.{PageEditions, Seo}
  alias MishkaDocument.Plugins.PageSeo
  alias MishkaDocument.{Provision, Section}

  require Ash.Query

  @editors_only ["admin:dashboard:document:section"]
  @noindex [%{tag: "meta", attrs: %{"name" => "robots"}, content: "noindex, follow"}]
  @index [%{tag: "meta", attrs: %{"name" => "robots"}, content: "index, follow"}]
  @example_documents ["internal-handbook", "team-guide", "release-notes-archive"]

  @doc false
  def two_axis_resources do
    :mishka_document
    |> Application.fetch_env!(:ash_domains)
    |> Enum.flat_map(&Ash.Domain.Info.resources/1)
    |> Enum.uniq()
    |> Enum.filter(&two_axis?/1)
    |> Enum.map(&{&1, AshPostgres.DataLayer.Info.table(&1)})
    |> Enum.sort_by(fn {resource, _table} -> inspect(resource) end)
  end

  defp two_axis?(resource) do
    !is_nil(Ash.Resource.Info.attribute(resource, :archived_at)) and
      :archived in status_values(resource)
  end

  defp status_values(resource) do
    case Ash.Resource.Info.attribute(resource, :status) do
      %{constraints: constraints} -> Keyword.get(constraints, :one_of, [])
      _other -> []
    end
  end

  defp count(sql) do
    MishkaDocument.Repo
    |> Ecto.Adapters.SQL.query!(sql, [])
    |> Map.fetch!(:rows)
    |> hd()
    |> hd()
  end

  defp labelled_but_live(table),
    do:
      count(
        "SELECT count(*) FROM #{table} WHERE status::text = 'archived' AND archived_at IS NULL"
      )

  defp archived_without_label(table),
    do:
      count(
        "SELECT count(*) FROM #{table} WHERE archived_at IS NOT NULL AND status::text <> 'archived'"
      )

  defp archived(table), do: count("SELECT count(*) FROM #{table} WHERE archived_at IS NOT NULL")

  # THE EXTENSION'S OWN ROLE ACCOUNTS, which its seed adds once installing it has created the names.
  defp held_by(email, site_id) do
    MishkaCmsCore.Accounts.User
    |> Ash.Query.filter(email == ^email and site_id == ^site_id)
    |> Ash.Query.load(:permissions)
    |> Ash.read_one!(authorize?: false)
    |> Map.fetch!(:permissions)
    |> Enum.map(& &1.name)
  end

  # Every page of the permission and robots examples, a row per page:
  # `{document, page, document's permissions, page's permissions, page's seo_tags, listed?}`.
  defp example_pages(site_id) do
    Section
    |> Ash.Query.filter(workspace_version.workspace.slug in @example_documents)
    |> Ash.Query.load(workspace_version: :workspace)
    |> Ash.read!(tenant: site_id, authorize?: false, page: false)
    |> Enum.map(fn %{workspace_version: %{workspace: document}} = page ->
      {document.slug, page.slug, document.permissions, page.permissions, page.seo_tags,
       PageEditions.listed?(page, document)}
    end)
    |> Enum.sort()
  end

  # What the documentation's page answers a reader of `document`'s `page`, as
  # `MishkaCmsWeb.RuntimeLive` asks it.
  defp page_seo(site_id, document, page) do
    {:reply, :halt, answered} =
      %{
        title: "Document page",
        path: Provision.item_paths().section,
        language: "en",
        seo: %{description: nil, schema: []}
      }
      |> Seo.given(
        site_id: site_id,
        url: nil,
        params: %{"lang" => "en", "workspace" => document, "section" => page},
        record: "docs:page"
      )
      |> PageSeo.call()

    answered
  end

  # A full seed is expensive, so it runs ONCE for the whole file and every assertion about seeded
  # data lives in the single test below.
  describe "a seeded site" do
    setup do
      site = create_site!()
      users = [create_user!(), create_user!(site_id: site.id)]

      MishkaDocument.Dev.Seeds.dev_seed(site.id, users)

      %{site: site}
    end

    # A full dev seed run, measured at 30-48s depending on machine load, against ExUnit's 60s
    # default — close enough that it timed out in a full-suite run and passed alone. The budget is
    # explicit rather than left to chance; it is not a retry, the test still has to finish.
    @tag timeout: 180_000
    test "labels and timestamps agree, the seeds really soft-delete, a master wrote comments", %{
      site: site
    } do
      assert held_by("editor@#{site.name}.test", site.id) == ["admin:dashboard:document:section"]

      offenders =
        for {resource, table} <- two_axis_resources(),
            live = labelled_but_live(table),
            orphan = archived_without_label(table),
            live > 0 or orphan > 0 do
          "#{inspect(resource)}: #{live} labelled-but-live, #{orphan} archived-without-label"
        end

      assert offenders == []

      assert archived("mishka_document_workspaces") > 0

      comments_by_authorship =
        MishkaDocument.IssueComment
        |> Ash.read!(tenant: site.id, authorize?: false, load: [:authored_by_master?])
        |> Enum.frequencies_by(& &1.authored_by_master?)

      assert Map.get(comments_by_authorship, true, 0) > 0
      assert Map.get(comments_by_authorship, false, 0) > 0

      assert MishkaDocument.SectionView
             |> Ash.read!(authorize?: false)
             |> Enum.any?(&(not is_nil(&1.user_id)))

      assert length(example_pages(site.id)) == 7
    end
  end

  describe "the permission examples" do
    setup do
      site = create_site!()
      create_workspace!(site_id: site.id, slug: "documented-before")

      %{site: site, users: [create_user!(), create_user!(site_id: site.id)]}
    end

    test "are written once, show to a reader, and keep what an admin changed", %{
      site: site,
      users: users
    } do
      assert MishkaDocument.Dev.Seeds.dev_seed(site.id, users) == :already_seeded

      assert example_pages(site.id) == [
               {"internal-handbook", "onboarding", @editors_only, [], [], false},
               {"internal-handbook", "tools-we-use", @editors_only, [], [], false},
               {"release-notes-archive", "latest-release", [], [], @index, true},
               {"release-notes-archive", "older-releases", [], [], [], false},
               {"team-guide", "meeting-notes", [], [], @noindex, false},
               {"team-guide", "pay-and-leave", [], @editors_only, [], false},
               {"team-guide", "welcome", [], [], [], true}
             ]

      for {document, page, title, permissions} <- [
            {"internal-handbook", "onboarding", "Onboarding", @editors_only},
            {"internal-handbook", "tools-we-use", "Tools we use", @editors_only},
            {"team-guide", "welcome", "Welcome", []},
            {"team-guide", "pay-and-leave", "Pay and leave", @editors_only},
            {"team-guide", "meeting-notes", "Meeting notes", []},
            {"release-notes-archive", "older-releases", "Older releases", []},
            {"release-notes-archive", "latest-release", "Latest release", []}
          ] do
        answered = page_seo(site.id, document, page)

        assert {answered.title, answered.permissions} == {title, permissions}
      end

      handbook =
        MishkaDocument.Workspace
        |> Ash.Query.filter(slug == "internal-handbook")
        |> Ash.read_one!(tenant: site.id, authorize?: false)

      Ash.update!(handbook, %{permissions: []}, tenant: site.id, authorize?: false)

      assert MishkaDocument.Dev.Seeds.dev_seed(site.id, users) == :already_seeded

      assert example_pages(site.id) == [
               {"internal-handbook", "onboarding", [], [], [], true},
               {"internal-handbook", "tools-we-use", [], [], [], true},
               {"release-notes-archive", "latest-release", [], [], @index, true},
               {"release-notes-archive", "older-releases", [], [], [], false},
               {"team-guide", "meeting-notes", [], [], @noindex, false},
               {"team-guide", "pay-and-leave", [], @editors_only, [], false},
               {"team-guide", "welcome", [], [], [], true}
             ]

      assert MishkaDocument.WorkspaceVersion
             |> Ash.Query.filter(workspace.slug in @example_documents)
             |> Ash.count!(tenant: site.id, authorize?: false) == 3
    end
  end

  # A guard on the discovery itself: were it ever to return [], the test above would pass vacuously
  # and stop protecting anything. Needs no seed, so it sits outside the describe.
  test "the discovery finds this extension's two-axis resources" do
    tables = two_axis_resources() |> Enum.map(&elem(&1, 1))

    assert "mishka_document_workspaces" in tables
  end
end
