defmodule Claudio.Messages do
  @moduledoc """
  Client for the Anthropic Messages API.

  This module provides functions for creating messages, counting tokens, and working
  with streaming responses. It supports both a structured Request/Response API and
  a legacy map-based API for backward compatibility.

  ## New API (Recommended)

  The new API provides type-safe request building and structured response handling:

      alias Claudio.Messages.{Request, Response}

      # Build a request
      request = Request.new("claude-3-5-sonnet-20241022")
      |> Request.add_message(:user, "Hello!")
      |> Request.set_max_tokens(1024)
      |> Request.set_temperature(0.7)

      # Create message
      {:ok, response} = Claudio.Messages.create(client, request)

      # Extract text
      text = Response.get_text(response)

  ## Features

  - **Streaming**: Real-time response streaming with SSE parsing
  - **Tool calling**: Function calling with structured schemas
  - **Prompt caching**: Cache large contexts to reduce costs
  - **Vision**: Send images for analysis
  - **Token counting**: Estimate costs before making requests
  - **Type safety**: Structured Request/Response types

  ## Streaming

  For streaming responses, enable streaming and consume events:

      request = Request.new("claude-3-5-sonnet-20241022")
      |> Request.add_message(:user, "Tell me a story")
      |> Request.set_max_tokens(1024)
      |> Request.enable_streaming()

      {:ok, stream_response} = Claudio.Messages.create(client, request)

      # Parse and accumulate text
      text = stream_response.body
      |> Claudio.Messages.Stream.parse_events()
      |> Claudio.Messages.Stream.accumulate_text()

      IO.puts(text)

  ## Tool Calling

  Define and use tools for function calling:

      alias Claudio.Tools

      tool = Tools.define_tool("get_weather", "Get weather", %{
        type: "object",
        properties: %{location: %{type: "string"}},
        required: ["location"]
      })

      request = Request.new("claude-3-5-sonnet-20241022")
      |> Request.add_message(:user, "What's the weather?")
      |> Request.add_tool(tool)
      |> Request.set_max_tokens(1024)

      {:ok, response} = Claudio.Messages.create(client, request)

      # Check for tool uses
      if Tools.has_tool_uses?(response) do
        tool_uses = Tools.extract_tool_uses(response)
        # Execute tools and continue conversation...
      end

  ## Prompt Caching

  Cache large contexts to reduce costs (up to 90% savings):

      request = Request.new("claude-3-5-sonnet-20241022")
      |> Request.set_system_with_cache("Large context here...", ttl: "5m")
      |> Request.add_message(:user, "Question about context")
      |> Request.set_max_tokens(1024)

      {:ok, response} = Claudio.Messages.create(client, request)

      # Check cache metrics
      IO.inspect(response.usage.cache_read_input_tokens)

  ## Legacy API (Backward Compatible)

  The original API using raw maps is still supported:

      {:ok, response} = Claudio.Messages.create_message(client, %{
        "model" => "claude-3-5-sonnet-20241022",
        "max_tokens" => 1024,
        "messages" => [%{"role" => "user", "content" => "Hello"}]
      })

  ## Error Handling

  All functions return `{:ok, result}` or `{:error, reason}` tuples:

      case Claudio.Messages.create(client, request) do
        {:ok, response} ->
          IO.puts("Success!")

        {:error, %Claudio.APIError{} = error} ->
          IO.puts("API Error: \#{error.message}")

        {:error, reason} ->
          IO.puts("Error: \#{inspect(reason)}")
      end
  """

  alias Claudio.Messages.{Request, Response}
  alias Claudio.APIError

  @doc """
  Creates a message using the new structured API.

  Accepts either a `Request` struct or a raw map (for backward compatibility).
  Returns either a `Response` struct or raw stream data for streaming requests.

  ## Examples

      # Using Request builder
      request = Request.new("claude-3-5-sonnet-20241022")
      |> Request.add_message(:user, "Hello!")
      |> Request.set_max_tokens(1024)

      {:ok, response} = Claudio.Messages.create(client, request)

      # Using raw map (backward compatible)
      {:ok, response} = Claudio.Messages.create(client, %{
        "model" => "claude-3-5-sonnet-20241022",
        "max_tokens" => 1024,
        "messages" => [%{"role" => "user", "content" => "Hello"}]
      })
  """
  @spec create(Req.Request.t(), Request.t() | map()) ::
          {:ok, Response.t() | Req.Response.t()} | {:error, APIError.t() | term()}
  def create(client, %Request{} = request) do
    create(client, Request.to_map(request))
  end

  def create(client, payload) when is_map(payload) do
    is_streaming = payload["stream"] == true || payload[:stream] == true

    if is_streaming do
      create_streaming(client, payload)
    else
      create_non_streaming(client, payload)
    end
  end

  @doc """
  Creates a message (legacy API, backward compatible).

  This function maintains backward compatibility with the original implementation.
  For new code, consider using `create/2` instead.
  """
  @spec create_message(Req.Request.t(), map()) ::
          {:ok, map() | Req.Response.t()} | {:error, term()}
  def create_message(client, payload = %{"stream" => true}) do
    case Req.post(client, url: "messages", json: payload, into: :self) do
      {:ok, %Req.Response{status: 200} = result} ->
        {:ok, result}

      {:ok, %Req.Response{status: status, body: body}} ->
        {:error, APIError.from_response(status, body)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  def create_message(client, payload) do
    case Req.post(client, url: "messages", json: payload) do
      {:ok, %Req.Response{status: 200, body: body}} ->
        # Convert atom keys to string keys for backward compatibility
        body_with_string_keys = atomize_keys_to_strings(body)
        {:ok, body_with_string_keys}

      {:ok, %Req.Response{status: status, body: body}} ->
        {:error, APIError.from_response(status, body)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Counts tokens for a message request.

  ## Example

      {:ok, count} = Claudio.Messages.count_tokens(client, %{
        "model" => "claude-3-5-sonnet-20241022",
        "messages" => [%{"role" => "user", "content" => "Hello"}]
      })

      IO.puts("Input tokens: \#{count.input_tokens}")
  """
  @spec count_tokens(Req.Request.t(), map() | Request.t()) ::
          {:ok, map()} | {:error, APIError.t() | term()}
  def count_tokens(client, %Request{} = request) do
    # Remove stream and max_tokens as they're not needed for counting
    payload =
      request
      |> Request.to_map()
      |> Map.delete("stream")
      |> Map.delete("max_tokens")

    count_tokens(client, payload)
  end

  def count_tokens(client, payload) when is_map(payload) do
    case Req.post(client, url: "messages/count_tokens", json: payload) do
      {:ok, %Req.Response{status: 200, body: body}} ->
        {:ok, body}

      {:ok, %Req.Response{status: status, body: body}} ->
        {:error, APIError.from_response(status, body)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # Private functions

  defp create_streaming(client, payload) do
    # Req uses `into: :self` for streaming responses
    # This sends messages to the caller's mailbox
    case Req.post(client, url: "messages", json: payload, into: :self) do
      {:ok, %Req.Response{status: 200} = result} ->
        {:ok, result}

      {:ok, %Req.Response{status: status, body: body}} ->
        {:error, APIError.from_response(status, body)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp create_non_streaming(client, payload) do
    case Req.post(client, url: "messages", json: payload) do
      {:ok, %Req.Response{status: 200, body: body}} ->
        {:ok, Response.from_map(body)}

      {:ok, %Req.Response{status: status, body: body}} ->
        {:error, APIError.from_response(status, body)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # Recursively convert atom keys to string keys for backward compatibility
  defp atomize_keys_to_strings(map) when is_map(map) do
    Map.new(map, fn {key, value} ->
      string_key = if is_atom(key), do: Atom.to_string(key), else: key
      string_value = atomize_keys_to_strings(value)
      {string_key, string_value}
    end)
  end

  defp atomize_keys_to_strings(list) when is_list(list) do
    Enum.map(list, &atomize_keys_to_strings/1)
  end

  defp atomize_keys_to_strings(other), do: other
end
