defmodule MishkaDocument.Resources.Validations.SectionAddress do
  @moduledoc """
  Refuses a page whose whole address in its version (`MishkaDocument.Address`) another page of the
  version already has.

  A slug is unique among the pages that share a parent, which kept every address unique while each
  address held every slug above it. A front page's and a group's slugs are in no address, so two
  pages under two parents can now meet at one: a top-level `breadcrumb` and a `breadcrumb` filed
  under the group `navigation` are both `/chelekom/docs/breadcrumb`.

  A group with a page of its own is read at its own slug while the pages under it leave that slug
  out, so a page filed under the group `navigation` with the slug `navigation` meets the group's own
  page at `/navigation`, and is refused.

  Checked on a create, and on an update that changes the slug, the parent, the version, or whether
  the page is a front page, a group or a group with a page — which moves the pages under it as well,
  so their addresses are checked too. The version's other pages not archived are read as the
  system, since the address must be free whether or not the writer may read them. A group with no
  page has no address and is never refused; two front pages are refused by
  `unique_front_page_per_version`.

  Each refusal is written in the Gettext locale of the process the action runs in, `errors` domain
  of `MishkaCmsCore.Gettext`.

  ## Usage

      validate MishkaDocument.Resources.Validations.SectionAddress
  """
  use Ash.Resource.Validation
  use Gettext, backend: MishkaCmsCore.Gettext

  require Ash.Query

  alias MishkaDocument.{Address, Section}

  @watched [
    :slug,
    :parent_section_id,
    :workspace_version_id,
    :front_page,
    :group_heading,
    :group_page
  ]

  # A parent chain deeper than this, which only a loop makes, stops there.
  @depth 20

  @impl true
  def init(opts), do: {:ok, opts}

  @impl true
  def validate(changeset, _opts, _context) do
    if changeset.action_type == :create or
         Enum.any?(@watched, &Ash.Changeset.changing_attribute?(changeset, &1)),
       do: check(changeset),
       else: :ok
  end

  defp check(changeset) do
    page = %{
      id: Ash.Changeset.get_attribute(changeset, :id) || make_ref(),
      slug: Ash.Changeset.get_attribute(changeset, :slug),
      title: Ash.Changeset.get_attribute(changeset, :title),
      parent_section_id: Ash.Changeset.get_attribute(changeset, :parent_section_id),
      front_page: Ash.Changeset.get_attribute(changeset, :front_page) == true,
      group_heading: Ash.Changeset.get_attribute(changeset, :group_heading) == true,
      group_page: Ash.Changeset.get_attribute(changeset, :group_page) == true
    }

    pages = [page | others(changeset, page.id)]
    paths = Address.paths(pages)
    moved = moved(pages, page.id)

    clash =
      Enum.find_value(pages, fn other ->
        path = Map.get(paths, other.id)

        with true <- MapSet.member?(moved, other.id),
             [_ | _] <- path,
             %{} = taken <-
               Enum.find(pages, &(&1.id != other.id and Map.get(paths, &1.id) == path)) do
          {path, taken}
        else
          _free -> nil
        end
      end)

    case clash do
      nil ->
        :ok

      {path, taken} ->
        {:error,
         field: :slug,
         message:
           dgettext(
             "errors",
             "The page %{title} of this version is read at /%{address} too. Choose another slug or parent.",
             title: taken.title,
             address: Enum.join(path, "/")
           )}
    end
  end

  # The page itself and every page filed under it, however deep: their addresses all follow it.
  defp moved(pages, id) do
    by_parent = Enum.group_by(pages, & &1.parent_section_id)
    gather(by_parent, [id], MapSet.new([id]), 0)
  end

  defp gather(_by_parent, [], gathered, _depth), do: gathered
  defp gather(_by_parent, _ids, gathered, depth) when depth >= @depth, do: gathered

  defp gather(by_parent, ids, gathered, depth) do
    children =
      ids
      |> Enum.flat_map(&Map.get(by_parent, &1, []))
      |> Enum.map(& &1.id)
      |> Enum.reject(&MapSet.member?(gathered, &1))

    gather(by_parent, children, MapSet.union(gathered, MapSet.new(children)), depth + 1)
  end

  defp others(changeset, id) do
    site_id = Ash.Changeset.get_attribute(changeset, :site_id) || changeset.tenant
    version_id = Ash.Changeset.get_attribute(changeset, :workspace_version_id)

    Section
    |> Ash.Query.for_read(:read, %{}, tenant: site_id, authorize?: false)
    |> Ash.Query.filter(workspace_version_id == ^version_id)
    |> Ash.Query.select([
      :id,
      :title,
      :slug,
      :parent_section_id,
      :front_page,
      :group_heading,
      :group_page
    ])
    |> Ash.read(tenant: site_id, authorize?: false, page: false)
    |> case do
      {:ok, found} -> Enum.reject(found, &(&1.id == id))
      {:error, _unreadable} -> []
    end
  end

  @impl true
  def has_validate?, do: true

  @impl true
  def supports(_opts), do: [Ash.Changeset]
end
