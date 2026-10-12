defmodule MishkaDocumentWeb.Test.DocumentFormsTest do
  @moduledoc """
  The document dashboard's forms, opened the way an admin opens them: the page's add button or a
  record's Edit, and for a note or a comment the page that owns it.

  A record stays on the site it was created on, so a master's edit form draws no Site picker, while
  the create form still asks for one. The pickers that list a site's records keep working on edit:
  they read the site from the record. An issue keeps who reported it: the edit form shows the
  reporter and does not let it change.

  A note added from a section's page and a comment added under an issue belong to that page's site:
  the Site picker shows it and cannot be changed, and a pick pushed for it anyway is not saved. A
  comment a master saves is listed under its issue with who wrote it.

  A section added from a workspace version's page goes into that version: the form shows the page's
  workspace and version, and a master its site, fixed while adding, also after a section was edited
  there. A pick pushed for any of them anyway changes none of them. Editing a section can still move
  it to another workspace and version. A version added from
  a workspace's versions page goes into that workspace, also after a version was edited there.

  The pickers that name a section, a section draft or a note list the records of the version picked:
  a section's parent, a draft's parent and source, a note draft's section, section draft and note. A
  section's source is listed from the workspace's other versions. A record of another version pushed
  anyway is refused, and the form says why on the field. Each of them that the record can do without
  offers an empty choice, so a section with a parent can move to another version as a top-level one.

  Who wrote a draft is picked when it is added; the edit form shows it and does not let it change.

  A note's Site and Section are drawn together, at the top of the form.

  A version's Published At is the form's calendar: it opens on the stored month, steps by month and
  year, and saves the day and the time picked.

  A title is one line, and every textarea besides the content editor is the Tailwind adapter's
  full-width field, also on the forms `MishkaCmsCoreWeb.UIAdapters.Admin` draws. While a workspace, a
  tag, a section or a section draft is added, typing its name or title fills the slug the save
  stores, until the author types one; editing a record's name or title never moves its slug.
  """
  use MishkaDocument.ConnCase

  import Phoenix.LiveViewTest
  import MishkaDocument.Test.Factory

  alias MishkaCmsCore.Accounts.{Permission, User, UserPermission}
  alias MishkaCmsCore.Runtime.States.SiteState

  alias MishkaDocument.{
    Issue,
    IssueComment,
    Note,
    NoteDraft,
    Section,
    SectionDraft,
    Tag,
    Workspace,
    WorkspaceVersion
  }

  alias MishkaDocument.Resources.Validations.SameWorkspaceVersion
  alias MishkaGervaz.Form.Web.State
  alias MishkaGervaz.Resource.Info.Form, as: FormInfo

  require Ash.Query

  @password "Password123!"
  @await 5_000
  @dashboard "/admin/dashboard/document"

  setup %{conn: conn} do
    SiteState.clear()
    :ok = Swoosh.TestAssertions.set_swoosh_global()

    site = create_site!(name: "localhost", host: "localhost", active: true, master: true)

    SiteState.save(%{
      id: site.id,
      name: site.name,
      host: site.host,
      priority: site.priority,
      active: site.active,
      master: site.master
    })

    :persistent_term.put(:mishka_installed, true)

    on_exit(fn ->
      :persistent_term.erase(:mishka_installed)
      SiteState.clear()
    end)

    :ok = MishkaCmsCore.Install.Extensions.mark_installed!(site.id, :mishka_document, "test")

    master = admin!("master@example.com")
    site_admin = admin!("site-admin@example.com", site.id)
    workspace = create_workspace!(site_id: site.id, skip_version: true, name: "Handbook")
    version = create_workspace_version!(workspace_id: workspace.id, site_id: site.id)
    section = create_section!(site_id: site.id, workspace_version_id: version.id)

    {:ok,
     master_conn: log_in(on_host(conn), master),
     site_admin_conn: log_in(on_host(Phoenix.ConnTest.build_conn()), site_admin),
     master: master,
     site_admin: site_admin,
     site: site,
     workspace: workspace,
     version: version,
     section: section}
  end

  describe "a master editing a record" do
    test "is offered no site to move a workspace, a tag or a draft to", ctx do
      pages = [
        {Workspace, @dashboard, ctx.workspace, :language_group_id},
        {Tag, "#{@dashboard}/tags", create_document_tag!(site_id: ctx.site.id),
         :language_group_id},
        {SectionDraft, "#{@dashboard}/section-drafts",
         create_section_draft!(site_id: ctx.site.id, workspace_version_id: ctx.version.id),
         :workspace},
        {NoteDraft, "#{@dashboard}/note-drafts",
         create_note_draft!(
           site_id: ctx.site.id,
           section_id: ctx.section.id,
           workspace_version_id: ctx.version.id
         ), :workspace}
      ]

      for {resource, path, record, site_picker_child} <- pages do
        form = FormInfo.component_id(resource)
        view = open(ctx.master_conn, path)

        assert has_element?(view, picker(form, :site_id)),
               "#{inspect(resource)}'s create form lost its Site picker"

        edit(view, record)

        assert has_element?(view, "##{form}-form[method=put]")

        refute has_element?(view, picker(form, :site_id)),
               "#{inspect(resource)}'s edit form offers a Site"

        assert has_element?(view, picker(form, site_picker_child)),
               "#{inspect(resource)}'s #{site_picker_child} waits for a Site on edit"
      end
    end

    test "still gets the record's own site's records in a picker that follows the site", ctx do
      tag = create_document_tag!(site_id: ctx.site.id, name: "Edited")
      same_site = create_document_tag!(site_id: ctx.site.id, name: "Same Site")
      other_site = create_document_tag!(name: "Other Site")
      form = FormInfo.component_id(Tag)

      view = ctx.master_conn |> open("#{@dashboard}/tags") |> edit(tag)

      view
      |> element("#{picker(form, :language_group_id)} input[name=_search_language_group_id]")
      |> render_focus()

      render_async(view, @await)

      assert has_element?(view, option(form, :language_group_id, same_site.id))
      refute has_element?(view, option(form, :language_group_id, other_site.id))
    end

    test "is offered no site to move a section to", ctx do
      form = FormInfo.component_id(Section)
      view = open(ctx.master_conn, "#{@dashboard}/sections/#{ctx.version.id}")

      assert has_element?(view, picker(form, :site_id))

      edit(view, ctx.section)

      assert has_element?(view, "##{form}-form[method=put]")
      refute has_element?(view, picker(form, :site_id))
      assert has_element?(view, picker(form, :workspace))
      assert has_element?(view, picker(form, :language_group_id))
    end

    test "is offered no site to move a note to", ctx do
      note = create_note!(site_id: ctx.site.id, section_id: ctx.section.id)
      form = FormInfo.component_id(Note)
      view = open(ctx.master_conn, "#{@dashboard}/sections/#{ctx.version.id}")

      add_note(view, ctx.section)
      assert has_element?(view, picker(form, :site_id))

      render_hook(view, "cancel_note_form", %{})

      view
      |> element(~s(button[phx-click="expand_row"][phx-value-id="#{ctx.section.id}"]))
      |> render_click()

      render_async(view, @await)

      view
      |> element(~s(button[phx-click="edit_note"][phx-value-id="#{note.id}"]))
      |> render_click()

      render_async(view, @await)

      assert has_element?(view, "##{form}-form[method=put]")
      refute has_element?(view, picker(form, :site_id))
      assert has_element?(view, picker(form, :section_id))
    end

    test "is offered no site to move an issue comment to", ctx do
      issue = create_issue!(site_id: ctx.site.id, section_id: ctx.section.id)

      comment =
        create_issue_comment!(
          site_id: ctx.site.id,
          issue_id: issue.id,
          contributor_id: ctx.site_admin.id
        )

      form = FormInfo.component_id(IssueComment)
      view = open_comments(ctx.master_conn, issue)

      view
      |> element(~s(button[phx-click="add_comment"][phx-value-issue-id="#{issue.id}"]))
      |> render_click()

      render_async(view, @await)
      assert has_element?(view, picker(form, :site_id))

      render_hook(view, "cancel_comment_form", %{})
      view |> element("#edit-comment-#{comment.id}") |> render_click()
      render_async(view, @await)

      assert has_element?(view, "##{form}-form[method=put]")
      refute has_element?(view, picker(form, :site_id))
    end
  end

  describe "a note or a comment a master adds from the page it belongs to" do
    test "stays on the site of the section it was added from", ctx do
      other_site = create_site!()
      form = FormInfo.component_id(Note)
      view = open(ctx.master_conn, "#{@dashboard}/sections/#{ctx.version.id}")

      add_note(view, ctx.section)

      assert has_element?(view, "#{picker(form, :site_id)} input[name=_search_site_id][disabled]")
      assert has_element?(view, hidden(form, :site_id, ctx.site.id))

      view
      |> with_target("##{form}-form-wrapper")
      |> render_hook("relation_select", %{
        "filter" => "site_id",
        "id" => other_site.id,
        "label" => other_site.name
      })

      view
      |> form("##{form}-form", form: %{title: "Added here", content: "Body"})
      |> render_submit()

      assert [%{section_id: section_id}] =
               Note
               |> Ash.Query.filter(title == "Added here")
               |> Ash.read!(tenant: ctx.site.id, authorize?: false)

      assert section_id == ctx.section.id
    end

    test "shows the issue's site on a comment and does not let it change", ctx do
      issue = create_issue!(site_id: ctx.site.id, section_id: ctx.section.id)
      form = FormInfo.component_id(IssueComment)
      view = open_comments(ctx.master_conn, issue)

      view
      |> element(~s(button[phx-click="add_comment"][phx-value-issue-id="#{issue.id}"]))
      |> render_click()

      render_async(view, @await)

      assert has_element?(view, "#{picker(form, :site_id)} input[name=_search_site_id][disabled]")
      assert has_element?(view, hidden(form, :site_id, ctx.site.id))
    end

    test "shows a comment once it is saved, under the issue, with who wrote it", ctx do
      issue = create_issue!(site_id: ctx.site.id, section_id: ctx.section.id)
      form = FormInfo.component_id(IssueComment)
      view = open_comments(ctx.master_conn, issue)

      view
      |> element(~s(button[phx-click="add_comment"][phx-value-issue-id="#{issue.id}"]))
      |> render_click()

      render_async(view, @await)

      view
      |> pick(form, :contributor_id, ctx.site_admin.id)
      |> form("##{form}-form", form: %{content: "Added by a master"})
      |> render_submit()

      assert [comment] =
               IssueComment
               |> Ash.Query.filter(issue_id == ^issue.id)
               |> Ash.read!(tenant: ctx.site.id, authorize?: false)

      # The page hands the broadcast comment to the list with a send_update, a message of its own.
      render(view)

      assert has_element?(view, "#edit-comment-#{comment.id}")
      assert has_element?(view, "#comments-stream-#{issue.id}", to_string(ctx.site_admin.email))
    end
  end

  describe "a section added from a workspace version's page" do
    test "shows the page's workspace and version to a site admin and a master", ctx do
      form = FormInfo.component_id(Section)

      for conn <- [ctx.site_admin_conn, ctx.master_conn] do
        view = open(conn, "#{@dashboard}/sections/#{ctx.version.id}")

        for {field, value} <- [workspace: ctx.workspace.id, workspace_version_id: ctx.version.id] do
          assert has_element?(view, hidden(form, field, value))

          assert has_element?(
                   view,
                   "#{picker(form, field)} input[name=_search_#{field}][disabled]"
                 )
        end
      end
    end

    test "shows a master the page's site, and a master's section is saved there", ctx do
      form = FormInfo.component_id(Section)
      view = open(ctx.master_conn, "#{@dashboard}/sections/#{ctx.version.id}")

      assert has_element?(view, hidden(form, :site_id, ctx.site.id))
      assert has_element?(view, "#{picker(form, :site_id)} input[name=_search_site_id][disabled]")

      assert saved_version(view, ctx, "added-by-master") == ctx.version.id
    end

    test "keeps the page's site, workspace and version when a master pushes others", ctx do
      form = FormInfo.component_id(Section)
      other_site = create_site!()
      other = create_workspace!(site_id: ctx.site.id, skip_version: true, name: "Other")
      other_version = create_workspace_version!(workspace_id: other.id, site_id: ctx.site.id)
      view = open(ctx.master_conn, "#{@dashboard}/sections/#{ctx.version.id}")

      for {field, record} <- [
            site_id: other_site,
            workspace: other,
            workspace_version_id: other_version
          ] do
        view
        |> with_target("##{form}-form-wrapper")
        |> render_hook("relation_select", %{
          "filter" => to_string(field),
          "id" => record.id,
          "label" => "Other"
        })
      end

      for {field, value} <- [
            site_id: ctx.site.id,
            workspace: ctx.workspace.id,
            workspace_version_id: ctx.version.id
          ] do
        assert has_element?(view, hidden(form, field, value)), "a pushed pick moved #{field}"
      end

      assert saved_version(view, ctx, "pushed-elsewhere") == ctx.version.id
    end

    test "is saved into the page's version", ctx do
      view = open(ctx.site_admin_conn, "#{@dashboard}/sections/#{ctx.version.id}")

      assert saved_version(view, ctx, "added-here") == ctx.version.id
    end

    test "still goes into the page's version after a site admin cancels or saves an edit", ctx do
      for leave <- [:cancel, :save] do
        view = open(ctx.site_admin_conn, "#{@dashboard}/sections/#{ctx.version.id}")

        assert_adds_into_page_version(view, ctx, leave)
      end
    end

    test "still goes into the page's site and version after a master saves an edit", ctx do
      form = FormInfo.component_id(Section)
      view = open(ctx.master_conn, "#{@dashboard}/sections/#{ctx.version.id}")

      assert_adds_into_page_version(view, ctx, :save)

      assert has_element?(view, hidden(form, :site_id, ctx.site.id))
      assert has_element?(view, "#{picker(form, :site_id)} input[name=_search_site_id][disabled]")
    end

    test "keeps the workspace and version the page gives fixed only while adding" do
      for field <- [:workspace, :workspace_version_id] do
        readonly = FormInfo.field(Section, field).readonly
        given = %{defaults: %{field => Ash.UUID.generate()}}

        assert readonly.(Map.put(given, :mode, :create))
        refute readonly.(Map.put(given, :mode, :update))
      end
    end

    test "a field the page's defaults lock is locked only while adding, on every document form",
         ctx do
      locks =
        for resource <- Ash.Domain.Info.resources(MishkaDocument),
            field <- FormInfo.fields(resource),
            is_function(field.readonly, 1),
            Map.get(field, :show_on) != :create,
            do: {resource, field}

      assert locks != []

      for {resource, field} <- locks do
        editing =
          resource
          |> FormInfo.component_id()
          |> State.init(resource, ctx.master)
          |> State.update(mode: :update)

        given = State.update(editing, defaults: %{field.name => Ash.UUID.generate()})

        assert field.readonly.(given) == field.readonly.(editing),
               "#{inspect(resource)}'s #{field.name} is locked on edit by the page's defaults"
      end
    end

    test "can still be moved to another workspace and version on edit", ctx do
      form = FormInfo.component_id(Section)

      view =
        ctx.site_admin_conn
        |> open("#{@dashboard}/sections/#{ctx.version.id}")
        |> edit(ctx.section)

      assert has_element?(view, "##{form}-form[method=put]")

      for field <- [:workspace, :workspace_version_id] do
        assert has_element?(view, "#{picker(form, field)} input[name=_search_#{field}]")
        refute has_element?(view, "#{picker(form, field)} input[name=_search_#{field}][disabled]")
      end
    end
  end

  describe "a version added from a workspace's versions page" do
    test "still goes into the page's workspace after a version is edited, cancelled or saved",
         ctx do
      form = FormInfo.component_id(WorkspaceVersion)

      for {conn, leave} <- [
            {ctx.site_admin_conn, :cancel},
            {ctx.site_admin_conn, :save},
            {ctx.master_conn, :save}
          ] do
        view = open(conn, "#{@dashboard}/workspace-version/#{ctx.workspace.id}")

        edit(view, ctx.version)

        assert has_element?(view, "##{form}-form[method=put]")

        leave_edit(view, form, leave, %{version_name: "Edited Here"})

        refute has_element?(view, "##{form}-form[method=put]")

        number = "9.#{System.unique_integer([:positive])}.0"

        view
        |> form("##{form}-form", form: %{version_number: number, status: "draft"})
        |> render_submit()

        assert [%{workspace_id: workspace_id}] =
                 WorkspaceVersion
                 |> Ash.Query.filter(version_number == ^number)
                 |> Ash.read!(tenant: ctx.site.id, authorize?: false)

        assert workspace_id == ctx.workspace.id, "after #{leave}, Add Version lost the workspace"
      end
    end
  end

  describe "a version's Published At" do
    test "is a calendar that opens on the stored month, moves by month and year, and saves the day and time picked",
         ctx do
      form = FormInfo.component_id(WorkspaceVersion)
      field = "##{form}-form_published_at"
      Ash.Seed.update!(ctx.version, %{published_at: ~U[2024-03-04 05:06:00Z]})

      view = open(ctx.site_admin_conn, "#{@dashboard}/workspace-version/#{ctx.workspace.id}")
      edit(view, ctx.version)

      assert shown(view, form, :published_at) == "2024-03-04T05:06:00"
      assert view |> element(field) |> render() =~ "04 Mar 2024, 05:06"

      view |> element(field) |> render_click()
      assert month(view, field) == "March 2024"

      step(view, field, "12")
      assert month(view, field) == "March 2025"
      step(view, field, "-12")
      step(view, field, "-1")
      assert month(view, field) == "February 2024"

      for _ <- 1..7, do: step(view, field, "1")
      assert month(view, field) == "September 2024"

      view |> element("#{field}-day-2024-09-09") |> render_click()

      view
      |> element("#{field}-hour")
      |> render_change(%{"_gvz_picker" => %{"published_at" => %{"hour" => "22"}}})

      view
      |> element("#{field}-minute")
      |> render_change(%{"_gvz_picker" => %{"published_at" => %{"minute" => "45"}}})

      assert shown(view, form, :published_at) == "2024-09-09T22:45:00"

      view |> element("#{field}-calendar button", "Done") |> render_click()
      refute has_element?(view, "#{field}-month")
      assert view |> element(field) |> render() =~ "09 Sep 2024, 22:45"

      view |> form("##{form}-form") |> render_submit()

      refute render(view) =~ "must be a valid date and time"

      assert %{published_at: ~U[2024-09-09 22:45:00Z]} =
               Ash.get!(WorkspaceVersion, ctx.version.id, tenant: ctx.site.id, authorize?: false)
    end
  end

  describe "the pickers that name a section, draft or note" do
    setup ctx do
      earlier = create_workspace_version!(workspace_id: ctx.workspace.id, site_id: ctx.site.id)
      elsewhere = create_workspace_version!(site_id: ctx.site.id)

      %{
        earlier: earlier,
        earlier_section: create_section!(site_id: ctx.site.id, workspace_version_id: earlier.id),
        elsewhere_section:
          create_section!(site_id: ctx.site.id, workspace_version_id: elsewhere.id)
      }
    end

    test "offer a new section the parents of its version and the sources of the workspace's other versions",
         ctx do
      form = FormInfo.component_id(Section)
      view = open(ctx.site_admin_conn, "#{@dashboard}/sections/#{ctx.version.id}")

      assert offered(view, form, :parent_section_id) == [ctx.section.id]
      assert offered(view, form, :source_section_id) == [ctx.earlier_section.id]
    end

    test "offer a section draft the sections of the version picked for it", ctx do
      form = FormInfo.component_id(SectionDraft)

      view =
        ctx.site_admin_conn
        |> open("#{@dashboard}/section-drafts")
        |> pick(form, :workspace, ctx.workspace.id)
        |> pick(form, :workspace_version_id, ctx.version.id)

      assert offered(view, form, :parent_section_id) == [ctx.section.id]
      assert offered(view, form, :source_section_id) == [ctx.section.id]
    end

    test "offer a note draft the section, section draft and note of the version picked for it",
         ctx do
      draft = create_section_draft!(site_id: ctx.site.id, workspace_version_id: ctx.version.id)

      create_section_draft!(site_id: ctx.site.id, workspace_version_id: ctx.earlier.id)
      note = create_note!(site_id: ctx.site.id, section_id: ctx.section.id)
      create_note!(site_id: ctx.site.id, section_id: ctx.earlier_section.id)
      form = FormInfo.component_id(NoteDraft)

      view =
        ctx.site_admin_conn
        |> open("#{@dashboard}/note-drafts")
        |> pick(form, :workspace, ctx.workspace.id)
        |> pick(form, :workspace_version_id, ctx.version.id)

      assert offered(view, form, :section_id) == [ctx.section.id]
      assert offered(view, form, :section_draft_id) == [draft.id]
      assert offered(view, form, :source_note_id) == [note.id]
    end

    test "say on the field why a section of another version is refused", ctx do
      form = FormInfo.component_id(Section)
      view = open(ctx.master_conn, "#{@dashboard}/sections/#{ctx.version.id}")

      view
      |> with_target("##{form}-form-wrapper")
      |> render_hook("relation_select", %{
        "filter" => "parent_section_id",
        "id" => ctx.earlier_section.id,
        "label" => ctx.earlier_section.title
      })

      view
      |> form("##{form}-form", form: %{title: "Stray", slug: "stray", language: "en"})
      |> render_submit()

      assert has_element?(
               view,
               "##{form}-form",
               "That section belongs to another workspace version."
             )

      refute Section
             |> Ash.Query.filter(slug == "stray")
             |> Ash.exists?(tenant: ctx.site.id, authorize?: false)
    end

    test "each offer an empty choice when the record can do without the link" do
      optional =
        for resource <- Ash.Domain.Info.resources(MishkaDocument),
            %{validation: {SameWorkspaceVersion, opts}} <- Ash.Resource.Info.validations(resource),
            Ash.Resource.Info.attribute(resource, opts[:field]).allow_nil?,
            field = FormInfo.field(resource, opts[:field]),
            not is_nil(field),
            do: {resource, field}

      assert optional != []

      for {resource, field} <- optional do
        assert field.include_nil,
               "#{inspect(resource)}'s #{field.name} picker cannot be emptied once a record is picked"
      end
    end

    test "let a section with a parent move to another version as a top-level section", ctx do
      child =
        create_section!(
          site_id: ctx.site.id,
          workspace_version_id: ctx.version.id,
          parent_section_id: ctx.section.id
        )

      form = FormInfo.component_id(Section)

      view =
        ctx.site_admin_conn
        |> open("#{@dashboard}/sections/#{ctx.version.id}")
        |> edit(child)
        |> pick(form, :workspace_version_id, ctx.earlier.id)

      assert offered(view, form, :parent_section_id) == [ctx.earlier_section.id]

      view
      |> pick(form, :parent_section_id, "__nil__")
      |> form("##{form}-form")
      |> render_submit()

      assert %{workspace_version_id: version_id, parent_section_id: nil} =
               Ash.get!(Section, child.id, tenant: ctx.site.id, authorize?: false)

      assert version_id == ctx.earlier.id
    end
  end

  describe "who wrote a draft" do
    test "is picked on create and shown but not changeable on edit", ctx do
      for {resource, path, draft} <- [
            {SectionDraft, "#{@dashboard}/section-drafts",
             create_section_draft!(
               site_id: ctx.site.id,
               workspace_version_id: ctx.version.id,
               created_by_user_id: ctx.site_admin.id
             )},
            {NoteDraft, "#{@dashboard}/note-drafts",
             create_note_draft!(
               site_id: ctx.site.id,
               section_id: ctx.section.id,
               workspace_version_id: ctx.version.id,
               created_by_user_id: ctx.site_admin.id
             )}
          ] do
        form = FormInfo.component_id(resource)
        author = "#{picker(form, :created_by_user_id)} input[name=_search_created_by_user_id]"
        view = open(ctx.site_admin_conn, path)

        assert has_element?(view, author)
        refute has_element?(view, author <> "[disabled]")

        edit(view, draft)

        assert has_element?(view, "##{form}-form[method=put]")
        assert has_element?(view, hidden(form, :created_by_user_id, ctx.site_admin.id))

        assert has_element?(view, author <> "[disabled]"),
               "#{inspect(resource)}'s edit form lets Created By change"
      end
    end
  end

  describe "a note's form" do
    test "draws a master its Site and Section in a group ahead of the SEO tags", ctx do
      form = FormInfo.component_id(Note)
      view = open(ctx.master_conn, "#{@dashboard}/sections/#{ctx.version.id}")

      add_note(view, ctx.section)

      groups =
        view
        |> render()
        |> LazyHTML.from_fragment()
        |> LazyHTML.query("##{form}-form fieldset")
        |> Enum.map(&LazyHTML.to_html/1)

      holding = fn text -> Enum.find_index(groups, &String.contains?(&1, text)) end
      site = holding.(~s(id="search-select-#{form}-site_id"))

      assert site
      assert site == holding.(~s(id="search-select-#{form}-section_id"))
      assert site < holding.("SEO Tags")
    end
  end

  # THE CONTENT EDITOR (`extra %{content_editor: true}`, drawn by
  # `MishkaCmsCoreWeb.UIAdapters.Admin.textarea/1`): a note's and a page's text, and their drafts', is
  # HTML written in it, with components placed as markers the document kit draws.
  describe "the content editor" do
    test "is the content field of a note, a section and their drafts", ctx do
      forms = [
        {Note, "#{@dashboard}/sections/#{ctx.version.id}", &add_note(&1, ctx.section)},
        {Section, "#{@dashboard}/sections/#{ctx.version.id}", & &1},
        {NoteDraft, "#{@dashboard}/note-drafts", & &1},
        {SectionDraft, "#{@dashboard}/section-drafts", & &1}
      ]

      for {resource, path, reach} <- forms do
        form = FormInfo.component_id(resource)
        view = ctx.master_conn |> open(path) |> reach.()
        editor = "#{form}-form_content-editor"

        assert has_element?(
                 view,
                 "##{editor}-surface[phx-hook=ContentEditor][phx-update=ignore][data-format=html]"
               ),
               "#{inspect(resource)}'s content is not written in the content editor"

        assert has_element?(view, "##{form}-form textarea##{editor}-value[name='form[content]']")
        assert has_element?(view, "##{editor}-components")
      end
    end

    test "and a note saved from it keeps its markers, scrubbed like any note", ctx do
      form = FormInfo.component_id(Note)
      view = open(ctx.master_conn, "#{@dashboard}/sections/#{ctx.version.id}")
      marker = ~s([[component doc-callout title="Heads up"]]Read <b>this</b>[[/component]])

      add_note(view, ctx.section)

      view
      |> form("##{form}-form", form: %{title: "With a component"})
      |> render_submit(%{
        "form" => %{
          "content" =>
            ~s|<p dir="auto">Intro</p><p>#{marker}</p><script>alert(1)</script><p onclick="x()">End</p>|
        }
      })

      assert [%{content: content}] =
               Note
               |> Ash.Query.filter(title == "With a component")
               |> Ash.read!(tenant: ctx.site.id, authorize?: false)

      assert content =~ "<p>#{marker}</p>"
      assert content =~ ~s(<p dir="auto">Intro</p>)
      refute content =~ "script"
      refute content =~ "onclick"
    end
  end

  describe "who may open a document or a page of it" do
    test "is picked by name on a workspace's and a section's form, beside the SEO tags", ctx do
      permission = create_permission!(name: "docs:members")

      for {resource, path, record, changes} <- [
            {Workspace, @dashboard, ctx.workspace, %{name: "Members"}},
            {Section, "#{@dashboard}/sections/#{ctx.version.id}", ctx.section, %{}}
          ] do
        form = FormInfo.component_id(resource)
        picker = "#multi-select-#{form}-permissions"
        view = ctx.master_conn |> open(path) |> edit(record)

        groups =
          view
          |> render()
          |> LazyHTML.from_fragment()
          |> LazyHTML.query("##{form}-form fieldset")
          |> Enum.map(&LazyHTML.to_html/1)

        holding = fn text -> Enum.find_index(groups, &String.contains?(&1, text)) end

        assert holding.(~s(id="multi-select-#{form}-permissions")),
               "#{inspect(resource)}'s form has no Permissions picker"

        assert holding.(~s(id="multi-select-#{form}-permissions")) == holding.("SEO Tags")

        view |> element("#{picker} input[name='_search_permissions']") |> render_focus()
        render_async(view, @await)
        view |> element("#{picker} [phx-value-id='#{permission.name}']") |> render_click()

        leave_edit(view, form, :save, changes)

        assert Ash.get!(resource, record.id, tenant: ctx.site.id, authorize?: false).permissions ==
                 [permission.name]
      end
    end
  end

  describe "an issue's reporter" do
    test "is shown on edit and cannot be changed there, and is picked on create", ctx do
      issue = create_issue!(site_id: ctx.site.id, section_id: ctx.section.id)
      form = FormInfo.component_id(Issue)
      view = open(ctx.master_conn, "#{@dashboard}/issues")

      pick(view, form, :site_id, ctx.site.id)

      assert has_element?(view, "#{picker(form, :reporter_id)} input[name=_search_reporter_id]")

      refute has_element?(
               view,
               "#{picker(form, :reporter_id)} input[name=_search_reporter_id][disabled]"
             )

      edit(view, issue)

      assert has_element?(view, "##{form}-form[method=put]")

      assert has_element?(view, hidden(form, :reporter_id, issue.reporter_id))

      assert has_element?(
               view,
               "#{picker(form, :reporter_id)} input[name=_search_reporter_id][disabled]"
             )
    end
  end

  describe "a document's title and slug" do
    test "a title is one line on every form that has one", ctx do
      forms = [
        {Note, "#{@dashboard}/sections/#{ctx.version.id}", &add_note(&1, ctx.section)},
        {Section, "#{@dashboard}/sections/#{ctx.version.id}", & &1},
        {NoteDraft, "#{@dashboard}/note-drafts", & &1},
        {SectionDraft, "#{@dashboard}/section-drafts", & &1},
        {Issue, "#{@dashboard}/issues", & &1}
      ]

      for {resource, path, reach} <- forms do
        form = FormInfo.component_id(resource)
        view = ctx.master_conn |> open(path) |> reach.()

        assert has_element?(view, "##{form}-form input[type=text][name='form[title]']"),
               "#{inspect(resource)}'s title is not one line"
      end
    end

    test "an SEO tag's content is the adapter's full-width field", ctx do
      field = MishkaGervaz.UIAdapters.Tailwind.multiline_class("")

      for {resource, path} <- [
            {Section, "#{@dashboard}/sections/#{ctx.version.id}"},
            {SectionDraft, "#{@dashboard}/section-drafts"},
            {Workspace, @dashboard}
          ] do
        form = FormInfo.component_id(resource)
        view = open(ctx.master_conn, path)

        view
        |> element("##{form}-form button[phx-click=add_nested]", "Add SEO Tag")
        |> render_click()

        render_async(view, @await)

        assert view
               |> element("##{form}-form textarea[name^='form[seo_tags]'][name$='[content]']")
               |> render()
               |> LazyHTML.from_fragment()
               |> LazyHTML.attribute("class") == [field],
               "#{inspect(resource)}'s SEO tag content is not the adapter's field"
      end
    end

    test "the slug follows the name or title while a record is added, until the author types one",
         ctx do
      for {resource, path, field} <- [
            {Workspace, @dashboard, :name},
            {Tag, "#{@dashboard}/tags", :name},
            {Section, "#{@dashboard}/sections/#{ctx.version.id}", :title},
            {SectionDraft, "#{@dashboard}/section-drafts", :title}
          ] do
        form = FormInfo.component_id(resource)
        view = open(ctx.site_admin_conn, path)

        type(view, form, field, "Getting Started: Part 1")

        assert shown(view, form, :slug) == "getting-started-part-1",
               "#{inspect(resource)}'s slug did not follow its #{field}"

        type(view, form, :slug, "own-slug")
        type(view, form, field, "Getting Started Again")

        assert shown(view, form, :slug) == "own-slug",
               "#{inspect(resource)} moved a slug the author typed"
      end
    end

    test "a Persian title is saved with the slug the form showed", ctx do
      form = FormInfo.component_id(Section)
      view = open(ctx.site_admin_conn, "#{@dashboard}/sections/#{ctx.version.id}")

      type(view, form, :title, "راهنمای شروع")
      slug = shown(view, form, :slug)

      assert slug == Slug.slugify("راهنمای شروع")

      view
      |> form("##{form}-form", form: %{language: "en"})
      |> render_submit()

      assert [%{slug: ^slug}] =
               Section
               |> Ash.Query.filter(title == "راهنمای شروع")
               |> Ash.read!(tenant: ctx.site.id, actor: ctx.site_admin)
    end

    test "an edited record keeps its slug when its name or title changes", ctx do
      for {resource, path, record, field} <- [
            {Workspace, @dashboard, ctx.workspace, :name},
            {Section, "#{@dashboard}/sections/#{ctx.version.id}", ctx.section, :title}
          ] do
        form = FormInfo.component_id(resource)
        view = ctx.site_admin_conn |> open(path) |> edit(record)

        assert has_element?(view, "##{form}-form[method=put]")

        type(view, form, field, "Renamed Record")
        assert shown(view, form, :slug) == record.slug

        leave_edit(view, form, :save, %{field => "Renamed Record"})

        assert Ash.get!(resource, record.id, tenant: ctx.site.id, actor: ctx.site_admin).slug ==
                 record.slug
      end
    end
  end

  # One keystroke's `phx-change`: the form sends every field it shows, with `field` changed.
  defp type(view, form, field, value) do
    view
    |> form("##{form}-form", %{"form" => %{to_string(field) => value}})
    |> render_change(%{"_target" => ["form", to_string(field)]})

    render_async(view, @await)
    view
  end

  defp shown(view, form, field) do
    view
    |> element("##{form}-form input[name='form[#{field}]']")
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.attribute("value")
    |> List.first()
  end

  defp month(view, field),
    do:
      view
      |> element("#{field}-month")
      |> render()
      |> LazyHTML.from_fragment()
      |> LazyHTML.text()
      |> String.trim()

  defp step(view, field, step) do
    view
    |> element(
      ~s(#{field}-calendar button[phx-click*="picker_month"][phx-click*='"step":"#{step}"'])
    )
    |> render_click()
  end

  defp open(conn, path) do
    {:ok, view, _html} = live(conn, path)
    render_async(view, @await)
    view
  end

  defp edit(view, record), do: row_action(view, record, "edit")

  defp row_action(view, record, event) do
    view
    |> element(~s([phx-click*="#{record.id}"][phx-click*='"event":"#{event}"']))
    |> render_click()

    render_async(view, @await)
    view
  end

  defp saved_version(view, ctx, slug) do
    view
    |> form("##{FormInfo.component_id(Section)}-form",
      form: %{title: "Added Here", slug: slug, language: "en"}
    )
    |> render_submit()

    case Section
         |> Ash.Query.filter(slug == ^slug)
         |> Ash.read!(tenant: ctx.site.id, authorize?: false) do
      [%{workspace_version_id: version_id}] -> version_id
      _not_saved -> nil
    end
  end

  defp assert_adds_into_page_version(view, ctx, leave) do
    form = FormInfo.component_id(Section)

    edit(view, ctx.section)

    assert has_element?(view, "##{form}-form[method=put]")

    leave_edit(view, form, leave)

    refute has_element?(view, "##{form}-form[method=put]")

    for {field, value} <- [workspace: ctx.workspace.id, workspace_version_id: ctx.version.id] do
      assert has_element?(view, hidden(form, field, value)),
             "after #{leave}, Add Section lost the page's #{field}"

      assert has_element?(view, "#{picker(form, field)} input[name=_search_#{field}][disabled]")
    end

    assert saved_version(view, ctx, "after-#{leave}-#{System.unique_integer([:positive])}") ==
             ctx.version.id
  end

  defp leave_edit(view, form, leave, changes \\ %{title: "Edited Here"})

  defp leave_edit(view, form, :cancel, _changes) do
    view
    |> element(~s(##{form}-form button[phx-click*='"event":"cancel"']))
    |> render_click()

    render_async(view, @await)
  end

  defp leave_edit(view, form, :save, changes) do
    view
    |> form("##{form}-form", form: changes)
    |> render_submit()

    render_async(view, @await)
  end

  defp add_note(view, section) do
    view
    |> element(
      ~s(button[phx-click="custom_event"][phx-value-event="manage_notes"][phx-value-values*="#{section.id}"])
    )
    |> render_click()

    render_async(view, @await)
    view
  end

  defp pick(view, form, field, id) do
    view |> element("#{picker(form, field)} input[name=_search_#{field}]") |> render_focus()
    render_async(view, @await)

    view |> element(option(form, field, id)) |> render_click()

    render_async(view, @await)
    view
  end

  defp offered(view, form, field) do
    view |> element("#{picker(form, field)} input[name=_search_#{field}]") |> render_focus()

    view
    |> render_async(@await)
    |> LazyHTML.from_fragment()
    |> LazyHTML.query(~s(#{picker(form, field)} button[phx-click="relation_select"]))
    |> LazyHTML.attribute("phx-value-id")
    |> Enum.reject(&(&1 == "__nil__"))
    |> Enum.sort()
  end

  defp hidden(form, field, value),
    do: ~s(#{picker(form, field)} input[type=hidden][name=#{field}][value="#{value}"])

  defp option(form, field, id),
    do: ~s(#{picker(form, field)} button[phx-click="relation_select"][phx-value-id="#{id}"])

  defp open_comments(conn, issue) do
    view = open(conn, "#{@dashboard}/issues")

    view
    |> element(~s(button[phx-click="expand_row"][phx-value-id="#{issue.id}"]))
    |> render_click()

    render_async(view, @await)
    view
  end

  defp picker(form, field), do: "#search-select-#{form}-#{field}"

  defp on_host(conn) do
    conn
    |> Map.put(:host, "localhost")
    |> Map.update!(:req_headers, &[{"host", "localhost"} | List.keydelete(&1, "host", 0)])
  end

  defp star_permission do
    case Permission |> Ash.Query.filter(name == "*") |> Ash.read_one(authorize?: false) do
      {:ok, nil} ->
        Permission
        |> Ash.Changeset.for_create(:create, %{name: "*"}, authorize?: false)
        |> Ash.create!()

      {:ok, permission} ->
        permission
    end
  end

  defp admin!(email, site_id \\ nil) do
    {:ok, user} =
      User
      |> Ash.Changeset.for_create(
        :register_with_password,
        %{email: email, password: @password, password_confirmation: @password},
        authorize?: false
      )
      |> then(&if(site_id, do: Ash.Changeset.set_tenant(&1, site_id), else: &1))
      |> Ash.create()

    UserPermission
    |> Ash.Changeset.for_create(:assign, %{}, authorize?: false)
    |> Ash.Changeset.force_change_attribute(:user_id, user.id)
    |> Ash.Changeset.force_change_attribute(:permission_id, star_permission().id)
    |> Ash.create!(authorize?: false)

    user
  end

  defp log_in(conn, user) do
    conn
    |> Plug.Test.init_test_session(%{})
    |> Plug.Conn.put_session(:master_mode, true)
    |> AshAuthentication.Plug.Helpers.store_in_session(user)
  end
end
