# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_document/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaDocument.LockedPageRecordsTest do
  @moduledoc """
  A record whose address is answered by a page of the site its reader may not open is not listed
  for that reader, and is not found when asked for alone
  (`MishkaDocument.Resources.Preparations.OpenToActor`). The pages are rows of the site's own
  (`MishkaCmsCore.Runtime.Page`): the two a document's address is given when it is set, and the
  pages with no address written by the factory, each showing the kind of record its `extra` names
  and locked by the permissions it names.

  Three documents: `own`, at an address of its own (`/guide/docs`); `bare`, with none, answered by
  the pages with no address; `plain`, at `/other/docs`, whose pages stay open. Each has a published
  version and a clone of it, a front page and another page; `own` also has a page filed under its
  front page. Every scenario locks some pages and names what a visitor who is not signed in, and a
  reader holding another name, may no longer see; a reader holding the page's permission sees all.
  """
  use MishkaDocument.DataCase, async: false

  alias MishkaCmsCore.Runtime.{Languages, Page, PageEditions}
  alias MishkaCmsCore.Runtime.States.SettingsState
  alias MishkaCmsCore.Settings
  alias MishkaDocument.{Section, Workspace, WorkspaceVersion, WorkspaceVersionLineage}
  alias MishkaDocument.Plugins.SitemapUrls

  @moduletag :unit

  @lock ["members:read"]

  @own_front "/guide/docs"
  @own_page "/guide/docs/*section"
  @plain_front "/other/docs"
  @plain_page "/other/docs/*section"
  @bare_front "/:lang/docs/:workspace"
  @bare_page "/:lang/docs/:workspace/*section"

  setup do
    name = "lockedpages#{System.unique_integer([:positive])}"
    site = create_site!(name: name, host: "#{name}.test", active: true)

    documents =
      for {key, path} <- [own: "/guide/docs", bare: nil, plain: "/other/docs"], into: %{} do
        document = document!(site, Atom.to_string(key), path)
        version = version!(site, document)
        clone = clone!(site, document, version)
        front = section!(site, version, "#{key}-front", front_page: true)
        other = section!(site, version, "#{key}-other")
        {key, %{document: document, version: version, clone: clone, front: front, other: other}}
      end

    child =
      section!(site, documents.own.version, "own-child",
        parent_section_id: documents.own.front.id
      )

    %{
      site: site,
      documents: documents,
      child: child,
      stranger: create_user_with_permissions!(["others:read"], site_id: site.id),
      member: create_user_with_permissions!(@lock, site_id: site.id)
    }
  end

  # The pages each scenario locks, and what a reader who may not open them no longer sees: a whole
  # document — its record, its versions, its clone records and its front page — or one of its pages.
  @scenarios [
    {"its own front page", [@own_front], [:own, own: :front]},
    {"the other pages at its own address", [@own_page], [own: :other, own: :child]},
    {"both pages at its own address", [@own_front, @own_page],
     [:own, own: :front, own: :other, own: :child]},
    {"the front page with no address", [@bare_front], [:bare, bare: :front]},
    {"the other pages with no address", [@bare_page], [bare: :other]},
    {"every documentation page", [@own_front, @own_page, @bare_front, @bare_page],
     [:own, :bare, own: :front, own: :other, own: :child, bare: :front, bare: :other]}
  ]

  describe "the tables the statement names" do
    test "are the resources' own" do
      assert AshPostgres.DataLayer.Info.table(Page) == "pages"
      assert AshPostgres.DataLayer.Info.table(Workspace) == "mishka_document_workspaces"

      for {resource, columns} <- [
            {Page, [:id, :site_id, :path, :extra, :permissions, :active, :archived_at]},
            {Workspace, [:site_id, :path]}
          ],
          column <- columns do
        assert %{source: ^column} = Ash.Resource.Info.attribute(resource, column),
               "#{inspect(resource)}.#{column}"
      end
    end
  end

  describe "a record whose page is locked" do
    for {name, locked, hidden} <- @scenarios do
      @locked locked
      @hidden hidden

      test "by #{name} is left out of every list for a reader who may not open it", ctx do
        register!(ctx.site, @locked)

        for actor <- [nil, ctx.stranger] do
          assert listed(ctx, actor) == expected(ctx, @hidden), "for #{inspect(held(actor))}"
        end

        assert listed(ctx, ctx.member) == expected(ctx, [])
      end

      test "by #{name} is not found alone by a reader who may not open it", ctx do
        register!(ctx.site, @locked)

        for actor <- [nil, ctx.stranger] do
          assert asked_alone(ctx, actor) == expected_alone(ctx, @hidden),
                 "for #{inspect(held(actor))}"
        end

        assert asked_alone(ctx, ctx.member) == expected_alone(ctx, [])
      end
    end

    test "is read by the system all the same", ctx do
      register!(ctx.site, [@own_front, @own_page, @bare_front, @bare_page])

      assert ids(read(Workspace, :public_list, ctx.site, nil, authorize?: false)) ==
               ids(Enum.map(Map.values(ctx.documents), & &1.document))

      assert length(read(Section, :public_list, ctx.site, nil, authorize?: false)) == 7
    end

    test "keeps its record lock: a locked document stays out for a reader its page lets in",
         ctx do
      register!(ctx.site, [@own_front])
      locked = document!(ctx.site, "locked", nil, @lock)

      assert locked.id not in ids(read(Workspace, :public_list, ctx.site, ctx.stranger))
      assert locked.id in ids(read(Workspace, :public_list, ctx.site, ctx.member))
      refute ctx.documents.own.document.id in ids(read(Workspace, :public_list, ctx.site, nil))
    end
  end

  describe "a read the JSON:API or GraphQL makes" do
    test "is kept to the same pages as the site's", ctx do
      register!(ctx.site, [@own_front, @bare_page])
      api = %{shared: %{admin_surface: :api}}

      for actor <- [nil, ctx.stranger, ctx.member] do
        assert listed(ctx, actor, context: api) == listed(ctx, actor),
               "for #{inspect(held(actor))}"

        assert asked_alone(ctx, actor, context: api) == asked_alone(ctx, actor)
      end

      assert listed(ctx, nil, context: api) == expected(ctx, [:own, own: :front, bare: :other])

      assert asked_alone(ctx, nil, context: api) ==
               expected_alone(ctx, [:own, own: :front, bare: :other])
    end
  end

  describe "a document with no address" do
    test "stays listed while one of the pages with no address is open", ctx do
      register!(ctx.site, [@bare_front], [{"/fa/docs/:workspace", "docs:document", []}])

      assert listed(ctx, nil) == expected(ctx, [])
    end

    test "is left out once every one of them is locked", ctx do
      register!(ctx.site, [@bare_front], [{"/fa/docs/:workspace", "docs:document", @lock}])

      assert listed(ctx, nil) == expected(ctx, [:bare, bare: :front])
    end
  end

  describe "while no documentation page is locked" do
    test "every list is what it is with no page at all, read by the same statement", ctx do
      archive_pages!(ctx.site)

      before =
        for actor <- [nil, ctx.stranger, ctx.member],
            do: {listed(ctx, actor), statements(ctx, actor)}

      register!(ctx.site, [])

      after_registering =
        for actor <- [nil, ctx.stranger, ctx.member],
            do: {listed(ctx, actor), statements(ctx, actor)}

      assert after_registering == before

      assert {listed, _statements} = hd(before)
      assert listed == expected(ctx, [])
    end
  end

  # A list is one statement, and a record asked for alone two — the record, then its lock — with
  # two more for a page of a document, whose lock (`EffectivePermissions`) is a calculation.
  describe "the statements a read costs" do
    test "a list is one statement, locked or not", ctx do
      for actor <- [nil, ctx.stranger, ctx.member] do
        assert counts(ctx, actor).lists == [1, 1, 1, 1]
        register!(ctx.site, [@own_front, @own_page, @bare_front, @bare_page])
        assert counts(ctx, actor).lists == [1, 1, 1, 1], "for #{inspect(held(actor))}"
        unlock!(ctx.site)
      end
    end

    test "a record asked for alone costs what it costs while nothing is locked", ctx do
      for actor <- [nil, ctx.stranger, ctx.member] do
        assert counts(ctx, actor).alone == [2, 2, 2, 4, 4]

        register!(ctx.site, [@plain_front, @plain_page])
        assert counts(ctx, actor).alone == [2, 2, 2, 4, 4], "for #{inspect(held(actor))}"
        unlock!(ctx.site)
      end

      register!(ctx.site, [@own_front, @own_page, @bare_front, @bare_page])
      assert counts(ctx, ctx.member).alone == [2, 2, 2, 4, 4]
    end

    test "a reader who does not carry their permissions has them read once for a read, " <>
           "locked or not",
         ctx do
      unloaded =
        Ash.get!(ctx.member.__struct__, ctx.member.id, tenant: ctx.site.id, authorize?: false)

      refute Ash.Resource.loaded?(unloaded, :permissions)

      open = counts(ctx, unloaded)
      register!(ctx.site, [@own_front, @own_page, @bare_front, @bare_page])

      assert counts(ctx, unloaded) == open
      assert open == %{lists: [2, 2, 2, 2], alone: [3, 3, 3, 5, 5]}
      assert listed(ctx, unloaded) == expected(ctx, [])
    end
  end

  describe "the sitemap" do
    setup %{site: site} do
      on_exit(fn ->
        SettingsState.delete(site.id, "site.languages")
        SettingsState.delete(site.id, "site.language_urls")
      end)

      {:ok, _} = Settings.put("site.languages", ["en", "fa"], site_id: site.id)
      {:ok, _} = Settings.put("site.language_urls", "prefix_others", site_id: site.id)
      MishkaDocument.Provision.ensure!(site)
      :ok
    end

    # The pages core hands the plugin are read once, before any is locked, so what is left out is
    # left out by the plugin's own reads.
    test "leaves out the pages of a document whose page a visitor may not open", ctx do
      served = served_pages(ctx.site)
      everything = sitemap(ctx.site, served)

      assert "/guide/docs/own-other" in everything
      assert "/guide/docs/own-child" in everything
      assert "/docs/bare/bare-other" in everything
      assert "/other/docs/plain-other" in everything

      register!(ctx.site, [@own_page])

      assert sitemap(ctx.site, served) ==
               everything -- ["/guide/docs/own-child", "/guide/docs/own-other"]

      unlock!(ctx.site)
      register!(ctx.site, [@bare_page])

      assert sitemap(ctx.site, served) == everything -- ["/docs/bare/bare-other"]
    end
  end

  # ---------------------------------------------------------------------------

  # Every list a reader is shown, as the ids in it, by kind. `opts` are the reads' own.
  defp listed(ctx, actor, opts \\ []) do
    %{
      documents: ids(read(Workspace, :public_list, ctx.site, actor, opts)),
      versions: ids(read(WorkspaceVersion, :public_list, ctx.site, actor, opts)),
      clones: ids(read(WorkspaceVersionLineage, :public_recent_clones, ctx.site, actor, opts)),
      sections: ids(read(Section, :public_list, ctx.site, actor, opts)),
      contents:
        ctx.documents
        |> Map.values()
        |> Enum.flat_map(fn %{version: version} ->
          query_opts = Keyword.merge([actor: actor, tenant: ctx.site.id], opts)

          Section
          |> Ash.Query.for_read(
            :public_list_at_workspace_version,
            %{workspace_version_id: version.id},
            query_opts
          )
          |> Ash.read!(Keyword.put(query_opts, :page, false))
        end)
        |> ids()
    }
  end

  # What a reader may see once `hidden` is taken away: a document key hides the document, its
  # versions and its clone records; `{document, page}` hides that page.
  defp expected(ctx, hidden) do
    shown = for {key, document} <- ctx.documents, key not in hidden, do: document

    sections =
      [ctx.child | Enum.flat_map(Map.values(ctx.documents), &[&1.front, &1.other])]
      |> Enum.reject(&(&1.id in hidden_sections(ctx, hidden)))
      |> ids()

    %{
      documents: shown |> Enum.map(& &1.document) |> ids(),
      versions: shown |> Enum.flat_map(&[&1.version, &1.clone.version]) |> ids(),
      clones: shown |> Enum.map(& &1.clone.lineage) |> ids(),
      sections: sections,
      contents: sections
    }
  end

  defp hidden_sections(ctx, hidden) do
    for {key, page} <- hidden, is_atom(page) do
      if page == :child, do: ctx.child.id, else: Map.fetch!(ctx.documents[key], page).id
    end
  end

  # Each record asked for by itself, by its public get: whether it is found or not.
  defp asked_alone(ctx, actor, opts \\ []) do
    fetch = &fetched(&1, &2, ctx.site, actor, opts)

    for {_key, document} <- ctx.documents, into: %{} do
      {document.document.id,
       %{
         document: fetch.(Workspace, document.document.id),
         version: fetch.(WorkspaceVersion, document.version.id),
         clone: fetch.(WorkspaceVersionLineage, document.clone.lineage.id),
         front: fetch.(Section, document.front.id),
         other: fetch.(Section, document.other.id)
       }}
    end
    |> Map.put(:child, fetch.(Section, ctx.child.id))
  end

  defp expected_alone(ctx, hidden) do
    for {key, document} <- ctx.documents, into: %{} do
      whole = if key in hidden, do: :not_found, else: :ok
      page = &if({key, &1} in hidden, do: :not_found, else: :ok)

      {document.document.id,
       %{
         document: whole,
         version: whole,
         clone: whole,
         front: page.(:front),
         other: page.(:other)
       }}
    end
    |> Map.put(:child, if({:own, :child} in hidden, do: :not_found, else: :ok))
  end

  defp fetched(resource, id, site, actor, opts \\ []) do
    case Ash.get(
           resource,
           id,
           Keyword.merge([action: :public_get, actor: actor, tenant: site.id], opts)
         ) do
      {:ok, _found} -> :ok
      {:error, %Ash.Error.Invalid{errors: [%Ash.Error.Query.NotFound{}]}} -> :not_found
      {:error, error} -> {:error, error}
    end
  end

  # The SQL of the statements each list is read with.
  defp statements(ctx, actor) do
    for {resource, action} <- lists() do
      {_rows, statements} = with_queries(fn -> read(resource, action, ctx.site, actor) end)
      statements
    end
  end

  # How many statements each list, and each record asked for alone, is read with.
  defp counts(ctx, actor) do
    lists = ctx |> statements(actor) |> Enum.map(&length/1)

    alone =
      for {resource, id} <- [
            {Workspace, ctx.documents.own.document.id},
            {WorkspaceVersion, ctx.documents.own.version.id},
            {WorkspaceVersionLineage, ctx.documents.own.clone.lineage.id},
            {Section, ctx.documents.own.front.id},
            {Section, ctx.documents.bare.other.id}
          ] do
        {_found, statements} = with_queries(fn -> fetched(resource, id, ctx.site, actor) end)
        length(statements)
      end

    %{lists: lists, alone: alone}
  end

  defp lists do
    [
      {Workspace, :public_list},
      {WorkspaceVersion, :public_list},
      {WorkspaceVersionLineage, :public_recent_clones},
      {Section, :public_list}
    ]
  end

  # A clone record's list is paged by its action, so it is read a page of them at a time.
  defp read(resource, action, site, actor, opts \\ []) do
    query_opts = Keyword.merge([actor: actor, tenant: site.id], opts)

    resource
    |> Ash.Query.for_read(action, %{}, query_opts)
    |> Ash.read!(
      Keyword.put(query_opts, :page, if(paged?(action), do: [limit: 200], else: false))
    )
    |> then(&if(paged?(action), do: &1.results, else: &1))
  end

  defp paged?(action), do: action == :public_recent_clones

  # The pages core hands the sitemap's plugins: the site's indexable pages holding a capture only
  # their owner can fill.
  defp served_pages(site) do
    {pages, _hidden} = PageEditions.indexable(site.id)

    Enum.reject(
      pages,
      &(Languages.url(&1.path, %{}, site.id) || PageEditions.language_only?(&1.path))
    )
  end

  defp sitemap(site, pages) do
    assert {:reply, %{urls: urls}} =
             SitemapUrls.call(%{site: site, pages: pages, urls: Stream.map([], & &1)})

    urls |> Enum.map(& &1.path) |> Enum.sort()
  end

  # The documentation's pages: those in `locked` name `@lock`, the rest none; `extra` adds
  # `{path, record, permissions}` of its own. A page the site already has at a path — the two a
  # document's address is given — is given these permissions; any other is written.
  defp register!(site, locked, extra \\ []) do
    pages =
      [
        {@own_front, "docs:document"},
        {@own_page, "docs:page"},
        {@plain_front, "docs:document"},
        {@plain_page, "docs:page"},
        {@bare_front, "docs:document"},
        {@bare_page, "docs:page"}
      ]
      |> Enum.map(fn {path, record} ->
        {path, record, if(path in locked, do: @lock, else: [])}
      end)
      |> Kernel.++(extra)

    held = Map.new(site_pages(site), &{&1.path, &1})

    for {path, record, permissions} <- pages do
      case held do
        %{^path => page} ->
          page
          |> Ash.Changeset.for_update(:update, %{permissions: permissions},
            tenant: site.id,
            authorize?: false,
            context: %{page_code: :package}
          )
          |> Ash.update!()

        _none ->
          create_page!(
            site_id: site.id,
            path: path,
            extra: %{"record" => record},
            permissions: permissions,
            active: true
          )
      end
    end

    :ok
  end

  # Every page of the site opened again.
  defp unlock!(site) do
    for %{permissions: [_ | _]} = page <- site_pages(site) do
      page
      |> Ash.Changeset.for_update(:update, %{permissions: []},
        tenant: site.id,
        authorize?: false,
        context: %{page_code: :package}
      )
      |> Ash.update!()
    end

    :ok
  end

  # Every page of the site archived, so none serves.
  defp archive_pages!(site) do
    for page <- site_pages(site),
        do:
          Ash.destroy!(page, tenant: site.id, authorize?: false, context: %{page_code: :package})

    assert site_pages(site) == []
  end

  defp site_pages(site), do: Ash.read!(Page, tenant: site.id, authorize?: false, page: false)

  defp document!(site, slug, path, permissions \\ []) do
    create_workspace!(
      site_id: site.id,
      skip_version: true,
      status: :active,
      slug: slug,
      path: path,
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
    version =
      version!(site, document,
        version_number: "2.0.0",
        is_latest_for_version: false,
        published_at: ~U[2026-02-01 00:00:00Z]
      )

    lineage =
      create_workspace_version_lineage!(
        site_id: site.id,
        new_version_id: version.id,
        source_version_id: source.id
      )

    %{version: version, lineage: lineage}
  end

  defp section!(site, version, slug, overrides \\ []) do
    create_section!(
      [
        site_id: site.id,
        workspace_version_id: version.id,
        slug: slug,
        language: "en",
        content_review_status: :approved,
        technical_review_status: :approved,
        permissions: []
      ] ++ overrides
    )
  end

  defp held(nil), do: :guest
  defp held(actor), do: Enum.map(actor.permissions, & &1.name)

  defp ids(records), do: records |> Enum.map(& &1.id) |> Enum.sort()
end
