defmodule Claudio.Messages.RequestTest do
  use ExUnit.Case, async: true

  alias Claudio.Messages.Request

  describe "new/1" do
    test "creates a request with model" do
      request = Request.new("claude-3-5-sonnet-20241022")

      assert %Request{model: "claude-3-5-sonnet-20241022", messages: []} = request
    end
  end

  describe "add_message/3" do
    test "adds user message" do
      request =
        Request.new("claude-3-5-sonnet-20241022")
        |> Request.add_message(:user, "Hello")

      assert [%{"role" => "user", "content" => "Hello"}] = request.messages
    end

    test "adds assistant message" do
      request =
        Request.new("claude-3-5-sonnet-20241022")
        |> Request.add_message(:assistant, "Hi there")

      assert [%{"role" => "assistant", "content" => "Hi there"}] = request.messages
    end

    test "adds multiple messages in order" do
      request =
        Request.new("claude-3-5-sonnet-20241022")
        |> Request.add_message(:user, "Hello")
        |> Request.add_message(:assistant, "Hi")
        |> Request.add_message(:user, "How are you?")

      assert length(request.messages) == 3
      assert Enum.at(request.messages, 0)["content"] == "Hello"
      assert Enum.at(request.messages, 1)["content"] == "Hi"
      assert Enum.at(request.messages, 2)["content"] == "How are you?"
    end
  end

  describe "set_system/2" do
    test "sets system prompt" do
      request =
        Request.new("claude-3-5-sonnet-20241022")
        |> Request.set_system("You are a helpful assistant")

      assert request.system == "You are a helpful assistant"
    end
  end

  describe "set_system_with_cache/2" do
    test "wraps text in a system text block with default ephemeral cache_control" do
      request =
        Request.new("claude-3-5-sonnet-20241022")
        |> Request.set_system_with_cache("Long context")

      assert request.system == [
               %{
                 "type" => "text",
                 "text" => "Long context",
                 "cache_control" => %{"type" => "ephemeral"}
               }
             ]
    end

    test "honours an explicit ttl" do
      request =
        Request.new("claude-3-5-sonnet-20241022")
        |> Request.set_system_with_cache("Long context", ttl: "1h")

      assert request.system == [
               %{
                 "type" => "text",
                 "text" => "Long context",
                 "cache_control" => %{"type" => "ephemeral", "ttl" => "1h"}
               }
             ]
    end
  end

  describe "set_max_tokens/2" do
    test "sets max tokens" do
      request =
        Request.new("claude-3-5-sonnet-20241022")
        |> Request.set_max_tokens(1024)

      assert request.max_tokens == 1024
    end
  end

  describe "set_temperature/2" do
    test "sets temperature" do
      request =
        Request.new("claude-3-5-sonnet-20241022")
        |> Request.set_temperature(0.7)

      assert request.temperature == 0.7
    end
  end

  describe "set_top_p/2" do
    test "sets top_p" do
      request =
        Request.new("claude-3-5-sonnet-20241022")
        |> Request.set_top_p(0.9)

      assert request.top_p == 0.9
    end
  end

  describe "set_top_k/2" do
    test "sets top_k" do
      request =
        Request.new("claude-3-5-sonnet-20241022")
        |> Request.set_top_k(40)

      assert request.top_k == 40
    end
  end

  describe "set_stop_sequences/2" do
    test "sets stop sequences" do
      request =
        Request.new("claude-3-5-sonnet-20241022")
        |> Request.set_stop_sequences(["END", "STOP"])

      assert request.stop_sequences == ["END", "STOP"]
    end
  end

  describe "enable_streaming/1" do
    test "enables streaming" do
      request =
        Request.new("claude-3-5-sonnet-20241022")
        |> Request.enable_streaming()

      assert request.stream == true
    end
  end

  describe "add_tool/2" do
    test "adds a tool" do
      tool = %{
        "name" => "get_weather",
        "description" => "Get weather",
        "input_schema" => %{"type" => "object"}
      }

      request =
        Request.new("claude-3-5-sonnet-20241022")
        |> Request.add_tool(tool)

      assert request.tools == [tool]
    end

    test "adds multiple tools" do
      tool1 = %{"name" => "tool1"}
      tool2 = %{"name" => "tool2"}

      request =
        Request.new("claude-3-5-sonnet-20241022")
        |> Request.add_tool(tool1)
        |> Request.add_tool(tool2)

      assert request.tools == [tool1, tool2]
    end
  end

  describe "add_tool_with_cache/3" do
    test "appends a tool with default ephemeral cache_control" do
      tool = %{"name" => "get_weather", "input_schema" => %{"type" => "object"}}

      request =
        Request.new("claude-3-5-sonnet-20241022")
        |> Request.add_tool_with_cache(tool)

      assert request.tools == [Map.put(tool, "cache_control", %{"type" => "ephemeral"})]
    end

    test "honours an explicit ttl" do
      tool = %{"name" => "get_weather", "input_schema" => %{"type" => "object"}}

      request =
        Request.new("claude-3-5-sonnet-20241022")
        |> Request.add_tool_with_cache(tool, ttl: "1h")

      assert request.tools ==
               [Map.put(tool, "cache_control", %{"type" => "ephemeral", "ttl" => "1h"})]
    end
  end

  describe "set_tool_choice/2" do
    test "sets tool choice to auto" do
      request =
        Request.new("claude-3-5-sonnet-20241022")
        |> Request.set_tool_choice(:auto)

      assert request.tool_choice == %{"type" => "auto"}
    end

    test "sets tool choice to any" do
      request =
        Request.new("claude-3-5-sonnet-20241022")
        |> Request.set_tool_choice(:any)

      assert request.tool_choice == %{"type" => "any"}
    end

    test "sets tool choice to specific tool" do
      request =
        Request.new("claude-3-5-sonnet-20241022")
        |> Request.set_tool_choice({:tool, "get_weather"})

      assert request.tool_choice == %{"type" => "tool", "name" => "get_weather"}
    end
  end

  describe "betas / add_beta/2 / required_betas/1" do
    test "a new request has no betas" do
      assert Request.new("claude-3-5-sonnet-20241022") |> Request.required_betas() == []
    end

    test "add_beta/2 records a beta string" do
      request =
        Request.new("claude-3-5-sonnet-20241022")
        |> Request.add_beta("context-management-2025-06-27")

      assert Request.required_betas(request) == ["context-management-2025-06-27"]
    end

    test "add_beta/2 dedups and preserves insertion order" do
      request =
        Request.new("claude-3-5-sonnet-20241022")
        |> Request.add_beta("a-2025-01-01")
        |> Request.add_beta("b-2025-01-01")
        |> Request.add_beta("a-2025-01-01")

      assert Request.required_betas(request) == ["a-2025-01-01", "b-2025-01-01"]
    end
  end

  describe "set_context_management/2 beta wiring" do
    test "declares the context-management beta" do
      request =
        Request.new("claude-opus-4-8")
        |> Request.set_context_management(%{"edits" => [%{"type" => "clear_tool_uses_20250919"}]})

      assert "context-management-2025-06-27" in Request.required_betas(request)
    end

    test "to_map includes context_management but never betas" do
      request =
        Request.new("claude-opus-4-8")
        |> Request.add_message(:user, "hi")
        |> Request.set_context_management(%{"edits" => [%{"type" => "clear_tool_uses_20250919"}]})

      map = Request.to_map(request)

      assert map["context_management"] == %{"edits" => [%{"type" => "clear_tool_uses_20250919"}]}
      refute Map.has_key?(map, "betas")
      refute Map.has_key?(map, "anthropic-beta")
    end
  end

  describe "set_output_config/2 and set_output_format/2" do
    test "set_output_format wraps a JSON schema as a json_schema format" do
      schema = %{
        "type" => "object",
        "properties" => %{"name" => %{"type" => "string"}},
        "required" => ["name"],
        "additionalProperties" => false
      }

      request =
        Request.new("claude-sonnet-4-6")
        |> Request.set_output_format(schema)

      map = Request.to_map(request)

      assert map["output_config"] == %{
               "format" => %{"type" => "json_schema", "schema" => schema}
             }
    end

    test "set_output_format preserves other output_config keys (merge, not replace)" do
      schema = %{"type" => "object", "properties" => %{}, "additionalProperties" => false}

      request =
        Request.new("claude-sonnet-4-6")
        |> Request.set_output_config(%{"effort" => "high"})
        |> Request.set_output_format(schema)

      map = Request.to_map(request)

      assert map["output_config"]["effort"] == "high"
      assert map["output_config"]["format"]["type"] == "json_schema"
      assert map["output_config"]["format"]["schema"] == schema
    end

    test "set_output_config sets the raw map" do
      request =
        Request.new("claude-sonnet-4-6")
        |> Request.set_output_config(%{"format" => %{"type" => "json_schema", "schema" => %{}}})

      assert Request.to_map(request)["output_config"] ==
               %{"format" => %{"type" => "json_schema", "schema" => %{}}}
    end

    test "to_map omits output_config when unset" do
      refute Map.has_key?(Request.to_map(Request.new("claude-sonnet-4-6")), "output_config")
    end
  end

  describe "add_strict_tool/2 and add_tool_with_eager_streaming/2" do
    @tool %{
      "name" => "get_weather",
      "description" => "Get weather",
      "input_schema" => %{
        "type" => "object",
        "properties" => %{"location" => %{"type" => "string"}},
        "required" => ["location"],
        "additionalProperties" => false
      }
    }

    test "add_strict_tool sets strict: true on the tool" do
      request =
        Request.new("claude-sonnet-4-6")
        |> Request.add_strict_tool(@tool)

      [tool] = Request.to_map(request)["tools"]
      assert tool["strict"] == true
      assert tool["name"] == "get_weather"
    end

    test "add_tool_with_eager_streaming sets eager_input_streaming: true" do
      request =
        Request.new("claude-sonnet-4-6")
        |> Request.add_tool_with_eager_streaming(@tool)

      [tool] = Request.to_map(request)["tools"]
      assert tool["eager_input_streaming"] == true
      assert tool["name"] == "get_weather"
    end

    test "both helpers append to existing tools" do
      request =
        Request.new("claude-sonnet-4-6")
        |> Request.add_tool(@tool)
        |> Request.add_strict_tool(@tool)
        |> Request.add_tool_with_eager_streaming(@tool)

      assert length(Request.to_map(request)["tools"]) == 3
    end
  end

  describe "add_message_with_cache/4" do
    test "adds a text block with default ephemeral cache_control" do
      request =
        Request.new("claude-sonnet-4-6")
        |> Request.add_message_with_cache(:user, "long context...")

      [message] = Request.to_map(request)["messages"]
      assert message["role"] == "user"

      assert message["content"] == [
               %{
                 "type" => "text",
                 "text" => "long context...",
                 "cache_control" => %{"type" => "ephemeral"}
               }
             ]
    end

    test "honours an explicit ttl" do
      request =
        Request.new("claude-sonnet-4-6")
        |> Request.add_message_with_cache(:assistant, "cached", ttl: "1h")

      [message] = Request.to_map(request)["messages"]

      assert message["content"] == [
               %{
                 "type" => "text",
                 "text" => "cached",
                 "cache_control" => %{"type" => "ephemeral", "ttl" => "1h"}
               }
             ]
    end

    test "appends after other messages" do
      request =
        Request.new("claude-sonnet-4-6")
        |> Request.add_message(:user, "first")
        |> Request.add_message_with_cache(:user, "second")

      assert length(Request.to_map(request)["messages"]) == 2
    end
  end

  describe "set_cache_control/2" do
    test "sets top-level cache_control with default ttl" do
      request =
        Request.new("claude-sonnet-4-6")
        |> Request.set_cache_control()

      assert Request.to_map(request)["cache_control"] == %{"type" => "ephemeral"}
    end

    test "honours an explicit ttl" do
      request =
        Request.new("claude-sonnet-4-6")
        |> Request.set_cache_control(ttl: "1h")

      assert Request.to_map(request)["cache_control"] == %{"type" => "ephemeral", "ttl" => "1h"}
    end

    test "to_map omits cache_control when unset" do
      refute Map.has_key?(Request.to_map(Request.new("claude-sonnet-4-6")), "cache_control")
    end
  end

  describe "to_map/1" do
    test "converts request to map with only required fields" do
      request = Request.new("claude-3-5-sonnet-20241022")

      map = Request.to_map(request)

      assert map["model"] == "claude-3-5-sonnet-20241022"
      assert map["messages"] == []
      refute Map.has_key?(map, "system")
      refute Map.has_key?(map, "max_tokens")
    end

    test "includes optional fields when set" do
      request =
        Request.new("claude-3-5-sonnet-20241022")
        |> Request.add_message(:user, "Hello")
        |> Request.set_max_tokens(1024)
        |> Request.set_temperature(0.7)
        |> Request.set_system("Be helpful")

      map = Request.to_map(request)

      assert map["model"] == "claude-3-5-sonnet-20241022"
      assert map["max_tokens"] == 1024
      assert map["temperature"] == 0.7
      assert map["system"] == "Be helpful"
      assert length(map["messages"]) == 1
    end
  end

  describe "add_message_with_document/5" do
    test "no opts emits the original document block (backward compatible)" do
      request =
        Request.new("claude-sonnet-4-6")
        |> Request.add_message_with_document(:user, "Summarize", "file_abc123")

      [message] = Request.to_map(request)["messages"]

      assert message["content"] == [
               %{
                 "type" => "document",
                 "source" => %{"type" => "file", "file_id" => "file_abc123"}
               },
               %{"type" => "text", "text" => "Summarize"}
             ]
    end

    test "citations: true enables citations on the document block" do
      request =
        Request.new("claude-sonnet-4-6")
        |> Request.add_message_with_document(:user, "Summarize", "file_abc123",
          citations: true
        )

      [message] = Request.to_map(request)["messages"]
      [document, _text] = message["content"]
      assert document["citations"] == %{"enabled" => true}
    end

    test ":title and :context are threaded onto the document block" do
      request =
        Request.new("claude-sonnet-4-6")
        |> Request.add_message_with_document(:user, "Summarize", "file_abc123",
          title: "Q4 Report",
          context: "Internal financials"
        )

      [message] = Request.to_map(request)["messages"]
      [document, _text] = message["content"]
      assert document["title"] == "Q4 Report"
      assert document["context"] == "Internal financials"
    end

    test "citations: false omits the citations key" do
      request =
        Request.new("claude-sonnet-4-6")
        |> Request.add_message_with_document(:user, "Summarize", "file_abc123",
          citations: false
        )

      [message] = Request.to_map(request)["messages"]
      [document, _text] = message["content"]
      refute Map.has_key?(document, "citations")
    end
  end

  describe "search_result_block/4" do
    test "wraps string contents into text blocks with required fields" do
      block =
        Request.search_result_block("https://example.com/a", "Article Title", [
          "chunk one",
          "chunk two"
        ])

      assert block == %{
               "type" => "search_result",
               "source" => "https://example.com/a",
               "title" => "Article Title",
               "content" => [
                 %{"type" => "text", "text" => "chunk one"},
                 %{"type" => "text", "text" => "chunk two"}
               ]
             }
    end

    test "passes pre-built text-block maps through unchanged" do
      content = [%{"type" => "text", "text" => "already a block"}]
      block = Request.search_result_block("src", "Title", content)
      assert block["content"] == content
    end

    test "citations: true enables citations" do
      block = Request.search_result_block("src", "Title", ["x"], citations: true)
      assert block["citations"] == %{"enabled" => true}
    end

    test "citations: false omits the citations key" do
      block = Request.search_result_block("src", "Title", ["x"], citations: false)
      refute Map.has_key?(block, "citations")
    end

    test "cache_control: true adds default ephemeral cache_control" do
      block = Request.search_result_block("src", "Title", ["x"], cache_control: true)
      assert block["cache_control"] == %{"type" => "ephemeral"}
    end

    test "cache_control with a ttl string sets the ttl" do
      block = Request.search_result_block("src", "Title", ["x"], cache_control: "1h")
      assert block["cache_control"] == %{"type" => "ephemeral", "ttl" => "1h"}
    end

    test "composes into a message via add_message/3" do
      result = Request.search_result_block("src", "Title", ["x"], citations: true)

      request =
        Request.new("claude-opus-4-8")
        |> Request.add_message(:user, [result, %{"type" => "text", "text" => "Question?"}])

      [message] = Request.to_map(request)["messages"]
      assert [%{"type" => "search_result"}, %{"type" => "text"}] = message["content"]
    end
  end
end
