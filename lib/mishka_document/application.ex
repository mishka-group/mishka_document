defmodule MishkaDocument.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

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
  # and gives each its own head on the page that shows it (a `runtime:page:seo` plugin).
  @seo_plugins [
    MishkaDocument.Plugins.SitemapUrls,
    MishkaDocument.Plugins.PageRecords,
    MishkaDocument.Plugins.PageSeo
  ]

  @doc """
  Every mishka_installer plugin this extension ships, and exactly what `start/2` supervises. A plugin
  left out of it never registers, so the event it listens on never reaches it.
  """
  @spec plugins() :: [module()]
  def plugins, do: @sidebar_menus ++ @provision_plugins ++ @seo_plugins

  @impl true
  def start(_type, _args) do
    opts = [strategy: :one_for_one, name: MishkaDocument.Supervisor]
    Supervisor.start_link(plugins(), opts)
  end
end
