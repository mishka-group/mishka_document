defmodule MishkaDocument.Test.SectionFrontPageTest do
  @moduledoc """
  A page marked as its version's front page (`MishkaDocument.Section.front_page`) is drawn at its
  document's own address (`MishkaDocument.Address`). Only a page at the top may be one, and a version
  has at most one among its pages not archived.

  Every write goes through the action an admin's form or the JSON:API calls, as an admin holding the
  section area, or as a master.
  """
  use MishkaDocument.DataCase, async: false

  alias MishkaDocument.Section
  alias MishkaGervaz.Resource.Info.Form, as: FormInfo

  require Ash.Query

  @moduletag :integration

  @area "admin:dashboard:document:section"

  setup do
    site = create_site!()
    workspace = create_workspace!(site_id: site.id)
    version = create_workspace_version!(workspace_id: workspace.id, site_id: site.id)

    %{
      site: site,
      workspace: workspace,
      version: version,
      editor: create_user_with_permissions!([@area], site_id: site.id)
    }
  end

  defp create(ctx, attrs, version \\ nil) do
    unique = System.unique_integer([:positive])

    Section
    |> Ash.Changeset.for_create(
      :create,
      Map.merge(
        %{
          title: "Page #{unique}",
          slug: "page-#{unique}",
          language: "en",
          workspace_version_id: (version || ctx.version).id
        },
        attrs
      ),
      actor: ctx.editor,
      tenant: ctx.site.id
    )
    |> Ash.create()
  end

  defp write(ctx, page, attrs) do
    page
    |> Ash.Changeset.for_update(:update, attrs, actor: ctx.editor, tenant: ctx.site.id)
    |> Ash.update()
  end

  defp messages(%{errors: errors}), do: Enum.map(errors, &Exception.message/1)

  test "a page is not a front page unless it is marked as one", ctx do
    assert {:ok, %{front_page: false}} = create(ctx, %{})
  end

  test "a page at the top may be its version's front page", ctx do
    assert {:ok, %{front_page: true}} = create(ctx, %{front_page: true})
  end

  describe "only a page at the top" do
    test "is marked as one: a page filed under another is refused", ctx do
      {:ok, parent} = create(ctx, %{})

      assert {:error, error} = create(ctx, %{front_page: true, parent_section_id: parent.id})

      assert Enum.any?(messages(error), &(&1 =~ "Only a page with no parent may be"))
      assert [%{field: :front_page}] = Enum.filter(error.errors, &(&1.field == :front_page))
    end

    test "and a front page is not filed under another afterwards", ctx do
      {:ok, parent} = create(ctx, %{})
      {:ok, front} = create(ctx, %{front_page: true})

      assert {:error, error} = write(ctx, front, %{parent_section_id: parent.id})
      assert Enum.any?(messages(error), &(&1 =~ "Only a page with no parent may be"))

      {:ok, child} = create(ctx, %{parent_section_id: parent.id})
      assert {:error, _refused} = write(ctx, child, %{front_page: true})
    end

    test "whoever writes it, a master too", ctx do
      master = create_user_with_permissions!([@area])
      {:ok, parent} = create(ctx, %{})
      {:ok, child} = create(ctx, %{parent_section_id: parent.id})

      assert {:error, error} =
               Section
               |> Ash.get!(child.id, action: :master_get, actor: master)
               |> Ash.Changeset.for_update(:master_update, %{front_page: true}, actor: master)
               |> Ash.update()

      assert Enum.any?(messages(error), &(&1 =~ "Only a page with no parent may be"))
    end
  end

  describe "one a version" do
    test "a second front page in the same version is refused", ctx do
      {:ok, _front} = create(ctx, %{front_page: true})

      assert {:error, error} = create(ctx, %{front_page: true})

      assert Enum.any?(
               messages(error),
               &(&1 =~ "Another page of this version is already its front page")
             )
    end

    test "and so is marking a second one afterwards", ctx do
      {:ok, _front} = create(ctx, %{front_page: true})
      {:ok, other} = create(ctx, %{})

      assert {:error, error} = write(ctx, other, %{front_page: true})

      assert Enum.any?(
               messages(error),
               &(&1 =~ "Another page of this version is already its front page")
             )
    end

    test "but each version has its own", ctx do
      newer = create_workspace_version!(workspace_id: ctx.workspace.id, site_id: ctx.site.id)

      assert {:ok, _front} = create(ctx, %{front_page: true})
      assert {:ok, _front} = create(ctx, %{front_page: true}, newer)
    end

    test "and an archived front page leaves room for another, but is not restored beside it",
         ctx do
      {:ok, front} = create(ctx, %{front_page: true})

      Ash.destroy!(front, action: :destroy, actor: ctx.editor, tenant: ctx.site.id)

      assert {:ok, _another} = create(ctx, %{front_page: true})

      archived =
        Section
        |> Ash.Query.for_read(:get_archived, %{}, actor: ctx.editor, tenant: ctx.site.id)
        |> Ash.Query.filter(id == ^front.id)
        |> Ash.read_one!()

      assert {:error, error} =
               archived
               |> Ash.Changeset.for_update(:unarchive, %{},
                 actor: ctx.editor,
                 tenant: ctx.site.id
               )
               |> Ash.update()

      assert Enum.any?(
               messages(error),
               &(&1 =~ "Another page of this version is already its front page")
             )
    end
  end

  test "the admin form marks it with a toggle, after Parent Section" do
    field = FormInfo.field(Section, :front_page)

    assert field, "the form has no Front page field"
    assert field.type == :toggle

    references =
      Section
      |> FormInfo.groups()
      |> Enum.find(&(&1.name == :references))

    assert [_, _, :parent_section_id, :front_page | _] = references.fields
  end
end
