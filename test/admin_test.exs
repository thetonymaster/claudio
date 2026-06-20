defmodule Claudio.AdminTest do
  use ExUnit.Case, async: true

  alias Claudio.Admin

  setup do
    bypass = Bypass.open()

    client =
      Claudio.Client.new(
        %{token: "sk-ant-admin-fake", version: "2023-06-01"},
        "http://localhost:#{bypass.port}/"
      )

    {:ok, %{client: client, bypass: bypass}}
  end

  defp json(conn, status, body) do
    conn
    |> Plug.Conn.put_resp_content_type("application/json")
    |> Plug.Conn.resp(status, Jason.encode!(body))
  end

  defp read_json_body(conn) do
    {:ok, body, conn} = Plug.Conn.read_body(conn)
    {Jason.decode!(body), conn}
  end

  describe "organization + reads" do
    test "get_organization hits /organizations/me with the admin key", %{
      client: client,
      bypass: bypass
    } do
      Bypass.expect_once(bypass, "GET", "/organizations/me", fn conn ->
        assert Plug.Conn.get_req_header(conn, "x-api-key") == ["sk-ant-admin-fake"]
        json(conn, 200, %{"id" => "org_1", "type" => "organization", "name" => "Acme"})
      end)

      assert {:ok, %{"id" => "org_1", "type" => "organization"}} = Admin.get_organization(client)
    end

    test "list_users passes pagination query params", %{client: client, bypass: bypass} do
      Bypass.expect_once(bypass, "GET", "/organizations/users", fn conn ->
        params = URI.decode_query(conn.query_string)
        assert params["limit"] == "10"
        assert params["after_id"] == "user_x"
        json(conn, 200, %{"data" => [], "has_more" => false})
      end)

      assert {:ok, %{"data" => []}} = Admin.list_users(client, limit: 10, after_id: "user_x")
    end

    test "get_user fetches a single member", %{client: client, bypass: bypass} do
      Bypass.expect_once(bypass, "GET", "/organizations/users/user_1", fn conn ->
        json(conn, 200, %{"id" => "user_1", "type" => "user", "role" => "developer"})
      end)

      assert {:ok, %{"id" => "user_1", "role" => "developer"}} = Admin.get_user(client, "user_1")
    end

    test "list_api_keys passes status and workspace_id filters", %{client: client, bypass: bypass} do
      Bypass.expect_once(bypass, "GET", "/organizations/api_keys", fn conn ->
        params = URI.decode_query(conn.query_string)
        assert params["status"] == "active"
        assert params["workspace_id"] == "wrkspc_1"
        json(conn, 200, %{"data" => [], "has_more" => false})
      end)

      assert {:ok, _} = Admin.list_api_keys(client, status: "active", workspace_id: "wrkspc_1")
    end

    test "list_workspaces / get_workspace / list_invites / get_invite / get_api_key", %{
      client: client,
      bypass: bypass
    } do
      Bypass.expect(bypass, fn conn ->
        case {conn.method, conn.request_path} do
          {"GET", "/organizations/workspaces"} -> json(conn, 200, %{"data" => []})
          {"GET", "/organizations/workspaces/w1"} -> json(conn, 200, %{"id" => "w1"})
          {"GET", "/organizations/invites"} -> json(conn, 200, %{"data" => []})
          {"GET", "/organizations/invites/i1"} -> json(conn, 200, %{"id" => "i1"})
          {"GET", "/organizations/api_keys/k1"} -> json(conn, 200, %{"id" => "k1"})
        end
      end)

      assert {:ok, %{"data" => []}} = Admin.list_workspaces(client)
      assert {:ok, %{"id" => "w1"}} = Admin.get_workspace(client, "w1")
      assert {:ok, %{"data" => []}} = Admin.list_invites(client)
      assert {:ok, %{"id" => "i1"}} = Admin.get_invite(client, "i1")
      assert {:ok, %{"id" => "k1"}} = Admin.get_api_key(client, "k1")
    end
  end

  describe "writes" do
    test "update_user POSTs the role body", %{client: client, bypass: bypass} do
      Bypass.expect_once(bypass, "POST", "/organizations/users/user_1", fn conn ->
        {body, conn} = read_json_body(conn)
        assert body == %{"role" => "billing"}
        json(conn, 200, %{"id" => "user_1", "role" => "billing"})
      end)

      assert {:ok, %{"role" => "billing"}} =
               Admin.update_user(client, "user_1", %{"role" => "billing"})
    end

    test "remove_user issues a DELETE", %{client: client, bypass: bypass} do
      Bypass.expect_once(bypass, "DELETE", "/organizations/users/user_1", fn conn ->
        json(conn, 200, %{"id" => "user_1", "type" => "user_deleted"})
      end)

      assert {:ok, %{"type" => "user_deleted"}} = Admin.remove_user(client, "user_1")
    end

    test "create_invite POSTs email and role", %{client: client, bypass: bypass} do
      Bypass.expect_once(bypass, "POST", "/organizations/invites", fn conn ->
        {body, conn} = read_json_body(conn)
        assert body == %{"email" => "new@acme.com", "role" => "developer"}
        json(conn, 200, %{"id" => "invite_1", "type" => "invite"})
      end)

      assert {:ok, %{"id" => "invite_1"}} =
               Admin.create_invite(client, %{"email" => "new@acme.com", "role" => "developer"})
    end

    test "delete_invite issues a DELETE", %{client: client, bypass: bypass} do
      Bypass.expect_once(bypass, "DELETE", "/organizations/invites/i1", fn conn ->
        json(conn, 200, %{"id" => "i1", "type" => "invite_deleted"})
      end)

      assert {:ok, %{"type" => "invite_deleted"}} = Admin.delete_invite(client, "i1")
    end

    test "create_workspace POSTs the name", %{client: client, bypass: bypass} do
      Bypass.expect_once(bypass, "POST", "/organizations/workspaces", fn conn ->
        {body, conn} = read_json_body(conn)
        assert body == %{"name" => "Prod"}
        json(conn, 200, %{"id" => "w1", "name" => "Prod"})
      end)

      assert {:ok, %{"name" => "Prod"}} = Admin.create_workspace(client, %{"name" => "Prod"})
    end

    test "update_workspace POSTs to the workspace id", %{client: client, bypass: bypass} do
      Bypass.expect_once(bypass, "POST", "/organizations/workspaces/w1", fn conn ->
        {body, conn} = read_json_body(conn)
        assert body == %{"name" => "Renamed"}
        json(conn, 200, %{"id" => "w1", "name" => "Renamed"})
      end)

      assert {:ok, %{"name" => "Renamed"}} =
               Admin.update_workspace(client, "w1", %{"name" => "Renamed"})
    end

    test "archive_workspace POSTs to /archive with an empty body", %{client: client, bypass: bypass} do
      Bypass.expect_once(bypass, "POST", "/organizations/workspaces/w1/archive", fn conn ->
        {body, conn} = read_json_body(conn)
        assert body == %{}
        json(conn, 200, %{"id" => "w1", "archived_at" => "2026-06-19T00:00:00Z"})
      end)

      assert {:ok, %{"archived_at" => _}} = Admin.archive_workspace(client, "w1")
    end

    test "update_api_key POSTs status/name", %{client: client, bypass: bypass} do
      Bypass.expect_once(bypass, "POST", "/organizations/api_keys/k1", fn conn ->
        {body, conn} = read_json_body(conn)
        assert body == %{"status" => "inactive"}
        json(conn, 200, %{"id" => "k1", "status" => "inactive"})
      end)

      assert {:ok, %{"status" => "inactive"}} =
               Admin.update_api_key(client, "k1", %{"status" => "inactive"})
    end
  end

  describe "usage + cost reports" do
    test "usage_report passes query params to /usage_report/messages", %{
      client: client,
      bypass: bypass
    } do
      Bypass.expect_once(bypass, "GET", "/organizations/usage_report/messages", fn conn ->
        params = URI.decode_query(conn.query_string)
        assert params["starting_at"] == "2026-06-01T00:00:00Z"
        json(conn, 200, %{"data" => []})
      end)

      assert {:ok, %{"data" => []}} =
               Admin.usage_report(client, starting_at: "2026-06-01T00:00:00Z")
    end

    test "cost_report hits /cost_report", %{client: client, bypass: bypass} do
      Bypass.expect_once(bypass, "GET", "/organizations/cost_report", fn conn ->
        json(conn, 200, %{"data" => []})
      end)

      assert {:ok, %{"data" => []}} = Admin.cost_report(client)
    end
  end

  describe "error handling" do
    test "maps a 401 to Claudio.APIError", %{client: client, bypass: bypass} do
      Bypass.expect_once(bypass, "GET", "/organizations/me", fn conn ->
        json(conn, 401, %{
          "type" => "error",
          "error" => %{"type" => "authentication_error", "message" => "invalid admin key"}
        })
      end)

      assert {:error, %Claudio.APIError{status_code: 401, type: :authentication_error}} =
               Admin.get_organization(client)
    end
  end
end
