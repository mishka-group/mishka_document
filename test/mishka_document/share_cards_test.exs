defmodule MishkaDocument.ShareCardsTest do
  @moduledoc """
  The documentation's share cards (`MishkaCmsCore.Runtime.ShareCard`): which card a document and a
  page show (`MishkaDocument.ShareCards.target/1`), the plugins that look at it again after each is
  saved — each on its own resource's `after_save` event — and the Share image field of their edit
  modals.
  """
  use MishkaDocument.DataCase, async: false
  use Oban.Testing, repo: MishkaDocument.Repo

  alias MishkaCmsCore.PluginRegistrations
  alias MishkaCmsCore.Runtime.Workers.ShareCardRefreshWorker
  alias MishkaDocument.{Section, ShareCards, Workspace}
  alias MishkaDocument.Plugins.{SectionShareCard, WorkspaceShareCard}
  alias MishkaGervaz.Resource.Info.Form, as: FormInfo
  alias MishkaInstaller.Event.{Event, EventHandler}

  # THE APPLICATION'S PLUGIN PROCESSES ARE NOT RUNNING IN THIS SUITE: each is registered the way the
  # CMS boot registers it, and unregistered when the test exits, since Mnesia is on disk.
  defp register(plugin) do
    PluginRegistrations.reconcile(false)
    {:ok, _} = plugin.register()
    on_exit(fn -> Event.unregister(:name, plugin, false) end)
    :ok = EventHandler.do_compile(plugin.config(:__event__), :start, false)
  end

  defp looks, do: for(job <- all_enqueued(worker: ShareCardRefreshWorker), do: job.args)

  defp approved, do: [content_review_status: :approved, technical_review_status: :approved]

  setup do
    site = create_site!(active: true)
    workspace = create_workspace!(site_id: site.id, status: :active, slug: "guide")
    version = create_workspace_version!(workspace_id: workspace.id, site_id: site.id)
    %{site: site, workspace: workspace, version: version}
  end

  describe "target/1" do
    test "an active document, by its slug and language", %{workspace: workspace} do
      assert ShareCards.target(workspace) ==
               {:record, "docs:document", %{"workspace" => "guide", "lang" => workspace.language}}

      assert ShareCards.target(%{workspace | status: :draft}) == nil
    end

    test "an approved page of an active document, under the document's slug", %{
      site: site,
      workspace: workspace,
      version: version
    } do
      section =
        create_section!(
          [site_id: site.id, workspace_version_id: version.id, slug: "start"] ++
            approved()
        )

      assert ShareCards.target(section) ==
               {:record, "docs:page",
                %{"workspace" => "guide", "section" => "start", "lang" => section.language}}

      assert ShareCards.target(%{section | content_review_status: :pending}) == nil

      workspace
      |> Ash.Changeset.for_update(:master_update, %{status: :draft}, authorize?: false)
      |> Ash.update!()

      assert ShareCards.target(section) == nil
    end
  end

  test "each plugin looks at its own record's card after it is saved, and only while it is shown",
       %{site: site, version: version} do
    register(WorkspaceShareCard)
    register(SectionShareCard)

    create_workspace!(site_id: site.id, status: :active, slug: "manual")
    create_workspace!(site_id: site.id, status: :draft, slug: "hidden")

    create_section!(
      [site_id: site.id, workspace_version_id: version.id, slug: "intro"] ++ approved()
    )

    create_section!(site_id: site.id, workspace_version_id: version.id, slug: "draft")

    targets = for %{"target" => target} <- looks(), do: target

    assert %{"record" => "docs:document", "params" => %{"workspace" => "manual"}} in Enum.map(
             targets,
             &Map.update!(&1, "params", fn params -> Map.take(params, ["workspace"]) end)
           )

    assert Enum.any?(
             targets,
             &match?(
               %{
                 "record" => "docs:page",
                 "params" => %{"workspace" => "guide", "section" => "intro"}
               },
               &1
             )
           )

    refute Enum.any?(targets, &match?(%{"params" => %{"workspace" => "hidden"}}, &1))
    refute Enum.any?(targets, &match?(%{"params" => %{"section" => "draft"}}, &1))
  end

  test "a document's and a page's edit modals have a Share image field, on an update" do
    for resource <- [Workspace, Section] do
      field = FormInfo.field(resource, :share_card)

      assert field, "#{inspect(resource)} has no Share image field"
      assert field.virtual
      assert field.show_on == :update
      assert field.ui.extra.share_card == (&ShareCards.target/1)
    end
  end
end
