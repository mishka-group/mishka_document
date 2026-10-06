defmodule MishkaDocument.Resources.Validations.SameWorkspaceVersion do
  @moduledoc """
  Refuses a record that names, by id, a record of the wrong workspace version.

  A section, a section draft and a note draft live in one workspace version (`workspace_version_id`)
  and name the records around them by id: a parent section, the section a draft changes, the note a
  draft rewrites. Those are the same version's records, or the version's tree and the drafts applied
  to it put a record where nobody reading that version finds it. A section's source is the section it
  was copied from, which is in another version of the same workspace.

  Checked when the id or the record's own version changes, whoever writes. Nothing is checked when
  either is absent. A record named that cannot be read is refused.

  Each refusal is written in the Gettext locale of the process the action runs in, `errors` domain
  of `MishkaCmsCore.Gettext`, with the `:label` translated in the same domain; a request with no
  locale reads it in English.

  `MishkaCmsCore.Runtime.Resources.Validations.SameSiteReference` holds the two records to one site;
  declare it before this one with `only_when_valid?: true`, so a record of another site gets its
  message and not this one's.

  ## Options

    * `:field` — required. The attribute holding the id.
    * `:resource` — required. The resource the id names.
    * `:label` — required. What the named record is called in the message, such as `"section"`.
    * `:read_action` — a read of the named resource that reaches every site's rows. Defaults to
      `:master_get`.
    * `:through` — for a named record with no `workspace_version_id` of its own, as a note:
      `{field, resource}` or `{field, resource, read_action}`, the attribute on it naming the record
      whose version it is in. Its read action defaults to `:master_get`.
    * `:in` — `:same_version` (the default), or `:other_version` for a record of another version of
      the same workspace.

  ## Usage

      validate {SameWorkspaceVersion,
                field: :parent_section_id, resource: MishkaDocument.Section, label: "section"},
               only_when_valid?: true

      validate {SameWorkspaceVersion,
                field: :source_note_id,
                resource: MishkaDocument.Note,
                label: "note",
                through: {:section_id, MishkaDocument.Section}},
               only_when_valid?: true

      validate {SameWorkspaceVersion,
                field: :source_section_id,
                resource: MishkaDocument.Section,
                label: "section",
                in: :other_version},
               only_when_valid?: true
  """
  use Ash.Resource.Validation
  use Gettext, backend: MishkaCmsCore.Gettext

  @impl true
  def init(opts) do
    with {:ok, field} when is_atom(field) <- Keyword.fetch(opts, :field),
         {:ok, resource} when is_atom(resource) <- Keyword.fetch(opts, :resource),
         {:ok, label} when is_binary(label) <- Keyword.fetch(opts, :label),
         placement when placement in [:same_version, :other_version] <-
           Keyword.get(opts, :in, :same_version),
         {:ok, through} <- through(Keyword.get(opts, :through)) do
      {:ok,
       [
         field: field,
         resource: resource,
         label: label,
         in: placement,
         read_action: Keyword.get(opts, :read_action, :master_get),
         through: through
       ]}
    else
      _invalid ->
        {:error,
         "SameWorkspaceVersion takes :field, :resource and :label, :in as :same_version or " <>
           ":other_version, and :through as {field, resource} or {field, resource, read_action}"}
    end
  end

  defp through(nil), do: {:ok, nil}
  defp through({field, resource}), do: {:ok, {field, resource, :master_get}}
  defp through({_field, _resource, _read_action} = through), do: {:ok, through}
  defp through(_invalid), do: :error

  @impl true
  def validate(changeset, opts, _context) do
    field = opts[:field]
    id = Ash.Changeset.get_attribute(changeset, field)
    own = Ash.Changeset.get_attribute(changeset, :workspace_version_id)

    if changing?(changeset, field) and not is_nil(id) and not is_nil(own),
      do: check(version_of(id, opts[:resource], opts[:read_action], opts[:through]), own, opts),
      else: :ok
  end

  defp changing?(changeset, field),
    do:
      Ash.Changeset.changing_attribute?(changeset, field) or
        Ash.Changeset.changing_attribute?(changeset, :workspace_version_id)

  defp version_of(nil, _resource, _read_action, _through), do: :error

  defp version_of(id, resource, read_action, through) do
    case Ash.get(resource, id, action: read_action, authorize?: false) do
      {:ok, record} -> own_version(record, through)
      _missing -> :error
    end
  end

  defp own_version(%{workspace_version_id: version}, nil) when not is_nil(version),
    do: {:ok, version}

  defp own_version(record, {field, resource, read_action}),
    do: version_of(Map.get(record, field), resource, read_action, nil)

  defp own_version(_record, _through), do: :error

  defp check({:ok, own}, own, opts) do
    if opts[:in] == :same_version, do: :ok, else: refuse_other_version(opts)
  end

  defp check({:ok, version}, own, opts) do
    cond do
      opts[:in] == :same_version -> refuse_same_version(opts)
      same_workspace?(version, own) -> :ok
      true -> refuse_other_version(opts)
    end
  end

  defp check(:error, _own, opts) do
    {:error,
     field: opts[:field],
     message: dgettext("errors", "That %{label} is no longer here.", label: noun(opts))}
  end

  defp same_workspace?(version, own) do
    case {workspace_of(version), workspace_of(own)} do
      {{:ok, workspace}, {:ok, workspace}} -> true
      _different_or_unknown -> false
    end
  end

  defp workspace_of(version) do
    case Ash.get(MishkaDocument.WorkspaceVersion, version, action: :read_any, authorize?: false) do
      {:ok, %{workspace_id: workspace}} -> {:ok, workspace}
      _missing -> :error
    end
  end

  defp refuse_same_version(opts) do
    {:error,
     field: opts[:field],
     message:
       dgettext(
         "errors",
         "That %{label} belongs to another workspace version. Choose one from the same version.",
         label: noun(opts)
       )}
  end

  defp refuse_other_version(opts) do
    {:error,
     field: opts[:field],
     message:
       dgettext("errors", "That %{label} is not in another version of this workspace.",
         label: noun(opts)
       )}
  end

  defp noun(opts), do: Gettext.dgettext(MishkaCmsCore.Gettext, "errors", opts[:label])

  @impl true
  def has_validate?, do: true

  @impl true
  def supports(_opts), do: [Ash.Changeset]
end
