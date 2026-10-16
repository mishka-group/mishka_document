# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_document/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaDocument.Resources.Calculations.AuthoredByMaster do
  @moduledoc """
  Whether an issue comment was written by a master — a user with no site.

  A tenant admin can read a master's comment but not change it (see
  `MishkaDocument.Resources.Validations.MasterCommentReadOnly`), so a tenant's comment list needs
  to know which comments to draw without Edit and Delete. Loading `:contributor` under a tenant
  returns `nil` for a master, the same as for no author, so this asks
  `MishkaCmsCore.Accounts.Calculations.ByMaster` about `:contributor_id` instead.

  A comment whose contributor was deleted has no `contributor_id` left (`on_delete :nilify`), so
  it is no longer a master's.
  """
  use Ash.Resource.Calculation

  alias MishkaCmsCore.Accounts.Calculations.ByMaster

  @field [field: :contributor_id]

  @impl true
  def load(query, _opts, context), do: ByMaster.load(query, @field, context)

  @impl true
  def calculate(records, _opts, context), do: ByMaster.calculate(records, @field, context)

  @doc "See `MishkaCmsCore.Accounts.Helper.master_ids/1`."
  @spec master_ids([Ash.UUID.t() | nil]) :: {:ok, MapSet.t()} | {:error, term()}
  defdelegate master_ids(user_ids), to: MishkaCmsCore.Accounts.Helper
end
