# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_document/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaDocument.TestEndpoint do
  @moduledoc """
  The endpoint this extension's suite runs against, doing two jobs at once:

    * it carries the test's HTTP request to `MishkaDocument.TestRouter`, and
    * it is what every resource broadcasts through on write, because `config/config.exs` names it as
      `config :mishka_cms_core, endpoint: …` — the setting each `pub_sub do module … end` reads.

  Everything the CMS's real endpoint carries and this one does not — sessions, LiveView, static
  assets, the admin pipeline — is machinery a JSON:API request never touches.

  Test-only: Mix does not compile a path dependency's `test/support`, so the CMS never sees this
  module, and `mix.exs` keeps `test` out of the hex `files:` list.
  """

  use Phoenix.Endpoint, otp_app: :mishka_document

  # The admin LiveViews mount over a session, so the browser pipeline needs one to fetch.
  @session_options [
    store: :cookie,
    key: "_mishka_document_test_key",
    signing_salt: "document-test",
    same_site: "Lax"
  ]

  socket "/live", Phoenix.LiveView.Socket, websocket: [connect_info: [session: @session_options]]

  plug Plug.Parsers,
    parsers: [:urlencoded, :multipart, {:json, length: 10_000_000}],
    pass: ["*/*"],
    json_decoder: Jason

  plug Plug.MethodOverride
  plug Plug.Session, @session_options
  plug Plug.Head
  plug MishkaDocument.TestRouter
end
