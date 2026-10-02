defmodule MishkaDocument.Dashboard.WidgetSettings do
  @moduledoc """
  Registers every mishka_document dashboard widget's own settings with the Settings page through the
  `settings:register` mishka_installer hook — so "Documents to show" is documented under the
  **Documents** tab (`category: "document"`, group **Dashboard widgets**) alongside the rest of the
  extension's settings, instead of hiding inside the dashboard's per-user layout.

  It walks `MishkaDocument.Application.dashboard_widgets/0` and asks each descriptor for its
  definitions (`MishkaCmsCore.Dashboard.Widget.settings_definitions/1`), which derives the key from
  `Widget.setting_key/2` — the same function the dashboard reads through. A widget that adds a
  setting is registered by declaring it; there is no second list to keep in step.

  Every definition is `scope: :user`: the value belongs to the admin reading the board, and both
  editors — the card's gear and this tab — write the same `Settings.put_user/3` row. Registered in
  `MishkaDocument.Application`.

  See `MishkaBlog.Dashboard.WidgetSettings` for the identical blog-side plugin, and
  `MishkaCmsCore.Settings.define/3`.
  """

  use MishkaInstaller.Event.Hook, event: "settings:register", initial: %{priority: 60}

  alias MishkaCmsCore.Dashboard.Widget
  alias MishkaCmsCore.Install.Extensions

  @impl true
  def call(%{definitions: definitions} = data) do
    widget_definitions =
      Enum.flat_map(
        MishkaDocument.Application.dashboard_widgets(),
        fn plugin -> Widget.settings_definitions(plugin.widget()) end
      )

    # THE EXTENSION'S OWN TAB CARRIES ITS OWN ANSWERS. `Extensions.settings/2` is where the two are
    # written — the version this site was set up at, and the switch that hides it — so every
    # extension asks them the same way and the installer reads them from one place.
    installer_definitions = Extensions.settings(:mishka_document, "document")

    {:reply, %{data | definitions: definitions ++ widget_definitions ++ installer_definitions}}
  end
end
