# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_document/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaDocumentWeb.Api.Json.LockedRecordsTest do
  @moduledoc """
  The public JSON API keeps a locked document, its versions and its pages to whoever their page
  opens for (`MishkaDocument.Resources.Preparations.OpenToActor`): a list leaves out what its caller
  may not open, and asking for one of them is answered as an id nothing is stored at is: a 404
  `not_found`, never a 403. A document opens with its own
  permissions, a version and a clone record with its document's, and a page with its own, else its
  nearest parent page's, else its document's. A locked page takes a bookmark, and a locked document
  a follow, from no one else (`MishkaDocument.Resources.Validations.OpenToActor`).

  handbook (locked to editors): start (names nothing), desk (writers) → style (names nothing)
  guide (names nothing): intro (names nothing)
  """
  use MishkaDocument.ConnCase
  import MishkaDocument.Test.Factory

  @moduletag :unit
  @moduletag :capture_log

  @password "Password123!"
  @documents "/api/json/v1/user/mishka-document/workspace"
  @versions "/api/json/v1/user/mishka-document/workspace-version"
  @pages "/api/json/v1/user/mishka-document/section"
  @lineage "/api/json/v1/user/mishka-document/workspace-version-lineage"

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

    handbook = document!(site, "handbook", ["editors:read"])
    locked = version!(site, handbook)
    start = page!(site, locked, "start", [])
    desk = page!(site, locked, "desk", ["writers:read"])
    style = page!(site, locked, "style", [], parent_section_id: desk.id)

    guide = document!(site, "guide", [])
    open = version!(site, guide)
    intro = page!(site, open, "intro", [])

    %{
      handbook: handbook,
      guide: guide,
      locked: locked,
      open: open,
      start: start,
      desk: desk,
      style: style,
      site: site,
      intro: intro,
      editor: token(site, "editor@example.com", ["editors:read"]),
      writer: token(site, "writer@example.com", ["writers:read"])
    }
  end

  test "a locked document and its versions are left out, and not found alone", ctx do
    assert ids(fetch(@documents, nil)) == ids_of([ctx.guide])
    assert ids(fetch(@documents, ctx.writer)) == ids_of([ctx.guide])
    assert ids(fetch(@documents, ctx.editor)) == ids_of([ctx.handbook, ctx.guide])

    assert ids(fetch(@versions, nil)) == ids_of([ctx.open])
    assert ids(fetch(@versions, ctx.editor)) == ids_of([ctx.locked, ctx.open])

    assert_not_found(@documents, ctx.handbook.id, nil)
    assert_not_found(@documents, ctx.handbook.id, ctx.writer)
    assert_not_found(@versions, ctx.locked.id, ctx.writer)
    assert fetch("#{@documents}/#{ctx.handbook.id}", ctx.editor).status == 200
    assert fetch("#{@versions}/#{ctx.locked.id}", ctx.editor).status == 200
  end

  test "each page opens with its own lock, else the nearest above it, else its document's", ctx do
    assert ids(fetch(@pages, nil)) == ids_of([ctx.intro])
    assert ids(fetch(@pages, ctx.editor)) == ids_of([ctx.start, ctx.intro])
    assert ids(fetch(@pages, ctx.writer)) == ids_of([ctx.desk, ctx.style, ctx.intro])

    at_version = "#{@pages}/workspace/#{ctx.locked.id}/version/1.0.0"
    assert ids(fetch(at_version, nil)) == []
    assert ids(fetch(at_version, ctx.writer)) == ids_of([ctx.desk, ctx.style])

    assert_not_found(@pages, ctx.style.id, ctx.editor)
    assert fetch("#{@pages}/#{ctx.style.id}", ctx.writer).status == 200
    assert_not_found(@pages, ctx.start.id, nil)
    assert fetch("#{@pages}/#{ctx.intro.id}", nil).status == 200
  end

  test "a locked document's clone records are left out, and not found alone",
       %{site: site} = ctx do
    locked = clone!(site, ctx.handbook, ctx.locked)
    open = clone!(site, ctx.guide, ctx.open)

    assert ids(fetch("#{@lineage}/recent", nil)) == ids_of([open])
    assert ids(fetch("#{@lineage}/recent", ctx.editor)) == ids_of([locked, open])
    assert ids(fetch("#{@lineage}/source-version/#{ctx.locked.id}", ctx.writer)) == []

    assert_not_found(@lineage, locked.id, ctx.writer)
    assert fetch("#{@lineage}/#{locked.id}", ctx.editor).status == 200
  end

  test "a locked page takes a bookmark, and a locked document a follow, only from its readers",
       ctx do
    bookmark =
      &write(
        "/api/json/v1/user/mishka-document/section-bookmark",
        "section_bookmark",
        %{"section_id" => &1.id},
        &2
      )

    follow =
      &write(
        "/api/json/v1/user/mishka-document/workspace-follow",
        "workspace_follower",
        %{"workspace_id" => &1.id},
        &2
      )

    refused = bookmark.(ctx.start, ctx.writer)
    assert refused.status == 400

    assert [%{"detail" => "Section not found or does not belong to your site."}] =
             Jason.decode!(refused.resp_body)["errors"]

    assert bookmark.(ctx.start, ctx.editor).status == 201
    assert bookmark.(ctx.style, ctx.writer).status == 201

    assert follow.(ctx.handbook, ctx.writer).status == 400
    assert follow.(ctx.handbook, ctx.editor).status == 201
    assert follow.(ctx.guide, ctx.writer).status == 201
  end

  # A request no site is chosen for — `x-no-tenant`, a master's switch — is told it needs one.
  test "a request with no site is told the route needs one", ctx do
    for path <- [@documents, @versions, @pages, "#{@pages}/#{ctx.intro.id}", "#{@lineage}/recent"] do
      response = make_api_request(path, %{}, method: :get, headers: [{"x-no-tenant", "true"}])

      assert response.status == 400, path
      assert [%{"code" => "tenant_required"}] = Jason.decode!(response.resp_body)["errors"]
    end
  end

  defp document!(site, slug, permissions) do
    create_workspace!(
      site_id: site.id,
      skip_version: true,
      status: :active,
      slug: slug,
      language: "en",
      permissions: permissions
    )
  end

  defp version!(site, document, overrides \\ []) do
    create_workspace_version!(
      [
        site_id: site.id,
        workspace_id: document.id,
        status: :stable,
        version_number: "1.0.0",
        is_latest_for_version: true,
        published_at: ~U[2026-03-01 00:00:00Z]
      ] ++ overrides
    )
  end

  # A version of `document` cloned from `source`, and the record saying so.
  defp clone!(site, document, source) do
    version = version!(site, document, version_number: "2.0.0", is_latest_for_version: false)

    create_workspace_version_lineage!(
      site_id: site.id,
      new_version_id: version.id,
      source_version_id: source.id
    )
  end

  defp page!(site, version, slug, permissions, overrides \\ []) do
    create_section!(
      [
        site_id: site.id,
        workspace_version_id: version.id,
        slug: slug,
        language: "en",
        content_review_status: :approved,
        technical_review_status: :approved,
        permissions: permissions
      ] ++ overrides
    )
  end

  # A user of `site` holding `permissions`, signed in to the API: its bearer token.
  defp token(site, email, permissions) do
    create_user_with_permissions!(permissions,
      site_id: site.id,
      email: email,
      password: @password,
      password_confirmation: @password
    )

    response =
      make_api_request("/api/json/v1/auth/user/sign-in", %{
        "type" => "user",
        "attributes" => %{"email" => email, "password" => @password}
      })

    assert response.status == 201
    Jason.decode!(response.resp_body)["meta"]["token"]
  end

  defp fetch(path, token), do: make_api_request(path, %{}, method: :get, headers: bearer(token))

  # A record the reader may not open answers what an id nothing is stored at answers: a 404
  # `not_found`, with nothing to tell the two apart.
  defp assert_not_found(collection, id, token) do
    refused = fetch("#{collection}/#{id}", token)
    missing = fetch("#{collection}/#{Ash.UUID.generate()}", token)

    assert error_of(refused) == error_of(missing)
    assert error_of(refused)["code"] == "not_found"
  end

  defp error_of(%{status: 404, resp_body: body}) do
    assert [error] = Jason.decode!(body)["errors"]
    Map.take(error, ["status", "code", "title"])
  end

  defp write(path, type, attributes, token) do
    make_api_request(path, %{"type" => type, "attributes" => attributes},
      method: :post,
      headers: bearer(token)
    )
  end

  defp bearer(nil), do: []
  defp bearer(token), do: [{"authorization", "Bearer #{token}"}]

  defp ids(%{status: 200, resp_body: body}),
    do: body |> Jason.decode!() |> Map.fetch!("data") |> Enum.map(& &1["id"]) |> Enum.sort()

  defp ids_of(records), do: records |> Enum.map(& &1.id) |> Enum.sort()
end
