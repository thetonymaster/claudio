Code.require_file("managed_agents_helper.exs", __DIR__)

defmodule Claudio.ManagedAgents.HTTPTest do
  use ExUnit.Case, async: true

  import Claudio.ManagedAgentsTestSupport

  alias Claudio.APIError
  alias Claudio.ManagedAgents.HTTP

  describe "encode_query/1" do
    test "scalars become strings" do
      assert HTTP.encode_query(
               limit: 20,
               include_archived: true,
               order: :desc,
               agent_id: "agent_1"
             ) ==
               [
                 {"limit", "20"},
                 {"include_archived", "true"},
                 {"order", "desc"},
                 {"agent_id", "agent_1"}
               ]
    end

    test "a list repeats key[] in order" do
      assert HTTP.encode_query(statuses: ["idle", "running"]) ==
               [{"statuses[]", "idle"}, {"statuses[]", "running"}]
    end

    test "a keyword list becomes key[sub]" do
      assert HTTP.encode_query(
               created_at: [gte: "2026-09-01T00:00:00Z", lt: "2026-10-01T00:00:00Z"]
             ) ==
               [
                 {"created_at[gte]", "2026-09-01T00:00:00Z"},
                 {"created_at[lt]", "2026-10-01T00:00:00Z"}
               ]
    end

    test "DateTime values are ISO 8601, at top level and in keywords" do
      dt = ~U[2026-09-01 00:00:00Z]

      assert HTTP.encode_query(created_at: [gte: dt]) ==
               [{"created_at[gte]", "2026-09-01T00:00:00Z"}]

      assert HTTP.encode_query(since: dt) == [{"since", "2026-09-01T00:00:00Z"}]
    end

    test "mixed options keep their order" do
      assert HTTP.encode_query(statuses: ["idle"], created_at: [gte: "x"], limit: 1) ==
               [{"statuses[]", "idle"}, {"created_at[gte]", "x"}, {"limit", "1"}]
    end

    test "empty opts encode to []" do
      assert HTTP.encode_query([]) == []
    end

    test "nil raises, naming the option" do
      assert_raise ArgumentError, ~r/:page.*nil/, fn -> HTTP.encode_query(page: nil) end
    end

    test "an empty list raises (ambiguous filter)" do
      assert_raise ArgumentError, ~r/:statuses.*\[\]/, fn -> HTTP.encode_query(statuses: []) end
    end

    test "a map raises" do
      assert_raise ArgumentError, ~r/:filter/, fn -> HTTP.encode_query(filter: %{a: 1}) end
    end

    test "a nested list raises" do
      assert_raise ArgumentError, ~r/:statuses/, fn ->
        HTTP.encode_query(statuses: [["idle"]])
      end
    end

    test "a list inside a keyword raises" do
      assert_raise ArgumentError, ~r/:created_at/, fn ->
        HTTP.encode_query(created_at: [gte: ["x"]])
      end
    end

    test "nil inside a list or keyword raises" do
      assert_raise ArgumentError, ~r/:statuses/, fn ->
        HTTP.encode_query(statuses: ["idle", nil])
      end

      assert_raise ArgumentError, ~r/:created_at/, fn ->
        HTTP.encode_query(created_at: [gte: nil])
      end
    end
  end

  describe "segment/1 and is_id/1" do
    test "segment escapes everything outside the unreserved set" do
      assert HTTP.segment("agent_01Ab-c.d~e") == "agent_01Ab-c.d~e"
      assert HTTP.segment("a/b") == "a%2Fb"
      assert HTTP.segment("../x?y#z") == "..%2Fx%3Fy%23z"
    end

    test "is_id accepts non-empty binaries only" do
      import HTTP, only: [is_id: 1]
      check = fn x -> if is_id(x), do: true, else: false end
      assert check.("agent_1")
      refute check.("")
      refute check.(nil)
      refute check.(:agent_1)
    end
  end

  describe "transport" do
    setup :setup_client

    test "get sends the beta and the encoded query", %{client: client, bypass: bypass} do
      expect_call(bypass, "GET", "/sessions", %{"data" => []}, fn _conn, query, _raw ->
        assert query == [{"statuses[]", "idle"}, {"limit", "5"}]
      end)

      assert {:ok, %{"data" => []}} = HTTP.get(client, "sessions", statuses: ["idle"], limit: 5)
    end

    test "the beta is merged with the client's betas and deduped", %{bypass: bypass} do
      client =
        Claudio.Client.new(
          %{token: "t", version: "2023-06-01", beta: ["foo-2026-01-01", HTTP.beta()]},
          "http://localhost:#{bypass.port}/"
        )

      Bypass.expect_once(bypass, "GET", "/agents", fn conn ->
        assert Enum.sort(betas(conn)) == Enum.sort(["foo-2026-01-01", HTTP.beta()])
        json(conn, 200, %{"data" => []})
      end)

      assert {:ok, _} = HTTP.get(client, "agents", [])
    end

    test "post with a map sends JSON", %{client: client, bypass: bypass} do
      expect_call(bypass, "POST", "/agents", %{"id" => "agent_1"}, fn conn, _query, raw ->
        assert ["application/json" <> _] = Plug.Conn.get_req_header(conn, "content-type")
        assert Jason.decode!(raw) == %{"name" => "n", "model" => "m"}
      end)

      assert {:ok, %{"id" => "agent_1"}} = HTTP.post(client, "agents", %{name: "n", model: "m"})
    end

    test "post with nil sends no body", %{client: client, bypass: bypass} do
      expect_call(bypass, "POST", "/agents/agent_1/archive", %{"id" => "agent_1"}, fn _conn,
                                                                                      _query,
                                                                                      raw ->
        assert raw == ""
      end)

      assert {:ok, _} = HTTP.post(client, "agents/agent_1/archive", nil)
    end

    test "delete issues a DELETE", %{client: client, bypass: bypass} do
      expect_call(bypass, "DELETE", "/environments/env_1", %{"type" => "environment_deleted"})

      assert {:ok, %{"type" => "environment_deleted"}} =
               HTTP.delete(client, "environments/env_1")
    end

    test "a JSON error becomes an APIError", %{client: client, bypass: bypass} do
      Bypass.expect_once(bypass, "POST", "/agents/agent_1", fn conn ->
        json(conn, 409, %{
          "type" => "error",
          "error" => %{
            "type" => "invalid_request_error",
            "message" =>
              "Concurrent modification detected. Please fetch the latest version and retry."
          }
        })
      end)

      assert {:error,
              %APIError{
                status_code: 409,
                type: :invalid_request_error,
                message: "Concurrent" <> _
              }} = HTTP.post(client, "agents/agent_1", %{version: 1})
    end

    test "a non-JSON 5xx becomes an APIError", %{client: client, bypass: bypass} do
      client = Req.merge(client, retry: false)

      Bypass.expect_once(bypass, "GET", "/agents", fn conn ->
        Plug.Conn.resp(conn, 502, "<html>bad gateway</html>")
      end)

      assert {:error, %APIError{status_code: 502, type: :api_error}} =
               HTTP.get(client, "agents", [])
    end
  end
end
