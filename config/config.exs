# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_document/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

import Config

config :mishka_document, ecto_repos: [MishkaDocument.Repo], ash_domains: [MishkaDocument]

# JSON:API speaks `application/vnd.api+json`, which Plug does not know by default — without this the
# `:accepts ["json"]` plug answers 406 to every request the suite makes. `:mime` reads this at compile
# time, so changing it needs `mix deps.compile mime --force`.
config :mime,
  extensions: %{"json" => "application/vnd.api+json"},
  types: %{"application/vnd.api+json" => ["json"]}

config :ash_json_api,
  show_public_calculations_when_loaded?: false,
  authorize_update_destroy_with_error?: true

config :ash,
  default_string_length_count: :codepoints,
  allow_forbidden_field_for_relationships_by_default?: true,
  include_embedded_source_by_default?: false,
  show_keysets_for_all_actions?: false,
  default_page_type: :keyset,
  policies: [no_filter_static_forbidden_reads?: false],
  keep_read_action_loads_when_loading?: false,
  default_actions_require_atomic?: true,
  read_action_after_action_hooks_in_order?: true,
  bulk_actions_default_to_errors?: true,
  transaction_rollback_on_error?: true

config :spark,
  formatter: [
    remove_parens?: true,
    "Ash.Resource": [
      section_order: [
        :postgres,
        :json_api,
        :resource,
        :code_interface,
        :actions,
        :policies,
        :pub_sub,
        :preparations,
        :changes,
        :validations,
        :multitenancy,
        :attributes,
        :relationships,
        :calculations,
        :aggregates,
        :identities
      ]
    ],
    "Ash.Domain": [
      section_order: [:json_api, :resources, :policies, :authorization, :domain, :execution]
    ]
  ]

# Which repo the resources write through and which endpoint they broadcast on. Every Ash resource
# reachable from here reads these with `Application.compile_env!/2`, so they must be set wherever this
# extension is compiled — the CMS sets them to its own; on its own it uses the ones below. Being
# compile-time and strict is deliberate: a host that forgets to configure this is told at build time,
# not by a crash in production.
config :mishka_cms_core,
  repo: MishkaDocument.Repo,
  endpoint: MishkaDocument.TestEndpoint,
  host_app: :mishka_document

import_config "#{config_env()}.exs"
