defmodule MishkaDocumentWeb.SidebarMenu do
  @moduledoc """
  The document extension's admin pages and the one sidebar entry that links to them — a
  `"sidebar:menus"` plugin (`MishkaCmsCore.Sidebar`).

  Only `document` is a link; it lands in the core's **Plugins** section. The core never names this
  extension, so removing it removes the entry and nothing in `MishkaCmsCore.Sidebar` changes.

  The other eight are `nav: false` — pages, not links. They are declared because they do NOT share
  one answer to "who may open this": the workspace pages are `admin:dashboard:document:workspace`,
  everything hanging off a section is `admin:dashboard:document:section`, and the event log opens
  for either and shows each area the events of its own records (`MishkaDocument.EventLog.logged/1`). The
  link carries the union, since holding either is reason enough to be shown the section. The data
  behind each page asks for the same area.

  Three of them are parameterised routes that could never be a static link anyway
  (`/document/sections/:workspace_version_id` and friends) — declaring them here is the only place
  their gate can be written down.

  Each page reads its own gate from here, so the permission is written down once:

      on_mount {MishkaCmsCore.LiveUserAuth,
                {:require_permission, MishkaDocumentWeb.SidebarMenu.permissions("document.issues")}}

  Registered in `MishkaDocument.Application`.
  """

  use MishkaInstaller.Event.Hook, event: "sidebar:menus", initial: %{priority: 50}
  use Gettext, backend: MishkaCmsCore.Gettext

  alias MishkaCmsCore.Accounts.Checks.AccessPermissions
  alias MishkaCmsCore.Sidebar
  alias MishkaCmsCore.Sidebar.Item

  @workspace ["admin:dashboard:document:workspace"]
  @section ["admin:dashboard:document:section"]
  @either @workspace ++ @section

  @items Enum.map(
           [
             %{
               extension: :mishka_document,
               key: "document",
               label: gettext_noop("Documents"),
               icon: "hero-document-duplicate",
               path: "/admin/dashboard/document",
               module: MishkaDocumentWeb.Live.Admin.Dashboard.Home.Index,
               group: "plugins",
               order: 20,
               permissions: @either,
               credit_name: "Mishka Document",
               credit_url: "https://mishka.tools/cms/extensions/documentation"
             }
           ],
           &Item.new!/1
         )

  @doc "This extension's sidebar entry plus every admin page it owns."
  @spec items() :: [Item.t()]
  def items, do: @items

  @doc "The permissions declared for one of this extension's pages. See `MishkaCmsCore.Sidebar.permissions/2`."
  @spec permissions(String.t()) :: [AccessPermissions.requirement()]
  def permissions(key), do: Sidebar.permissions(@items, key)

  @impl true
  def call(%{items: items} = data), do: {:reply, %{data | items: items ++ @items}}
end
