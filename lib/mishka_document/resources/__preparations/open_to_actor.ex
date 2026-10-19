# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_document/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaDocument.Resources.Preparations.OpenToActor do
  @moduledoc """
  Keeps a public read to the records its reader may open, by the rule the record's page keeps: a
  record whose lock names permissions opens only for a reader holding one of them
  (`AccessPermissions.match?/3`), and never for a visitor who is not signed in. A list leaves out,
  in its own query, every record the reader may not open, so its pages and its count are of what
  the reader sees; asking for one of them by itself is refused as forbidden.

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
  against patterns, and none that walks down a tree from the pages that name a lock.

  ## Options

  * `:kind` - Required. `:workspace`, `:version`, `:lineage` or `:section`.
  """
  use Ash.Resource.Preparation

  require Ash.Expr
  require Ash.Query

  alias Ash.Error.Forbidden
  alias Ash.Resource.Info, as: ResourceInfo
  alias MishkaCmsCore.Accounts.Checks.AccessPermissions
  alias MishkaDocument.WorkspaceVersion

  # Where the lock each kind opens with is read, for one asked for alone: the attribute naming the
  # record that holds it, that record's resource (`nil` for the record's own) and its field.
  @locks %{
    workspace: {:id, nil, :permissions},
    version: {:id, nil, :effective_permissions},
    lineage: {:new_version_id, WorkspaceVersion, :effective_permissions},
    section: {:id, nil, :effective_permissions}
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

  defp keep(query, kind, actor) do
    Ash.Query.before_action(query, fn
      %{tenant: site_id} = query when is_binary(site_id) ->
        Ash.Query.filter(query, ^visible(kind, site_id, actor))

      query ->
        query
    end)
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
  # One asked for alone
  # ---------------------------------------------------------------------------

  defp admit(query, records, kind, actor) do
    {key, resource, lock} = Map.fetch!(@locks, kind)
    keys = Enum.map(records, &Map.get(&1, key))
    locks = locks(resource || query.resource, lock, keys, query.tenant)

    case Enum.reject(records, &opens?(locks, Map.get(&1, key), actor)) do
      [] -> {:ok, records}
      _closed -> {:error, Forbidden.exception([])}
    end
  end

  # A record whose lock is not found — its row gone — opens for no one.
  defp opens?(locks, id, actor) do
    case Map.fetch(locks, id) do
      {:ok, required} -> opens?(required, actor)
      :error -> false
    end
  end

  # The lock of each of these records, read as the system: a hook runs before the query's own
  # loads, and the caller may have selected fields the lock needs away.
  defp locks(_resource, _lock, [], _tenant), do: %{}

  defp locks(resource, lock, ids, tenant) do
    resource
    |> Ash.Query.filter(id in ^Enum.uniq(ids))
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
