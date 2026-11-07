# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_document/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaDocument.Resources.Helpers.Slug do
  @moduledoc """
  The `MishkaSlug.Change` options every public slug of the document is made with.

  Workspaces, sections, section drafts and tags all use them, so the same text gives the same
  slug in each. The slug keeps the script of the record's `language`, as far as the site's
  languages allow (`MishkaCmsCore.Runtime.Languages.slug_locales/1`).

      change {MishkaSlug.Change, MishkaDocument.Resources.Helpers.Slug.options()}
  """

  @doc "The options of `MishkaSlug.Change` for a resource that has a `:slug` and a `:language`."
  @spec options() :: keyword()
  def options do
    [
      from: :slug,
      into: :slug,
      language: :language,
      locales: {MishkaCmsCore.Runtime.Languages, :slug_locales, []}
    ]
  end
end
