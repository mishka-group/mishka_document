defmodule MishkaDocument.Plugins.SectionShareCard do
  @moduledoc """
  A plain mishka_installer plugin: after a documentation page is saved (`document:section:after_save` — created or updated, a
  master's twin alike), its share card is looked at in the background and drawn when what it shows
  changed (`MishkaCmsCore.Runtime.ShareCard.refresh/3`), so it is ready before the first reader.
  Only while it is approved and its document active (`MishkaDocument.ShareCards.target/1`). Registered in
  `MishkaDocument.Application`.
  """

  alias MishkaCmsCore.Runtime.Resources.Notifiers.PluginHook

  use MishkaInstaller.Event.Hook,
    event: PluginHook.save_event_name(MishkaDocument.Section),
    initial: %{priority: 60}

  alias MishkaCmsCore.Runtime.ShareCard
  alias MishkaDocument.ShareCards

  @impl true
  def call(record, _meta) do
    with site_id when is_binary(site_id) <- record.site_id,
         {:record, _kind, _captures} = target <- ShareCards.target(record) do
      ShareCard.refresh(site_id, target)
    end

    {:reply, record}
  end
end
