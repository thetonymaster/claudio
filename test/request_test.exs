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
end
