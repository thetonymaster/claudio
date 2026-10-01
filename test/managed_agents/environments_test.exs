Code.require_file("managed_agents_helper.exs", __DIR__)

defmodule Claudio.ManagedAgents.EnvironmentsTest do
  use ExUnit.Case, async: true

  import Claudio.ManagedAgentsTestSupport

  alias Claudio.ManagedAgents.Environments

  setup :setup_client

  @config %{"type" => "cloud", "networking" => %{"type" => "unrestricted"}}

  test "create posts the params", %{client: client, bypass: bypass} do
    expect_call(bypass, "POST", "/environments", %{"id" => "env_1"}, fn _c, _q, raw ->
      assert Jason.decode!(raw) == %{"name" => "default", "config" => @config}
    end)

    assert {:ok, %{"id" => "env_1"}} =
             Environments.create(client, %{name: "default", config: @config})
  end

  test "get", %{client: client, bypass: bypass} do
    expect_call(bypass, "GET", "/environments/env_1", %{"id" => "env_1", "state" => "active"})
    assert {:ok, %{"state" => "active"}} = Environments.get(client, "env_1")
  end

  test "update posts to the environment path", %{client: client, bypass: bypass} do
    expect_call(bypass, "POST", "/environments/env_1", %{"id" => "env_1"}, fn _c, _q, raw ->
      assert Jason.decode!(raw) == %{"description" => "d"}
    end)

    assert {:ok, _} = Environments.update(client, "env_1", %{description: "d"})
  end

  test "list encodes options", %{client: client, bypass: bypass} do
    expect_call(bypass, "GET", "/environments", %{"data" => []}, fn _c, query, _r ->
      assert query == [{"limit", "5"}, {"page", "page_abc"}]
    end)

    assert {:ok, %{"data" => []}} = Environments.list(client, limit: 5, page: "page_abc")
  end

  test "archive posts no body", %{client: client, bypass: bypass} do
    expect_call(bypass, "POST", "/environments/env_1/archive", %{"id" => "env_1"}, fn _c,
                                                                                      _q,
                                                                                      raw ->
      assert raw == ""
    end)

    assert {:ok, _} = Environments.archive(client, "env_1")
  end

  test "delete", %{client: client, bypass: bypass} do
    expect_call(bypass, "DELETE", "/environments/env_1", %{
      "id" => "env_1",
      "type" => "environment_deleted"
    })

    assert {:ok, %{"type" => "environment_deleted"}} = Environments.delete(client, "env_1")
  end

  test "an empty id raises FunctionClauseError", %{client: client} do
    assert_raise FunctionClauseError, fn -> Environments.delete(client, "") end
  end
end
