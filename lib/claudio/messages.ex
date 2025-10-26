defmodule Claudio.Messages do
  @moduledoc """
  Client for the Messages API.

  This module provides functions for creating messages, counting tokens, and working
  with streaming responses.

  ## New API (Recommended)

  The new API provides structured request building and response handling:

      alias Claudio.Messages.{Request, Response}

      request = Request.new("claude-3-5-sonnet-20241022")
      |> Request.add_message(:user, "Hello!")
      |> Request.set_max_tokens(1024)
      |> Request.set_temperature(0.7)

      {:ok, response} = Claudio.Messages.create(client, request)
      text = Response.get_text(response)

  ## Legacy API (Backward Compatible)

  The original API using raw maps is still supported:

      {:ok, response} = Claudio.Messages.create_message(client, %{
        "model" => "claude-3-5-sonnet-20241022",
        "max_tokens" => 1024,
        "messages" => [%{"role" => "user", "content" => "Hello"}]
      })

  ## Streaming

  For streaming responses:

      request = Request.new("claude-3-5-sonnet-20241022")
      |> Request.add_message(:user, "Tell me a story")
      |> Request.set_max_tokens(1024)
      |> Request.enable_streaming()

      {:ok, stream} = Claudio.Messages.create(client, request)

      stream
      |> Claudio.Messages.Stream.parse_events()
      |> Claudio.Messages.Stream.accumulate_text()
      |> Enum.each(&IO.write/1)
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
