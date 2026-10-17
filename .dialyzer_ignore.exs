# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_document/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

# The four sidebar warnings are false. `MishkaDocumentWeb.SidebarMenu.permissions/1` works at
# runtime (test/mishka_document_web/sidebar_menu_test.exs calls it). They come from core's
# `MishkaCmsCore.Sidebar.Item.t()`, a GuardedStruct whose type dialyzer reads wrongly.
#
# The fifth is false too. `MishkaDocument.EventLog` broadcasts through the endpoint the host sets in
# `config :mishka_cms_core, endpoint:`; `MishkaDocument.TestEndpoint` exists only under test/support,
# so a dialyzer run that does not compile the test support cannot find it.
#
# Each entry names the file and the exact warning text, so nothing else in these files or any other
# file is hidden.
[
  {"lib/mishka_document_web/sidebar_menu.ex", "Invalid type specification for function items."},
  {"lib/mishka_document_web/sidebar_menu.ex",
   "Invalid type specification for function permissions."},
  {"lib/mishka_document_web/sidebar_menu.ex", "The function call permissions will not succeed."},
  {"lib/mishka_document_web/sidebar_menu.ex", "Function permissions/1 has no local return."},
  {"lib/mishka_document/resources/event_log.ex",
   "Function MishkaDocument.TestEndpoint.broadcast/3 does not exist."}
]
