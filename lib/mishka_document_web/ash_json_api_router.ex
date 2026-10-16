# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_document/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaDocumentWeb.AshJsonApiRouter do
  use AshJsonApi.Router,
    domains: [],
    open_api: "/open_api"
end
