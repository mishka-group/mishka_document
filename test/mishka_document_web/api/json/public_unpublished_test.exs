# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_document/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaDocumentWeb.Api.Json.PublicUnpublishedTest do
  @moduledoc """
  What is not published is not public, through the JSON:API or the site: a page approved by both
  its reviews is read only while its version is published — alpha, beta, rc or stable — and its
  document is active, and a version only while its document is active
  (`MishkaDocument.Resources.Preparations.OpenToActor`). A list leaves the others out and one asked
  for alone is not found.

  The system still reads them: the components a page names are in the site's stylesheet before
  its version is published (`MishkaDocument.Plugins.ContentComponents`).
  """
  use MishkaDocument.ConnCase

  import MishkaDocument.Test.Factory

  alias MishkaDocument.{Section, WorkspaceVersion}

  @moduletag :capture_log

  @sections "/api/json/v1/user/mishka-document/section"
  @versions "/api/json/v1/user/mishka-document/workspace-version"
  @lineages "/api/json/v1/user/mishka-document/workspace-version-lineage"

  setup do
    MishkaCmsCore.Runtime.States.SiteState.clear()
    Application.put_env(:ash_json_api, MishkaDocument, router: MishkaDocument.TestRouter)

    site = create_site!(name: "localhost", host: "localhost", active: true, master: true)

    MishkaCmsCore.Runtime.States.SiteState.save(%{
      id: site.id,
      name: site.name,
      host: site.host,
      priority: site.priority,
      active: site.active,
      master: site.master
    })

    on_exit(fn -> MishkaCmsCore.Runtime.States.SiteState.clear() end)

    active = create_workspace!(site_id: site.id, skip_version: true, status: :active)
    stable = version!(site, active, :stable)

    pages =
      for {document_status, version_status} <- [
            {:active, :stable},
            {:active, :beta},
            {:active, :draft},
            {:active, :archived},
            {:draft, :stable},
            {:archived, :stable}
          ],
          into: %{} do
        document =
          if document_status == :active,
            do: active,
            else: create_workspace!(site_id: site.id, skip_version: true, status: document_status)

        version =
          if {document_status, version_status} == {:active, :stable},
            do: stable,
            else: version!(site, document, version_status)

        {{document_status, version_status},
         page!(site, version, "doc-#{document_status}-#{version_status}")}
      end

    %{site: site, active: active, stable: stable, pages: pages}
  end

  defp version!(site, document, status),
    do:
      create_workspace_version!(
        site_id: site.id,
        workspace_id: document.id,
        status: status,
        published_at: ~U[2026-03-01 00:00:00Z]
      )

  # Each page names a component of its own, so the stylesheet says which pages it was built from.
  defp page!(site, version, component),
    do:
      create_section!(
        site_id: site.id,
        workspace_version_id: version.id,
        content: ~s(<p>[[component #{component} /]] Read me</p>),
        content_review_status: :approved,
        technical_review_status: :approved
      )

  defp get(path) do
    response = make_api_request(path, %{}, method: :get, headers: [])
    {response.status, Jason.decode!(response.resp_body)}
  end

  defp ids({200, %{"data" => data}}), do: data |> Enum.map(& &1["id"]) |> Enum.sort()

  defp published(pages),
    do: pages |> Map.take([{:active, :stable}, {:active, :beta}]) |> Map.values()

  defp unpublished(pages),
    do: pages |> Map.drop([{:active, :stable}, {:active, :beta}]) |> Map.values()

  describe "a page of a version or a document that is not published" do
    test "is not listed", ctx do
      assert ids(get("#{@sections}?page[limit]=100")) ==
               ctx.pages |> published() |> Enum.map(& &1.id) |> Enum.sort()
    end

    test "is not found asked for alone", ctx do
      for page <- published(ctx.pages), do: assert({200, _} = get("#{@sections}/#{page.id}"))
      for page <- unpublished(ctx.pages), do: assert({404, _} = get("#{@sections}/#{page.id}"))
    end

    test "is not listed under its own version", ctx do
      for page <- ctx.pages |> Map.values() do
        version =
          Ash.get!(WorkspaceVersion, page.workspace_version_id,
            tenant: ctx.site.id,
            authorize?: false
          )

        listed =
          ids(get("#{@sections}/workspace/#{version.id}/version/#{version.version_number}"))

        if page in published(ctx.pages),
          do: assert(listed == [page.id]),
          else: assert(listed == [])
      end
    end

    test "is not read by a visitor of the site, and is still in its stylesheet", ctx do
      visible =
        Section
        |> Ash.Query.for_read(:public_list, %{}, actor: nil, tenant: ctx.site.id)
        |> Ash.read!(page: false)
        |> Enum.map(& &1.id)
        |> Enum.sort()

      assert visible == ctx.pages |> published() |> Enum.map(& &1.id) |> Enum.sort()

      {:reply, %{components: components}} =
        MishkaDocument.Plugins.ContentComponents.call(%{
          site_id: ctx.site.id,
          components: [],
          icons: []
        })

      for {{document_status, version_status}, _page} <- ctx.pages,
          do: assert("doc-#{document_status}-#{version_status}" in components)
    end
  end

  describe "a version of a document that is not active" do
    test "is neither listed nor found", ctx do
      inactive =
        for {{status, _version}, page} <- ctx.pages,
            status != :active,
            do: page.workspace_version_id

      listed = ids(get("#{@versions}?page[limit]=100"))

      assert ctx.stable.id in listed
      for id <- inactive, do: refute(id in listed)
      for id <- inactive, do: assert({404, _} = get("#{@versions}/#{id}"))
    end

    test "is not named by a clone record", ctx do
      draft_document = create_workspace!(site_id: ctx.site.id, skip_version: true, status: :draft)
      source = version!(ctx.site, draft_document, :stable)
      copy = version!(ctx.site, draft_document, :beta)
      open_copy = version!(ctx.site, ctx.active, :beta)

      hidden =
        create_workspace_version_lineage!(
          site_id: ctx.site.id,
          source_version_id: source.id,
          new_version_id: copy.id
        )

      shown =
        create_workspace_version_lineage!(
          site_id: ctx.site.id,
          source_version_id: ctx.stable.id,
          new_version_id: open_copy.id
        )

      assert {404, _} = get("#{@lineages}/#{hidden.id}")
      assert {200, _} = get("#{@lineages}/#{shown.id}")
      assert ids(get("#{@lineages}/recent")) == [shown.id]
    end
  end
end
