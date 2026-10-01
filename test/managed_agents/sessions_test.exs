Code.require_file("managed_agents_helper.exs", __DIR__)

defmodule Claudio.ManagedAgents.SessionsTest do
  use ExUnit.Case, async: true

  import Claudio.ManagedAgentsTestSupport

  alias Claudio.ManagedAgents.Sessions

  setup :setup_client

  describe "sessions" do
    test "create posts the params", %{client: client, bypass: bypass} do
      expect_call(bypass, "POST", "/sessions", %{"id" => "sesn_1", "status" => "idle"}, fn _c,
                                                                                           _q,
                                                                                           raw ->
        assert Jason.decode!(raw) == %{"agent" => "agent_1", "environment_id" => "env_1"}
      end)

      assert {:ok, %{"status" => "idle"}} =
               Sessions.create(client, %{agent: "agent_1", environment_id: "env_1"})
    end

    test "get", %{client: client, bypass: bypass} do
      expect_call(bypass, "GET", "/sessions/sesn_1", %{"id" => "sesn_1"})
      assert {:ok, %{"id" => "sesn_1"}} = Sessions.get(client, "sesn_1")
    end

    test "update posts to the session path", %{client: client, bypass: bypass} do
      expect_call(bypass, "POST", "/sessions/sesn_1", %{"title" => "t"}, fn _c, _q, raw ->
        assert Jason.decode!(raw) == %{"title" => "t", "metadata" => %{"k" => "v"}}
      end)

      assert {:ok, %{"title" => "t"}} =
               Sessions.update(client, "sesn_1", %{title: "t", metadata: %{k: "v"}})
    end

    test "list encodes bracketed filters", %{client: client, bypass: bypass} do
      expect_call(bypass, "GET", "/sessions", %{"data" => []}, fn _c, query, _r ->
        assert query == [
                 {"statuses[]", "idle"},
                 {"statuses[]", "running"},
                 {"created_at[gte]", "2026-09-01T00:00:00Z"},
                 {"agent_id", "agent_1"}
               ]
      end)

      assert {:ok, _} =
               Sessions.list(client,
                 statuses: ["idle", "running"],
                 created_at: [gte: ~U[2026-09-01 00:00:00Z]],
                 agent_id: "agent_1"
               )
    end

    test "archive posts no body; delete issues DELETE", %{client: client, bypass: bypass} do
      expect_call(bypass, "POST", "/sessions/sesn_1/archive", %{"id" => "sesn_1"}, fn _c,
                                                                                      _q,
                                                                                      raw ->
        assert raw == ""
      end)

      expect_call(bypass, "DELETE", "/sessions/sesn_1", %{"type" => "session_deleted"})

      assert {:ok, _} = Sessions.archive(client, "sesn_1")
      assert {:ok, %{"type" => "session_deleted"}} = Sessions.delete(client, "sesn_1")
    end
  end

  describe "events" do
    test "send_events wraps the list in an events body", %{client: client, bypass: bypass} do
      event = %{type: "user.message", content: [%{type: "text", text: "Hi"}]}

      expect_call(bypass, "POST", "/sessions/sesn_1/events", %{"data" => []}, fn _c, _q, raw ->
        assert Jason.decode!(raw) == %{
                 "events" => [
                   %{
                     "type" => "user.message",
                     "content" => [%{"type" => "text", "text" => "Hi"}]
                   }
                 ]
               }
      end)

      assert {:ok, _} = Sessions.send_events(client, "sesn_1", [event])
    end

    test "send_events with a non-list raises ArgumentError naming the function", %{
      client: client
    } do
      assert_raise ArgumentError, ~r/send_events\/3.*%\{type: "user.message"\}/, fn ->
        Sessions.send_events(client, "sesn_1", %{type: "user.message"})
      end
    end

    test "list_events encodes types[] and order", %{client: client, bypass: bypass} do
      expect_call(bypass, "GET", "/sessions/sesn_1/events", %{"data" => []}, fn _c, query, _r ->
        assert query == [{"types[]", "agent.message"}, {"order", "desc"}, {"limit", "10"}]
      end)

      assert {:ok, %{"data" => []}} =
               Sessions.list_events(client, "sesn_1",
                 types: ["agent.message"],
                 order: :desc,
                 limit: 10
               )
    end
  end

  describe "resources" do
    test "add_resource posts the resource", %{client: client, bypass: bypass} do
      expect_call(bypass, "POST", "/sessions/sesn_1/resources", %{"id" => "sesrsc_1"}, fn _c,
                                                                                          _q,
                                                                                          raw ->
        assert Jason.decode!(raw) == %{"type" => "file", "file_id" => "file_1"}
      end)

      assert {:ok, %{"id" => "sesrsc_1"}} =
               Sessions.add_resource(client, "sesn_1", %{type: "file", file_id: "file_1"})
    end

    test "list_resources / get_resource", %{client: client, bypass: bypass} do
      expect_call(bypass, "GET", "/sessions/sesn_1/resources", %{"data" => []})
      expect_call(bypass, "GET", "/sessions/sesn_1/resources/sesrsc_1", %{"id" => "sesrsc_1"})

      assert {:ok, %{"data" => []}} = Sessions.list_resources(client, "sesn_1")
      assert {:ok, %{"id" => "sesrsc_1"}} = Sessions.get_resource(client, "sesn_1", "sesrsc_1")
    end

    test "update_resource posts the params", %{client: client, bypass: bypass} do
      expect_call(
        bypass,
        "POST",
        "/sessions/sesn_1/resources/sesrsc_1",
        %{"id" => "sesrsc_1"},
        fn _c, _q, raw ->
          assert Jason.decode!(raw) == %{"authorization_token" => "ghp_x"}
        end
      )

      assert {:ok, _} =
               Sessions.update_resource(client, "sesn_1", "sesrsc_1", %{
                 authorization_token: "ghp_x"
               })
    end

    test "delete_resource", %{client: client, bypass: bypass} do
      expect_call(bypass, "DELETE", "/sessions/sesn_1/resources/sesrsc_1", %{
        "type" => "session_resource_deleted"
      })

      assert {:ok, %{"type" => "session_resource_deleted"}} =
               Sessions.delete_resource(client, "sesn_1", "sesrsc_1")
    end

    test "an empty resource id raises FunctionClauseError", %{client: client} do
      assert_raise FunctionClauseError, fn -> Sessions.get_resource(client, "sesn_1", "") end
    end
  end
end
