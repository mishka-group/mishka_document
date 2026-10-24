# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_document/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaDocument.Resources.Preparations.OpenToActor do
  @moduledoc """
  Keeps a public read to the records its reader may open, by the rule the record's page keeps: a
  record whose lock names permissions opens only for a reader holding one of them
  (`AccessPermissions.match?/3`), and never for a visitor who is not signed in. A list leaves out,
  in its own query, every record the reader may not open, so its pages and its count are of what
  the reader sees; asking for one of them by itself finds nothing, as an id nothing is stored at
  does.

      prepare {OpenToActor, kind: :section}

  THE READER is the actor of an authorized read: the visitor a page reads for, as the
  documentation's components pass it — `nil` for a visitor who is not signed in — and the JSON:API's
  caller.

      Ash.Query.for_read(MishkaDocument.Section, :public_list, %{},
        actor: current_user,
        tenant: site_id
      )

  A read made with `authorize?: false` is the system's — the lock a page's head hands its gate, the
  document a page sits in — and is not filtered.

  WHAT IS NOT PUBLISHED opens for no reader, whatever its lock: a version (`:version`) of a document
  that is not active, a clone record (`:lineage`) either of whose versions is of one, and a page
  (`:section`) of a version that is not published — alpha, beta, rc or stable — or of a document
  that is not active. A list leaves them out and one asked for alone is not found, as a document's
  own public reads leave out one that is not active.

  WHAT A LIST IS KEPT TO is decided in the statement that reads it, by the lock each record opens
  with, so no read of another record is made to decide it and its pages and its count are of what
  the reader sees:

    * a document (`:workspace`) — by its own lock;
    * a version (`:version`) and a clone record (`:lineage`, by its new version) — by its
      document's;
    * a page of a document (`:section`) — by the lock it opens with
      (`MishkaDocument.Resources.Calculations.EffectivePermissions`): its own, else the nearest page
      above it that names one, else its document's.

  A lock that names nothing opens for anyone. Any other opens for a reader holding a name that
  `AccessPermissions` finds covering one of its entries, and the statement asks the same: the names
  the reader holds are handed to it as the literals that cover only themselves and the patterns of
  those with a `*`, and the entries a dashboard request does not count (`admin:api:…`) match none.
  An actor whose permissions are not loaded has them read once for the read, as the checker reads
  them.

  The statement holds `fragment`s because Ash has no function that tests the elements of an array
  against patterns, none that walks down a tree from the pages that name a lock, and no
  relationship from a document to the site's pages.

  WHAT ITS PAGE KEEPS CLOSED is left out as well, in the same statement: a record whose address is
  answered by a page of the site (`MishkaCmsCore.Runtime.Page`) that the reader may not open is not
  listed, and one asked for alone is not found. A page counts while it is active and not archived,
  and answers the documentation's records by the kind its `extra` names under `"record"`:
  `"docs:document"`, a document's front page, or `"docs:page"`, one page of a document.

    * a document with an address of its own (`path`, `MishkaDocument.Address`) is answered at that
      address — its front page by the page at `path` that shows `"docs:document"`, its other pages
      by the page at `path/*section` that shows `"docs:page"`;
    * a document with no address is answered by the pages of each kind that no document's address
      claims (`/:lang/docs/:workspace`, `/:lang/docs/:workspace/*section`), and is closed by them
      only when there is one and every one of them is closed;
    * a document (`:workspace`), its versions (`:version`) and its clone records (`:lineage`, by
      its new version's document) are closed with its front page;
    * a version's front page (`:section`, `front_page`) is closed with its document's front page,
      and any other page with the page its document's other pages are answered at.

  A page that names no permission opens for anyone; any other opens for a reader holding a name
  that covers one of its entries, by the same match a record's lock is asked with. The statement
  is the same whether a page is locked or not, and nothing is read before it to decide. The
  JSON:API and GraphQL keep to the same rule as the site's pages.

  ## Options

  * `:kind` - Required. `:workspace`, `:version`, `:lineage` or `:section`.
  """
  use Ash.Resource.Preparation

  require Ash.Expr
  require Ash.Query

  alias Ash.Resource.Info, as: ResourceInfo
  alias MishkaCmsCore.Accounts.Checks.AccessPermissions
  alias MishkaDocument.WorkspaceVersion

  # Where the lock each kind opens with is read, for one asked for alone: the attribute naming the
  # record that holds it, that record's resource (`nil` for the record's own), its field, and the
  # kind whose pages answer that record.
  @locks %{
    workspace: {:id, nil, :permissions, :workspace},
    version: {:id, nil, :effective_permissions, :version},
    lineage: {:new_version_id, WorkspaceVersion, :effective_permissions, :version},
    section: {:id, nil, :effective_permissions, :section}
  }

  # The kinds of record the documentation's pages show (`MishkaDocument.Plugins.PageRecords`), each
  # with what its page's path adds to a document's own address (`MishkaDocument.Address`).
  @front_page {"docs:document", ""}
  @other_page {"docs:page", "/*section"}

  # Where the document a record belongs to is reached from the record.
  @document %{
    workspace: [],
    version: [:workspace],
    lineage: [:new_version, :workspace],
    section: [:workspace_version, :workspace]
  }

  @impl true
  def init(opts) do
    if Map.has_key?(@locks, opts[:kind]),
      do: {:ok, opts},
      else: {:error, "kind is one of :workspace, :version, :lineage or :section"}
  end

  # The statuses a version is read in by a reader, as its own public reads keep them.
  @published [:alpha, :beta, :rc, :stable]

  @impl true
  def prepare(query, opts, context) do
    case reader(context) do
      :system -> query
      {:reader, actor} -> query |> published(opts[:kind]) |> keep(opts[:kind], actor)
    end
  end

  @doc """
  Whether `actor` may open a record that opens with `required`: anyone when it names none, else an
  actor holding one of them, as the record's page asks (`AccessPermissions.match?/3`).
  """
  @spec opens?([String.t()] | nil, map() | nil) :: boolean()
  def opens?(required, _actor) when required in [nil, []], do: true
  def opens?(_required, nil), do: false
  def opens?(required, actor), do: AccessPermissions.match?(actor, %{}, permissions: required)

  defp published(query, :workspace), do: query

  defp published(query, :version), do: Ash.Query.filter(query, workspace.status == :active)

  defp published(query, :lineage),
    do:
      Ash.Query.filter(
        query,
        new_version.workspace.status == :active and source_version.workspace.status == :active
      )

  defp published(query, :section),
    do:
      Ash.Query.filter(
        query,
        workspace_version.status in ^@published and workspace_version.workspace.status == :active
      )

  defp reader(%{authorize?: false}), do: :system
  defp reader(%{actor: actor}), do: {:reader, actor}

  defp keep(%{action: %{get?: true}} = query, kind, actor) do
    Ash.Query.after_action(query, fn query, records -> admit(query, records, kind, actor) end)
  end

  # A QUERY PREPARED FOR ITS SITE IS KEPT AT ONCE, in its own filter, and so is everything computed
  # from it: `Ash.count/2` and the other aggregates of a read run none of its `before_action` hooks,
  # so a count of a list kept only there counted the records the reader may not open — a guest was
  # told how many locked documents there are. One whose site arrives with the read is kept as it
  # runs.
  defp keep(%{tenant: site_id} = query, kind, actor) when is_binary(site_id),
    do: kept(query, kind, site_id, actor)

  defp keep(query, kind, actor) do
    Ash.Query.before_action(query, fn
      %{tenant: site_id} = query when is_binary(site_id) -> kept(query, kind, site_id, actor)
      query -> query
    end)
  end

  defp kept(query, kind, site_id, actor) do
    actor = AccessPermissions.with_permissions(actor)

    query
    |> Ash.Query.filter(^visible(kind, site_id, actor))
    |> Ash.Query.filter(^served(kind, site_id, actor))
  end

  # ---------------------------------------------------------------------------
  # A list
  # ---------------------------------------------------------------------------

  defp visible(:workspace, _site_id, actor), do: opens_by(actor, Ash.Expr.ref([], :permissions))

  defp visible(:version, _site_id, actor),
    do: opens_by(actor, Ash.Expr.ref([:workspace], :permissions))

  defp visible(:lineage, _site_id, actor),
    do: opens_by(actor, Ash.Expr.ref([:new_version, :workspace], :permissions))

  defp visible(:section, site_id, actor) do
    document = opens_by(actor, Ash.Expr.ref([:workspace_version, :workspace], :permissions))

    case held(actor) do
      {[], []} ->
        Ash.Expr.expr(^document and ^not_under_a_lock(site_id))

      {literals, patterns} ->
        Ash.Expr.expr(
          ^under_a_lock_held(site_id, literals, patterns) or
            (^not_under_a_lock(site_id) and ^document)
        )
    end
  end

  # THE PAGES THAT OPEN WITH A LOCK OF A PAGE: a page that names a lock, and each page under it that
  # names none, down to the next page that does — `EffectivePermissions` for every page of the site
  # at once, by walking down from the pages that name a lock. A page is under another when it names
  # it as its parent, in the same version; an archived page is neither. Written as a statement
  # because Ash has no way to walk a tree, and as two literals because `fragment/2` takes nothing
  # else.

  # The pages that open with the lock of none of them: a reader meets their document's alone.
  defp not_under_a_lock(site_id) do
    Ash.Expr.expr(
      type(
        fragment(
          """
          ? NOT IN (
            WITH RECURSIVE locked(id, version_id) AS (
              SELECT s.id, s.workspace_version_id
                FROM mishka_document_sections s
               WHERE s.site_id = ? AND s.archived_at IS NULL
                 AND s.permissions IS NOT NULL AND s.permissions <> '{}'
              UNION ALL
              SELECT c.id, c.workspace_version_id
                FROM mishka_document_sections c
                JOIN locked l ON c.parent_section_id = l.id
               WHERE c.site_id = ? AND c.archived_at IS NULL
                 AND c.workspace_version_id = l.version_id
                 AND (c.permissions IS NULL OR c.permissions = '{}')
            )
            SELECT id FROM locked
          )
          """,
          id,
          type(^site_id, :uuid),
          type(^site_id, :uuid)
        ),
        :boolean
      )
    )
  end

  # The pages that open with the lock of one of them, that a reader holding `literals` and
  # `patterns` is let in by.
  defp under_a_lock_held(site_id, literals, patterns) do
    Ash.Expr.expr(
      type(
        fragment(
          """
          ? IN (
            WITH RECURSIVE locked(id, version_id, lock) AS (
              SELECT s.id, s.workspace_version_id, s.permissions
                FROM mishka_document_sections s
               WHERE s.site_id = ? AND s.archived_at IS NULL
                 AND s.permissions IS NOT NULL AND s.permissions <> '{}'
              UNION ALL
              SELECT c.id, c.workspace_version_id, l.lock
                FROM mishka_document_sections c
                JOIN locked l ON c.parent_section_id = l.id
               WHERE c.site_id = ? AND c.archived_at IS NULL
                 AND c.workspace_version_id = l.version_id
                 AND (c.permissions IS NULL OR c.permissions = '{}')
            )
            SELECT id FROM locked
             WHERE EXISTS (
               SELECT 1 FROM unnest(lock) AS held(name)
                WHERE held.name NOT LIKE 'admin:api:%'
                  AND (held.name = ANY(?) OR held.name ~ ANY(?))
             )
          )
          """,
          id,
          type(^site_id, :uuid),
          type(^site_id, :uuid),
          type(^literals, {:array, :string}),
          type(^patterns, {:array, :string})
        ),
        :boolean
      )
    )
  end

  # What `opens?/2` answers for the lock at `lock`, answered by the statement: a lock that names
  # nothing opens for anyone; any other opens only for a reader holding what `AccessPermissions`
  # would find among its names.
  defp opens_by(actor, lock) do
    case held(actor) do
      {[], []} ->
        Ash.Expr.expr(is_nil(^lock) or ^lock == [])

      {literals, patterns} ->
        Ash.Expr.expr(
          is_nil(^lock) or ^lock == [] or
            type(
              fragment(
                "EXISTS (SELECT 1 FROM unnest(?) AS lock(name) WHERE lock.name NOT LIKE 'admin:api:%' AND (lock.name = ANY(?) OR lock.name ~ ANY(?)))",
                type(^lock, {:array, :string}),
                type(^literals, {:array, :string}),
                type(^patterns, {:array, :string})
              ),
              :boolean
            )
        )
    end
  end

  # The names `actor` holds, as `AccessPermissions` reads them (`with_permissions/1`, then each
  # permission's name), told apart into those that cover only themselves and those with a wildcard,
  # which are written as the pattern of the names they cover: a `*` covers one segment, the last
  # one the rest of the name.
  defp held(nil), do: {[], []}

  defp held(actor) do
    names =
      actor
      |> AccessPermissions.with_permissions()
      |> Map.get(:permissions)
      |> List.wrap()
      |> Enum.flat_map(fn
        %{name: name} when is_binary(name) -> [name]
        _other -> []
      end)
      |> Enum.uniq()

    {literals, wildcards} = Enum.split_with(names, &(not String.contains?(&1, "*")))
    {literals, wildcards |> Enum.map(&pattern/1) |> Enum.uniq()}
  end

  defp pattern(name) do
    segments = String.split(name, ":")
    last = List.last(segments)

    body =
      segments
      |> Enum.drop(-1)
      |> Enum.map(fn
        "*" -> "[^:]*"
        segment -> literal(segment)
      end)
      |> Kernel.++([if(last == "*", do: ".*", else: literal(last))])
      |> Enum.join(":")

    "^" <> body <> "$"
  end

  # An ASCII punctuation mark is escaped, so it matches itself; anything else matches itself as it is.
  defp literal(segment),
    do: Regex.replace(~r/[!-\/:-@\[-\^`{-~]/, segment, fn character -> "\\" <> character end)

  # ---------------------------------------------------------------------------
  # The pages that answer a record
  # ---------------------------------------------------------------------------

  # The records of `kind` whose page `actor` may open on the site `site_id`.
  defp served(:section, site_id, actor) do
    document = Map.fetch!(@document, :section)
    front = closed_by(@front_page, document, site_id, actor)
    other = closed_by(@other_page, document, site_id, actor)

    Ash.Expr.expr((front_page == true and not (^front)) or (front_page == false and not (^other)))
  end

  defp served(kind, site_id, actor),
    do: Ash.Expr.expr(not (^closed_by(@front_page, Map.fetch!(@document, kind), site_id, actor)))

  # Whether the page of `record` that answers the document at `document` is closed to `actor`. A
  # document with an address is answered by the serving page at that address plus `suffix`; one
  # with none by the serving pages of `record` no document's address claims, closed only while
  # there is one and every one of them is closed. A page is closed when it names permissions and
  # the reader holds none of them, as `opens_by/2` asks of a record's lock. Written as a statement
  # because a page is a row of core's `pages`, which no relationship of a document reaches.
  defp closed_by({record, suffix}, document, site_id, actor) do
    path = Ash.Expr.ref(document, :path)
    {literals, patterns} = held(actor)

    Ash.Expr.expr(
      type(
        fragment(
          """
          CASE WHEN ? IS NULL THEN COALESCE((
            SELECT bool_and(
                     pg.permissions IS NOT NULL AND pg.permissions <> '{}'
                     AND NOT EXISTS (
                       SELECT 1 FROM unnest(pg.permissions) AS held(name)
                        WHERE held.name NOT LIKE 'admin:api:%'
                          AND (held.name = ANY(?) OR held.name ~ ANY(?))
                     ))
              FROM pages pg
             WHERE pg.site_id = ? AND pg.active AND pg.archived_at IS NULL
               AND pg.extra->>'record' = ?
               AND NOT EXISTS (
                 SELECT 1 FROM mishka_document_workspaces w
                  WHERE w.site_id = pg.site_id AND w.path IS NOT NULL
                    AND (pg.path = w.path OR pg.path = w.path || '/*section')
               )
          ), false)
          ELSE EXISTS (
            SELECT 1 FROM pages pg
             WHERE pg.site_id = ? AND pg.active AND pg.archived_at IS NULL
               AND pg.extra->>'record' = ? AND pg.path = ? || ?
               AND pg.permissions IS NOT NULL AND pg.permissions <> '{}'
               AND NOT EXISTS (
                 SELECT 1 FROM unnest(pg.permissions) AS held(name)
                  WHERE held.name NOT LIKE 'admin:api:%'
                    AND (held.name = ANY(?) OR held.name ~ ANY(?))
               )
          ) END
          """,
          ^path,
          type(^literals, {:array, :string}),
          type(^patterns, {:array, :string}),
          type(^site_id, :uuid),
          type(^record, :string),
          type(^site_id, :uuid),
          type(^record, :string),
          ^path,
          type(^suffix, :string),
          type(^literals, {:array, :string}),
          type(^patterns, {:array, :string})
        ),
        :boolean
      )
    )
  end

  # ---------------------------------------------------------------------------
  # One asked for alone
  # ---------------------------------------------------------------------------

  defp admit(_query, [], _kind, _actor), do: {:ok, []}

  defp admit(query, records, kind, actor) do
    {key, resource, lock, answered_as} = Map.fetch!(@locks, kind)
    actor = AccessPermissions.with_permissions(actor)
    served = served(answered_as, query.tenant, actor)
    keys = Enum.map(records, &Map.get(&1, key))
    locks = locks(resource || query.resource, lock, keys, query.tenant, served)

    {:ok, Enum.filter(records, &opens?(locks, Map.get(&1, key), actor))}
  end

  # A record whose lock is not found — its row gone, or its page closed — opens for no one.
  defp opens?(locks, id, actor) do
    case Map.fetch(locks, id) do
      {:ok, required} -> opens?(required, actor)
      :error -> false
    end
  end

  # The lock of each of these records whose page is open (`served`), read as the system: a hook runs
  # before the query's own loads, and the caller may have selected fields the lock needs away.
  defp locks(_resource, _lock, [], _tenant, _served), do: %{}

  defp locks(resource, lock, ids, tenant, served) do
    resource
    |> Ash.Query.filter(id in ^Enum.uniq(ids))
    |> Ash.Query.filter(^served)
    |> Ash.Query.select([:id])
    |> with_field(lock)
    |> Ash.read!(tenant: tenant, authorize?: false, page: false)
    |> Map.new(&{&1.id, Map.get(&1, lock)})
  end

  # An attribute is selected, a calculation loaded.
  defp with_field(query, field) do
    case ResourceInfo.attribute(query.resource, field) do
      nil -> Ash.Query.load(query, field)
      _attribute -> Ash.Query.ensure_selected(query, [field])
    end
  end
end
