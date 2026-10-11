defmodule MishkaDocument.Plugins.AddressRedirect do
  @moduledoc """
  Sends a reader who asks for a document with an address of its own at its old address under the
  documentation's base to that address, with a permanent redirect: `/docs/chelekom` to
  `/chelekom/docs`, `/docs/chelekom/headless/switch` to `/chelekom/docs/headless/switch`, the query
  string with it. One document, one address — a link or a crawler that knew the old one lands on the
  new one, and nothing indexes the same page twice (`MishkaDocument.Address`).

  On the `web:request:after_site_resolve` mishka_installer hook
  `MishkaCmsCore.Runtime.Plugs.SiteLookupPlug` fires once the request's site is known, before a page
  is resolved. Only a `GET` or `HEAD` under the base (`MishkaDocument.Provision.docs_base/0`) in one
  of the site's languages is read for — one read of one document by its slug and language, as the
  system, since where a document is read is public whoever asks; a locked document's own page still
  decides who may open it. Every other request passes untouched, as does one for a document read
  under the base.

  A module because a mishka_installer hook is one. Registered in `MishkaDocument.Application`.
  """
  use MishkaInstaller.Event.Hook, event: "web:request:after_site_resolve"

  import Plug.Conn

  require Ash.Query

  alias MishkaCmsCore.Runtime.Languages
  alias MishkaDocument.{Provision, Workspace}

  @impl true
  def call(conn, _meta) do
    case moved_to(conn) do
      nil ->
        {:reply, conn}

      to ->
        {:reply,
         conn
         |> put_resp_header("location", with_query(to, conn.query_string))
         |> send_resp(301, "")
         |> halt()}
    end
  end

  defp moved_to(%Plug.Conn{halted: false, method: method, path_info: [_ | _] = segments} = conn)
       when method in ["GET", "HEAD"] do
    with %{id: site_id} when is_binary(site_id) <- conn.assigns[:current_site],
         {language, under} when is_binary(language) <- language_of(segments, site_id),
         [slug | page] <- under_base(under),
         %{path: address} = document when is_binary(address) <- document(slug, language, site_id) do
      Languages.url(Enum.join([address | page], "/"), %{"lang" => document.language}, site_id)
    else
      _not_moved -> nil
    end
  end

  defp moved_to(_conn), do: nil

  defp language_of(segments, site_id) do
    case Languages.leading(segments, Languages.site(site_id)) do
      nil -> {Languages.implied(segments, site_id), segments}
      code -> {code, tl(segments)}
    end
  end

  defp under_base(segments) do
    base = Provision.docs_base() |> String.split("/", trim: true) |> List.delete(":lang")

    if List.starts_with?(segments, base), do: Enum.drop(segments, length(base)), else: []
  end

  defp document(slug, language, site_id) do
    Workspace
    |> Ash.Query.for_read(:public_list, %{}, authorize?: false)
    |> Ash.Query.filter(slug == ^slug and language == ^language and not is_nil(path))
    |> Ash.Query.select([:path, :language])
    |> Ash.read(tenant: site_id, authorize?: false, page: [limit: 1])
    |> case do
      {:ok, %{results: [found | _rest]}} -> found
      _not_moved -> nil
    end
  end

  defp with_query(to, ""), do: to
  defp with_query(to, query), do: to <> "?" <> query
end
