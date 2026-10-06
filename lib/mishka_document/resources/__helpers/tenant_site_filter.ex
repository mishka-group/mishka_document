defmodule MishkaDocument.Resources.Helpers.TenantSiteFilter do
  @moduledoc """
  Ash preparation that filters event logs by the actor's site_id.

  EventLog stores site_id inside JSONB metadata/data fields rather than
  as a top-level column, so standard Ash multitenancy doesn't apply.
  This preparation reads the actor's site_id and applies a fragment filter.

  - Master users (site_id: nil) see all events — no filter applied.
  - Tenant users see only events matching their site_id in metadata or data,
    AND only events created by system (no actor) or by tenant users (not master users).
  - Anything else, a missing actor included, sees no event.
  """
  use Ash.Resource.Preparation
  require Ash.Query

  @impl true
  def prepare(query, _opts, context) do
    case context.actor do
      %{site_id: site_id} when is_binary(site_id) ->
        Ash.Query.filter(
          query,
          (fragment("(?->>'site_id') = ?::text", metadata, ^site_id) or
             fragment("(?->>'site_id') = ?::text", data, ^site_id)) and
            (is_nil(actor_id) or not is_nil(actor.site_id))
        )

      %{id: _, site_id: nil} ->
        query

      _ ->
        Ash.Query.filter(query, false)
    end
  end
end
