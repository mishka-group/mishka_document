defmodule MishkaDocument.Resources.Changes.EnsureAddressPages do
  @moduledoc """
  Gives a document the two pages its own address is read at, when the address is set — its front
  page and every page of it (`MishkaDocument.Provision.ensure_address!/3`) — so an admin who writes
  `/product/docs` on the form is answered there without building a page.

  A page the site already has at either path is kept, its own design among them. The pages are
  written as the writer, in the same transaction as the document: a writer who may not write pages
  is refused before anything is saved, with what they are missing, unless the site already has
  both — a document whose address answers nothing would also send its old address there
  (`MishkaDocument.Plugins.AddressRedirect`). With no actor the system writes, as the seeds do.

  Nothing happens when the address is not changing, or is emptied: a document read under `/docs`
  again leaves the pages it had for the admin to keep or remove.

  ## Usage

      change MishkaDocument.Resources.Changes.EnsureAddressPages
  """
  use Ash.Resource.Change
  use Gettext, backend: MishkaCmsCore.Gettext

  alias MishkaDocument.Provision

  @impl true
  def change(changeset, _opts, context) do
    address = Ash.Changeset.get_attribute(changeset, :path)

    if is_binary(address) and Ash.Changeset.changing_attribute?(changeset, :path) do
      changeset
      |> Ash.Changeset.before_action(&permitted(&1, address, context.actor))
      |> Ash.Changeset.after_action(&written(&1, &2, address, context.actor))
    else
      changeset
    end
  end

  defp permitted(changeset, _address, nil), do: changeset

  defp permitted(changeset, address, actor) do
    case Provision.address_permissions_missing(site_id(changeset), address, actor) do
      [] ->
        changeset

      missing ->
        Ash.Changeset.add_error(changeset,
          field: :path,
          message:
            dgettext(
              "errors",
              "This address needs its pages written, which needs %{names}. Ask an admin who holds them, or leave the address empty.",
              names: Enum.join(missing, ", ")
            )
        )
    end
  end

  defp written(_changeset, record, address, actor) do
    Provision.ensure_address!(record.site_id, address, actor: actor)
    {:ok, record}
  end

  defp site_id(changeset),
    do: Ash.Changeset.get_attribute(changeset, :site_id) || changeset.tenant
end
