# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_document/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

# The CMS's application supervisor owns the runtime around the core; running the extension's suite on
# its own means starting it here, and the core ships the harness that does: `MishkaCmsCore.Test.Boot`
# creates Oban's tables (they are not an Ash resource, so `mix ash.codegen` never emits them), then
# starts the repo, Oban, the core's caches and runtime compiler, AshAuthentication and the endpoint,
# the way a host starts them. The core's own application has already started `MishkaCmsCore.PubSub`,
# the partition counter the compiler picks a partition with, and `mishka_installer`'s registry.
#
# THE RUN STARTS ONCE THE CORE'S PLUGINS AND THIS EXTENSION'S OWN ARE LIVE. Each registers from its
# own `handle_continue`, and on a slow boot it tries again a second later, after the first tests have
# already asked its event.
#
# A TEST PLUGIN THAT OUTLIVED ITS RUN is swept first: `mishka_installer` keeps registrations in Mnesia,
# on disk, so a suite killed part-way leaves one of `MishkaDocument.Test.Plugins` registered and every
# later run boots with it live.
:ok =
  MishkaCmsCore.Test.Boot.start!(
    otp_app: :mishka_document,
    repo: MishkaDocument.Repo,
    endpoint: MishkaDocument.TestEndpoint,
    plugins: MishkaCmsCore.Application.plugins() ++ MishkaDocument.Application.plugins(),
    sweep: ["Elixir.MishkaDocument.Test.Plugins."]
  )

ExUnit.start(assert_receive_timeout: 5_000, exclude: [:benchmark])
Ecto.Adapters.SQL.Sandbox.mode(MishkaDocument.Repo, :manual)
