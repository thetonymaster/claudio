defmodule Claudio.Messages.Request.MCPTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias Claudio.Messages.Request
  alias Claudio.MCP.ServerConfig

  @beta "mcp-client-2025-11-20"

  describe "add_mcp_server/2 with ServerConfig" do
    test "adds the server entry, a matching toolset, and the beta" do
      server = ServerConfig.new("my_server", "https://mcp.example.com/sse")

      request = Request.new("claude-opus-5") |> Request.add_mcp_server(server)
      map = Request.to_map(request)

      assert map["mcp_servers"] == [
               %{"type" => "url", "name" => "my_server", "url" => "https://mcp.example.com/sse"}
             ]

      assert map["tools"] == [%{"type" => "mcp_toolset", "mcp_server_name" => "my_server"}]
      assert Request.required_betas(request) == [@beta]
    end

    test "auth token stays on the server; allowlist goes on the toolset" do
      server =
        ServerConfig.new("secure", "https://mcp.example.com")
        |> ServerConfig.set_auth_token("my-token")
        |> ServerConfig.allow_tools(["search_events"])

      map = Request.new("claude-opus-5") |> Request.add_mcp_server(server) |> Request.to_map()

      [server_map] = map["mcp_servers"]
      assert server_map["authorization_token"] == "my-token"
      refute Map.has_key?(server_map, "tool_configuration")

      assert [
               %{
                 "type" => "mcp_toolset",
                 "mcp_server_name" => "secure",
                 "default_config" => %{"enabled" => false},
                 "configs" => %{"search_events" => %{"enabled" => true}}
               }
             ] = map["tools"]
    end

    test "rejects a second server with the same name" do
      assert_raise ArgumentError, ~r/already has an MCP server named "a"/, fn ->
        Request.new("claude-opus-5-5")
        |> Request.add_mcp_server(ServerConfig.new("a", "https://a.example.com"))
        |> Request.add_mcp_server(ServerConfig.new("a", "https://other.example.com"))
      end
    end

    test "rejects a raw map whose name matches an existing atom-keyed server" do
      assert_raise ArgumentError, ~r/already has an MCP server named "a"/, fn ->
        Request.new("claude-opus-5-5")
        |> Request.add_mcp_server(%{type: "url", name: "a", url: "https://a.example.com"})
        |> Request.add_mcp_server(%{"type" => "url", "name" => "a", "url" => "https://b"})
      end
    end

    test "two servers -> two toolsets, beta declared once" do
      request =
        Request.new("claude-opus-5")
        |> Request.add_mcp_server(ServerConfig.new("a", "https://a.example.com"))
        |> Request.add_mcp_server(ServerConfig.new("b", "https://b.example.com"))

      map = Request.to_map(request)
      assert length(map["mcp_servers"]) == 2
      assert Enum.map(map["tools"], & &1["mcp_server_name"]) == ["a", "b"]
      assert Request.required_betas(request) == [@beta]
    end

    test "toolset is appended after tools already on the request" do
      map =
        Request.new("claude-opus-5")
        |> Request.add_tool(%{"name" => "local", "input_schema" => %{"type" => "object"}})
        |> Request.add_mcp_server(ServerConfig.new("s", "https://x.example.com"))
        |> Request.to_map()

      assert [%{"name" => "local"}, %{"type" => "mcp_toolset"}] = map["tools"]
    end

    test "raises instead of dropping config when a toolset already exists (struct path)" do
      assert_raise ArgumentError, ~r/already has an mcp_toolset for "s"/, fn ->
        Request.new("claude-opus-5")
        |> Request.add_tool(%{"type" => "mcp_toolset", "mcp_server_name" => "s"})
        |> Request.add_mcp_server(
          ServerConfig.new("s", "https://x")
          |> ServerConfig.allow_tools(["only_this"])
        )
      end
    end
  end

  describe "add_mcp_server/2 with a raw map" do
    test "string-keyed map gets a toolset and the beta" do
      request =
        Request.new("claude-opus-5")
        |> Request.add_mcp_server(%{"type" => "url", "name" => "raw", "url" => "https://x"})

      map = Request.to_map(request)
      assert [%{"name" => "raw"}] = map["mcp_servers"]
      assert map["tools"] == [%{"type" => "mcp_toolset", "mcp_server_name" => "raw"}]
      assert Request.required_betas(request) == [@beta]
    end

    test "atom-keyed raw map gets a toolset for :name" do
      map =
        Request.new("claude-opus-5")
        |> Request.add_mcp_server(%{type: "url", name: "atomy", url: "https://x"})
        |> Request.to_map()

      assert map["tools"] == [%{"type" => "mcp_toolset", "mcp_server_name" => "atomy"}]
    end

    test "does not duplicate a hand-built toolset for the same server" do
      hand_built = %{
        "type" => "mcp_toolset",
        "mcp_server_name" => "raw",
        "default_config" => %{"defer_loading" => true}
      }

      map =
        Request.new("claude-opus-5")
        |> Request.add_tool(hand_built)
        |> Request.add_mcp_server(%{"type" => "url", "name" => "raw", "url" => "https://x"})
        |> Request.to_map()

      assert map["tools"] == [hand_built]
    end

    test "raises instead of dropping translated legacy config when a toolset already exists" do
      capture_log(fn ->
        assert_raise ArgumentError, ~r/already has an mcp_toolset for "raw"/, fn ->
          Request.new("claude-opus-5")
          |> Request.add_tool(%{"type" => "mcp_toolset", "mcp_server_name" => "raw"})
          |> Request.add_mcp_server(%{
            "name" => "raw",
            "url" => "https://x",
            "tool_configuration" => %{"allowed_tools" => ["a"]}
          })
        end
      end)
    end

    test "legacy tool_configuration is translated, stripped, and warned about" do
      log =
        capture_log(fn ->
          map =
            Request.new("claude-opus-5")
            |> Request.add_mcp_server(%{
              "type" => "url",
              "name" => "legacy",
              "url" => "https://x",
              "tool_configuration" => %{"enabled" => true, "allowed_tools" => ["a"]}
            })
            |> Request.to_map()

          [server_map] = map["mcp_servers"]
          refute Map.has_key?(server_map, "tool_configuration")

          assert map["tools"] == [
                   %{
                     "type" => "mcp_toolset",
                     "mcp_server_name" => "legacy",
                     "default_config" => %{"enabled" => false},
                     "configs" => %{"a" => %{"enabled" => true}}
                   }
                 ]
        end)

      assert log =~ "tool_configuration is deprecated"
    end

    test "raw map without a name raises" do
      assert_raise ArgumentError, ~r/needs a "name" key/, fn ->
        Request.new("claude-opus-5") |> Request.add_mcp_server(%{"url" => "https://x"})
      end
    end

    test "mixes ServerConfig and raw maps" do
      map =
        Request.new("claude-opus-5")
        |> Request.add_mcp_server(ServerConfig.new("typed", "https://mcp.example.com"))
        |> Request.add_mcp_server(%{"name" => "raw", "url" => "https://x"})
        |> Request.to_map()

      assert length(map["mcp_servers"]) == 2
      assert Enum.map(map["tools"], & &1["mcp_server_name"]) == ["typed", "raw"]
    end
  end
end
