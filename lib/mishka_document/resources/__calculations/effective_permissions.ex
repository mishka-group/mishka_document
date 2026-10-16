# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_document/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaDocument.Resources.Calculations.EffectivePermissions do
  @moduledoc """
  The permissions a section — one page of a document — opens with on its page, in its sitemap
  entry and wherever else a reader is let in: its own, else those of the nearest parent section
  that names some, else its document's (the workspace's). What a section names itself always wins
  over what it would take from above, and a section of a document that names nothing, under
  parents that name nothing, is public.

  A parent section counts while it exists, whatever its review status. The sections and documents
  above are read only for the sections that name nothing themselves, once per site for the whole
  batch.

      calculate :effective_permissions, {:array, :string}, EffectivePermissions
  """
  use Ash.Resource.Calculation

  require Ash.Query

  alias MishkaDocument.{Section, Workspace, WorkspaceVersion}

  @impl true
  def load(_query, _opts, _context),
    do: [:id, :site_id, :permissions, :parent_section_id, :workspace_version_id]

  @impl true
  def calculate(sections, _opts, _context) do
    above =
      sections
      |> Enum.reject(&match?(%{permissions: [_ | _]}, &1))
      |> Enum.group_by(& &1.site_id)
      |> Map.new(fn {site_id, open} ->
        {site_id, {tree(site_id, open), documents(site_id, open)}}
      end)

    Enum.map(sections, &opens_with(&1, Map.get(above, &1.site_id, {%{}, %{}})))
  end

  defp opens_with(%{parent_section_id: parent_id} = section, {tree, documents}) do
    case inherited(section.permissions, parent_id, tree) do
      [] -> Map.get(documents, section.workspace_version_id, [])
      found -> found
    end
  end

  # Every section of the versions these are in, as `{parent_id, permissions}` by id — read only
  # when one of them has a parent.
  defp tree(site_id, sections) do
    case sections |> Enum.filter(& &1.parent_section_id) |> versions() do
      [] ->
        %{}

      version_ids ->
        Section
        |> Ash.Query.filter(workspace_version_id in ^version_ids)
        |> Ash.Query.select([:id, :parent_section_id, :permissions])
        |> Ash.read!(tenant: site_id, authorize?: false, page: false)
        |> Map.new(&{&1.id, {&1.parent_section_id, &1.permissions}})
    end
  end

  # The permissions of the document each of these versions belongs to, by the version's id.
  defp documents(site_id, sections) do
    version_ids = versions(sections)

    WorkspaceVersion
    |> Ash.Query.filter(id in ^version_ids)
    |> Ash.Query.select([:id, :workspace_id])
    |> Ash.Query.load(workspace: Ash.Query.select(Workspace, [:permissions]))
    |> Ash.read!(tenant: site_id, authorize?: false, page: false)
    |> Map.new(&{&1.id, document_permissions(&1.workspace)})
  end

  defp versions(sections), do: sections |> Enum.map(& &1.workspace_version_id) |> Enum.uniq()

  defp document_permissions(%Workspace{permissions: permissions}), do: List.wrap(permissions)
  defp document_permissions(_none), do: []

  # Its own permissions when it names any, else those of the nearest one above it that does: `tree`
  # is `{parent_id, permissions}` by id, and leaving it, or meeting an id twice, ends the walk.
  defp inherited(own, parent_id, tree, seen \\ MapSet.new())

  defp inherited([_ | _] = own, _parent_id, _tree, _seen), do: own

  defp inherited(_none, parent_id, tree, seen) do
    with false <- MapSet.member?(seen, parent_id),
         {:ok, {grandparent_id, permissions}} <- Map.fetch(tree, parent_id) do
      inherited(permissions, grandparent_id, tree, MapSet.put(seen, parent_id))
    else
      _top -> []
    end
  end
end
