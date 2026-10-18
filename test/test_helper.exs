# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_document/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

# The CMS's application supervisor owns these; running the extension's suite on its own means
# starting the ones a JSON API request actually touches, and nothing more:
#
#   Repo                 the database, named by the resources (see the test-only `MishkaDocument.Repo`)
#   PubSub               resources broadcast on write through their `pub_sub` blocks
#   SiteState            ETS host index — the tenant plug resolves a request's site through it
#   SettingsState        ETS settings cache, read while rendering and authorizing
#   TranslationsState    ETS cache of the words runtime templates ask t/1 for
#   ViewerState          ETS cache of who a signed-in user is to the site gates
#   RateLimitState       ETS counters signing in is limited by, hit on every sign-in
#   AshAuthentication    token signing and verification for the bearer flow
#   TestEndpoint         the endpoint the requests are made against
#
# Left out deliberately: Oban, the compilers, the asset and page-builder caches and BootHandler. They
# belong to running a site, not to answering an API call, and starting them would make this suite
# depend on machinery it never exercises.
# Oban's tables are not an Ash resource, so `mix ash.codegen` never emits them.
{:ok, _} = MishkaDocument.Repo.start_link()
Ecto.Migrator.up(MishkaDocument.Repo, 0, MishkaDocument.Test.ObanMigration, log: false)
:ok = Supervisor.stop(MishkaDocument.Repo)

# THE COUNTER THE PARTITION SUPERVISOR PICKS A PARTITION WITH. `ModuleCompilerHandler` reads it
# from `:persistent_term` on every compile, and the CMS's own application puts it there at boot —
# so a suite that compiles components has to put it there itself.
:persistent_term.put(:module_compiler_partition_counter, :atomics.new(1, signed: false))

children = [
  MishkaDocument.Repo,
  {Oban, Application.fetch_env!(:mishka_document, Oban)},
  {Phoenix.PubSub, name: MishkaCmsCore.PubSub},
  MishkaCmsCore.Runtime.States.SiteState,
  MishkaCmsCore.Runtime.States.SettingsState,
  MishkaCmsCore.Runtime.States.TranslationsState,
  MishkaCmsCore.Runtime.States.ViewerState,
  MishkaCmsCore.Runtime.States.RateLimitState,
  # THE ONE ASSET CACHE THIS SUITE STARTS, the sitemap's store.
  # `MishkaDocument.Plugins.SitemapUrlsTest` reads what this extension adds to a sitemap
  # the way core's build reads it, and the build keeps the sitemap it makes there.
  MishkaCmsCore.Runtime.States.AssetsState,
  # WHAT THE INSTALL WIZARD'S RUN WRITES AS IT COMPILES THE NEW SITE: `Bootstrap.run/1`, which
  # `MishkaDocument.ProvisionTest` drives, saves each layout it compiles here.
  MishkaCmsCore.Runtime.States.WebRunTimeMetaDataState,
  # THIS EXTENSION SHIPS COMPONENTS NOW, and a component is only a row until something compiles it.
  # `MishkaDocument.LiveComponentsRenderTest` renders the five out of the database for real — the
  # same lazy compile a visitor's first request triggers — and that needs the gate, the registry
  # that names each compile, and the supervisor those compiles run under. The CMS's own suite starts
  # the same three for the same reason.
  #
  # Everything else the comment at the top of this file leaves out stays out: these three are what
  # rendering a stored component costs, and nothing more.
  MishkaCmsCore.Runtime.Handlers.CompileGate,
  {Registry, keys: :unique, name: MishkaCms.ModuleCompilerHandlerRegistry},
  {PartitionSupervisor,
   child_spec: DynamicSupervisor,
   name: MishkaCmsCore.Runtime.Handlers.ModuleCompilerHandlerPartition,
   partitions: System.schedulers_online()},
  {AshAuthentication.Supervisor, [otp_app: :mishka_document]},
  MishkaDocument.TestEndpoint
]

{:ok, _} =
  Supervisor.start_link(children,
    strategy: :one_for_one,
    name: MishkaDocument.TestSupervisor
  )

ExUnit.start(assert_receive_timeout: 5_000)
Ecto.Adapters.SQL.Sandbox.mode(MishkaDocument.Repo, :manual)
