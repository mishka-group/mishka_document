# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_document/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

import Config

config :mishka_document, MishkaDocument.Repo,
  username: "postgres",
  password: "postgres",
  hostname: "localhost",
  database: "mishka_document_dev",
  show_sensitive_data_on_connection_error: true,
  pool_size: 10

config :ash, policies: [show_policy_breakdowns?: true]
