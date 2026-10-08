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

  WHAT A LIST IS KEPT TO is worked out as it runs, from the site's locked records alone, each lock
  matched once, and the list's query is filtered by the ids that come out:

    * a document (`:workspace`) — by its own lock;
    * a version (`:version`) and a clone record (`:lineage`, by its new version) — by its
      document's;
    * a page of a document (`:section`) — by the lock it opens with (`effective_permissions`): those
      in a version holding a page with a lock of its own are each worked out, every other one opens
      with its document's.

  ## Options

  * `:kind` - Required. `:workspace`, `:version`, `:lineage` or `:section`.
  """
  use Ash.Resource.Preparation

  require Ash.Expr
  require Ash.Query

  alias MishkaCmsCore.Accounts.Checks.AccessPermissions
  alias MishkaDocument.{Section, Workspace, WorkspaceVersion}

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

  @impl true
  def prepare(query, opts, context) do
    case reader(context) do
      :system -> query
      {:reader, actor} -> keep(query, opts[:kind], actor)
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

  defp visible(:workspace, site_id, actor) do
    case closed_documents(site_id, actor) do
      [] -> true
      closed -> Ash.Expr.expr(id not in ^closed)
    end
  end

  defp visible(:version, site_id, actor) do
    case closed_documents(site_id, actor) do
      [] -> true
      closed -> Ash.Expr.expr(workspace_id not in ^closed)
    end
  end

  defp visible(:lineage, site_id, actor) do
    case closed_documents(site_id, actor) do
      [] -> true
      closed -> Ash.Expr.expr(new_version.workspace_id not in ^closed)
    end
  end

  defp visible(:section, site_id, actor) do
    {opened, closed} = site_id |> worked_out_pages() |> split(actor)

    case {closed, closed_documents(site_id, actor)} do
      {[], []} ->
        true

      {_closed, []} ->
        Ash.Expr.expr(id not in ^closed)

      {_closed, documents} ->
        Ash.Expr.expr(
          id not in ^closed and
            (id in ^opened or workspace_version.workspace_id not in ^documents)
        )
    end
  end

  defp closed_documents(site_id, actor) do
    {_opened, closed} =
      Workspace
      |> Ash.Query.filter(not is_nil(permissions) and permissions != [])
      |> Ash.Query.select([:id, :permissions])
      |> Ash.read!(tenant: site_id, authorize?: false, page: false)
      |> Map.new(&{&1.id, &1.permissions})
      |> split(actor)

    closed
  end

  # The lock every page opens with in each version holding a page that names one of its own — the
  # only versions where a page can open with anything but its document's.
  defp worked_out_pages(site_id) do
    versions =
      Section
      |> Ash.Query.filter(not is_nil(permissions) and permissions != [])
      |> Ash.Query.select([:id, :workspace_version_id])
      |> Ash.read!(tenant: site_id, authorize?: false, page: false)
      |> Enum.map(& &1.workspace_version_id)
      |> Enum.uniq()

    case versions do
      [] ->
        %{}

      versions ->
        Section
        |> Ash.Query.filter(workspace_version_id in ^versions)
        |> Ash.Query.select([:id])
        |> Ash.Query.load(:effective_permissions)
        |> Ash.read!(tenant: site_id, authorize?: false, page: false)
        |> Map.new(&{&1.id, &1.effective_permissions})
    end
  end

  # The ids of these records the reader may open, and those it may not. Each distinct lock is
  # matched once.
  defp split(locks, actor) do
    answers =
      locks
      |> Map.values()
      |> Enum.uniq()
      |> Map.new(&{&1, opens?(&1, actor)})

    Enum.reduce(locks, {[], []}, fn {id, required}, {opened, closed} ->
      if Map.fetch!(answers, required), do: {[id | opened], closed}, else: {opened, [id | closed]}
    end)
  end

  # ---------------------------------------------------------------------------
  # One asked for alone
  # ---------------------------------------------------------------------------

  defp admit(query, records, kind, actor) do
    {key, resource, lock} = Map.fetch!(@locks, kind)
    keys = Enum.map(records, &Map.get(&1, key))
    locks = locks(resource || query.resource, lock, keys, query.tenant)

    case Enum.reject(records, &opens?(locks, Map.get(&1, key), actor)) do
      [] -> {:ok, records}
      _closed -> {:error, Ash.Error.Forbidden.exception([])}
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
    case Ash.Resource.Info.attribute(query.resource, field) do
      nil -> Ash.Query.load(query, field)
      _attribute -> Ash.Query.ensure_selected(query, [field])
    end
  end
end
