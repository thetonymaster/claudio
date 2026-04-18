defmodule Claudio.MCP.ResultMapperTest do
  use ExUnit.Case, async: true

  alias Claudio.MCP.ResultMapper
  alias Claudio.Messages.Response

  describe "extract_mcp_calls/1" do
    test "extracts mcp_tool_use blocks" do
      response =
        Response.from_map(%{
          "id" => "msg_1",
          "type" => "message",
          "role" => "assistant",
          "model" => "claude-sonnet-4-5-20250929",
          "content" => [
            %{
              "type" => "mcp_tool_use",
              "id" => "toolu_1",
              "name" => "search",
              "server_name" => "my_server",
              "input" => %{"query" => "elixir"}
            }
          ],
          "stop_reason" => "end_turn",
          "usage" => %{"input_tokens" => 10, "output_tokens" => 5}
        })

      calls = ResultMapper.extract_mcp_calls(response)

      assert [call] = calls
      assert call.id == "toolu_1"
      assert call.name == "search"
      assert call.arguments == %{"query" => "elixir"}
      assert call.server_name == "my_server"
    end

    test "extracts prefixed tool_use blocks" do
      response =
        Response.from_map(%{
          "id" => "msg_2",
          "type" => "message",
          "role" => "assistant",
          "model" => "claude-sonnet-4-5-20250929",
          "content" => [
            %{
              "type" => "tool_use",
              "id" => "toolu_2",
              "name" => "server_a__fetch",
              "input" => %{"url" => "https://example.com"}
            }
          ],
          "stop_reason" => "tool_use",
          "usage" => %{"input_tokens" => 10, "output_tokens" => 5}
        })

      calls = ResultMapper.extract_mcp_calls(response)

      assert [call] = calls
      assert call.name == "fetch"
      assert call.server_name == "server_a"
    end

    test "ignores non-prefixed tool_use blocks" do
      response =
        Response.from_map(%{
          "id" => "msg_3",
          "type" => "message",
          "role" => "assistant",
          "model" => "claude-sonnet-4-5-20250929",
          "content" => [
            %{
              "type" => "tool_use",
              "id" => "toolu_3",
              "name" => "regular_tool",
              "input" => %{}
            }
          ],
          "stop_reason" => "tool_use",
          "usage" => %{"input_tokens" => 10, "output_tokens" => 5}
        })

      assert ResultMapper.extract_mcp_calls(response) == []
    end

    test "ignores text and other block types" do
      response =
        Response.from_map(%{
          "id" => "msg_4",
          "type" => "message",
          "role" => "assistant",
          "model" => "claude-sonnet-4-5-20250929",
          "content" => [
            %{"type" => "text", "text" => "Hello"},
            %{
              "type" => "mcp_tool_use",
              "id" => "toolu_4",
              "name" => "search",
              "server_name" => "s1",
              "input" => %{}
            }
          ],
          "stop_reason" => "end_turn",
          "usage" => %{"input_tokens" => 10, "output_tokens" => 5}
        })

      calls = ResultMapper.extract_mcp_calls(response)
      assert length(calls) == 1
    end
  end

  describe "extract_mcp_calls/2" do
    test "filters by server name" do
      response =
        Response.from_map(%{
          "id" => "msg_5",
          "type" => "message",
          "role" => "assistant",
          "model" => "claude-sonnet-4-5-20250929",
          "content" => [
            %{
              "type" => "mcp_tool_use",
              "id" => "toolu_a",
              "name" => "search",
              "server_name" => "server_a",
              "input" => %{}
            },
            %{
              "type" => "mcp_tool_use",
              "id" => "toolu_b",
              "name" => "fetch",
              "server_name" => "server_b",
              "input" => %{}
            }
          ],
          "stop_reason" => "end_turn",
          "usage" => %{"input_tokens" => 10, "output_tokens" => 5}
        })

      assert [call] = ResultMapper.extract_mcp_calls(response, "server_a")
      assert call.name == "search"

      assert [call] = ResultMapper.extract_mcp_calls(response, "server_b")
      assert call.name == "fetch"

      assert ResultMapper.extract_mcp_calls(response, "nonexistent") == []
    end
  end

  describe "claudio_to_mcp/1" do
    test "is an alias for extract_mcp_calls/1" do
      response = Response.from_map(%{"content" => []})
      assert ResultMapper.claudio_to_mcp(response) == ResultMapper.extract_mcp_calls(response)
    end
  end
end
