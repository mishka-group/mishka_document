defmodule MishkaDocumentWeb.Api.Json.IssueCommentTest do
  @moduledoc """
  Comprehensive tests for IssueComment JSON API endpoints.

  Tests all tenant admin and master admin issue comment endpoints including
  CRUD operations, archive/unarchive, tenant isolation, and
  relationship loading with pagination.
  """

  use MishkaDocument.ConnCase
  import MishkaDocument.Test.Factory

  @moduletag :unit
  @moduletag :capture_log

  if Code.ensure_loaded?(MishkaDocument) do
    @password "Password123!"
    @api_user_path "/api/json/v1/auth/user"
    @tenant_path "/api/json/v1/tenant/admin/mishka-document/issue-comment"
    @master_path "/api/json/v1/master/admin/mishka-document/issue-comment"

    setup do
      MishkaCmsCore.Runtime.States.SiteState.clear()
      :ok = Swoosh.TestAssertions.set_swoosh_global()

      Application.put_env(:ash_json_api, MishkaDocument, router: MishkaDocument.TestRouter)

      # Create two sites for tenant isolation testing
      site1 =
        create_site!(
          name: "localhost",
          host: "localhost",
          active: true,
          priority: 50,
          master: true
        )

      site2 = create_site!(name: "site2", host: "site2.local", active: true, priority: 40)

      MishkaCmsCore.Runtime.States.SiteState.save(%{
        id: site1.id,
        name: site1.name,
        host: site1.host,
        priority: site1.priority,
        active: site1.active,
        master: site1.master
      })

      MishkaCmsCore.Runtime.States.SiteState.save(%{
        id: site2.id,
        name: site2.name,
        host: site2.host,
        priority: site2.priority,
        active: site2.active
      })

      # Create admin permission
      admin_permission = create_permission!(name: "admin:api:*")

      # Create master user with admin permissions (no site_id)
      master_user =
        MishkaCmsCore.Accounts.User
        |> Ash.Changeset.for_create(:create, %{
          email: "master@example.com",
          hashed_password: Bcrypt.hash_pwd_salt(@password)
        })
        |> Ash.create!(authorize?: false, tenant: nil)
        |> Ash.Changeset.for_update(
          :assign_permissions,
          %{permission_ids: [admin_permission.id]},
          authorize?: false
        )
        |> Ash.update!()

      # Create tenant admin user for site1
      tenant_admin1 =
        create_user!(
          email: "admin1@example.com",
          password: @password,
          password_confirmation: @password,
          site_id: site1.id
        )
        |> Ash.Changeset.for_update(
          :assign_permissions,
          %{permission_ids: [admin_permission.id]},
          authorize?: false,
          tenant: site1.id
        )
        |> Ash.update!()

      # Create tenant admin user for site2
      tenant_admin2 =
        create_user!(
          email: "admin2@example.com",
          password: @password,
          password_confirmation: @password,
          site_id: site2.id
        )
        |> Ash.Changeset.for_update(
          :assign_permissions,
          %{permission_ids: [admin_permission.id]},
          authorize?: false,
          tenant: site2.id
        )
        |> Ash.update!()

      on_exit(fn ->
        MishkaCmsCore.Runtime.States.SiteState.delete(site1.id)
        MishkaCmsCore.Runtime.States.SiteState.delete(site2.id)
        MishkaCmsCore.Runtime.States.SiteState.clear()
      end)

      %{
        site1: site1,
        site2: site2,
        master_user: master_user,
        tenant_admin1: tenant_admin1,
        tenant_admin2: tenant_admin2
      }
    end

    # Helper functions for sign-in
    defp sign_in_master(master_user) do
      sign_in_response =
        make_api_request(
          "#{@api_user_path}/sign-in",
          %{
            "type" => "user",
            "attributes" => %{
              "email" => to_string(master_user.email),
              "password" => @password
            }
          },
          headers: [{"x-no-tenant", "true"}]
        )

      assert sign_in_response.status == 201
      %{"meta" => %{"token" => token}} = Jason.decode!(sign_in_response.resp_body)
      token
    end

    defp sign_in_tenant(tenant_user) do
      sign_in_response =
        make_api_request(
          "#{@api_user_path}/sign-in",
          %{
            "type" => "user",
            "attributes" => %{
              "email" => to_string(tenant_user.email),
              "password" => @password
            }
          }
        )

      assert sign_in_response.status == 201
      %{"meta" => %{"token" => token}} = Jason.decode!(sign_in_response.resp_body)
      token
    end

    describe "MASTER ADMIN - POST /v1/master/admin/mishka-document/issue-comment (create)" do
      test "can create comment on site1 issue", %{
        site1: site1,
        master_user: master_user,
        tenant_admin1: tenant_admin1
      } do
        token = sign_in_master(master_user)

        issue = create_issue!(site_id: site1.id)

        response =
          make_api_request(
            @master_path,
            %{
              "type" => "issue_comment",
              "attributes" => %{
                "issue_id" => issue.id,
                "contributor_id" => tenant_admin1.id,
                "content" => "Master comment on site1",
                "site_id" => site1.id
              }
            },
            headers: [{"authorization", "Bearer #{token}"}, {"x-no-tenant", "true"}]
          )

        assert response.status == 201
        body = Jason.decode!(response.resp_body)
        assert body["data"]["attributes"]["content"] == "Master comment on site1"
        assert body["data"]["attributes"]["issue_id"] == issue.id
      end

      test "can create comment on site2 issue", %{
        site2: site2,
        master_user: master_user,
        tenant_admin2: tenant_admin2
      } do
        token = sign_in_master(master_user)

        issue = create_issue!(site_id: site2.id)

        response =
          make_api_request(
            @master_path,
            %{
              "type" => "issue_comment",
              "attributes" => %{
                "issue_id" => issue.id,
                "contributor_id" => tenant_admin2.id,
                "content" => "Master comment on site2",
                "site_id" => site2.id
              }
            },
            headers: [{"authorization", "Bearer #{token}"}, {"x-no-tenant", "true"}]
          )

        assert response.status == 201
        body = Jason.decode!(response.resp_body)
        assert body["data"]["attributes"]["content"] == "Master comment on site2"
      end

      test "returns error when content is missing", %{
        site1: site1,
        master_user: master_user,
        tenant_admin1: tenant_admin1
      } do
        token = sign_in_master(master_user)

        issue = create_issue!(site_id: site1.id)

        response =
          make_api_request(
            @master_path,
            %{
              "type" => "issue_comment",
              "attributes" => %{
                "issue_id" => issue.id,
                "contributor_id" => tenant_admin1.id,
                "site_id" => site1.id
              }
            },
            headers: [{"authorization", "Bearer #{token}"}, {"x-no-tenant", "true"}]
          )

        assert response.status == 400
      end
    end

    describe "MASTER ADMIN - GET /v1/master/admin/mishka-document/issue-comment (index)" do
      test "returns all comments system-wide", %{
        site1: site1,
        site2: site2,
        master_user: master_user
      } do
        token = sign_in_master(master_user)

        # Create comments on different sites
        comment1 = create_issue_comment!(site_id: site1.id)
        comment2 = create_issue_comment!(site_id: site2.id)

        response =
          make_api_request(
            @master_path,
            nil,
            method: :get,
            headers: [{"authorization", "Bearer #{token}"}, {"x-no-tenant", "true"}]
          )

        assert response.status == 200
        body = Jason.decode!(response.resp_body)
        comment_ids = Enum.map(body["data"], & &1["id"])
        assert comment1.id in comment_ids
        assert comment2.id in comment_ids
      end

      test "can read single comment by ID", %{site1: site1, master_user: master_user} do
        token = sign_in_master(master_user)

        comment = create_issue_comment!(site_id: site1.id, content: "Test comment")

        response =
          make_api_request(
            "#{@master_path}/#{comment.id}",
            nil,
            method: :get,
            headers: [{"authorization", "Bearer #{token}"}, {"x-no-tenant", "true"}]
          )

        assert response.status == 200
        body = Jason.decode!(response.resp_body)
        assert body["data"]["id"] == comment.id
        assert body["data"]["attributes"]["content"] == "Test comment"
      end

      test "supports pagination", %{site1: site1, master_user: master_user} do
        token = sign_in_master(master_user)

        # Create multiple comments
        for _ <- 1..5, do: create_issue_comment!(site_id: site1.id)

        response =
          make_api_request(
            "#{@master_path}?page[limit]=2",
            nil,
            method: :get,
            headers: [{"authorization", "Bearer #{token}"}, {"x-no-tenant", "true"}]
          )

        assert response.status == 200
        body = Jason.decode!(response.resp_body)
        assert length(body["data"]) == 2
        assert body["meta"]["page"]
      end
    end

    describe "MASTER ADMIN - PATCH /v1/master/admin/mishka-document/issue-comment/:id (update)" do
      test "can update comment content", %{site1: site1, master_user: master_user} do
        token = sign_in_master(master_user)

        comment = create_issue_comment!(site_id: site1.id, content: "Original")

        response =
          make_api_request(
            "#{@master_path}/#{comment.id}",
            %{
              "type" => "issue_comment",
              "id" => comment.id,
              "attributes" => %{
                "content" => "Updated content"
              }
            },
            method: :patch,
            headers: [{"authorization", "Bearer #{token}"}, {"x-no-tenant", "true"}]
          )

        assert response.status == 200
        body = Jason.decode!(response.resp_body)
        assert body["data"]["attributes"]["content"] == "Updated content"
      end

      test "can update comment from any site", %{site2: site2, master_user: master_user} do
        token = sign_in_master(master_user)

        comment = create_issue_comment!(site_id: site2.id, content: "Site2 comment")

        response =
          make_api_request(
            "#{@master_path}/#{comment.id}",
            %{
              "type" => "issue_comment",
              "id" => comment.id,
              "attributes" => %{
                "content" => "Master updated site2"
              }
            },
            method: :patch,
            headers: [{"authorization", "Bearer #{token}"}, {"x-no-tenant", "true"}]
          )

        assert response.status == 200
        body = Jason.decode!(response.resp_body)
        assert body["data"]["attributes"]["content"] == "Master updated site2"
      end
    end

    describe "MASTER ADMIN - DELETE /v1/master/admin/mishka-document/issue-comment/:id/archive (archive)" do
      test "can archive comment", %{site1: site1, master_user: master_user} do
        token = sign_in_master(master_user)

        comment = create_issue_comment!(site_id: site1.id)

        response =
          make_api_request(
            "#{@master_path}/#{comment.id}/archive",
            nil,
            method: :delete,
            headers: [{"authorization", "Bearer #{token}"}, {"x-no-tenant", "true"}]
          )

        assert response.status == 200

        # Verify it's in archived list
        archived_response =
          make_api_request(
            "#{@master_path}/archived",
            nil,
            method: :get,
            headers: [{"authorization", "Bearer #{token}"}, {"x-no-tenant", "true"}]
          )

        assert archived_response.status == 200
        archived_body = Jason.decode!(archived_response.resp_body)
        archived_ids = Enum.map(archived_body["data"], & &1["id"])
        assert comment.id in archived_ids
      end

      test "can unarchive comment", %{site1: site1, master_user: master_user} do
        token = sign_in_master(master_user)

        comment = create_issue_comment!(site_id: site1.id)

        # Archive first
        make_api_request(
          "#{@master_path}/#{comment.id}/archive",
          nil,
          method: :delete,
          headers: [{"authorization", "Bearer #{token}"}, {"x-no-tenant", "true"}]
        )

        # Unarchive
        response =
          make_api_request(
            "#{@master_path}/#{comment.id}/unarchive",
            %{"type" => "issue_comment", "id" => comment.id},
            method: :patch,
            headers: [{"authorization", "Bearer #{token}"}, {"x-no-tenant", "true"}]
          )

        assert response.status == 200

        # Verify it's back in regular list
        list_response =
          make_api_request(
            @master_path,
            nil,
            method: :get,
            headers: [{"authorization", "Bearer #{token}"}, {"x-no-tenant", "true"}]
          )

        list_body = Jason.decode!(list_response.resp_body)
        comment_ids = Enum.map(list_body["data"], & &1["id"])
        assert comment.id in comment_ids
      end
    end

    describe "MASTER ADMIN - DELETE /v1/master/admin/mishka-document/issue-comment/:id/permanent (permanent delete)" do
      test "can permanently delete comment", %{site1: site1, master_user: master_user} do
        token = sign_in_master(master_user)

        comment = create_issue_comment!(site_id: site1.id)

        response =
          make_api_request(
            "#{@master_path}/#{comment.id}/permanent",
            nil,
            method: :delete,
            headers: [{"authorization", "Bearer #{token}"}, {"x-no-tenant", "true"}]
          )

        assert response.status == 200

        # Verify it's gone
        get_response =
          make_api_request(
            "#{@master_path}/#{comment.id}",
            nil,
            method: :get,
            headers: [{"authorization", "Bearer #{token}"}, {"x-no-tenant", "true"}]
          )

        assert get_response.status == 404
      end
    end

    describe "TENANT ADMIN - POST /v1/tenant/admin/mishka-document/issue-comment (create)" do
      test "can create comment on own site's issue", %{site1: site1, tenant_admin1: tenant_admin1} do
        token = sign_in_tenant(tenant_admin1)

        issue = create_issue!(site_id: site1.id)

        response =
          make_api_request(
            @tenant_path,
            %{
              "type" => "issue_comment",
              "attributes" => %{
                "issue_id" => issue.id,
                "content" => "Tenant comment on own issue"
              }
            },
            headers: [{"authorization", "Bearer #{token}"}]
          )

        assert response.status == 201
        body = Jason.decode!(response.resp_body)
        assert body["data"]["attributes"]["content"] == "Tenant comment on own issue"
        assert body["data"]["attributes"]["issue_id"] == issue.id
        assert body["data"]["attributes"]["site_id"] == site1.id
        assert body["data"]["attributes"]["contributor_id"] == tenant_admin1.id
      end

      test "CANNOT create comment on another site's issue (tenant isolation)", %{
        site2: site2,
        tenant_admin1: tenant_admin1
      } do
        token = sign_in_tenant(tenant_admin1)

        issue = create_issue!(site_id: site2.id)

        response =
          make_api_request(
            @tenant_path,
            %{
              "type" => "issue_comment",
              "attributes" => %{
                "issue_id" => issue.id,
                "content" => "Trying to comment on another site's issue"
              }
            },
            headers: [{"authorization", "Bearer #{token}"}]
          )

        assert response.status == 400
        body = Jason.decode!(response.resp_body)
        assert body["errors"]

        error_messages =
          body["errors"]
          |> Enum.map(& &1["detail"])
          |> Enum.join(" ")

        assert error_messages =~ "not found or does not belong to your site"
      end
    end

    describe "TENANT ADMIN - GET /v1/tenant/admin/mishka-document/issue-comment (index)" do
      test "can read only own site's comments", %{
        site1: site1,
        site2: site2,
        tenant_admin1: tenant_admin1
      } do
        token = sign_in_tenant(tenant_admin1)

        # Create comments on different sites
        comment1 = create_issue_comment!(site_id: site1.id)
        comment2 = create_issue_comment!(site_id: site2.id)

        response =
          make_api_request(
            @tenant_path,
            nil,
            method: :get,
            headers: [{"authorization", "Bearer #{token}"}]
          )

        assert response.status == 200
        body = Jason.decode!(response.resp_body)
        comment_ids = Enum.map(body["data"], & &1["id"])
        assert comment1.id in comment_ids
        refute comment2.id in comment_ids
      end

      test "can read single comment from own site", %{site1: site1, tenant_admin1: tenant_admin1} do
        token = sign_in_tenant(tenant_admin1)

        comment = create_issue_comment!(site_id: site1.id, content: "Site1 comment")

        response =
          make_api_request(
            "#{@tenant_path}/#{comment.id}",
            nil,
            method: :get,
            headers: [{"authorization", "Bearer #{token}"}]
          )

        assert response.status == 200
        body = Jason.decode!(response.resp_body)
        assert body["data"]["id"] == comment.id
        assert body["data"]["attributes"]["content"] == "Site1 comment"
      end

      test "CANNOT read comment from another site", %{site2: site2, tenant_admin1: tenant_admin1} do
        token = sign_in_tenant(tenant_admin1)

        comment = create_issue_comment!(site_id: site2.id)

        response =
          make_api_request(
            "#{@tenant_path}/#{comment.id}",
            nil,
            method: :get,
            headers: [{"authorization", "Bearer #{token}"}]
          )

        assert response.status == 404
      end

      test "can filter comments by issue", %{site1: site1, tenant_admin1: tenant_admin1} do
        token = sign_in_tenant(tenant_admin1)

        issue = create_issue!(site_id: site1.id)
        comment1 = create_issue_comment!(site_id: site1.id, issue_id: issue.id)
        _comment2 = create_issue_comment!(site_id: site1.id)

        response =
          make_api_request(
            "#{@tenant_path}/by-issue/#{issue.id}",
            nil,
            method: :get,
            headers: [{"authorization", "Bearer #{token}"}]
          )

        assert response.status == 200
        body = Jason.decode!(response.resp_body)
        comment_ids = Enum.map(body["data"], & &1["id"])
        assert comment1.id in comment_ids
      end

      test "can filter comments by contributor", %{
        site1: site1,
        tenant_admin1: tenant_admin1
      } do
        token = sign_in_tenant(tenant_admin1)

        comment1 = create_issue_comment!(site_id: site1.id, contributor_id: tenant_admin1.id)
        _comment2 = create_issue_comment!(site_id: site1.id)

        response =
          make_api_request(
            "#{@tenant_path}/by-contributor/#{tenant_admin1.id}",
            nil,
            method: :get,
            headers: [{"authorization", "Bearer #{token}"}]
          )

        assert response.status == 200
        body = Jason.decode!(response.resp_body)
        comment_ids = Enum.map(body["data"], & &1["id"])
        assert comment1.id in comment_ids
      end

      test "supports pagination", %{site1: site1, tenant_admin1: tenant_admin1} do
        token = sign_in_tenant(tenant_admin1)

        # Create multiple comments
        for _ <- 1..5, do: create_issue_comment!(site_id: site1.id)

        response =
          make_api_request(
            "#{@tenant_path}?page[limit]=2",
            nil,
            method: :get,
            headers: [{"authorization", "Bearer #{token}"}]
          )

        assert response.status == 200
        body = Jason.decode!(response.resp_body)
        assert length(body["data"]) == 2
        assert body["meta"]["page"]
      end
    end

    describe "TENANT ADMIN - PATCH /v1/tenant/admin/mishka-document/issue-comment/:id (update)" do
      test "can update own site's comment", %{site1: site1, tenant_admin1: tenant_admin1} do
        token = sign_in_tenant(tenant_admin1)

        comment = create_issue_comment!(site_id: site1.id, content: "Original")

        response =
          make_api_request(
            "#{@tenant_path}/#{comment.id}",
            %{
              "type" => "issue_comment",
              "id" => comment.id,
              "attributes" => %{
                "content" => "Updated by tenant"
              }
            },
            method: :patch,
            headers: [{"authorization", "Bearer #{token}"}]
          )

        assert response.status == 200
        body = Jason.decode!(response.resp_body)
        assert body["data"]["attributes"]["content"] == "Updated by tenant"
      end

      test "CANNOT update another site's comment", %{
        site2: site2,
        tenant_admin1: tenant_admin1
      } do
        token = sign_in_tenant(tenant_admin1)

        comment = create_issue_comment!(site_id: site2.id, content: "Site2 comment")

        response =
          make_api_request(
            "#{@tenant_path}/#{comment.id}",
            %{
              "type" => "issue_comment",
              "id" => comment.id,
              "attributes" => %{
                "content" => "Trying to update"
              }
            },
            method: :patch,
            headers: [{"authorization", "Bearer #{token}"}]
          )

        assert response.status == 404
      end
    end

    describe "TENANT ADMIN - DELETE /v1/tenant/admin/mishka-document/issue-comment/:id/archive (archive)" do
      test "can archive own site's comment", %{site1: site1, tenant_admin1: tenant_admin1} do
        token = sign_in_tenant(tenant_admin1)

        comment = create_issue_comment!(site_id: site1.id)

        response =
          make_api_request(
            "#{@tenant_path}/#{comment.id}/archive",
            nil,
            method: :delete,
            headers: [{"authorization", "Bearer #{token}"}]
          )

        assert response.status == 200

        # Verify it's in archived list
        archived_response =
          make_api_request(
            "#{@tenant_path}/archived",
            nil,
            method: :get,
            headers: [{"authorization", "Bearer #{token}"}]
          )

        assert archived_response.status == 200
        archived_body = Jason.decode!(archived_response.resp_body)
        archived_ids = Enum.map(archived_body["data"], & &1["id"])
        assert comment.id in archived_ids
      end

      test "can unarchive own site's comment", %{site1: site1, tenant_admin1: tenant_admin1} do
        token = sign_in_tenant(tenant_admin1)

        comment = create_issue_comment!(site_id: site1.id)

        # Archive first
        make_api_request(
          "#{@tenant_path}/#{comment.id}/archive",
          nil,
          method: :delete,
          headers: [{"authorization", "Bearer #{token}"}]
        )

        # Unarchive
        response =
          make_api_request(
            "#{@tenant_path}/#{comment.id}/unarchive",
            %{"type" => "issue_comment", "id" => comment.id},
            method: :patch,
            headers: [{"authorization", "Bearer #{token}"}]
          )

        assert response.status == 200

        # Verify it's back in regular list
        list_response =
          make_api_request(
            @tenant_path,
            nil,
            method: :get,
            headers: [{"authorization", "Bearer #{token}"}]
          )

        list_body = Jason.decode!(list_response.resp_body)
        comment_ids = Enum.map(list_body["data"], & &1["id"])
        assert comment.id in comment_ids
      end

      test "CANNOT archive another site's comment", %{site2: site2, tenant_admin1: tenant_admin1} do
        token = sign_in_tenant(tenant_admin1)

        comment = create_issue_comment!(site_id: site2.id)

        response =
          make_api_request(
            "#{@tenant_path}/#{comment.id}/archive",
            nil,
            method: :delete,
            headers: [{"authorization", "Bearer #{token}"}]
          )

        assert response.status == 404
      end
    end

    describe "TENANT ADMIN - DELETE /v1/tenant/admin/mishka-document/issue-comment/:id/permanent (permanent delete)" do
      test "can permanently delete own site's comment", %{
        site1: site1,
        tenant_admin1: tenant_admin1
      } do
        token = sign_in_tenant(tenant_admin1)

        comment = create_issue_comment!(site_id: site1.id)

        response =
          make_api_request(
            "#{@tenant_path}/#{comment.id}/permanent",
            nil,
            method: :delete,
            headers: [{"authorization", "Bearer #{token}"}]
          )

        assert response.status == 200

        # Verify it's gone
        get_response =
          make_api_request(
            "#{@tenant_path}/#{comment.id}",
            nil,
            method: :get,
            headers: [{"authorization", "Bearer #{token}"}]
          )

        assert get_response.status == 404
      end

      test "CANNOT permanently delete another site's comment", %{
        site2: site2,
        tenant_admin1: tenant_admin1
      } do
        token = sign_in_tenant(tenant_admin1)

        comment = create_issue_comment!(site_id: site2.id)

        response =
          make_api_request(
            "#{@tenant_path}/#{comment.id}/permanent",
            nil,
            method: :delete,
            headers: [{"authorization", "Bearer #{token}"}]
          )

        assert response.status == 404
      end
    end

    describe "TENANT ADMIN - a comment a master wrote is read-only" do
      setup %{site1: site1, master_user: master_user, tenant_admin1: tenant_admin1} do
        %{
          comment: create_issue_comment!(site_id: site1.id, contributor_id: master_user.id),
          token: sign_in_tenant(tenant_admin1)
        }
      end

      test "CANNOT update it", %{comment: comment, token: token} do
        response =
          make_api_request(
            "#{@tenant_path}/#{comment.id}",
            %{
              "type" => "issue_comment",
              "id" => comment.id,
              "attributes" => %{"content" => "Rewritten by tenant"}
            },
            method: :patch,
            headers: [{"authorization", "Bearer #{token}"}]
          )

        assert_master_rule(response)
        assert stored(comment) == {comment.content, false}
      end

      test "CANNOT archive it", %{comment: comment, token: token} do
        response =
          make_api_request(
            "#{@tenant_path}/#{comment.id}/archive",
            nil,
            method: :delete,
            headers: [{"authorization", "Bearer #{token}"}]
          )

        assert_master_rule(response)
        assert stored(comment) == {comment.content, false}
      end

      test "CANNOT unarchive it", %{comment: comment, token: token} do
        Ash.destroy!(comment, action: :master_destroy, authorize?: false)

        response =
          make_api_request(
            "#{@tenant_path}/#{comment.id}/unarchive",
            %{"type" => "issue_comment", "id" => comment.id},
            method: :patch,
            headers: [{"authorization", "Bearer #{token}"}]
          )

        assert_master_rule(response)
        assert stored(comment) == {comment.content, true}
      end

      test "CANNOT permanently delete it", %{comment: comment, token: token} do
        response =
          make_api_request(
            "#{@tenant_path}/#{comment.id}/permanent",
            nil,
            method: :delete,
            headers: [{"authorization", "Bearer #{token}"}]
          )

        assert_master_rule(response)
        assert stored(comment) == {comment.content, false}
      end
    end

    describe "MASTER ADMIN - a comment a master wrote" do
      setup %{site1: site1, master_user: master_user} do
        %{
          comment: create_issue_comment!(site_id: site1.id, contributor_id: master_user.id),
          token: sign_in_master(master_user)
        }
      end

      test "can update it", %{comment: comment, token: token} do
        response =
          make_api_request(
            "#{@master_path}/#{comment.id}",
            %{
              "type" => "issue_comment",
              "id" => comment.id,
              "attributes" => %{"content" => "Rewritten by master"}
            },
            method: :patch,
            headers: [{"authorization", "Bearer #{token}"}, {"x-no-tenant", "true"}]
          )

        assert response.status == 200
        assert stored(comment) == {"Rewritten by master", false}
      end

      test "can permanently delete it", %{comment: comment, token: token} do
        response =
          make_api_request(
            "#{@master_path}/#{comment.id}/permanent",
            nil,
            method: :delete,
            headers: [{"authorization", "Bearer #{token}"}, {"x-no-tenant", "true"}]
          )

        assert response.status == 200
        assert stored(comment) == :gone
      end
    end

    defp assert_master_rule(response) do
      assert response.status == 400

      details =
        response.resp_body
        |> Jason.decode!()
        |> Map.fetch!("errors")
        |> Enum.map_join(" ", & &1["detail"])

      assert details =~ "written by a master admin"
    end

    defp stored(comment) do
      case Ash.get(MishkaDocument.IssueComment, comment.id,
             action: :master_get,
             authorize?: false
           ) do
        {:ok, row} -> {row.content, not is_nil(row.archived_at)}
        {:error, _not_found} -> :gone
      end
    end

    describe "JSON API Includes - Master Users" do
      test "master can include master_issue relationship to see issue title", %{
        site1: site1,
        master_user: master_user
      } do
        token = sign_in_master(master_user)

        issue = create_issue!(site_id: site1.id, title: "Master Issue Title")
        comment = create_issue_comment!(site_id: site1.id, issue_id: issue.id)

        response =
          make_api_request(
            "#{@master_path}/#{comment.id}?include=master_issue",
            nil,
            method: :get,
            headers: [{"authorization", "Bearer #{token}"}, {"x-no-tenant", "true"}]
          )

        assert response.status == 200
        body = Jason.decode!(response.resp_body)
        assert body["data"]["id"] == comment.id
        assert body["included"]

        included_issue = Enum.find(body["included"], &(&1["type"] == "issue"))
        assert included_issue["id"] == issue.id
        assert included_issue["attributes"]["title"] == "Master Issue Title"
      end

      test "master can include master_contributor relationship to see commenter details", %{
        site1: site1,
        master_user: master_user,
        tenant_admin1: tenant_admin1
      } do
        token = sign_in_master(master_user)

        comment = create_issue_comment!(site_id: site1.id, contributor_id: tenant_admin1.id)

        response =
          make_api_request(
            "#{@master_path}/#{comment.id}?include=master_contributor",
            nil,
            method: :get,
            headers: [{"authorization", "Bearer #{token}"}, {"x-no-tenant", "true"}]
          )

        assert response.status == 200
        body = Jason.decode!(response.resp_body)
        assert body["data"]["id"] == comment.id
        assert body["included"]

        included_contributor = Enum.find(body["included"], &(&1["type"] == "user"))
        assert included_contributor["id"] == tenant_admin1.id
        assert included_contributor["attributes"]["email"] == "admin1@example.com"
      end

      test "master can include both master_issue and master_contributor", %{
        site1: site1,
        master_user: master_user,
        tenant_admin1: tenant_admin1
      } do
        token = sign_in_master(master_user)

        issue = create_issue!(site_id: site1.id, title: "Master Multi-include")

        comment =
          create_issue_comment!(
            site_id: site1.id,
            issue_id: issue.id,
            contributor_id: tenant_admin1.id
          )

        response =
          make_api_request(
            "#{@master_path}/#{comment.id}?include=master_issue,master_contributor",
            nil,
            method: :get,
            headers: [{"authorization", "Bearer #{token}"}, {"x-no-tenant", "true"}]
          )

        assert response.status == 200
        body = Jason.decode!(response.resp_body)
        assert body["data"]["id"] == comment.id
        assert body["included"]
        assert length(body["included"]) >= 2

        included_issue = Enum.find(body["included"], &(&1["type"] == "issue"))
        assert included_issue["id"] == issue.id
        assert included_issue["attributes"]["title"] == "Master Multi-include"

        included_contributor = Enum.find(body["included"], &(&1["type"] == "user"))
        assert included_contributor["id"] == tenant_admin1.id
      end
    end

    describe "JSON API Includes - Tenant Users" do
      test "tenant can include issue relationship to see issue title", %{
        site1: site1,
        tenant_admin1: tenant_admin1
      } do
        token = sign_in_tenant(tenant_admin1)

        issue = create_issue!(site_id: site1.id, title: "Document Bug Report")
        comment = create_issue_comment!(site_id: site1.id, issue_id: issue.id)

        response =
          make_api_request(
            "#{@tenant_path}/#{comment.id}?include=issue",
            nil,
            method: :get,
            headers: [{"authorization", "Bearer #{token}"}]
          )

        assert response.status == 200
        body = Jason.decode!(response.resp_body)
        assert body["data"]["id"] == comment.id
        assert body["included"]

        included_issue = Enum.find(body["included"], &(&1["type"] == "issue"))
        assert included_issue["id"] == issue.id
        assert included_issue["attributes"]["title"] == "Document Bug Report"
      end

      test "tenant can include contributor relationship to see commenter details", %{
        site1: site1,
        tenant_admin1: tenant_admin1
      } do
        token = sign_in_tenant(tenant_admin1)

        comment = create_issue_comment!(site_id: site1.id, contributor_id: tenant_admin1.id)

        response =
          make_api_request(
            "#{@tenant_path}/#{comment.id}?include=contributor",
            nil,
            method: :get,
            headers: [{"authorization", "Bearer #{token}"}]
          )

        assert response.status == 200
        body = Jason.decode!(response.resp_body)
        assert body["data"]["id"] == comment.id
        assert body["included"]

        included_contributor = Enum.find(body["included"], &(&1["type"] == "user"))
        assert included_contributor["id"] == tenant_admin1.id
        assert included_contributor["attributes"]["email"] == "admin1@example.com"
      end

      test "tenant can include both issue and contributor", %{
        site1: site1,
        tenant_admin1: tenant_admin1
      } do
        token = sign_in_tenant(tenant_admin1)

        issue = create_issue!(site_id: site1.id, title: "Multi-include Test")

        comment =
          create_issue_comment!(
            site_id: site1.id,
            issue_id: issue.id,
            contributor_id: tenant_admin1.id
          )

        response =
          make_api_request(
            "#{@tenant_path}/#{comment.id}?include=issue,contributor",
            nil,
            method: :get,
            headers: [{"authorization", "Bearer #{token}"}]
          )

        assert response.status == 200
        body = Jason.decode!(response.resp_body)
        assert body["data"]["id"] == comment.id
        assert body["included"]
        assert length(body["included"]) >= 2

        included_issue = Enum.find(body["included"], &(&1["type"] == "issue"))
        assert included_issue["id"] == issue.id
        assert included_issue["attributes"]["title"] == "Multi-include Test"

        included_contributor = Enum.find(body["included"], &(&1["type"] == "user"))
        assert included_contributor["id"] == tenant_admin1.id
      end
    end
  end
end
