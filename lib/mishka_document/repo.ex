# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_document/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaDocument.Repo do
  use AshPostgres.Repo, otp_app: :mishka_document

  def min_pg_version do
    %Version{major: 16, minor: 9, patch: 0}
  end

  # Don't open unnecessary transactions
  # will default to `false` in 4.0
  def prefer_transaction? do
    false
  end

  def installed_extensions do
    # Must match the CMS's `MishkaCms.Repo`: the resources are the same either way, and a user's
    # `email` is a `citext` column, so a repo without it cannot hold the accounts tables this
    # extension borrows. The migration generator installs whatever is listed here.
    ["ash-functions", "citext"]
  end
end
