# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_document/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

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
  # and gives each its own head on the page that shows it (a `runtime:page:seo` plugin).
  @seo_plugins [
    MishkaDocument.Plugins.SitemapUrls,
    MishkaDocument.Plugins.PageRecords,
    MishkaDocument.Plugins.PageSeo
  ]

  # Each document's and page's share card looked at again after it is saved, on its own
  # `document:<resource>:after_save` event, and every one of a site named for a redraw of them all
  # (a `runtime:share_card:targets` plugin) — `MishkaCmsCore.Runtime.ShareCard`.
  @share_card_plugins [
    MishkaDocument.Plugins.WorkspaceShareCard,
    MishkaDocument.Plugins.SectionShareCard,
    MishkaDocument.Plugins.ShareCardTargets
  ]

  # Names the components the site's documentation draws in its text, the icons it names and the
  # classes it writes, so its stylesheet carries them (a `runtime:compile:content_components`
  # plugin), tells a page whether its reader came by a live navigation (a
  # `RuntimeLive.OnMount.AfterCompile` plugin), and gives the site's layout what only a
  # documentation page knows: the languages its document or page is written in, and the bar under
  # the header (a `runtime:page:frame` plugin) — `MishkaCmsCore.Runtime.SiteLayout`.
  @runtime_plugins [
    MishkaDocument.Plugins.ContentComponents,
    MishkaDocument.Plugins.LiveVisit,
    MishkaDocument.Plugins.PageFrame
  ]

  # Each code block of a page being written is lexed in a task of its own under this supervisor — see
  # `MishkaDocument.Resources.Changes.HighlightCode`.
  @highlight_supervisor {Task.Supervisor, name: MishkaDocument.HighlightSupervisor}

  @doc """
  Every mishka_installer plugin this extension ships, all of which `start/2` supervises. A plugin
  left out of it never registers, so the event it listens on never reaches it.
  """
  @spec plugins() :: [module()]
  def plugins,
    do:
      @dashboard_widgets ++
        @settings_plugins ++
        @sidebar_menus ++
        @provision_plugins ++ @seo_plugins ++ @share_card_plugins ++ @runtime_plugins

  @impl true
  def start(_type, _args) do
    opts = [strategy: :one_for_one, name: MishkaDocument.Supervisor]
    Supervisor.start_link([@highlight_supervisor | plugins()], opts)
  end
end
