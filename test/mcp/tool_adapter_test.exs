defmodule Claudio.MCP.ToolAdapterTest do
  use ExUnit.Case, async: true

  alias Claudio.MCP.ToolAdapter
  alias Claudio.MCP.Client.Tool
  alias Claudio.Messages.Request

  @tools [
    %Tool{
      name: "search",
      description: "Search documents",
      input_schema: %{
        "type" => "object",
        "properties" => %{"query" => %{"type" => "string"}},
        "required" => ["query"]
      }
    },
    %Tool{
      name: "fetch",
      description: "Fetch a URL",
      input_schema: %{"type" => "object"}
    }
  ]

  describe "add_tools/3" do
    test "adds MCP tools to a request" do
      request =
        Request.new("claude-sonnet-4-5-20250929")
        |> ToolAdapter.add_tools(@tools)

      map = Request.to_map(request)
      tools = map["tools"]

      assert length(tools) == 2
      assert Enum.at(tools, 0)["name"] == "search"
      assert Enum.at(tools, 1)["name"] == "fetch"
    end

    test "adds prefix to tool names" do
      request =
        Request.new("claude-sonnet-4-5-20250929")
        |> ToolAdapter.add_tools(@tools, prefix: "my_server")

      map = Request.to_map(request)
      tools = map["tools"]

      assert Enum.at(tools, 0)["name"] == "my_server__search"
      assert Enum.at(tools, 1)["name"] == "my_server__fetch"
    end

    test "preserves input_schema" do
      request =
        Request.new("claude-sonnet-4-5-20250929")
        |> ToolAdapter.add_tools(@tools)

      map = Request.to_map(request)
      tool = hd(map["tools"])

      assert tool["input_schema"]["type"] == "object"
      assert tool["input_schema"]["required"] == ["query"]
    end
  end

  describe "to_claudio_tool/2" do
    test "converts a Tool struct to map format" do
      tool = hd(@tools)
      result = ToolAdapter.to_claudio_tool(tool)

      assert result == %{
               "name" => "search",
               "description" => "Search documents",
               "input_schema" => %{
                 "type" => "object",
                 "properties" => %{"query" => %{"type" => "string"}},
                 "required" => ["query"]
               }
             }
    end

    test "passes nil description through" do
      tool = %Tool{name: "test", description: nil, input_schema: %{}}
      result = ToolAdapter.to_claudio_tool(tool)

      assert result["description"] == nil
    end

    test "applies prefix when given" do
      tool = hd(@tools)
      result = ToolAdapter.to_claudio_tool(tool, "server_a")

      assert result["name"] == "server_a__search"
    end
  end

  describe "mcp_to_claudio/2" do
    test "is an alias for to_claudio_tool/2" do
      tool = hd(@tools)

      assert ToolAdapter.mcp_to_claudio(tool, "prefix") ==
               ToolAdapter.to_claudio_tool(tool, "prefix")
    end
  end

  describe "API-valid tool maps (pre-release audit)" do
    # Live probes G4–G6 (2026-09-26): names must match ^[a-zA-Z0-9_-]{1,128}$,
    # description may not be null, input_schema needs "type".
    test "a nil description is omitted and a schema without type gets type object" do
      tool = %Claudio.MCP.Client.Tool{name: "search", description: nil, input_schema: %{}}

      assert Claudio.MCP.ToolAdapter.to_claudio_tool(tool) == %{
               "name" => "search",
               "input_schema" => %{"type" => "object"}
             }
    end

    test "an existing schema type is kept" do
      schema = %{"type" => "object", "properties" => %{"q" => %{"type" => "string"}}}
      tool = %Claudio.MCP.Client.Tool{name: "s", description: "d", input_schema: schema}

      assert %{"input_schema" => ^schema, "description" => "d"} =
               Claudio.MCP.ToolAdapter.to_claudio_tool(tool)
    end

    test "names the API would reject raise ArgumentError naming the tool" do
      for {name, prefix} <- [
            {"search.v2", nil},
            {"search", "my server"},
            {String.duplicate("a", 127), "p"}
          ] do
        tool = %Claudio.MCP.Client.Tool{name: name, description: "d", input_schema: %{}}

        assert_raise ArgumentError, ~r/tool name .* must match/, fn ->
          Claudio.MCP.ToolAdapter.to_claudio_tool(tool, prefix)
        end
      end
    end
  end
end
