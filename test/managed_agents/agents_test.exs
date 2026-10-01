Code.require_file("managed_agents_helper.exs", __DIR__)

defmodule Claudio.ManagedAgents.AgentsTest do
  use ExUnit.Case, async: true

  import Claudio.ManagedAgentsTestSupport

  alias Claudio.ManagedAgents.Agents

  setup :setup_client

  test "create posts the params", %{client: client, bypass: bypass} do
    expect_call(bypass, "POST", "/agents", %{"id" => "agent_1", "version" => 1}, fn _c, _q, raw ->
      assert Jason.decode!(raw) == %{"name" => "researcher", "model" => "claude-opus-5-5"}
    end)

    assert {:ok, %{"id" => "agent_1", "version" => 1}} =
             Agents.create(client, %{name: "researcher", model: "claude-opus-5-5"})
  end

  test "get without opts sends no query", %{client: client, bypass: bypass} do
    expect_call(bypass, "GET", "/agents/agent_1", %{"id" => "agent_1"}, fn _c, query, _r ->
      assert query == []
    end)

    assert {:ok, %{"id" => "agent_1"}} = Agents.get(client, "agent_1")
  end

  test "get with version: sends ?version=", %{client: client, bypass: bypass} do
    expect_call(bypass, "GET", "/agents/agent_1", %{"version" => 1}, fn _c, query, _r ->
      assert query == [{"version", "1"}]
    end)

    assert {:ok, %{"version" => 1}} = Agents.get(client, "agent_1", version: 1)
  end

  test "update posts to the agent path, version passed through", %{
    client: client,
    bypass: bypass
  } do
    expect_call(bypass, "POST", "/agents/agent_1", %{"version" => 2}, fn _c, _q, raw ->
      assert Jason.decode!(raw) == %{"version" => 1, "system" => "v2"}
    end)

    assert {:ok, %{"version" => 2}} =
             Agents.update(client, "agent_1", %{version: 1, system: "v2"})
  end

  test "list encodes options", %{client: client, bypass: bypass} do
    expect_call(bypass, "GET", "/agents", %{"data" => []}, fn _c, query, _r ->
      assert query == [{"include_archived", "true"}, {"limit", "10"}]
    end)

    assert {:ok, %{"data" => []}} = Agents.list(client, include_archived: true, limit: 10)
  end

  test "archive posts no body", %{client: client, bypass: bypass} do
    expect_call(bypass, "POST", "/agents/agent_1/archive", %{"archived_at" => "t"}, fn _c,
                                                                                       _q,
                                                                                       raw ->
      assert raw == ""
    end)

    assert {:ok, %{"archived_at" => "t"}} = Agents.archive(client, "agent_1")
  end

  test "list_versions hits the versions path", %{client: client, bypass: bypass} do
    expect_call(bypass, "GET", "/agents/agent_1/versions", %{"data" => []}, fn _c, query, _r ->
      assert query == [{"limit", "1"}]
    end)

    assert {:ok, %{"data" => []}} = Agents.list_versions(client, "agent_1", limit: 1)
  end

  test "ids are escaped as one path segment", %{client: client, bypass: bypass} do
    Bypass.expect_once(bypass, fn conn ->
      assert conn.request_path == "/agents/a%2Fb"

      json(conn, 404, %{
        "type" => "error",
        "error" => %{"type" => "not_found_error", "message" => "x"}
      })
    end)

    assert {:error, %Claudio.APIError{status_code: 404}} = Agents.get(client, "a/b")
  end

  test "an empty or non-binary id raises FunctionClauseError", %{client: client} do
    assert_raise FunctionClauseError, fn -> Agents.get(client, "") end
    assert_raise FunctionClauseError, fn -> Agents.archive(client, nil) end
  end
end
