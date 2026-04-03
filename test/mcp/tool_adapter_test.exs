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
end
