defmodule Claudio.MCP.ServerConfigTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias Claudio.MCP.ServerConfig

  describe "new/2" do
    test "creates a server config with type, name, and url" do
      config = ServerConfig.new("my_server", "https://mcp.example.com/sse")

      assert config.type == "url"
      assert config.name == "my_server"
      assert config.url == "https://mcp.example.com/sse"
      assert config.authorization_token == nil
      assert config.default_config == nil
      assert config.configs == nil
      refute Map.has_key?(config, :tool_configuration)
    end
  end

  describe "set_auth_token/2" do
    test "sets the authorization token" do
      config =
        ServerConfig.new("my_server", "https://mcp.example.com")
        |> ServerConfig.set_auth_token("my-token")

      assert config.authorization_token == "my-token"
    end
  end

  describe "allow_tools/2" do
    test "disables by default and enables each named tool" do
      config =
        ServerConfig.new("s", "https://mcp.example.com")
        |> ServerConfig.allow_tools(["search_events", "fetch_data"])

      assert config.default_config == %{"enabled" => false}

      assert config.configs == %{
               "search_events" => %{"enabled" => true},
               "fetch_data" => %{"enabled" => true}
             }
    end

    test "empty allowlist disables everything and emits no configs key" do
      toolset =
        ServerConfig.new("s", "https://mcp.example.com")
        |> ServerConfig.allow_tools([])
        |> ServerConfig.to_toolset()

      assert toolset == %{
               "type" => "mcp_toolset",
               "mcp_server_name" => "s",
               "default_config" => %{"enabled" => false}
             }
    end

    test "raises on a * pattern, naming the pattern" do
      error =
        assert_raise ArgumentError, fn ->
          ServerConfig.new("s", "https://x") |> ServerConfig.allow_tools(["search_*"])
        end

      assert error.message ==
               "MCP allow_tools/2 takes exact tool names; got pattern \"search_*\". " <>
                 "The mcp-client-2025-11-20 connector matches configs keys literally, " <>
                 "so a pattern would silently enable no tools."
    end

    test "raises on a ? pattern" do
      assert_raise ArgumentError, ~r/got pattern "tool_\?"/, fn ->
        ServerConfig.new("s", "https://x") |> ServerConfig.allow_tools(["tool_?"])
      end
    end

    test "raises on a non-string name" do
      assert_raise ArgumentError, ~r/takes tool name strings; got :search/, fn ->
        ServerConfig.new("s", "https://x") |> ServerConfig.allow_tools([:search])
      end
    end
  end

  describe "set_default_config/2 and configure_tool/3" do
    test "merge into existing config" do
      config =
        ServerConfig.new("s", "https://x")
        |> ServerConfig.allow_tools(["a"])
        |> ServerConfig.set_default_config(%{"defer_loading" => true})
        |> ServerConfig.configure_tool("a", %{"defer_loading" => false})
        |> ServerConfig.configure_tool("b", %{"enabled" => false})

      assert config.default_config == %{"enabled" => false, "defer_loading" => true}

      assert config.configs == %{
               "a" => %{"enabled" => true, "defer_loading" => false},
               "b" => %{"enabled" => false}
             }
    end
  end

  describe "to_map/1" do
    test "converts minimal config to the server entry" do
      map = ServerConfig.new("my_server", "https://mcp.example.com") |> ServerConfig.to_map()

      assert map == %{"type" => "url", "name" => "my_server", "url" => "https://mcp.example.com"}
    end

    test "includes authorization_token when set" do
      map =
        ServerConfig.new("my_server", "https://mcp.example.com")
        |> ServerConfig.set_auth_token("token-123")
        |> ServerConfig.to_map()

      assert map["authorization_token"] == "token-123"
    end

    test "never includes tool configuration (it lives on the toolset)" do
      map =
        ServerConfig.new("my_server", "https://mcp.example.com")
        |> ServerConfig.allow_tools(["search"])
        |> ServerConfig.to_map()

      refute Map.has_key?(map, "tool_configuration")
      refute Map.has_key?(map, "default_config")
      refute Map.has_key?(map, "configs")
    end
  end

  describe "to_toolset/1" do
    test "bare toolset when nothing is configured" do
      assert ServerConfig.new("s", "https://x") |> ServerConfig.to_toolset() ==
               %{"type" => "mcp_toolset", "mcp_server_name" => "s"}
    end

    test "allowlist toolset" do
      assert ServerConfig.new("s", "https://x")
             |> ServerConfig.allow_tools(["a"])
             |> ServerConfig.to_toolset() == %{
               "type" => "mcp_toolset",
               "mcp_server_name" => "s",
               "default_config" => %{"enabled" => false},
               "configs" => %{"a" => %{"enabled" => true}}
             }
    end
  end

  describe "split_raw/1" do
    test "plain raw map yields the map and a bare toolset" do
      assert ServerConfig.split_raw(%{"type" => "url", "name" => "raw", "url" => "https://x"}) ==
               {%{"type" => "url", "name" => "raw", "url" => "https://x"},
                %{"type" => "mcp_toolset", "mcp_server_name" => "raw"}}
    end

    test "atom-keyed raw map uses :name" do
      {server, toolset} = ServerConfig.split_raw(%{name: "atomy", url: "https://x"})
      assert server == %{name: "atomy", url: "https://x"}
      assert toolset == %{"type" => "mcp_toolset", "mcp_server_name" => "atomy"}
    end

    test "raises when the map has no name" do
      assert_raise ArgumentError, ~r/needs a "name" key/, fn ->
        ServerConfig.split_raw(%{"url" => "https://x"})
      end
    end

    test "legacy enabled: true with no allowlist -> bare toolset, field stripped, warning logged" do
      log =
        capture_log(fn ->
          {server, toolset} =
            ServerConfig.split_raw(%{
              "name" => "s",
              "url" => "https://x",
              "tool_configuration" => %{"enabled" => true}
            })

          assert server == %{"name" => "s", "url" => "https://x"}
          assert toolset == %{"type" => "mcp_toolset", "mcp_server_name" => "s"}
        end)

      assert log =~ "tool_configuration is deprecated"
    end

    test "legacy enabled: false -> default_config disabled (allowlist ignored)" do
      capture_log(fn ->
        {_server, toolset} =
          ServerConfig.split_raw(%{
            "name" => "s",
            "url" => "https://x",
            "tool_configuration" => %{"enabled" => false, "allowed_tools" => ["a"]}
          })

        assert toolset == %{
                 "type" => "mcp_toolset",
                 "mcp_server_name" => "s",
                 "default_config" => %{"enabled" => false}
               }
      end)
    end

    test "legacy allowed_tools -> allowlist toolset" do
      capture_log(fn ->
        {_server, toolset} =
          ServerConfig.split_raw(%{
            "name" => "s",
            "url" => "https://x",
            "tool_configuration" => %{"enabled" => true, "allowed_tools" => ["a", "b"]}
          })

        assert toolset == %{
                 "type" => "mcp_toolset",
                 "mcp_server_name" => "s",
                 "default_config" => %{"enabled" => false},
                 "configs" => %{"a" => %{"enabled" => true}, "b" => %{"enabled" => true}}
               }
      end)
    end

    test "strips both string and atom tool_configuration keys; string key wins" do
      capture_log(fn ->
        {server, toolset} =
          ServerConfig.split_raw(%{
            "name" => "s",
            "url" => "https://x",
            "tool_configuration" => %{"allowed_tools" => ["from_string"]},
            :tool_configuration => %{allowed_tools: ["from_atom"]}
          })

        assert server == %{"name" => "s", "url" => "https://x"}
        assert toolset["configs"] == %{"from_string" => %{"enabled" => true}}
      end)
    end

    test "legacy allowed_tools with a pattern raises" do
      capture_log(fn ->
        assert_raise ArgumentError, ~r/got pattern "search_\*"/, fn ->
          ServerConfig.split_raw(%{
            "name" => "s",
            "url" => "https://x",
            "tool_configuration" => %{"allowed_tools" => ["search_*"]}
          })
        end
      end)
    end
  end
end
