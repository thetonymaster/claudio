defmodule Claudio.Messages.Response.MCPTest do
  use ExUnit.Case, async: true

  alias Claudio.Messages.Response

  @mcp_tool_use_response %{
    "id" => "msg_123",
    "type" => "message",
    "role" => "assistant",
    "model" => "claude-sonnet-4-5-20250929",
    "content" => [
      %{
        "type" => "text",
        "text" => "Let me search for that."
      },
      %{
        "type" => "mcp_tool_use",
        "id" => "toolu_abc",
        "name" => "search",
        "server_name" => "my_server",
        "input" => %{"query" => "elixir mcp"}
      },
      %{
        "type" => "mcp_tool_result",
        "tool_use_id" => "toolu_abc",
        "server_name" => "my_server",
        "content" => "Found 3 results",
        "is_error" => false
      }
    ],
    "stop_reason" => "end_turn",
    "usage" => %{
      "input_tokens" => 100,
      "output_tokens" => 50
    }
  }

  describe "from_map/1 with MCP content blocks" do
    test "parses mcp_tool_use blocks" do
      response = Response.from_map(@mcp_tool_use_response)

      mcp_block = Enum.find(response.content, &(&1.type == :mcp_tool_use))
      assert mcp_block.id == "toolu_abc"
      assert mcp_block.name == "search"
      assert mcp_block.server_name == "my_server"
      assert mcp_block.input == %{"query" => "elixir mcp"}
    end

    test "parses mcp_tool_result blocks" do
      response = Response.from_map(@mcp_tool_use_response)

      result_block = Enum.find(response.content, &(&1.type == :mcp_tool_result))
      assert result_block.tool_use_id == "toolu_abc"
      assert result_block.server_name == "my_server"
      assert result_block.content == "Found 3 results"
      assert result_block.is_error == false
    end

    test "parses mcp_tool_result with is_error true" do
      data = %{
        "id" => "msg_456",
        "type" => "message",
        "role" => "assistant",
        "model" => "claude-sonnet-4-5-20250929",
        "content" => [
          %{
            "type" => "mcp_tool_result",
            "tool_use_id" => "toolu_xyz",
            "server_name" => "failing_server",
            "content" => "Connection refused",
            "is_error" => true
          }
        ],
        "stop_reason" => "end_turn",
        "usage" => %{"input_tokens" => 10, "output_tokens" => 5}
      }

      response = Response.from_map(data)
      block = hd(response.content)
      assert block.type == :mcp_tool_result
      assert block.is_error == true
    end

    test "parses mcp_tool_result with explicit is_error false" do
      data = %{
        "id" => "msg_explicit_false",
        "type" => "message",
        "role" => "assistant",
        "model" => "claude-sonnet-4-5-20250929",
        "content" => [
          %{
            "type" => "mcp_tool_result",
            "tool_use_id" => "toolu_ef",
            "server_name" => "server",
            "content" => "OK",
            "is_error" => false
          }
        ],
        "stop_reason" => "end_turn",
        "usage" => %{"input_tokens" => 10, "output_tokens" => 5}
      }

      response = Response.from_map(data)
      block = hd(response.content)
      assert block.is_error == false
    end

    test "handles atom-keyed mcp_tool_use blocks" do
      data = %{
        id: "msg_789",
        type: "message",
        role: "assistant",
        model: "claude-sonnet-4-5-20250929",
        content: [
          %{
            type: "mcp_tool_use",
            id: "toolu_atom",
            name: "fetch",
            server_name: "atom_server",
            input: %{url: "https://example.com"}
          }
        ],
        stop_reason: "end_turn",
        usage: %{input_tokens: 10, output_tokens: 5}
      }

      response = Response.from_map(data)
      block = hd(response.content)
      assert block.type == :mcp_tool_use
      assert block.name == "fetch"
      assert block.server_name == "atom_server"
    end

    test "defaults is_error to false when omitted in atom-keyed mcp_tool_result" do
      data = %{
        id: "msg_atom_result",
        type: "message",
        role: "assistant",
        model: "claude-sonnet-4-5-20250929",
        content: [
          %{
            type: "mcp_tool_result",
            tool_use_id: "toolu_ar",
            server_name: "atom_server",
            content: "Success"
          }
        ],
        stop_reason: "end_turn",
        usage: %{input_tokens: 10, output_tokens: 5}
      }

      response = Response.from_map(data)
      block = hd(response.content)
      assert block.type == :mcp_tool_result
      assert block.is_error == false
    end
  end

  describe "get_mcp_tool_uses/1" do
    test "returns only mcp_tool_use blocks" do
      response = Response.from_map(@mcp_tool_use_response)
      uses = Response.get_mcp_tool_uses(response)

      assert length(uses) == 1
      assert hd(uses).type == :mcp_tool_use
      assert hd(uses).name == "search"
    end

    test "returns empty list when no MCP tool uses" do
      data = %{
        "id" => "msg_no_mcp",
        "type" => "message",
        "role" => "assistant",
        "model" => "claude-sonnet-4-5-20250929",
        "content" => [%{"type" => "text", "text" => "Hello"}],
        "stop_reason" => "end_turn",
        "usage" => %{"input_tokens" => 10, "output_tokens" => 5}
      }

      response = Response.from_map(data)
      assert Response.get_mcp_tool_uses(response) == []
    end
  end

  describe "get_mcp_tool_uses/2" do
    test "filters by server name" do
      data = %{
        "id" => "msg_multi",
        "type" => "message",
        "role" => "assistant",
        "model" => "claude-sonnet-4-5-20250929",
        "content" => [
          %{
            "type" => "mcp_tool_use",
            "id" => "toolu_1",
            "name" => "search",
            "server_name" => "server_a",
            "input" => %{}
          },
          %{
            "type" => "mcp_tool_use",
            "id" => "toolu_2",
            "name" => "fetch",
            "server_name" => "server_b",
            "input" => %{}
          }
        ],
        "stop_reason" => "end_turn",
        "usage" => %{"input_tokens" => 10, "output_tokens" => 5}
      }

      response = Response.from_map(data)

      server_a_uses = Response.get_mcp_tool_uses(response, "server_a")
      assert length(server_a_uses) == 1
      assert hd(server_a_uses).name == "search"

      server_b_uses = Response.get_mcp_tool_uses(response, "server_b")
      assert length(server_b_uses) == 1
      assert hd(server_b_uses).name == "fetch"

      assert Response.get_mcp_tool_uses(response, "nonexistent") == []
    end
  end
end
