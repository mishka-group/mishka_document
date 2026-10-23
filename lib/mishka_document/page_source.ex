# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_document/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaDocument.PageSource do
  @moduledoc """
  The rows a documentation page is made of: the document its address names, the version of it a
  reader is shown and that version's approved pages as a tree.

  Two plugins answer for the same page, `MishkaDocument.Plugins.PageSeo` for its head and
  `MishkaDocument.Plugins.PageFrame` for the bar under the header and the page's other languages,
  and they read it here so that they cannot name two documents for one address. A request is the
  map core hands either of them (`MishkaCmsCore.Runtime.Seo.given/2`,
  `MishkaCmsCore.Runtime.SiteLayout.given/2`): the `site_id`, the page and its `path`, the
  `params` (the path's captures and the query) and the `language` of the response.

  READ AS THE SYSTEM. What is read is the lock `MishkaCmsWeb.RuntimeLive` admits the visitor by:
  read as a visitor who may not open it, a locked document or page is no record at all, and the
  page is handed no permissions to refuse them with. Neither hook names the visitor either, and
  what they build reaches only a visitor the page admitted.
  """

  require Ash.Query

  alias MishkaDocument.{Address, Section, Workspace, WorkspaceVersion}

  @version_fields [
    :id,
    :workspace_id,
    :version_number,
    :is_latest_for_version,
    :published_at,
    :inserted_at
  ]

  # What a tree of pages is asked for: where each one sits, what it is called, how it is locked and
  # which group of translations it belongs to. Never its text.
  @page_fields [
    :id,
    :workspace_version_id,
    :title,
    :slug,
    :order_position,
    :parent_section_id,
    :front_page,
    :group_heading,
    :group_page,
    :permissions,
    :language_group_id
  ]

  @doc """
  The document whose own address the page is at, else the one with no address of its own the
  `workspace` capture names, in the page's language, on the page's site; `nil` when the request
  names none or none is shown. Only `fields` of it are read, and `loads` loaded.

  A slug names only a document with no address of its own: one that has an address is read there
  and nowhere else, so `/docs/<its slug>` names nothing.
  """
  @spec workspace(map(), [atom()], term()) :: struct() | nil
  def workspace(%{site_id: site_id} = request, fields, loads) when is_binary(site_id),
    do:
      Enum.find_value(own_address(request) ++ by_slug(request), &read(&1, request, fields, loads))

  def workspace(_request, _fields, _loads), do: nil

  defp own_address(%{page: %{path: path}}) do
    case Address.of_page(path) do
      nil -> []
      address -> [{:path, address}]
    end
  end

  defp own_address(_request), do: []

  defp by_slug(%{params: %{"workspace" => slug}}) when is_binary(slug) and slug != "",
    do: [{:slug, slug}]

  defp by_slug(_request), do: []

  defp read(named, %{site_id: site_id} = request, fields, loads) do
    Workspace
    |> Ash.Query.for_read(:public_list, %{}, tenant: site_id, authorize?: false)
    |> named_by(named)
    |> in_language(Map.get(request, :language))
    |> Ash.Query.select(fields)
    |> Ash.Query.load(loads)
    |> Ash.read(tenant: site_id, authorize?: false, page: [limit: 1])
    |> case do
      {:ok, %{results: [workspace | _rest]}} -> workspace
      _none -> nil
    end
  end

  defp named_by(query, {:slug, slug}),
    do: Ash.Query.filter(query, slug == ^slug and is_nil(path))

  defp named_by(query, {:path, address}), do: Ash.Query.filter(query, path == ^address)

  defp in_language(query, language) when is_binary(language) and language != "",
    do: Ash.Query.filter(query, language == ^language)

  defp in_language(query, _no_language), do: query

  @doc "A document's published versions, without their pages, for `workspace/3` to load."
  @spec versions() :: Ash.Query.t()
  def versions, do: Ash.Query.select(WorkspaceVersion, @version_fields)

  @doc """
  The version a reader is shown among a document's published `versions`
  (`MishkaDocument.Address.version_shown/2`) and its approved pages as a tree — what a page's
  address is followed through (`MishkaDocument.Address.page_at/2`), read for that version alone;
  `nil` when there is none.
  """
  @spec shown([struct()], String.t() | nil, String.t()) :: {struct(), [struct()]} | nil
  def shown(versions, asked, site_id) do
    with %WorkspaceVersion{} = version <- Address.version_shown(versions, asked),
         {:ok, %WorkspaceVersion{sections: pages} = shown} when is_list(pages) <-
           Ash.load(version, [sections: pages()], tenant: site_id, authorize?: false) do
      {shown, pages}
    else
      _none -> nil
    end
  end

  @doc "A version's pages, without their text, for `Ash.load/3` or a read of the pages of several."
  @spec pages() :: Ash.Query.t()
  def pages, do: Ash.Query.select(Section, @page_fields)
end
