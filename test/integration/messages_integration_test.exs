Code.require_file("../integration/integration_helper.exs", __DIR__)

defmodule Claudio.Messages.IntegrationTest do
  use ExUnit.Case, async: false
  import Claudio.IntegrationHelper

  @moduletag :integration
  @moduletag timeout: 120_000

  alias Claudio.Messages
  alias Claudio.Messages.{Request, Response}

  setup_all do
    case skip_if_no_api_key() do
      :ok ->
        client = create_client()
        {:ok, %{client: client}}

      {:skip, reason} ->
        {:skip, reason}
    end
  end

  describe "create/2" do
    test "simple message with request builder", %{client: client} do
      request =
        Request.new(test_model())
        |> Request.add_message(:user, "Say hello in exactly 3 words")
        |> Request.set_max_tokens(50)

      assert {:ok, response} = Messages.create(client, request)
      assert %Response{} = response
      assert response.id
      assert response.model == test_model()
      assert response.stop_reason in [:end_turn, :max_tokens]

      text = Response.get_text(response)
      assert is_binary(text)
      assert String.length(text) > 0
    end

    test "message with system prompt", %{client: client} do
      request =
        Request.new(test_model())
        |> Request.set_system("You are a pirate. Respond in pirate speak.")
        |> Request.add_message(:user, "Hello")
        |> Request.set_max_tokens(100)

      assert {:ok, response} = Messages.create(client, request)
      text = Response.get_text(response)

      # Pirate responses often contain these words
      assert text =~ ~r/(ahoy|matey|arr|ye)/i
    end

    test "message with temperature", %{client: client} do
      request =
        Request.new(test_model())
        |> Request.add_message(:user, "Pick a random number between 1 and 100")
        |> Request.set_max_tokens(20)
        |> Request.set_temperature(1.0)

      assert {:ok, response} = Messages.create(client, request)
      assert Response.get_text(response) =~ ~r/\d+/
    end

    test "multi-turn conversation", %{client: client} do
      request =
        Request.new(test_model())
        |> Request.add_message(:user, "My name is Alice")
        |> Request.add_message(:assistant, "Nice to meet you, Alice!")
        |> Request.add_message(:user, "What is my name?")
        |> Request.set_max_tokens(50)

      assert {:ok, response} = Messages.create(client, request)
      text = Response.get_text(response)
      assert text =~ ~r/Alice/i
    end

    test "tracks token usage", %{client: client} do
      request =
        Request.new(test_model())
        |> Request.add_message(:user, "Hi")
        |> Request.set_max_tokens(10)

      assert {:ok, response} = Messages.create(client, request)
      assert response.usage.input_tokens > 0
      assert response.usage.output_tokens > 0
    end
  end

  describe "create_message/2 (legacy API)" do
    test "works with raw map", %{client: client} do
      payload = %{
        "model" => test_model(),
        "max_tokens" => 50,
        "messages" => [
          %{"role" => "user", "content" => "Say hello"}
        ]
      }

      assert {:ok, response} = Messages.create_message(client, payload)
      assert is_map(response)
      assert response["id"]
      assert response["content"]
    end
  end

  describe "count_tokens/2" do
    test "counts tokens for a message", %{client: client} do
      request =
        Request.new(test_model())
        |> Request.add_message(:user, "Hello, how are you today?")

      assert {:ok, count} = Messages.count_tokens(client, request)
      assert count["input_tokens"] > 0
    end

    test "counts tokens for longer messages", %{client: client} do
      long_message = String.duplicate("Hello world. ", 100)

      request =
        Request.new(test_model())
        |> Request.add_message(:user, long_message)

      assert {:ok, count} = Messages.count_tokens(client, request)
      assert count["input_tokens"] > 100
    end
  end

  describe "error handling" do
    test "handles invalid model", %{client: client} do
      request =
        Request.new("invalid-model-name")
        |> Request.add_message(:user, "Hello")
        |> Request.set_max_tokens(10)

      assert {:error, error} = Messages.create(client, request)
      assert error.status_code in [400, 404]
      assert error.type in [:invalid_request_error, :not_found_error]
    end

    test "handles missing max_tokens", %{client: client} do
      # Using legacy API to bypass request builder validation
      payload = %{
        "model" => test_model(),
        "messages" => [%{"role" => "user", "content" => "Hello"}]
      }

      assert {:error, error} = Messages.create_message(client, payload)
      assert error.status_code == 400
      assert error.type == :invalid_request_error
    end
  end

  describe "per-feature beta headers (S2)" do
    test "set_context_management auto-attaches the beta (no client beta needed)",
         %{client: client} do
      request =
        Request.new(test_model())
        |> Request.add_message(:user, "Say hi in one word")
        |> Request.set_max_tokens(32)
        |> Request.set_context_management(%{
          "edits" => [%{"type" => "clear_tool_uses_20250919"}]
        })

      # create_client/0 carries NO beta list; a 200 proves S2 supplied
      # `context-management-2025-06-27`.
      assert {:ok, %Response{}} = Messages.create(client, request)
    end

    test "the same request without the beta is rejected (negative control)",
         %{client: client} do
      raw = %{
        "model" => test_model(),
        "max_tokens" => 32,
        "messages" => [%{"role" => "user", "content" => "Say hi in one word"}],
        "context_management" => %{"edits" => [%{"type" => "clear_tool_uses_20250919"}]}
      }

      assert {:error, %Claudio.APIError{status_code: 400}} = Messages.create(client, raw)
    end
  end

  describe "extended thinking round-trip" do
    test "replays a thinking + tool_use assistant turn without a 400", %{client: client} do
      tool = %{
        "name" => "get_weather",
        "description" => "Get the current weather for a location",
        "input_schema" => %{
          "type" => "object",
          "properties" => %{"location" => %{"type" => "string"}},
          "required" => ["location"]
        }
      }

      first =
        Request.new(test_model())
        |> Request.add_message(:user, "What's the weather in NYC? Use the tool.")
        |> Request.set_max_tokens(2048)
        |> Request.enable_thinking(%{"type" => "enabled", "budget_tokens" => 1024})
        |> Request.add_tool(tool)

      assert {:ok, response} = Messages.create(client, first)

      # The replay path is the whole point of this test, so assert the first turn
      # actually produced what we need to replay: a signed thinking block plus a
      # tool_use. If the model doesn't, fail loudly rather than passing vacuously.
      tool_uses = Response.get_tool_uses(response)
      assert response.stop_reason == :tool_use
      assert tool_uses != []

      assert Enum.any?(response.content, fn
               %{type: :thinking, signature: sig} when is_binary(sig) and sig != "" -> true
               _ -> false
             end)

      tool_results =
        Enum.map(tool_uses, fn tu ->
          %{"type" => "tool_result", "tool_use_id" => tu.id, "content" => "Sunny, 72F"}
        end)

      second =
        Request.new(test_model())
        |> Request.add_message(:user, "What's the weather in NYC? Use the tool.")
        |> Request.add_message(:assistant, Response.to_assistant_content(response))
        |> Request.add_message(:user, tool_results)
        |> Request.set_max_tokens(2048)
        |> Request.enable_thinking(%{"type" => "enabled", "budget_tokens" => 1024})
        |> Request.add_tool(tool)

      # The point of the test: this must NOT return {:error, %APIError{status: 400}}.
      assert {:ok, %Response{}} = Messages.create(client, second)
    end
  end
end
