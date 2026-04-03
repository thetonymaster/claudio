defmodule Claudio.MCP.ServerConfigTest do
  use ExUnit.Case, async: true

  alias Claudio.MCP.ServerConfig

  describe "new/2" do
    test "creates a server config with type, name, and url" do
      config = ServerConfig.new("my_server", "https://mcp.example.com/sse")

      assert config.type == "url"
      assert config.name == "my_server"
      assert config.url == "https://mcp.example.com/sse"
      assert config.authorization_token == nil
      assert config.tool_configuration == nil
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
    test "sets tool configuration with allowed patterns" do
      config =
        ServerConfig.new("my_server", "https://mcp.example.com")
        |> ServerConfig.allow_tools(["search_*", "fetch_data"])

      assert config.tool_configuration == %{
               "allowed_tools" => ["search_*", "fetch_data"],
               "enabled" => true
             }
    end
  end

  describe "to_map/1" do
    test "converts minimal config to map" do
      map =
        ServerConfig.new("my_server", "https://mcp.example.com")
        |> ServerConfig.to_map()

      assert map == %{
               "type" => "url",
               "name" => "my_server",
               "url" => "https://mcp.example.com"
             }
    end

    test "includes authorization_token when set" do
      map =
        ServerConfig.new("my_server", "https://mcp.example.com")
        |> ServerConfig.set_auth_token("token-123")
        |> ServerConfig.to_map()

      assert map["authorization_token"] == "token-123"
    end

    test "includes tool_configuration when set" do
      map =
        ServerConfig.new("my_server", "https://mcp.example.com")
        |> ServerConfig.allow_tools(["search_*"])
        |> ServerConfig.to_map()

      assert map["tool_configuration"] == %{
               "allowed_tools" => ["search_*"],
               "enabled" => true
             }
    end

    test "omits nil optional fields" do
      map =
        ServerConfig.new("my_server", "https://mcp.example.com")
        |> ServerConfig.to_map()

      refute Map.has_key?(map, "authorization_token")
      refute Map.has_key?(map, "tool_configuration")
    end
  end

  describe "fluent builder chain" do
    test "all setters chain correctly" do
      config =
        ServerConfig.new("full_server", "https://mcp.example.com/sse")
        |> ServerConfig.set_auth_token("bearer-token")
        |> ServerConfig.allow_tools(["tool_a", "tool_b"])

      map = ServerConfig.to_map(config)

      assert map == %{
               "type" => "url",
               "name" => "full_server",
               "url" => "https://mcp.example.com/sse",
               "authorization_token" => "bearer-token",
               "tool_configuration" => %{
                 "allowed_tools" => ["tool_a", "tool_b"],
                 "enabled" => true
               }
             }
    end
  end
end
