defmodule Claudio.Messages.ResponseTest do
  use ExUnit.Case, async: true

  alias Claudio.Messages.Response

  describe "from_map/1" do
    test "parses basic response with string keys" do
      data = %{
        "id" => "msg_123",
        "type" => "message",
        "role" => "assistant",
        "model" => "claude-3-5-sonnet-20241022",
        "content" => [%{"type" => "text", "text" => "Hello!"}],
        "stop_reason" => "end_turn",
        "stop_sequence" => nil,
        "usage" => %{"input_tokens" => 10, "output_tokens" => 5}
      }

      response = Response.from_map(data)

      assert response.id == "msg_123"
      assert response.role == "assistant"
      assert response.stop_reason == :end_turn

      assert response.usage == %{
               input_tokens: 10,
               output_tokens: 5,
               cache_creation_input_tokens: nil,
               cache_read_input_tokens: nil
             }
    end

    test "parses response with atom keys" do
      data = %{
        id: "msg_123",
        type: "message",
        role: "assistant",
        model: "claude-3-5-sonnet-20241022",
        content: [%{type: "text", text: "Hello!"}],
        stop_reason: "max_tokens",
        usage: %{input_tokens: 10, output_tokens: 5}
      }

      response = Response.from_map(data)

      assert response.id == "msg_123"
      assert response.stop_reason == :max_tokens
    end

    test "parses all stop reason types" do
      stop_reasons = [
        {"end_turn", :end_turn},
        {"max_tokens", :max_tokens},
        {"stop_sequence", :stop_sequence},
        {"tool_use", :tool_use},
        {"pause_turn", :pause_turn},
        {"refusal", :refusal},
        {"model_context_window_exceeded", :model_context_window_exceeded}
      ]

      for {api_reason, expected_atom} <- stop_reasons do
        data = %{
          "id" => "msg_123",
          "type" => "message",
          "role" => "assistant",
          "model" => "claude-3-5-sonnet-20241022",
          "content" => [],
          "stop_reason" => api_reason,
          "usage" => %{"input_tokens" => 10, "output_tokens" => 5}
        }

        response = Response.from_map(data)
        assert response.stop_reason == expected_atom
      end
    end

    test "parses text content blocks" do
      data = %{
        "id" => "msg_123",
        "content" => [
          %{"type" => "text", "text" => "Hello"},
          %{"type" => "text", "text" => " world"}
        ],
        "usage" => %{"input_tokens" => 10, "output_tokens" => 5}
      }

      response = Response.from_map(data)

      assert length(response.content) == 2
      assert Enum.at(response.content, 0).type == :text
      assert Enum.at(response.content, 0).text == "Hello"
      assert Enum.at(response.content, 1).text == " world"
    end

    test "parses tool use content blocks" do
      data = %{
        "id" => "msg_123",
        "content" => [
          %{
            "type" => "tool_use",
            "id" => "toolu_123",
            "name" => "get_weather",
            "input" => %{"location" => "Paris"}
          }
        ],
        "usage" => %{"input_tokens" => 10, "output_tokens" => 5}
      }

      response = Response.from_map(data)

      assert length(response.content) == 1
      tool_use = Enum.at(response.content, 0)
      assert tool_use.type == :tool_use
      assert tool_use.id == "toolu_123"
      assert tool_use.name == "get_weather"
      assert tool_use.input == %{"location" => "Paris"}
    end
  end

  describe "get_text/1" do
    test "extracts text from single text block" do
      response = %Response{
        content: [%{type: :text, text: "Hello world"}]
      }

      assert Response.get_text(response) == "Hello world"
    end

    test "concatenates multiple text blocks" do
      response = %Response{
        content: [
          %{type: :text, text: "Hello"},
          %{type: :text, text: " "},
          %{type: :text, text: "world"}
        ]
      }

      assert Response.get_text(response) == "Hello world"
    end

    test "ignores non-text blocks" do
      response = %Response{
        content: [
          %{type: :text, text: "Hello"},
          %{type: :tool_use, id: "toolu_1", name: "tool", input: %{}},
          %{type: :text, text: "world"}
        ]
      }

      assert Response.get_text(response) == "Helloworld"
    end

    test "returns empty string for no text blocks" do
      response = %Response{
        content: [%{type: :tool_use, id: "toolu_1", name: "tool", input: %{}}]
      }

      assert Response.get_text(response) == ""
    end
  end

  describe "get_tool_uses/1" do
    test "extracts tool use blocks" do
      response = %Response{
        content: [
          %{type: :text, text: "Let me check"},
          %{type: :tool_use, id: "toolu_1", name: "get_weather", input: %{"location" => "NYC"}},
          %{type: :tool_use, id: "toolu_2", name: "get_time", input: %{"timezone" => "EST"}}
        ]
      }

      tool_uses = Response.get_tool_uses(response)

      assert length(tool_uses) == 2
      assert Enum.at(tool_uses, 0).name == "get_weather"
      assert Enum.at(tool_uses, 1).name == "get_time"
    end

    test "returns empty list when no tool uses" do
      response = %Response{
        content: [%{type: :text, text: "Just text"}]
      }

      assert Response.get_tool_uses(response) == []
    end
  end
end
