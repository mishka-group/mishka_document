# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_document/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaDocument.Resources.Mixins.PaperTrailMixin do
  @moduledoc """
  The version resource a PaperTrail-tracked page, note or draft keeps its history in: the table,
  its foreign key to the record, and the actions and policies that read the history.

      paper_trail do
        mixin {MishkaDocument.Resources.Mixins.PaperTrailMixin, :postgres,
               ["mishka_document_section_versions"]}
      end

  The versions are global rather than per site, so a record's history can be read across sites by a
  master. The foreign key cascades, so deleting the record deletes its versions.

  The version resource gets these read actions, all bypassing the tenant:

  * `:get_any` - One version by id.
  * `:read_any` - Every version.
  * `:sorted_versions` - Every version, newest first, paginated.

  A version holds a full copy of its record, so it is for an admin of the section area however it
  is reached, the record's own history included: a master reads every site's, a site's admin its
  own site's. A call made with `authorize?: false` is not checked.
  """

  @doc """
  The version resource's DSL for `table`, as quoted code the mixin expands into the resource.
  """
  @spec postgres(String.t()) :: Macro.t()
  def postgres(table) when is_binary(table) do
    quote do
      multitenancy do
        global? true
      end

      postgres do
        table unquote(table)
        repo Application.compile_env!(:mishka_cms_core, :repo)

        references do
          reference :version_source, on_delete: :delete
        end

        custom_indexes do
          index [:version_inserted_at]
          index [:version_inserted_at], all_tenants?: true
          index [:version_source_id], all_tenants?: true
        end
      end

      actions do
        read :get_any do
          get? true
          multitenancy :bypass
        end

        read :read_any do
          multitenancy :bypass
        end

        read :sorted_versions do
          multitenancy :bypass
          pagination offset?: true, default_limit: 20, max_page_size: 100, required?: false

          prepare fn query, _context ->
            Ash.Query.sort(query, version_inserted_at: :desc)
          end
        end
      end

      changes do
        change MishkaCmsCore.Runtime.Resources.Changes.SetVersionSiteId, on: [:create]
      end

      policies do
        policy always() do
          authorize_if {MishkaCmsCore.Accounts.Checks.AccessPermissions,
                        permissions: [
                          "admin:dashboard:document:section",
                          "admin:api:document:section"
                        ]}
        end

        policy always() do
          authorize_if actor_attribute_equals(:site_id, nil)
          authorize_if expr(^ref(:site_id) == ^actor(:site_id))
        end
      end
    end
  end
end
