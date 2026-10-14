defmodule MishkaDocument.Test.IconLibrary do
  @moduledoc """
  Test icon set: the `hero-` glyphs the tests name, and no other — `hero-section` is text, not an
  icon. Registered as the site's only configured set by `registered/1`, so an icon is known whatever
  kit bundle `priv/cms_ui_kits/` holds on this machine, or whether it holds one at all.

      setup {MishkaDocument.Test.IconLibrary, :registered}
  """

  @behaviour MishkaCmsCore.Runtime.PageBuilder.IconLibrary

  @glyphs ~w(hero-bell hero-circle-stack hero-cloud hero-envelope hero-inbox hero-moon hero-star)

  @doc "Configures this set as the only `:icon_libraries`, and puts the configured ones back on exit."
  @spec registered(map()) :: :ok
  def registered(_context) do
    original = Application.get_env(:mishka_cms_core, :icon_libraries)
    Application.put_env(:mishka_cms_core, :icon_libraries, [__MODULE__])

    ExUnit.Callbacks.on_exit(fn ->
      case original do
        nil -> Application.delete_env(:mishka_cms_core, :icon_libraries)
        libraries -> Application.put_env(:mishka_cms_core, :icon_libraries, libraries)
      end
    end)

    :ok
  end

  @impl true
  def prefixes, do: ["hero-"]

  @impl true
  def label, do: "Test"

  @impl true
  def all, do: @glyphs

  @impl true
  def variants, do: [{"", "Outline"}]

  @impl true
  def svg(name, size) when name in @glyphs,
    do: {:safe, [~s(<svg width="#{size}" height="#{size}"></svg>)]}

  def svg(_name, _size), do: nil

  @impl true
  def css(names) do
    names
    |> Enum.filter(&(&1 in @glyphs))
    |> Enum.map_join("\n", &".#{&1}{mask:none;}")
  end

  @impl true
  def search(query, opts) do
    needle = query |> to_string() |> String.trim() |> String.downcase()

    @glyphs
    |> Enum.filter(&String.contains?(&1, needle))
    |> Enum.take(Keyword.get(opts, :limit, 60))
  end

  @impl true
  def count(query, _variant), do: length(search(query, limit: length(@glyphs)))
end
