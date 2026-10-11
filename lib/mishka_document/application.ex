defmodule MishkaDocument.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @dashboard_widgets [
    MishkaDocument.Dashboard.Widgets.RecentDocuments,
    MishkaDocument.Dashboard.Widgets.VersionActivity,
    MishkaDocument.Dashboard.Widgets.OpenIssues,
    MishkaDocument.Dashboard.Widgets.WorkspacesSummary
  ]

  @doc """
  The document extension's dashboard widget plugins. Each self-registers on the `dashboard:widgets`
  event, and `MishkaDocument.Dashboard.WidgetSettings` walks this same list to register each
  widget's own settings under the Documents tab — so the two can never disagree about which widgets
  exist.
  """
  @spec dashboard_widgets() :: [module()]
  def dashboard_widgets, do: @dashboard_widgets

  # Registers the document widgets' settings under the Documents tab (a `settings:register` plugin).
  @settings_plugins [
    MishkaDocument.Dashboard.WidgetSettings
  ]

  # Contributes this extension's entry to the admin sidebar (a `sidebar:menus` plugin).
  @sidebar_menus [
    MishkaDocumentWeb.SidebarMenu
  ]

  # Installs this extension onto a site when an admin asks for it — the `installer:extension:install`
  # event. Subscribing is also how the installer's own registry learns this extension exists, so
  # there is nothing else to register: see `MishkaCmsCore.Install.Extensions`.
  @provision_plugins [
    MishkaDocument.Plugins.Installer
  ]

  # Lists this extension's documents in a site's sitemap (a `seo:sitemap:urls` plugin), names a
  # document and a page of one as kinds of record a page can show (a `runtime:page:records` plugin),
  # gives each its own head on the page that shows it (a `runtime:page:seo` plugin), and sends a
  # document's old address under /docs to its own (a `web:request:after_site_resolve` plugin).
  @seo_plugins [
    MishkaDocument.Plugins.SitemapUrls,
    MishkaDocument.Plugins.PageRecords,
    MishkaDocument.Plugins.PageSeo,
    MishkaDocument.Plugins.AddressRedirect
  ]

  # Each document's and page's share card looked at again after it is saved, on its own
  # `document:<resource>:after_save` event (`MishkaCmsCore.Runtime.ShareCard`).
  @share_card_plugins [
    MishkaDocument.Plugins.WorkspaceShareCard,
    MishkaDocument.Plugins.SectionShareCard
  ]

  @doc """
  Every mishka_installer plugin this extension ships, and exactly what `start/2` supervises. A plugin
  left out of it never registers, so the event it listens on never reaches it.
  """
  @spec plugins() :: [module()]
  def plugins,
    do:
      @dashboard_widgets ++
        @settings_plugins ++
        @sidebar_menus ++ @provision_plugins ++ @seo_plugins ++ @share_card_plugins

  @impl true
  def start(_type, _args) do
    opts = [strategy: :one_for_one, name: MishkaDocument.Supervisor]
    Supervisor.start_link(plugins(), opts)
  end
end
