defmodule MishkaDocument.Test.WorkspaceVersionCloneTest do
  @moduledoc """
  `MishkaDocument.WorkspaceVersion`'s `:clone` and `:master_clone` write a new draft version of the
  source's document with a copy of every page in the source's tree, each page's notes and tags, and
  a lineage row — in one transaction, as the actor, and only from the actor's own site.
  """
  use MishkaDocument.DataCase, async: false

  import MishkaDocument.Test.Factory

  alias MishkaDocument.{
    Note,
    NoteDraft,
    Section,
    SectionDraft,
    SectionTag,
    WorkspaceVersion,
    WorkspaceVersionLineage
  }

  alias MishkaDocument.Resources.Changes.CloneVersion
  alias MishkaDocument.Test.Plugins.VersionCloned
  alias MishkaInstaller.Event.{Event, EventHandler}

  require Ash.Query

  @document "admin:dashboard:document:*"

  setup do
    site = create_site!()
    workspace = create_workspace!(site_id: site.id, skip_version: true)

    source =
      create_workspace_version!(
        workspace_id: workspace.id,
        site_id: site.id,
        version_number: "0.0.9",
        status: :stable,
        published_at: DateTime.add(DateTime.utc_now(), -3600),
        is_latest_for_version: true
      )

    page = &create_section!([site_id: site.id, workspace_version_id: source.id] ++ &1)

    front =
      page.(
        title: "Introduction",
        slug: "introduction",
        front_page: true,
        order_position: 0,
        content_review_status: :approved,
        technical_review_status: :approved,
        permissions: ["document:read:members"],
        seo_tags: [%{tag: "meta", attrs: %{"name" => "robots"}, content: "index"}]
      )

    group = page.(title: "Components", slug: "components", group_heading: true, order_position: 1)

    button =
      page.(
        title: "Button",
        slug: "button",
        parent_section_id: group.id,
        order_position: 0,
        content: "<p>A button.</p>"
      )

    alert = page.(title: "Alert", slug: "alert", parent_section_id: group.id, order_position: 1)

    alert_icon =
      page.(
        title: "Alert icon",
        slug: "alert-icon",
        parent_section_id: alert.id,
        order_position: 0
      )

    button_fa =
      page.(
        title: "دکمه",
        slug: "button-fa",
        language: "fa",
        language_group_id: button.id,
        order_position: 2
      )

    notes = [
      create_note!(site_id: site.id, section_id: button.id, title: "First", order_position: 0),
      create_note!(site_id: site.id, section_id: button.id, title: "Second", order_position: 1),
      create_note!(site_id: site.id, section_id: alert_icon.id, title: "Deep", order_position: 0)
    ]

    tag = create_document_tag!(site_id: site.id)
    create_section_tag!(section_id: button.id, tag_id: tag.id)

    create_section_draft!(
      site_id: site.id,
      workspace_version_id: source.id,
      source_section_id: button.id
    )

    create_note_draft!(site_id: site.id, section_id: button.id, workspace_version_id: source.id)

    admin = create_user_with_permissions!([@document], site_id: site.id)

    {:ok,
     site: site,
     workspace: workspace,
     source: source,
     admin: admin,
     tag: tag,
     notes: notes,
     pages: %{
       front: front,
       group: group,
       button: button,
       alert: alert,
       alert_icon: alert_icon,
       button_fa: button_fa
     }}
  end

  defp clone(source, actor, params \\ %{}) do
    WorkspaceVersion
    |> Ash.Changeset.for_create(
      :clone,
      Map.merge(%{source_version_id: source.id, version_number: "0.0.10"}, params),
      actor: actor,
      tenant: actor.site_id
    )
    |> Ash.create()
  end

  defp pages_of(version, site) do
    Section
    |> Ash.Query.filter(workspace_version_id == ^version.id)
    |> Ash.read!(tenant: site.id, authorize?: false)
  end

  defp copy_of(pages, source_page),
    do: Enum.find(pages, &(&1.source_section_id == source_page.id))

  defp count(resource, site), do: Ash.count!(resource, tenant: site.id, authorize?: false)

  defp reload(version),
    do: Ash.get!(WorkspaceVersion, version.id, tenant: version.site_id, authorize?: false)

  describe ":clone" do
    test "writes a draft version of the source's document, not the latest, naming the source", %{
      source: source,
      admin: admin,
      workspace: workspace
    } do
      assert {:ok, version} =
               clone(source, admin, %{version_name: "Next", description: "What comes next"})

      assert version.workspace_id == workspace.id
      assert version.site_id == source.site_id
      assert version.source_version_id == source.id
      assert version.version_number == "0.0.10"
      assert version.version_name == "Next"
      assert version.description == "What comes next"
      assert version.status == :draft
      assert version.is_latest_for_version == false
      assert version.published_at == nil
      assert version.__metadata__.cloned == %{pages: 6, notes: 3, tags: 1, from: "0.0.9"}

      assert %{is_latest_for_version: true} =
               Ash.get!(WorkspaceVersion, source.id, tenant: source.site_id, authorize?: false)
    end

    test "copies the tree: each parent is the copy of the source's parent, in the same order", %{
      source: source,
      admin: admin,
      site: site,
      pages: pages
    } do
      {:ok, version} = clone(source, admin)
      copies = pages_of(version, site)

      assert length(copies) == 6

      for {_name, page} <- pages do
        copy = copy_of(copies, page)

        assert copy, "#{page.title} was not copied"
        assert copy.id != page.id
        assert copy.title == page.title
        assert copy.slug == page.slug
        assert copy.content == page.content
        assert copy.order_position == page.order_position
        assert copy.language == page.language
        assert copy.change_version == page.change_version
        assert copy.content_review_status == page.content_review_status
        assert copy.technical_review_status == page.technical_review_status
        assert copy.section_lineage_id == page.section_lineage_id

        expected_parent =
          case page.parent_section_id do
            nil -> nil
            parent_id -> copy_of(copies, %{id: parent_id}).id
          end

        assert copy.parent_section_id == expected_parent
      end
    end

    test "keeps the front page and the group flags, the permissions and the SEO tags", %{
      source: source,
      admin: admin,
      site: site,
      pages: pages
    } do
      {:ok, version} = clone(source, admin)
      copies = pages_of(version, site)

      front = copy_of(copies, pages.front)
      assert front.front_page
      assert front.permissions == ["document:read:members"]
      assert [%{tag: "meta", content: "index"}] = front.seo_tags
      assert copy_of(copies, pages.group).group_heading
      refute copy_of(copies, pages.button).front_page
    end

    test "a translation is grouped with the copy of its original", %{
      source: source,
      admin: admin,
      site: site,
      pages: pages
    } do
      {:ok, version} = clone(source, admin)
      copies = pages_of(version, site)

      button = copy_of(copies, pages.button)
      button_fa = copy_of(copies, pages.button_fa)

      assert button.language_group_id == button.id
      assert button_fa.language_group_id == button.id
      assert copy_of(copies, pages.alert).language_group_id == copy_of(copies, pages.alert).id
    end

    test "copies every note to the copy of its page, and the tags", %{
      source: source,
      admin: admin,
      site: site,
      pages: pages,
      notes: notes,
      tag: tag
    } do
      {:ok, version} = clone(source, admin)
      copies = pages_of(version, site)
      ids = Enum.map(copies, & &1.id)

      copied_notes =
        Note
        |> Ash.Query.filter(section_id in ^ids)
        |> Ash.Query.sort(title: :asc)
        |> Ash.read!(tenant: site.id, authorize?: false)

      assert Enum.map(copied_notes, &{&1.title, &1.order_position, &1.content}) ==
               notes
               |> Enum.sort_by(& &1.title)
               |> Enum.map(&{&1.title, &1.order_position, &1.content})

      button = copy_of(copies, pages.button)
      deep = copy_of(copies, pages.alert_icon)

      assert copied_notes |> Enum.filter(&(&1.section_id == button.id)) |> length() == 2
      assert [%{title: "Deep"}] = Enum.filter(copied_notes, &(&1.section_id == deep.id))

      assert [%{tag_id: tag_id}] =
               SectionTag
               |> Ash.Query.filter(section_id == ^button.id)
               |> Ash.read!(authorize?: false)

      assert tag_id == tag.id
    end

    # A PAGE STORES `{{doc.version}}` AS IT WAS WRITTEN, and the kit fills it with the version read,
    # so the copy draws its own number with nothing rewritten.
    test "copies a page's and a note's {{doc.version}} as it was written", %{
      source: source,
      admin: admin,
      site: site
    } do
      content =
        ~S(<p>Install {{doc.version}}, {{ doc.version }} and \{{doc.version}}.</p>) <>
          ~S(<pre><code>{:lib, "~&gt; {{doc.version}}"}</code></pre>)

      page =
        create_section!(
          site_id: site.id,
          workspace_version_id: source.id,
          title: "Install",
          slug: "install",
          order_position: 5,
          content: content
        )

      note =
        create_note!(
          site_id: site.id,
          section_id: page.id,
          title: "Release",
          content: "<p>Notes of {{doc.version}}.</p>"
        )

      {:ok, version} = clone(source, admin)
      copy = version |> pages_of(site) |> copy_of(page)

      assert copy.content == page.content
      assert copy.content =~ "{{doc.version}}"

      assert [copied_note] =
               Note
               |> Ash.Query.filter(section_id == ^copy.id)
               |> Ash.read!(tenant: site.id, authorize?: false)

      assert copied_note.content == note.content
      assert copied_note.content =~ "{{doc.version}}"
    end

    test "writes the lineage row, source to new", %{source: source, admin: admin, site: site} do
      before = DateTime.utc_now() |> DateTime.add(-1)
      {:ok, version} = clone(source, admin)

      assert [lineage] =
               WorkspaceVersionLineage
               |> Ash.Query.filter(new_version_id == ^version.id)
               |> Ash.read!(tenant: site.id, authorize?: false)

      assert lineage.source_version_id == source.id
      assert DateTime.compare(lineage.cloned_at, before) != :lt
    end

    test "copies no draft of a page or a note", %{source: source, admin: admin, site: site} do
      drafts = count(SectionDraft, site)
      note_drafts = count(NoteDraft, site)

      {:ok, version} = clone(source, admin)

      assert count(SectionDraft, site) == drafts
      assert count(NoteDraft, site) == note_drafts

      refute SectionDraft
             |> Ash.Query.filter(workspace_version_id == ^version.id)
             |> Ash.exists?(tenant: site.id, authorize?: false)
    end

    test "a page under an archived page is not copied", %{
      source: source,
      admin: admin,
      site: site,
      pages: pages
    } do
      Ash.destroy!(pages.alert, action: :destroy, tenant: site.id, authorize?: false)

      {:ok, version} = clone(source, admin)
      copies = pages_of(version, site)

      assert length(copies) == 4
      refute copy_of(copies, pages.alert)
      refute copy_of(copies, pages.alert_icon)
      assert version.__metadata__.cloned == %{pages: 4, notes: 2, tags: 1, from: "0.0.9"}
    end

    test "a version number the document already has is refused, and nothing is written", %{
      source: source,
      admin: admin,
      site: site
    } do
      counts =
        for resource <- [WorkspaceVersion, Section, Note, WorkspaceVersionLineage, SectionTag],
            do: {resource, count(resource, site)}

      assert {:error, %Ash.Error.Invalid{} = error} =
               clone(source, admin, %{version_number: "0.0.9"})

      assert Enum.any?(error.errors, &(Map.get(&1, :field) == :version_number))

      for {resource, before} <- counts do
        assert count(resource, site) == before, "#{inspect(resource)} was written"
      end
    end

    test "a page that cannot be copied rolls the whole copy back", %{
      source: source,
      admin: admin,
      site: site
    } do
      # Read at /alert like the Alert filed under the group Components, which the page's own
      # validation refuses to write; seeded past it, as a row written before that rule was.
      Ash.Seed.seed!(
        Section,
        %{
          site_id: site.id,
          workspace_version_id: source.id,
          title: "Alert again",
          slug: "alert",
          language: "en",
          order_position: 3
        },
        tenant: site.id
      )

      counts =
        for resource <- [WorkspaceVersion, Section, Note, WorkspaceVersionLineage, SectionTag],
            do: {resource, count(resource, site)}

      assert {:error, %Ash.Error.Invalid{}} = clone(source, admin)

      for {resource, before} <- counts do
        assert count(resource, site) == before, "#{inspect(resource)} was written"
      end
    end

    test "is refused to an admin who may not write pages, and nothing is written", %{
      source: source,
      site: site
    } do
      versions = count(WorkspaceVersion, site)

      workspace_admin =
        create_user_with_permissions!(["admin:dashboard:document:workspace"], site_id: site.id)

      assert {:error, %Ash.Error.Forbidden{}} = clone(source, workspace_admin)
      assert count(WorkspaceVersion, site) == versions
      refute WorkspaceVersion.clone_allowed?(workspace_admin)
    end

    test "an archived tag stays on the source", %{
      source: source,
      admin: admin,
      site: site,
      tag: tag
    } do
      Ash.destroy!(tag, action: :destroy, tenant: site.id, authorize?: false)

      assert {:ok, version} = clone(source, admin)
      assert version.__metadata__.cloned.tags == 0
    end

    test "another site's version is refused", %{source: source} do
      other = create_site!()
      stranger = create_user_with_permissions!([@document], site_id: other.id)

      assert {:error, _refused} = clone(source, stranger)

      refute WorkspaceVersion
             |> Ash.Query.filter(source_version_id == ^source.id)
             |> Ash.exists?(authorize?: false, tenant: source.site_id)
    end

    test "fires document:version:cloned with the ids and counts once it is committed", %{
      source: source,
      admin: admin
    } do
      Process.register(self(), :__version_cloned_probe__)

      {:ok, _} =
        Event.write(%{
          name: VersionCloned,
          event: CloneVersion.event(),
          extension: :mishka_installer,
          status: :started
        })

      :ok = EventHandler.do_compile(CloneVersion.event(), :start, false)
      on_exit(fn -> Event.unregister(:name, VersionCloned, false) end)

      {:ok, version} = clone(source, admin)

      assert_receive {:version_cloned, payload, meta}, 5000
      assert payload.version_id == version.id
      assert payload.source_version_id == source.id
      assert payload.workspace_id == source.workspace_id
      assert payload.site_id == source.site_id
      assert %{pages: 6, notes: 3, tags: 1} = payload
      assert meta.actor.id == admin.id
    end
  end

  describe ":master_clone" do
    test "copies a version of the site the source is on", %{source: source, site: site} do
      master = create_user_with_permissions!(["admin:dashboard:*"])

      assert {:ok, version} =
               WorkspaceVersion
               |> Ash.Changeset.for_create(
                 :master_clone,
                 %{source_version_id: source.id, version_number: "1.0.0"},
                 actor: master
               )
               |> Ash.create()

      assert version.site_id == site.id
      assert version.workspace_id == source.workspace_id
      assert length(pages_of(version, site)) == 6
    end

    test "is refused to a site user", %{source: source, admin: admin} do
      assert {:error, _refused} =
               WorkspaceVersion
               |> Ash.Changeset.for_create(
                 :master_clone,
                 %{source_version_id: source.id, version_number: "1.0.0"},
                 actor: admin
               )
               |> Ash.create()
    end
  end

  describe ":create with a source" do
    defp create(actor, params) do
      WorkspaceVersion
      |> Ash.Changeset.for_create(:create, params, actor: actor, tenant: actor.site_id)
      |> Ash.create()
    end

    test "copies everything the clone does, keeping the status, latest and publishing given", %{
      source: source,
      admin: admin,
      site: site,
      workspace: workspace,
      pages: pages
    } do
      published_at = DateTime.utc_now() |> DateTime.add(-60) |> DateTime.truncate(:second)

      assert {:ok, version} =
               create(admin, %{
                 workspace_id: workspace.id,
                 version_number: "1.0.0",
                 status: :stable,
                 is_latest_for_version: true,
                 published_at: published_at,
                 source_version_id: source.id
               })

      assert version.status == :stable
      assert version.is_latest_for_version
      assert version.published_at == published_at
      assert version.source_version_id == source.id
      assert version.__metadata__.cloned == %{pages: 6, notes: 3, tags: 1, from: "0.0.9"}

      copies = pages_of(version, site)
      assert length(copies) == 6

      assert copy_of(copies, pages.alert_icon).parent_section_id ==
               copy_of(copies, pages.alert).id

      assert WorkspaceVersionLineage
             |> Ash.Query.filter(
               new_version_id == ^version.id and source_version_id == ^source.id
             )
             |> Ash.exists?(tenant: site.id, authorize?: false)

      refute Ash.get!(WorkspaceVersion, source.id, tenant: site.id, authorize?: false).is_latest_for_version
    end

    test "with no source writes an empty version and no lineage, as before", %{
      admin: admin,
      site: site,
      workspace: workspace
    } do
      lineages = count(WorkspaceVersionLineage, site)

      assert {:ok, version} =
               create(admin, %{
                 workspace_id: workspace.id,
                 version_number: "1.0.0",
                 status: :draft
               })

      assert pages_of(version, site) == []
      refute Map.has_key?(version.__metadata__, :cloned)
      assert count(WorkspaceVersionLineage, site) == lineages
    end

    test "copy_pages: false only names the source", %{
      source: source,
      admin: admin,
      site: site,
      workspace: workspace
    } do
      assert {:ok, version} =
               create(admin, %{
                 workspace_id: workspace.id,
                 version_number: "1.0.0",
                 status: :draft,
                 source_version_id: source.id,
                 copy_pages: false
               })

      assert version.source_version_id == source.id
      assert pages_of(version, site) == []
    end

    test "a source of another document is refused, and nothing is written", %{
      source: source,
      admin: admin,
      site: site
    } do
      other = create_workspace!(site_id: site.id, skip_version: true)
      versions = count(WorkspaceVersion, site)

      assert {:error, %Ash.Error.Invalid{} = error} =
               create(admin, %{
                 workspace_id: other.id,
                 version_number: "1.0.0",
                 status: :draft,
                 source_version_id: source.id
               })

      assert Enum.any?(error.errors, &(Map.get(&1, :field) == :source_version_id))
      assert count(WorkspaceVersion, site) == versions
    end

    test ":master_create copies too", %{source: source, site: site, workspace: workspace} do
      master = create_user_with_permissions!(["admin:dashboard:*"])

      assert {:ok, version} =
               WorkspaceVersion
               |> Ash.Changeset.for_create(
                 :master_create,
                 %{
                   workspace_id: workspace.id,
                   site_id: site.id,
                   version_number: "1.0.0",
                   status: :draft,
                   source_version_id: source.id
                 },
                 actor: master
               )
               |> Ash.create()

      assert length(pages_of(version, site)) == 6
    end
  end

  describe "a version's source after it is created" do
    test "no update takes a new one", %{source: source, admin: admin, site: site} do
      {:ok, version} = clone(source, admin)
      other = create_workspace_version!(workspace_id: source.workspace_id, site_id: site.id)
      master = create_user_with_permissions!(["admin:dashboard:*"])

      assert {:error, %Ash.Error.Invalid{}} =
               version
               |> Ash.Changeset.for_update(:update, %{source_version_id: other.id},
                 actor: admin,
                 tenant: site.id
               )
               |> Ash.update()

      assert {:error, %Ash.Error.Invalid{}} =
               version
               |> Ash.Changeset.for_update(:master_update, %{source_version_id: other.id},
                 actor: master
               )
               |> Ash.update()

      assert Ash.get!(WorkspaceVersion, version.id, tenant: site.id, authorize?: false).source_version_id ==
               source.id
    end
  end

  describe "deleting a version" do
    defp make_latest(workspace, site) do
      create_workspace_version!(
        workspace_id: workspace.id,
        site_id: site.id,
        version_number: "9.9.9",
        is_latest_for_version: true
      )
    end

    defp destroy(version, actor) do
      version
      |> reload()
      |> Ash.Changeset.for_destroy(:destroy, %{}, actor: actor, tenant: version.site_id)
      |> Ash.destroy()
    end

    defp gone?(version),
      do:
        match?(
          {:error, _},
          Ash.get(WorkspaceVersion, version.id, tenant: version.site_id, authorize?: false)
        )

    defp sections_of(version, site),
      do:
        Section
        |> Ash.Query.filter(workspace_version_id == ^version.id)
        |> Ash.count!(tenant: site.id, authorize?: false)

    test "deletes its own pages and notes, and leaves its source", %{
      source: source,
      admin: admin,
      site: site,
      workspace: workspace
    } do
      make_latest(workspace, site)
      {:ok, copy} = clone(source, admin)
      notes = count(Note, site)

      assert :ok = destroy(copy, admin)

      assert gone?(copy)
      assert sections_of(copy, site) == 0
      assert count(Note, site) == notes - 3
      refute gone?(source)
      assert sections_of(source, site) == 6
    end

    test "deletes every version cloned from it, however deep, with their pages and notes", %{
      source: source,
      admin: admin,
      site: site,
      workspace: workspace
    } do
      latest = make_latest(workspace, site)
      {:ok, child} = clone(source, admin)
      {:ok, grandchild} = clone(child, admin, %{version_number: "1.0.0"})

      assert Ash.load!(source, :clone_numbers, actor: admin, tenant: site.id).clone_numbers ==
               ["0.0.10", "1.0.0"]

      assert :ok = destroy(source, admin)

      assert gone?(source) and gone?(child) and gone?(grandchild)
      refute gone?(latest)
      assert count(Section, site) == 0
      assert count(Note, site) == 0
      assert count(WorkspaceVersionLineage, site) == 0
    end

    test "is refused, with nothing deleted, when a version cloned from it is the latest", %{
      source: source,
      admin: admin,
      site: site,
      workspace: workspace
    } do
      make_latest(workspace, site)
      {:ok, child} = clone(source, admin)
      {:ok, grandchild} = clone(child, admin, %{version_number: "1.0.0"})

      grandchild
      |> Ash.Changeset.for_update(:mark_as_latest, %{}, actor: admin, tenant: site.id)
      |> Ash.update!()

      pages = count(Section, site)

      assert {:error, %Ash.Error.Invalid{} = error} = destroy(source, admin)
      assert Exception.message(error) =~ "1.0.0, cloned from this version, is the latest"

      refute gone?(source) or gone?(child) or gone?(grandchild)
      assert count(Section, site) == pages
    end
  end

  describe ":detach" do
    defp detach(version, actor, action \\ :detach, tenant \\ :own) do
      tenant = if tenant == :own, do: version.site_id, else: tenant

      version
      |> Ash.Changeset.for_update(action, %{}, actor: actor, tenant: tenant)
      |> Ash.update()
    end

    test "unties the version and its pages; deleting the old source then leaves them", %{
      source: source,
      admin: admin,
      site: site,
      workspace: workspace
    } do
      create_workspace_version!(
        workspace_id: workspace.id,
        site_id: site.id,
        version_number: "9.9.9",
        is_latest_for_version: true
      )

      {:ok, copy} = clone(source, admin)
      before = pages_of(copy, site)
      archived = Enum.find(before, &(&1.slug == "button-fa"))
      Ash.destroy!(archived, action: :destroy, tenant: site.id, authorize?: false)

      Process.register(self(), :__version_cloned_probe__)

      {:ok, _} =
        Event.write(%{
          name: VersionCloned,
          event: MishkaDocument.Resources.Changes.DetachVersion.event(),
          extension: :mishka_installer,
          status: :started
        })

      :ok =
        EventHandler.do_compile(
          MishkaDocument.Resources.Changes.DetachVersion.event(),
          :start,
          false
        )

      on_exit(fn -> Event.unregister(:name, VersionCloned, false) end)

      assert {:ok, detached} = detach(copy, admin)
      assert detached.source_version_id == nil

      assert_receive {:version_cloned, %{version_id: id, source_version_id: from, pages: 6}, _},
                     5000

      assert id == copy.id and from == source.id

      after_detach = pages_of(copy, site)
      assert Enum.all?(after_detach, &is_nil(&1.source_section_id))

      assert Enum.sort(Enum.map(after_detach, & &1.section_lineage_id)) ==
               before
               |> Enum.reject(&(&1.id == archived.id))
               |> Enum.map(& &1.section_lineage_id)
               |> Enum.sort()

      refute WorkspaceVersionLineage
             |> Ash.Query.filter(new_version_id == ^copy.id)
             |> Ash.exists?(tenant: site.id, authorize?: false)

      notes = count(Note, site)

      assert :ok =
               source
               |> reload()
               |> Ash.Changeset.for_destroy(:destroy, %{}, actor: admin, tenant: site.id)
               |> Ash.destroy()

      assert %{source_version_id: nil} =
               Ash.get!(WorkspaceVersion, copy.id, tenant: site.id, authorize?: false)

      assert length(pages_of(copy, site)) == 5
      assert count(Note, site) == notes - 3

      assert {:ok, %{source_section_id: nil}} =
               Ash.get(Section, archived.id,
                 action: :get_archived,
                 tenant: site.id,
                 authorize?: false
               )
    end

    test "a master detaches a version of any site", %{source: source, admin: admin, site: site} do
      {:ok, copy} = clone(source, admin)
      master = create_user_with_permissions!(["admin:dashboard:*"])

      assert {:ok, %{source_version_id: nil}} = detach(copy, master, :master_detach, nil)
      assert Enum.all?(pages_of(copy, site), &is_nil(&1.source_section_id))
    end

    test "is refused for a version with no source, and to an admin who may not write pages", %{
      source: source,
      admin: admin,
      site: site
    } do
      assert {:error, %Ash.Error.Invalid{}} = detach(source, admin)

      {:ok, copy} = clone(source, admin)

      workspace_admin =
        create_user_with_permissions!(["admin:dashboard:document:workspace"], site_id: site.id)

      assert {:error, %Ash.Error.Forbidden{}} = detach(copy, workspace_admin)

      assert %{source_version_id: source_id} =
               Ash.get!(WorkspaceVersion, copy.id, tenant: site.id, authorize?: false)

      assert source_id == source.id
    end
  end
end
