# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_document/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaDocumentWeb.Api.Json.UserIncludeTest do
  @moduledoc """
  Every JSON:API include in this extension that ends at a `MishkaCmsCore.Accounts.User` — an issue's
  reporter, a comment's contributor, a draft's author, a bookmark's owner — answers a caller with the
  account's id. The account's email, permissions, site and confirmation time go only to the account's
  owner and to admins; the field policies on User decide that for every extension at once.

  The walk covers every resource this extension routes, admin routes included, because a route that
  is admin-only today can be opened to the public tomorrow without anyone looking at its includes.
  """
  use MishkaDocument.ConnCase

  require Ash.Query

  @user MishkaCmsCore.Accounts.User
  @account_fields [:email, :confirmed_at, :site_id, :permission_values]

  setup do
    site = create_site!(name: "localhost", host: "localhost", active: true, priority: 50)
    # The account holds a site and a permission, so an empty answer for either is it withheld.
    user =
      create_user_with_permissions!(["admin:dashboard:document:section"],
        email: "contributor@example.com",
        site_id: site.id
      )

    {:ok, site: site, user: user}
  end

  # A relationship held back carries nothing: no site, no permissions. The fixtures give the account
  # both, so an empty answer here is the account's own being held back.
  defp withheld?(nil), do: true
  defp withheld?([]), do: true
  defp withheld?(%Ash.NotLoaded{}), do: true
  defp withheld?(%Ash.ForbiddenField{}), do: true
  defp withheld?(_loaded), do: false

  defp routed do
    :mishka_document
    |> Application.fetch_env!(:ash_domains)
    |> Enum.flat_map(&AshJsonApi.Domain.Info.routes/1)
    |> Enum.map(& &1.resource)
    |> Enum.uniq()
  end

  defp account_paths(resource) do
    resource
    |> AshJsonApi.Resource.Info.includes()
    |> List.wrap()
    |> walk(resource, [])
  end

  defp walk(includes, resource, prefix) do
    Enum.flat_map(includes, fn
      {name, nested} ->
        relationship = Ash.Resource.Info.relationship(resource, name)

        hop(relationship, prefix ++ [name], List.wrap(nested)) ++
          walk(List.wrap(nested), relationship.destination, prefix ++ [name])

      name ->
        hop(Ash.Resource.Info.relationship(resource, name), prefix ++ [name], [])
    end)
  end

  defp hop(%{destination: @user} = relationship, path, nested),
    do: [%{relationship: relationship, path: path, beyond: nested}]

  defp hop(_relationship, _path, _nested), do: []

  defp all_paths do
    for resource <- routed(), path <- account_paths(resource), do: {resource, path}
  end

  # Exactly the read an include runs for that last hop: the relationship's own read action, with
  # the context Ash puts on a relationship load — marked as one, and naming where it came from —
  # and the account's site and permissions asked for, as `fields[user]=site,permissions` asks.
  # Run on the API's surface unless another is named, as a JSON:API include is.
  defp read_through(
         %{source: source, name: name, read_action: read_action},
         user,
         actor,
         surface \\ :api
       ) do
    @user
    |> Ash.Query.set_context(%{
      private: %{loading_relationships?: true},
      shared: %{admin_surface: surface}
    })
    |> Ash.Query.load([:permission_values, :site, :permissions])
    |> Ash.Query.for_read(read_action || :read, %{}, actor: actor)
    |> Ash.Query.set_context(%{accessing_from: %{source: source, name: name}})
    |> Ash.Query.filter(id == ^user.id)
    |> Ash.read_one(actor: actor, tenant: user.site_id)
  end

  defp where({resource, %{path: path}}),
    do: "#{inspect(resource)} include=#{Enum.join(path, ".")}"

  # An include is one way through a relationship; a filter and a sort are others, and they need no
  # include. Every public relationship into an account, routed or not, reads through User's
  # `:related`, where the account's fields answer only its owner and admins, and cannot be sorted
  # through, because Ash checks no field policy on a sort.
  test "every public relationship into an account reads through :related and sorts through nothing" do
    offenders =
      for domain <- Application.fetch_env!(:mishka_document, :ash_domains),
          resource <- Ash.Domain.Info.resources(domain),
          %{destination: @user, public?: true} = relationship <-
            Ash.Resource.Info.relationships(resource),
          relationship.read_action != :related or relationship.sortable?,
          do: "#{inspect(resource)}.#{relationship.name}"

    assert offenders == [],
           "these reach an account without `read_action :related` and `sortable? false`: " <>
             Enum.join(offenders, ", ")
  end

  test "the walk finds the paths it is meant to guard" do
    found = Enum.map(all_paths(), fn {resource, %{path: path}} -> {resource, path} end)

    for expected <- [
          {MishkaDocument.Issue, [:reporter]},
          {MishkaDocument.IssueComment, [:contributor]},
          {MishkaDocument.SectionBookmark, [:user]}
        ] do
      assert expected in found, "#{inspect(expected)} is no longer found by the walk"
    end
  end

  test "no path goes on past the account to what the account holds" do
    offenders = Enum.filter(all_paths(), fn {_resource, %{beyond: beyond}} -> beyond != [] end)

    assert offenders == [],
           "these includes continue into the account's own relationships: " <>
             Enum.map_join(offenders, ", ", &where/1)
  end

  test "a visitor loading through any of them gets no account field", %{user: user} do
    for {_resource, %{relationship: relationship}} = path <- all_paths() do
      case read_through(relationship, user, nil) do
        {:ok, %{} = seen} ->
          for field <- @account_fields do
            assert %Ash.ForbiddenField{} = Map.get(seen, field),
                   "#{where(path)} gave #{field} to a visitor"
          end

          assert withheld?(seen.site), "#{where(path)} gave the site record to a visitor"
          assert withheld?(seen.permissions), "#{where(path)} gave the permissions to a visitor"

        _refused_or_missing ->
          :ok
      end
    end
  end

  test "a signed-in admin of another area gets no one else's account field", %{
    user: user,
    site: site
  } do
    reader = create_user_with_permissions!(["admin:dashboard:document:section"], site_id: site.id)

    for {_resource, %{relationship: relationship}} = path <- all_paths() do
      assert {:ok, seen} = read_through(relationship, user, reader)

      for field <- @account_fields do
        assert %Ash.ForbiddenField{} = Map.get(seen, field),
               "#{where(path)} gave #{field} to a reader"
      end

      assert withheld?(seen.site), "#{where(path)} gave the site record to a reader"
      assert withheld?(seen.permissions), "#{where(path)} gave the permissions to a reader"
    end
  end

  test "the owner of the account still sees their own through every path", %{user: user} do
    for {_resource, %{relationship: relationship}} = path <- all_paths() do
      assert {:ok, seen} = read_through(relationship, user, user)

      assert to_string(seen.email) == to_string(user.email),
             "#{where(path)} hid the owner's email"
    end
  end

  for {permission, surface} <- [
        {"admin:dashboard:*", :dashboard},
        {"admin:api:*", :api},
        {"*", :api}
      ] do
    test "an admin holding #{permission} still sees the whole account through every path on the #{surface}",
         %{user: user, site: site} do
      admin = create_user_with_permissions!([unquote(permission)], site_id: site.id)

      for {_resource, %{relationship: relationship}} = path <- all_paths() do
        assert {:ok, seen} = read_through(relationship, user, admin, unquote(surface))
        assert to_string(seen.email) == to_string(user.email), "#{where(path)} hid the email"
        assert seen.site_id == user.site_id, "#{where(path)} hid the site"
        assert seen.site.id == user.site_id, "#{where(path)} held back the site record"

        assert seen.permission_values == ["admin:dashboard:document:section"],
               "#{where(path)} hid the permissions"

        assert Enum.map(seen.permissions, & &1.name) == ["admin:dashboard:document:section"],
               "#{where(path)} held back the permission records"
      end
    end
  end
end
