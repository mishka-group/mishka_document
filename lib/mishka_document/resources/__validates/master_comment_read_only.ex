# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_document/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaDocument.Resources.Validations.MasterCommentReadOnly do
  @moduledoc """
  Stops a tenant changing an issue comment a master wrote.

  ## What it is for

  A master can write on any site's issue, and a tenant admin of that site can read what they wrote.
  Nothing in the policies stops the tenant editing or deleting it too — both are admins, and the
  comment sits on their own site — so a master's answer on an issue could be rewritten or removed
  by the site it was written to. A master's comment is theirs; the tenant only sees it.

  Only a tenant actor (one with a `site_id`) is checked. A master is never refused, and neither is
  system code running without an actor, such as the seeds archiving comments. `authorize?: false`
  does not skip it: a tenant actor is a tenant actor either way.

  ## Usage

      update :update do
        validate MasterCommentReadOnly
      end

  Put it on the tenant `:update`, `:destroy`, `:unarchive` and `:permanent_destroy`, never on their
  `master_*` twins.

  It reads the comment's CURRENT `contributor_id` — `Ash.Changeset.get_data/2`, not
  `get_attribute/2` — because the question is who wrote the row, not what the changeset would like
  it to say. Who counts as a master is decided by
  `MishkaDocument.Resources.Calculations.AuthoredByMaster.master_ids/1`, the same read that tells
  the admin which comments to draw without Edit and Delete. When that read fails the change is
  refused with its error rather than let through.
  """
  use Ash.Resource.Validation
  use Gettext, backend: MishkaCmsCore.Gettext

  alias MishkaDocument.Resources.Calculations.AuthoredByMaster

  @impl true
  def init(opts), do: {:ok, opts}

  @impl true
  def validate(changeset, _opts, %{actor: %{site_id: site_id}}) when is_binary(site_id) do
    contributor_id = Ash.Changeset.get_data(changeset, :contributor_id)

    with {:ok, masters} <- AuthoredByMaster.master_ids([contributor_id]) do
      if MapSet.member?(masters, contributor_id) do
        {:error,
         field: :contributor_id,
         message:
           dgettext_noop(
             "errors",
             "This comment was written by a master admin and can only be changed by a master."
           )}
      else
        :ok
      end
    end
  end

  def validate(_changeset, _opts, _context), do: :ok

  @impl true
  def has_validate?, do: true

  @impl true
  def supports(_opts), do: [Ash.Changeset]
end
