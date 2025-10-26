defmodule Claudio.ToolsTest do
  use ExUnit.Case, async: true

  alias Claudio.Tools

  describe "define_tool/3" do
    test "creates a tool definition" do
      tool =
        Tools.define_tool(
          "get_weather",
          "Get the weather for a location",
          %{
            "type" => "object",
            "properties" => %{
              "location" => %{"type" => "string"}
            },
            "required" => ["location"]
          }
        )

      assert tool["name"] == "get_weather"
      assert tool["description"] == "Get the weather for a location"
      assert tool["input_schema"]["type"] == "object"
    end
  end

  describe "extract_tool_uses/1" do
    test "extracts tool uses from response with string keys" do
      response = %{
        "content" => [
          %{"type" => "text", "text" => "Let me check"},
          %{
            "type" => "tool_use",
            "id" => "toolu_123",
            "name" => "get_weather",
            "input" => %{"location" => "Paris"}
          }
        ]
      }

      tool_uses = Tools.extract_tool_uses(response)

      assert length(tool_uses) == 1
      assert hd(tool_uses).id == "toolu_123"
      assert hd(tool_uses).name == "get_weather"
      assert hd(tool_uses).input == %{"location" => "Paris"}
    end

    test "extracts tool uses from response with atom keys" do
      response = %{
        content: [
          %{type: "text", text: "Let me check"},
          %{
            type: "tool_use",
            id: "toolu_123",
            name: "get_weather",
            input: %{location: "Paris"}
          }
        ]
      }

      tool_uses = Tools.extract_tool_uses(response)

      assert length(tool_uses) == 1
      assert hd(tool_uses).id == "toolu_123"
    end

    test "extracts multiple tool uses" do
      response = %{
        content: [
          %{type: :tool_use, id: "toolu_1", name: "tool1", input: %{}},
          %{type: :tool_use, id: "toolu_2", name: "tool2", input: %{}}
        ]
      }

      tool_uses = Tools.extract_tool_uses(response)

      assert length(tool_uses) == 2
    end

    test "returns empty list when no tool uses" do
      response = %{
        content: [
          %{type: "text", text: "Just text"}
        ]
      }

      assert Tools.extract_tool_uses(response) == []
    end

    test "returns empty list for invalid response" do
      assert Tools.extract_tool_uses(%{}) == []
      assert Tools.extract_tool_uses(%{content: nil}) == []
    end
  end

  describe "create_tool_result/3" do
    test "creates tool result with string content" do
      result = Tools.create_tool_result("toolu_123", "The weather is sunny")

      assert result["type"] == "tool_result"
      assert result["tool_use_id"] == "toolu_123"
      assert result["content"] == "The weather is sunny"
      refute Map.has_key?(result, "is_error")
    end

    test "creates tool result with list content" do
      content = [%{"type" => "text", "text" => "Result"}]
      result = Tools.create_tool_result("toolu_123", content)

      assert result["content"] == content
    end

    test "creates error tool result" do
      result = Tools.create_tool_result("toolu_123", "Error occurred", true)

      assert result["is_error"] == true
      assert result["content"] == "Error occurred"
    end

    test "converts map to JSON string" do
      result = Tools.create_tool_result("toolu_123", %{temp: 72, condition: "sunny"})

      assert is_binary(result["content"])
      assert result["content"] =~ "temp"
      assert result["content"] =~ "sunny"
    end
  end

  describe "has_tool_uses?/1" do
    test "returns true when response has tool uses" do
      response = %{
        content: [
          %{type: :tool_use, id: "toolu_1", name: "tool", input: %{}}
        ]
      }

      assert Tools.has_tool_uses?(response) == true
    end

    test "returns false when response has no tool uses" do
      response = %{
        content: [
          %{type: "text", text: "Just text"}
        ]
      }

      assert Tools.has_tool_uses?(response) == false
    end

    test "returns false for empty content" do
      assert Tools.has_tool_uses?(%{content: []}) == false
    end
  end

  describe "create_tool_result_message/1" do
    test "returns list of tool results" do
      results = [
        Tools.create_tool_result("toolu_1", "Result 1"),
        Tools.create_tool_result("toolu_2", "Result 2")
      ]

      message = Tools.create_tool_result_message(results)

      assert is_list(message)
      assert length(message) == 2
    end
  end
end
