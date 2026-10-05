defmodule Claudio.ToolsTest do
  use ExUnit.Case, async: true

  alias Claudio.Messages.Response
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
    test "exposes toolset_name and caller (nil when absent), for raw maps and Responses" do
      raw = %{
        "content" => [
          %{
            "type" => "tool_use",
            "id" => "toolu_1",
            "name" => "left_click",
            "input" => %{"coordinate" => [1, 2]},
            "toolset_name" => "computer",
            "caller" => %{"type" => "direct"}
          },
          %{"type" => "tool_use", "id" => "toolu_2", "name" => "x", "input" => %{}}
        ]
      }

      expected = [
        %{
          id: "toolu_1",
          name: "left_click",
          input: %{"coordinate" => [1, 2]},
          toolset_name: "computer",
          caller: %{"type" => "direct"}
        },
        %{id: "toolu_2", name: "x", input: %{}, toolset_name: nil, caller: nil}
      ]

      assert Tools.extract_tool_uses(raw) == expected
      assert Tools.extract_tool_uses(Response.from_map(raw)) == expected
    end

    test "skips tool_use blocks before the last fallback block (raw maps and Response)" do
      raw = %{
        "content" => [
          %{"type" => "tool_use", "id" => "toolu_1", "name" => "x", "input" => %{}},
          %{"type" => "fallback", "from" => %{"model" => "a"}, "to" => %{"model" => "b"}},
          %{"type" => "tool_use", "id" => "toolu_2", "name" => "y", "input" => %{}}
        ]
      }

      assert [%{id: "toolu_2"}] = Tools.extract_tool_uses(raw)
      assert [%{id: "toolu_2"}] = Tools.extract_tool_uses(Response.from_map(raw))

      atom_keyed = %{
        content: [%{type: "tool_use", id: "toolu_1", name: "x", input: %{}}, %{type: "fallback"}]
      }

      assert Tools.extract_tool_uses(atom_keyed) == []
      refute Tools.has_tool_uses?(atom_keyed)
    end

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
    test "create_tool_result/4 echoes toolset_name" do
      result = Tools.create_tool_result("toolu_1", "OK", false, toolset_name: "computer")

      assert result == %{
               "type" => "tool_result",
               "tool_use_id" => "toolu_1",
               "content" => "OK",
               "toolset_name" => "computer"
             }
    end

    test "create_tool_result/4 rejects unknown options" do
      assert_raise ArgumentError, fn -> Tools.create_tool_result("t", "x", false, foo: 1) end
    end

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

  describe "halt_result/1" do
    test "exact halt text per toolset, is_error, toolset_name echoed" do
      assert Tools.halt_result(%{id: "toolu_1", toolset_name: "computer"}) == %{
               "type" => "tool_result",
               "tool_use_id" => "toolu_1",
               "content" => "Not executed: an earlier computer action in this turn failed.",
               "is_error" => true,
               "toolset_name" => "computer"
             }

      assert Tools.halt_result(%{id: "toolu_2", toolset_name: "browser"})["content"] ==
               "Not executed: an earlier action in this turn failed."
    end

    test "a plain tool use, or a map without toolset_name, raises ArgumentError" do
      for bad <- [%{id: "toolu_1", toolset_name: nil}, %{id: "toolu_1"}, "x"] do
        assert_raise ArgumentError, ~r/halt_result\/1/, fn -> Tools.halt_result(bad) end
      end
    end

    test "halt_text/1: text for known toolsets, nil otherwise" do
      assert Tools.halt_text("browser") == "Not executed: an earlier action in this turn failed."
      assert Tools.halt_text("terminal") == nil
      assert Tools.halt_text(nil) == nil
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

  describe "tool results the API accepts (pre-release audit)" do
    test "an error result with empty content raises (the API rejects it)" do
      for empty <- ["", nil] do
        assert_raise ArgumentError, ~r/is_error.*empty/, fn ->
          Tools.create_tool_result("t", empty, true)
        end
      end
    end

    test "a list must hold content-block maps" do
      assert_raise ArgumentError, ~r/content blocks/, fn ->
        Tools.create_tool_result("t", ["a", "b"])
      end

      assert %{"content" => [%{"type" => "text", "text" => "a"}]} =
               Tools.create_tool_result("t", [%{"type" => "text", "text" => "a"}])
    end

    test "a struct without a JSON encoder raises ArgumentError instead of a protocol crash" do
      assert_raise ArgumentError, ~r/cannot be sent as tool_result content/, fn ->
        Tools.create_tool_result("t", {:a, 1})
      end
    end

    test "a raw tool_use block without input normalizes to input: %{}" do
      raw = %{"content" => [%{"type" => "tool_use", "id" => "a", "name" => "n"}]}

      assert [%{id: "a", name: "n", input: %{}, toolset_name: nil, caller: nil}] =
               Tools.extract_tool_uses(raw)
    end
  end

  describe "create_tool_result/4 unknown options" do
    test "the error names the function" do
      assert_raise ArgumentError,
                   "Tools.create_tool_result/4: unknown option :toolset; allowed: :toolset_name",
                   fn -> Tools.create_tool_result("id", "ok", false, toolset: "computer") end
    end

    test "non-keyword opts name the function" do
      assert_raise ArgumentError,
                   "Tools.create_tool_result/4: options must be a keyword list; got %{}",
                   fn -> Tools.create_tool_result("id", "ok", false, %{}) end
    end
  end

  test "define_tool/3 with an atom name says what it expected" do
    assert_raise ArgumentError,
                 ~r/define_tool\/3: expected name and description strings and an input_schema map; got :weather/,
                 fn -> Tools.define_tool(:weather, "d", %{}) end
  end
end
