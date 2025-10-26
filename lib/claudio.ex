defmodule Claudio do
  @moduledoc """
  Claudio - An Elixir client for the Anthropic API.

  Claudio provides a comprehensive interface for interacting with Claude models
  through the Anthropic API, including support for:

  - Messages API with streaming support
  - Tool/function calling
  - Message Batches API for large-scale processing
  - Request building with validation
  - Structured response handling
  - Token counting

  ## Quick Start

      # Create a client
      client = Claudio.Client.new(%{
        token: "your-api-key",
        version: "2023-06-01"
      })

      # Build and send a request
      alias Claudio.Messages.{Request, Response}

      request = Request.new("claude-3-5-sonnet-20241022")
      |> Request.add_message(:user, "Hello!")
      |> Request.set_max_tokens(1024)

      {:ok, response} = Claudio.Messages.create(client, request)
      text = Response.get_text(response)
      IO.puts(text)

  ## Modules

  - `Claudio.Client` - HTTP client configuration
  - `Claudio.Messages` - Messages API operations
  - `Claudio.Messages.Request` - Request builder
  - `Claudio.Messages.Response` - Response parsing
  - `Claudio.Messages.Stream` - Streaming response handling
  - `Claudio.Batches` - Message Batches API
  - `Claudio.Tools` - Tool/function calling utilities
  - `Claudio.APIError` - API error handling

  ## Examples

  ### Basic Message

      client = Claudio.Client.new(%{
        token: System.get_env("ANTHROPIC_API_KEY"),
        version: "2023-06-01"
      })

      request = Request.new("claude-3-5-sonnet-20241022")
      |> Request.add_message(:user, "What is 2+2?")
      |> Request.set_max_tokens(100)

      {:ok, response} = Claudio.Messages.create(client, request)
      IO.puts(Response.get_text(response))

  ### Streaming

      request = Request.new("claude-3-5-sonnet-20241022")
      |> Request.add_message(:user, "Write a poem")
      |> Request.set_max_tokens(1024)
      |> Request.enable_streaming()

      {:ok, stream} = Claudio.Messages.create(client, request)

      stream
      |> Claudio.Messages.Stream.parse_events()
      |> Claudio.Messages.Stream.accumulate_text()
      |> Enum.each(&IO.write/1)

  ### Tool Use

      alias Claudio.Tools

      weather_tool = Tools.define_tool(
        "get_weather",
        "Get weather for a location",
        %{
          "type" => "object",
          "properties" => %{
            "location" => %{"type" => "string"}
          },
          "required" => ["location"]
        }
      )

      request = Request.new("claude-3-5-sonnet-20241022")
      |> Request.add_message(:user, "What's the weather in Paris?")
      |> Request.add_tool(weather_tool)
      |> Request.set_max_tokens(1024)

      {:ok, response} = Claudio.Messages.create(client, request)

      if Tools.has_tool_uses?(response) do
        tool_uses = Tools.extract_tool_uses(response)
        # Execute tools and continue conversation
      end

  ### Batch Processing

      requests = [
        %{
          "custom_id" => "req-1",
          "params" => %{
            "model" => "claude-3-5-sonnet-20241022",
            "max_tokens" => 1024,
            "messages" => [%{"role" => "user", "content" => "Hello"}]
          }
        }
      ]

      {:ok, batch} = Claudio.Batches.create(client, requests)
      {:ok, final} = Claudio.Batches.wait_for_completion(client, batch.id)
      {:ok, results} = Claudio.Batches.get_results(client, batch.id)
  """
end
