# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_document/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaDocument.WorkspaceScope do
  @moduledoc """
  Which workspaces the admin list shows: one row per document, not one per translation.

  The rule and the reasoning are `MishkaCmsCore.LanguageEditions`', which every translatable admin list
  shares. What is workspace-specific is what an edition chip reads: a variant is itself a workspace, so
  its progress lives on its own `health_metrics`, and that has to be asked for through the variant
  relationship — which the table's `preload` DSL cannot express, since it takes a name rather than a
  nested load.

  See `MishkaDocument.Workspace`, which declares both sibling relationships, and
  `MishkaDocumentWeb.Templates.DocumentCard`, which draws the chips.
  """

  alias MishkaCmsCore.Accounts.Checks.AccessPermissions
  alias MishkaCmsCore.LanguageEditions

  @doc """
  Narrows the list to master editions while it is collapsed — see
  `MishkaCmsCore.LanguageEditions.collapsed?/1`.

  The `on_load` contract is `fn query, state -> query`.
  """
  @spec scope_to_masters(Ash.Query.t(), map()) :: Ash.Query.t()
  defdelegate scope_to_masters(query, state), to: LanguageEditions

  @doc "Loads how far along each of a workspace's sibling editions is, so a chip can read `FA · 76%`."
  @spec load_edition_progress(Ash.Query.t(), map()) :: Ash.Query.t()
  def load_edition_progress(query, state) do
    LanguageEditions.load_variants(query, state, [:health_metrics])
  end

  @doc """
  Whether a table action is drawn: the table shows `status` records (`:active` or `:archived`) and
  its viewer holds `permission`. For a Gervaz `visible` function.

      visible fn _record, state ->
        MishkaDocument.WorkspaceScope.shown?(state, :active, "admin:dashboard:document:workspace")
      end
  """
  @spec shown?(map(), :active | :archived, String.t()) :: boolean()
  def shown?(%{archive_status: status, current_user: user}, status, permission),
    do: AccessPermissions.match?(user, %{}, permissions: [permission])

  def shown?(_state, _status, _permission), do: false

  @doc "Whether the table is currently showing search results."
  @spec searching?(map()) :: boolean()
  defdelegate searching?(state), to: LanguageEditions
end
