defmodule MishkaDocument.Resources.Validations.DocumentAddress do
  @moduledoc """
  Refuses a document's `path` — its own address, `/chelekom/docs` — that the site could not answer,
  or that another document's pages would answer too (`MishkaDocument.Address`).

    * It is a site path: segments of lower-case letters, digits and dashes, and `:lang` at most once.
    * It is outside the documentation's base, `/docs`, where the documents with no address of their
      own are read by their slug.
    * No other document of the site is read at it, above it or under it: `/chelekom/docs` and
      `/chelekom/docs/headless` would both answer `/chelekom/docs/headless/switch`. The one exception
      is a translation of the same document (its `language_group_id`) at the same address holding
      `:lang`, whose pages answer in their own language.

  Checked when the path, the language, the language group or the site changes, whoever writes. An
  empty path is a document with no address of its own, and is not checked. The other documents are
  read as the system, since the address must be free whether or not the writer may read them.

  Each refusal is written in the Gettext locale of the process the action runs in, `errors` domain
  of `MishkaCmsCore.Gettext`.

  ## Usage

      validate MishkaDocument.Resources.Validations.DocumentAddress
  """
  use Ash.Resource.Validation
  use Gettext, backend: MishkaCmsCore.Gettext

  require Ash.Query

  alias MishkaDocument.{Address, Workspace}

  @watched [:path, :language, :language_group_id, :site_id]

  @impl true
  def init(opts), do: {:ok, opts}

  @impl true
  def validate(changeset, _opts, _context) do
    address = Ash.Changeset.get_attribute(changeset, :path)

    if is_binary(address) and
         Enum.any?(@watched, &Ash.Changeset.changing_attribute?(changeset, &1)),
       do: check(Address.check(address), address, changeset),
       else: :ok
  end

  defp check(:ok, address, changeset) do
    case Enum.find(others(changeset), &taken?(&1, address, changeset)) do
      nil ->
        :ok

      other ->
        {:error,
         field: :path,
         message:
           dgettext(
             "errors",
             "The document %{name} is read at %{address}. Choose an address that is not that one, above it or under it.",
             name: other.name,
             address: other.path
           )}
    end
  end

  defp check({:error, :in_docs_base}, _address, _changeset) do
    {:error,
     field: :path,
     message:
       dgettext(
         "errors",
         "Documents without an address of their own are read under /docs. Choose an address outside it, such as /product/docs."
       )}
  end

  defp check({:error, :not_a_path}, _address, _changeset) do
    {:error,
     field: :path,
     message:
       dgettext(
         "errors",
         "Write an address of this site, such as /product/docs: lower-case letters, digits and dashes between slashes, and :lang at most once."
       )}
  end

  defp others(changeset) do
    site_id = Ash.Changeset.get_attribute(changeset, :site_id) || changeset.tenant

    Workspace
    |> Ash.Query.for_read(:read_any, %{}, authorize?: false)
    |> Ash.Query.filter(site_id == ^site_id and not is_nil(path))
    |> filter_out(changeset.data)
    |> Ash.Query.select([:id, :name, :path, :language_group_id])
    |> Ash.read(authorize?: false, page: false)
    |> case do
      {:ok, found} -> found
      {:error, _unreadable} -> []
    end
  end

  defp filter_out(query, %{id: id}) when is_binary(id), do: Ash.Query.filter(query, id != ^id)
  defp filter_out(query, _new), do: query

  defp taken?(other, address, changeset) do
    Address.overlap?(other.path, address) and not shared_edition?(other, address, changeset)
  end

  defp shared_edition?(other, address, changeset) do
    group = Ash.Changeset.get_attribute(changeset, :language_group_id)

    other.path == address and Address.language?(address) and not is_nil(group) and
      other.language_group_id == group
  end

  @impl true
  def has_validate?, do: true

  @impl true
  def supports(_opts), do: [Ash.Changeset]
end
