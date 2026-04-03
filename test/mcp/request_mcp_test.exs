defmodule Claudio.Messages.Request.MCPTest do
  use ExUnit.Case, async: true

  alias Claudio.Messages.Request
  alias Claudio.MCP.ServerConfig

  describe "add_mcp_server/2 with ServerConfig" do
    test "accepts a ServerConfig struct and converts to map" do
      server = ServerConfig.new("my_server", "https://mcp.example.com/sse")

      request =
        Request.new("claude-sonnet-4-5-20250929")
        |> Request.add_mcp_server(server)

      map = Request.to_map(request)
      [server_map] = map["mcp_servers"]

      assert server_map["type"] == "url"
      assert server_map["name"] == "my_server"
      assert server_map["url"] == "https://mcp.example.com/sse"
    end

    test "accepts a raw map (backward compat)" do
      request =
        Request.new("claude-sonnet-4-5-20250929")
        |> Request.add_mcp_server(%{"name" => "raw", "url" => "http://localhost"})

      map = Request.to_map(request)
      [server_map] = map["mcp_servers"]

      assert server_map["name"] == "raw"
    end

    test "mixes ServerConfig and raw maps" do
      server = ServerConfig.new("typed", "https://mcp.example.com")

      request =
        Request.new("claude-sonnet-4-5-20250929")
        |> Request.add_mcp_server(server)
        |> Request.add_mcp_server(%{"name" => "raw", "url" => "http://localhost"})

      map = Request.to_map(request)
      assert length(map["mcp_servers"]) == 2
    end

    test "ServerConfig with auth token and tool config" do
      server =
        ServerConfig.new("secure", "https://mcp.example.com")
        |> ServerConfig.set_auth_token("my-token")
        |> ServerConfig.allow_tools(["search_*"])

      request =
        Request.new("claude-sonnet-4-5-20250929")
        |> Request.add_mcp_server(server)

      map = Request.to_map(request)
      [server_map] = map["mcp_servers"]

      assert server_map["authorization_token"] == "my-token"
      assert server_map["tool_configuration"]["allowed_tools"] == ["search_*"]
    end
  end
end
