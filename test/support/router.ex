defmodule MishkaDocument.TestRouter do
  @moduledoc """
  The routes the JSON API tests drive, mirroring the CMS's `/api/json` scope.

  The pipeline is the CMS's `:api` pipeline: the tenant lookup that resolves a request's site from its
  host, CORS, then the bearer token and the actor it names, the gate that closes an offline site
  to all but its admins, and the shared context that tells every policy the request came in on the
  admin API (`admin_surface: :api`), so the `admin:api:` names answer rather than the dashboard's.
  Dropping any of them changes what the API does — tenancy and authorization are enforced through
  them, so a suite that skipped them would be testing a different application.

  The admin pages sit behind the CMS's entry gate: anything under `admin:dashboard`.

  See `MishkaDocument.TestJsonApiRouter` for which domains are mounted.
  """

  use Phoenix.Router

  # `extension_routes/1` expands to `live/3`.
  import Phoenix.LiveView.Router
  use AshAuthentication.Phoenix.Router

  import MishkaCmsCore.ExtensionRouter
  import MishkaCmsCore.Runtime.Plugs.SiteLookupPlug, only: [confirm_tenant: 2]
  import MishkaCmsCore.Runtime.Plugs.ApiTenantLookupPlug, only: [confirm_bearer_tenant: 2]

  pipeline :api do
    plug :accepts, ["json"]
    plug MishkaCmsCore.Runtime.Plugs.ApiTenantLookupPlug
    plug MishkaCmsCore.Runtime.Plugs.ApiCorsPlug
    plug :load_from_bearer
    plug :confirm_bearer_tenant
    plug :set_actor, :user
    plug MishkaCmsCore.Runtime.Plugs.ApiAvailabilityPlug, api: :json_api
    plug :put_api_surface
  end

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {MishkaDocument.TestLayouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
    plug MishkaCmsCore.Runtime.Plugs.SiteLookupPlug
    plug :load_from_session
    plug :confirm_tenant
    plug :set_actor, :user
  end

  # The CMS's public pipeline as far as an extension's own public route reads it: the site of the
  # host, the visitor, and the response headers with their Content-Security-Policy and its nonce.
  pipeline :public do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {MishkaDocument.TestLayouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
    plug MishkaCmsCore.Runtime.Plugs.SiteLookupPlug
    plug :load_from_session
    plug :confirm_tenant
    plug MishkaCmsWeb.Runtime.Plugs.SecurityHeaders
  end

  scope "/" do
    pipe_through [:public]

    extension_routes(:public)
  end

  scope "/api/json" do
    pipe_through [:api]

    forward "/", MishkaDocument.TestJsonApiRouter
  end

  scope "/admin/dashboard" do
    pipe_through [:browser]

    ash_authentication_live_session :test_authenticated_routes,
      on_mount: [
        {MishkaCmsCore.LiveUserAuth, :live_user_required},
        {MishkaCmsCore.LiveUserAuth, {:require_permission, [{:under, "admin:dashboard"}]}}
      ] do
      extension_routes(:admin)
    end
  end

  defp put_api_surface(conn, _opts) do
    Ash.PlugHelpers.update_context(conn, fn context ->
      Map.update(
        context || %{},
        :shared,
        %{admin_surface: :api},
        &Map.put(&1, :admin_surface, :api)
      )
    end)
  end
end
