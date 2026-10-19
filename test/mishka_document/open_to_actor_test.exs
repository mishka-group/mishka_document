# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_document/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaDocument.OpenToActorTest do
  @moduledoc """
  The statement a public read is kept to its reader by gives the answer `AccessPermissions` gives
  (`MishkaDocument.Resources.Preparations.OpenToActor`), and a read of records that name no lock
  asks nothing more than the records.

  The first half is a differential test: random sets of names a reader holds, random locks on
  documents, their versions, their clone records and their pages, and for each reader the records a
  list returns, the pages and count of a page at a time, and the records asked for one by one are
  compared with what `AccessPermissions.match?/3` says of every record's lock.

  Then pages: trees of them, as deep as a draw makes them and with a loop, an archived parent and a
  parent in another version among them, are compared with `EffectivePermissions` and the checker.
  The last part counts the statements a read costs, with and without a lock anywhere.
  """
  use MishkaDocument.DataCase, async: false

  require Ash.Query

  alias MishkaCmsCore.Accounts.Checks.AccessPermissions
  alias MishkaDocument.{Section, Workspace, WorkspaceVersion, WorkspaceVersionLineage}

  @moduletag :unit

  # Segments the random names are made of: the surfaces the checker treats apart, and a few areas.
  @segments ~w(admin dashboard api blog post document section x y)

  describe "the statement answers as AccessPermissions does" do
    setup do
      :rand.seed(:exsss, {17, 29, 31})
      site = create_site!()

      records =
        for n <- 1..36 do
          lock = lock()
          document = document!(site, "doc-#{n}", lock)
          version = version!(site, document)
          page = page!(site, version, "page-#{n}", [])

          clone =
            if rem(n, 3) == 0, do: clone!(site, document, version), else: nil

          %{lock: lock, document: document, version: version, page: page, clone: clone}
        end

      %{site: site, records: records}
    end

    test "for documents, versions, clone records and pages, by list and a page at a time", ctx do
      outcomes =
        Enum.reduce(1..30, %{}, fn round, outcomes ->
          actor = reader(ctx.site, round)
          shown = Enum.filter(ctx.records, &visible?(actor, &1.lock))

          expected = %{
            documents: shown |> Enum.map(& &1.document.id) |> Enum.sort(),
            versions:
              shown
              |> Enum.flat_map(&[&1.version.id | List.wrap(&1.clone && &1.clone.new_version_id)])
              |> Enum.sort(),
            pages: shown |> Enum.map(& &1.page.id) |> Enum.sort(),
            clones: shown |> Enum.flat_map(&List.wrap(&1.clone && &1.clone.id)) |> Enum.sort()
          }

          held = inspect(Enum.map(actor.permissions, & &1.name))

          assert ids(read_documents(ctx.site, actor)) == expected.documents,
                 "documents for #{held}"

          assert ids(read_versions(ctx.site, actor)) == expected.versions, "versions for #{held}"
          assert ids(read_pages(ctx.site, actor)) == expected.pages, "pages for #{held}"
          assert ids(read_clones(ctx.site, actor)) == expected.clones, "clones for #{held}"

          page =
            Workspace
            |> Ash.Query.for_read(:public_list, %{}, actor: actor, tenant: ctx.site.id)
            |> Ash.Query.sort(:slug)
            |> Ash.read!(actor: actor, tenant: ctx.site.id, page: [limit: 5, count: true])

          assert page.count == length(expected.documents), "count for #{held}"
          assert length(page.results) == min(5, length(expected.documents))

          Enum.reduce(ctx.records, outcomes, fn record, outcomes ->
            Map.update(outcomes, outcome(actor, record.lock), 1, &(&1 + 1))
          end)
        end)

      # The readers and the locks reach every outcome the statement must tell apart, or the
      # comparison above would pass on a statement that answered the same to all of them.
      assert Enum.all?(
               [:unlocked, :held, :not_held, :covered_but_not_counted],
               &(Map.get(outcomes, &1, 0) > 5)
             ),
             inspect(outcomes)
    end

    test "for a document asked for alone", ctx do
      for round <- 1..12, record <- Enum.take(ctx.records, 12) do
        actor = reader(ctx.site, round)

        result =
          Ash.get(Workspace, record.document.id,
            action: :public_get,
            actor: actor,
            tenant: ctx.site.id
          )

        held = inspect(Enum.map(actor.permissions, & &1.name))

        if visible?(actor, record.lock) do
          assert {:ok, _document} = result, "#{inspect(record.lock)} for #{held}"
        else
          assert {:error, %Ash.Error.Invalid{errors: [%Ash.Error.Query.NotFound{}]}} = result,
                 "#{inspect(record.lock)} for #{held}"
        end
      end
    end
  end

  describe "a name that holds punctuation" do
    test "matches only the names the checker matches" do
      site = create_site!()

      locks = [
        "docs:v1.2",
        "docs:v1x2",
        "docs:v1.*",
        "docs:v1",
        "docs:(x)",
        "docs:x+",
        "docs:naïve"
      ]

      documents =
        for {lock, n} <- Enum.with_index(locks) do
          {lock, document!(site, "punct-#{n}", [lock])}
        end

      for held <- [
            "docs:v1.2",
            "docs:v1.*",
            "docs:v1*",
            "docs:*",
            "docs:(x)",
            "docs:x+",
            "docs:naïve",
            "*"
          ] do
        actor = %{id: Ecto.UUID.generate(), site_id: site.id, permissions: [%{name: held}]}

        expected =
          documents
          |> Enum.filter(fn {lock, _document} -> visible?(actor, [lock]) end)
          |> Enum.map(fn {_lock, document} -> document.id end)
          |> Enum.sort()

        assert ids(read_documents(site, actor)) == expected, "held #{held}"
      end
    end
  end

  describe "a page whose own lock differs from its document's" do
    test "opens for whoever the checker opens it for, and is left out of every list otherwise" do
      site = create_site!()
      :rand.seed(:exsss, {3, 5, 7})

      for n <- 1..10 do
        document = document!(site, "mixed-#{n}", lock())
        version = version!(site, document)
        top = page!(site, version, "top", lock())
        middle = page!(site, version, "middle", lock(), parent_section_id: top.id)
        leaf = page!(site, version, "leaf", lock(), parent_section_id: middle.id)
        bare = page!(site, version, "bare", [], parent_section_id: leaf.id)

        locks = %{
          top.id => top.permissions,
          middle.id => middle.permissions,
          leaf.id => leaf.permissions,
          bare.id => []
        }

        for round <- 1..6 do
          actor = reader(site, round)

          expected =
            [top, middle, leaf, bare]
            |> Enum.filter(fn page ->
              visible?(
                actor,
                effective(page, [top, middle, leaf, bare], document.permissions, locks)
              )
            end)
            |> Enum.map(& &1.id)
            |> Enum.sort()

          seen =
            Section
            |> Ash.Query.for_read(
              :public_list_at_workspace_version,
              %{workspace_version_id: version.id},
              actor: actor,
              tenant: site.id
            )
            |> Ash.read!(actor: actor, tenant: site.id, page: false)
            |> ids()

          assert seen == expected,
                 "#{inspect(locks)} / #{inspect(document.permissions)} for #{inspect(actor.permissions)}"
        end
      end
    end
  end

  describe "while nothing is locked" do
    setup do
      site = create_site!()
      plain = document!(site, "plain", [])
      version = version!(site, plain)
      top = page!(site, version, "top", [])
      leaf = page!(site, version, "leaf", [], parent_section_id: top.id)

      %{
        site: site,
        plain: plain,
        version: version,
        top: top,
        leaf: leaf,
        lineage: clone!(site, plain, version),
        reader: user!(site, ["members:read"])
      }
    end

    test "a list of documents, versions or clone records is its own statement", ctx do
      for actor <- [nil, ctx.reader] do
        {documents, statements} = with_queries(fn -> read_documents(ctx.site, actor) end)
        assert ids(documents) == [ctx.plain.id]
        assert length(statements) == 1

        {versions, statements} = with_queries(fn -> read_versions(ctx.site, actor) end)
        assert length(versions) == 2
        assert length(statements) == 1

        {clones, statements} = with_queries(fn -> read_clones(ctx.site, actor) end)
        assert ids(clones) == [ctx.lineage.id]
        assert length(statements) == 1
      end
    end

    test "a page of documents is the page and its count, and nothing more", ctx do
      for actor <- [nil, ctx.reader] do
        {page, statements} =
          with_queries(fn ->
            Workspace
            |> Ash.Query.for_read(:public_list, %{}, actor: actor, tenant: ctx.site.id)
            |> Ash.read!(actor: actor, tenant: ctx.site.id, page: [limit: 10, count: true])
          end)

        assert page.count == 1
        assert length(statements) == 2
      end
    end

    test "a list of pages is its own statement", ctx do
      for actor <- [nil, ctx.reader] do
        {pages, statements} = with_queries(fn -> read_pages(ctx.site, actor) end)

        assert length(pages) == 2
        assert length(statements) == 1
      end
    end
  end

  describe "while a page of the site is locked" do
    test "a list of pages is its own statement still" do
      site = create_site!()
      locked = document!(site, "locked", [])
      version = version!(site, locked)
      secret = page!(site, version, "secret", ["members:read"])
      page!(site, version, "under", [], parent_section_id: secret.id)
      plain = document!(site, "plain", [])
      other = version!(site, plain)
      page!(site, other, "open", [])
      reader = user!(site, ["members:read"])

      for {actor, expected} <- [
            {nil, ["open"]},
            {user!(site, ["others:read"]), ["open"]},
            {reader, ["open", "secret", "under"]}
          ] do
        {pages, statements} = with_queries(fn -> read_pages(site, actor) end)

        assert Enum.sort(Enum.map(pages, & &1.slug)) == expected
        assert length(statements) == 1
      end
    end
  end

  describe "a page filed where a tree is not meant to have it" do
    test "meets the lock of the pages it is really under, and no other" do
      site = create_site!()
      guest = nil
      members = user!(site, ["members:read"])

      document = document!(site, "plain", [])
      version = version!(site, document)
      other = version!(site, document!(site, "elsewhere", []))

      across = page!(site, other, "across", ["members:read"])
      stray = page!(site, version, "stray", [])
      parent!(stray, across)

      locked = page!(site, version, "locked", ["members:read"])
      archived = page!(site, version, "archived", [], parent_section_id: locked.id)
      below = page!(site, version, "below", [], parent_section_id: archived.id)
      archive!(archived)

      loop_a = page!(site, version, "loop-a", ["members:read"])
      loop_b = page!(site, version, "loop-b", [], parent_section_id: loop_a.id)
      parent!(loop_a, loop_b)

      seen = fn actor ->
        Section
        |> Ash.Query.for_read(
          :public_list_at_workspace_version,
          %{workspace_version_id: version.id},
          actor: actor,
          tenant: site.id
        )
        |> Ash.read!(actor: actor, tenant: site.id, page: false)
        |> Enum.map(& &1.slug)
        |> Enum.sort()
      end

      assert seen.(guest) == ["below", "stray"]
      assert seen.(members) == ["below", "locked", "loop-a", "loop-b", "stray"]

      locks =
        Section
        |> Ash.Query.filter(id in ^[stray.id, below.id, loop_b.id])
        |> Ash.Query.load(:effective_permissions)
        |> Ash.read!(tenant: site.id, authorize?: false)
        |> Map.new(&{&1.slug, &1.effective_permissions})

      assert locks == %{"stray" => [], "below" => [], "loop-b" => ["members:read"]}
    end
  end

  describe "a tree of pages" do
    setup do
      :rand.seed(:exsss, {5, 8, 13})
      %{site: create_site!()}
    end

    test "opens for whoever EffectivePermissions and the checker open it for, however deep, " <>
           "looped, archived or filed under another version's page",
         %{site: site} do
      forests =
        for round <- 1..10 do
          document = document!(site, "forest-#{round}", lock())
          version = version!(site, document)
          other = version!(site, document!(site, "other-#{round}", lock()))
          nodes = grow(site, version, round)
          foreign = page!(site, other, "foreign-#{round}", lock())

          damage(nodes, foreign, round)
          %{document: document, version: version, nodes: nodes}
        end

      for round <- 1..12 do
        actor = reader(site, round)
        held = inspect(Enum.map(actor.permissions, & &1.name))

        for %{version: version, document: document} <- forests do
          expected =
            Section
            |> Ash.Query.filter(workspace_version_id == ^version.id)
            |> Ash.Query.load(:effective_permissions)
            |> Ash.read!(tenant: site.id, authorize?: false)
            |> Enum.filter(&visible?(actor, &1.effective_permissions))
            |> ids()

          seen =
            Section
            |> Ash.Query.for_read(
              :public_list_at_workspace_version,
              %{workspace_version_id: version.id},
              actor: actor,
              tenant: site.id
            )
            |> Ash.read!(actor: actor, tenant: site.id, page: false)
            |> ids()

          assert seen == expected,
                 "#{document.slug} (#{inspect(document.permissions)}) for #{held}"
        end
      end
    end
  end

  # ---------------------------------------------------------------------------

  # What a page opens with: its own, else its nearest parent's, else its document's.
  defp effective(page, pages, document_lock, locks) do
    by_id = Map.new(pages, &{&1.id, &1})

    case locks[page.id] do
      [_ | _] = own ->
        own

      _none ->
        case by_id[page.parent_section_id] do
          nil -> document_lock
          parent -> effective(parent, pages, document_lock, locks)
        end
    end
  end

  defp outcome(_actor, []), do: :unlocked

  defp outcome(actor, lock) do
    held = Enum.map(actor.permissions, & &1.name)

    api_covered? =
      Enum.any?(lock, fn entry ->
        String.starts_with?(entry, "admin:api:") and
          Enum.any?(held, &AccessPermissions.covers?(&1, entry))
      end)

    cond do
      AccessPermissions.match?(actor, %{}, permissions: lock) -> :held
      api_covered? -> :covered_but_not_counted
      true -> :not_held
    end
  end

  defp visible?(actor, lock),
    do: lock == [] or AccessPermissions.match?(actor, %{}, permissions: lock)

  # A forest of up to twenty-two pages, as deep as the draw makes it, a quarter of them naming a lock.
  defp grow(site, version, round) do
    Enum.reduce(1..22, [], fn n, made ->
      parent = if made == [] or :rand.uniform() < 0.2, do: nil, else: Enum.random(made)
      own = if :rand.uniform() < 0.25, do: lock(), else: []
      overrides = if parent, do: [parent_section_id: parent.id], else: []
      made ++ [page!(site, version, "r#{round}-#{n}", own, overrides)]
    end)
  end

  # What a tree is not meant to hold and the reads must still agree on: a page filed under another
  # version's, two pages under each other, and a page whose parent was archived.
  defp damage(nodes, foreign, round) do
    [a, b, c, d | _] = Enum.shuffle(nodes)

    case rem(round, 3) do
      0 ->
        parent!(a, foreign)

      1 ->
        parent!(a, b)
        parent!(b, a)

      2 ->
        archive!(c)
        parent!(d, c)
    end
  end

  defp parent!(section, parent) do
    {1, _} =
      MishkaDocument.Repo.update_all(
        from(s in "mishka_document_sections",
          where: s.id == type(^section.id, :binary_id),
          update: [set: [parent_section_id: type(^parent.id, :binary_id)]]
        ),
        []
      )

    :ok
  end

  defp archive!(section) do
    {1, _} =
      MishkaDocument.Repo.update_all(
        from(s in "mishka_document_sections",
          where: s.id == type(^section.id, :binary_id),
          update: [set: [archived_at: ^DateTime.utc_now()]]
        ),
        []
      )

    :ok
  end

  defp lock do
    case :rand.uniform(5) do
      1 -> []
      2 -> []
      3 -> [name()]
      4 -> [name(), name()]
      5 -> [name(), name(), name()]
    end
    |> Enum.uniq()
  end

  defp name do
    prefix =
      case :rand.uniform(5) do
        1 -> ["admin", "api"]
        2 -> ["admin", "dashboard"]
        _none -> []
      end

    rest = Enum.map(1..:rand.uniform(3), fn _ -> Enum.random(@segments) end)
    Enum.join(prefix ++ rest, ":")
  end

  # A name a reader holds: a name like a lock's, sometimes with a segment made a wildcard, and
  # sometimes the wildcard alone.
  defp held_name do
    case :rand.uniform(6) do
      1 ->
        "*"

      2 ->
        segments = String.split(name(), ":")
        index = :rand.uniform(length(segments)) - 1
        segments |> List.replace_at(index, "*") |> Enum.join(":")

      3 ->
        name() |> String.split(":") |> Enum.drop(-1) |> Kernel.++(["*"]) |> Enum.join(":")

      _plain ->
        name()
    end
  end

  # A reader holding up to four names. A map rather than a user: the checker reads only the names.
  defp reader(site, round) do
    names =
      if round == 1,
        do: [],
        else: 1..:rand.uniform(4) |> Enum.map(fn _ -> held_name() end) |> Enum.uniq()

    %{
      id: Ecto.UUID.generate(),
      site_id: site.id,
      permissions: Enum.map(names, &%{name: &1})
    }
  end

  defp user!(site, permissions), do: create_user_with_permissions!(permissions, site_id: site.id)

  defp document!(site, slug, permissions) do
    create_workspace!(
      site_id: site.id,
      skip_version: true,
      status: :active,
      slug: slug,
      language: "en",
      permissions: permissions
    )
  end

  defp version!(site, document, overrides \\ []) do
    create_workspace_version!(
      [
        site_id: site.id,
        workspace_id: document.id,
        status: :stable,
        version_number: "1.0.0",
        is_latest_for_version: true,
        published_at: ~U[2026-03-01 00:00:00Z]
      ] ++ overrides
    )
  end

  defp clone!(site, document, source) do
    version = version!(site, document, version_number: "2.0.0", is_latest_for_version: false)

    create_workspace_version_lineage!(
      site_id: site.id,
      new_version_id: version.id,
      source_version_id: source.id
    )
  end

  defp page!(site, version, slug, permissions, overrides \\ []) do
    create_section!(
      [
        site_id: site.id,
        workspace_version_id: version.id,
        slug: slug,
        language: "en",
        content_review_status: :approved,
        technical_review_status: :approved,
        permissions: permissions
      ] ++ overrides
    )
  end

  defp read_documents(site, actor) do
    Workspace
    |> Ash.Query.for_read(:public_list, %{}, actor: actor, tenant: site.id)
    |> Ash.read!(actor: actor, tenant: site.id, page: false)
  end

  defp read_versions(site, actor) do
    WorkspaceVersion
    |> Ash.Query.for_read(:public_list, %{}, actor: actor, tenant: site.id)
    |> Ash.read!(actor: actor, tenant: site.id, page: false)
  end

  defp read_clones(site, actor) do
    WorkspaceVersionLineage
    |> Ash.Query.for_read(:public_recent_clones, %{}, actor: actor, tenant: site.id)
    |> Ash.read!(actor: actor, tenant: site.id, page: [limit: 200])
    |> Map.fetch!(:results)
  end

  defp read_pages(site, actor) do
    Section
    |> Ash.Query.for_read(:public_list, %{}, actor: actor, tenant: site.id)
    |> Ash.read!(actor: actor, tenant: site.id, page: false)
  end

  defp ids(records), do: records |> Enum.map(& &1.id) |> Enum.sort()
end
