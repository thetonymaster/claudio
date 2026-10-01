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
      request = Request.new("claude-opus-5-5")
      |> Request.add_message(:user, "Hello!")
      |> Request.set_max_tokens(1024)

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

      request = Request.new("claude-opus-5-5")
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

      request = Request.new("claude-opus-5-5")
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

      request = Request.new("claude-opus-5-5")
      |> Request.set_system_with_cache("Large context here...", ttl: "5m")
      |> Request.add_message(:user, "Question about context")
      |> Request.set_max_tokens(1024)

      {:ok, response} = Claudio.Messages.create(client, request)

      # Check cache metrics
      IO.inspect(response.usage.cache_read_input_tokens)

  ## Legacy API (Backward Compatible)

  The original API using raw maps is still supported:

      {:ok, response} = Claudio.Messages.create_message(client, %{
        "model" => "claude-opus-5-5",
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

  alias Claudio.APIError
  alias Claudio.Messages.{Request, Response}

  @doc """
  Creates a message using the new structured API.

  Accepts either a `Request` struct or a raw map (for backward compatibility).
  Returns either a `Response` struct or raw stream data for streaming requests.

  ## Examples

      # Using Request builder
      request = Request.new("claude-opus-5-5")
      |> Request.add_message(:user, "Hello!")
      |> Request.set_max_tokens(1024)

      {:ok, response} = Claudio.Messages.create(client, request)

      # Using raw map (backward compatible)
      {:ok, response} = Claudio.Messages.create(client, %{
        "model" => "claude-opus-5-5",
        "max_tokens" => 1024,
        "messages" => [%{"role" => "user", "content" => "Hello"}]
      })
  """
  @spec create(Req.Request.t(), Request.t() | map()) ::
          {:ok, Response.t() | Req.Response.t()} | {:error, APIError.t() | term()}
  def create(client, %Request{} = request) do
    client = Claudio.Client.with_betas(client, Request.required_betas(request))
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
  def create_message(client, %{"stream" => true} = payload) do
    # Same as create_streaming/2: not retried, and a non-200 body is drained off the mailbox.
    case Req.post(client, url: "messages", json: payload, into: :self, retry: false) do
      {:ok, %Req.Response{status: 200} = result} ->
        {:ok, result}

      {:ok, %Req.Response{status: status} = resp} ->
        {:error, APIError.from_response(status, drain_async_body(resp))}

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
        "model" => "claude-opus-5-5",
        "messages" => [%{"role" => "user", "content" => "Hello"}]
      })

      IO.puts("Input tokens: \#{count.input_tokens}")
  """
  @spec count_tokens(Req.Request.t(), map() | Request.t()) ::
          {:ok, map()} | {:error, APIError.t() | term()}
  # Messages fields the count endpoint rejects with 400 "Extra inputs are not permitted"
  # (probed 2026-09-25/26), stripped so a request can be counted as built.
  @not_counted ~w(stream max_tokens inference_geo diagnostics fallbacks temperature top_k top_p
                  stop_sequences metadata service_tier container)

  def count_tokens(client, %Request{} = request) do
    client = Claudio.Client.with_betas(client, Request.required_betas(request))

    count_tokens(client, Request.to_map(request))
  end

  def count_tokens(client, payload) when is_map(payload) do
    payload = Map.drop(payload, @not_counted ++ Enum.map(@not_counted, &String.to_atom/1))

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
    metadata = %{model: payload["model"] || payload[:model], stream: true}

    :telemetry.span([:claudio, :messages, :create], metadata, fn ->
      # Not retried: a retried async request would leave the failed attempt's body
      # messages in the caller's mailbox.
      result =
        case Req.post(client, url: "messages", json: payload, into: :self, retry: false) do
          {:ok, %Req.Response{status: 200} = r} ->
            {:ok, r}

          {:ok, %Req.Response{status: status} = resp} ->
            # On non-200, Req with `into: :self` leaves the body as an async
            # reference — drain the mailbox into a decoded body so the error
            # message from Anthropic survives instead of being lost.
            {:error, APIError.from_response(status, drain_async_body(resp))}

          {:error, reason} ->
            {:error, reason}
        end

      {result, enrich_stop_metadata(metadata, result)}
    end)
  end

  # Drain the into: :self mailbox for a non-200 response so the JSON error
  # body from Anthropic is visible instead of silently lost. Non-Req messages
  # (e.g. GenServer casts, monitor DOWNs) that happen to arrive during the
  # drain are buffered and replayed to self() so the caller does not lose them.
  defp drain_async_body(%Req.Response{} = resp) do
    drain_loop(resp, [], [], System.monotonic_time(:millisecond) + 2_000)
  end

  defp drain_loop(resp, acc, unknown, deadline) do
    if System.monotonic_time(:millisecond) > deadline do
      # Cancel so chunks still in flight don't reach the caller's mailbox after we return.
      Req.cancel_async_response(resp)
      finish_drain(acc, unknown)
    else
      receive do
        msg ->
          case Req.parse_message(resp, msg) do
            {:ok, [{:data, chunk} | _rest]} ->
              drain_loop(resp, [acc, chunk], unknown, deadline)

            {:ok, [:done]} ->
              finish_drain(acc, unknown)

            # A transport error ends the body; keep what arrived (the status is authoritative).
            {:error, _reason} ->
              finish_drain(acc, unknown)

            :unknown ->
              drain_loop(resp, acc, [msg | unknown], deadline)

            _ ->
              drain_loop(resp, acc, unknown, deadline)
          end
      after
        200 -> drain_loop(resp, acc, unknown, deadline)
      end
    end
  end

  defp finish_drain(acc, unknown) do
    replay_unknown(unknown)
    acc |> IO.iodata_to_binary() |> try_decode()
  end

  defp replay_unknown([]), do: :ok

  defp replay_unknown(messages) do
    messages
    |> Enum.reverse()
    |> Enum.each(&send(self(), &1))
  end

  # A non-JSON (or empty) body stays a binary so APIError types it from the status.
  defp try_decode(body) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, map} when is_map(map) -> map
      _ -> body
    end
  end

  defp create_non_streaming(client, payload) do
    metadata = %{model: payload["model"] || payload[:model], stream: false}

    :telemetry.span([:claudio, :messages, :create], metadata, fn ->
      result =
        case Req.post(client, url: "messages", json: payload) do
          {:ok, %Req.Response{status: 200, body: body}} when is_map(body) ->
            {:ok, Response.from_map(body)}

          # Includes a 200 whose body isn't a JSON object (e.g. a proxy's text page).
          {:ok, %Req.Response{status: status, body: body}} ->
            {:error, APIError.from_response(status, body)}

          {:error, reason} ->
            {:error, reason}
        end

      {result, enrich_stop_metadata(metadata, result)}
    end)
  end

  defp enrich_stop_metadata(metadata, result) do
    stop_meta =
      metadata
      |> Map.put(:status, elem(result, 0))
      |> maybe_put_usage_metadata(result)

    case result do
      {:error, reason} -> Map.put(stop_meta, :error, inspect(reason))
      _ -> stop_meta
    end
  end

  defp maybe_put_usage_metadata(metadata, {:ok, %Response{usage: usage}}) when is_map(usage) do
    Map.merge(metadata, usage_to_metadata(usage))
  end

  defp maybe_put_usage_metadata(metadata, _result), do: metadata

  defp usage_to_metadata(usage) when is_map(usage) do
    usage
    |> Map.take([
      :input_tokens,
      :output_tokens,
      :cache_creation_input_tokens,
      :cache_read_input_tokens
    ])
    |> Map.put(:thinking_tokens, thinking_tokens(usage))
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end

  # usage.output_tokens_details is carried raw by Response (atom or string keys).
  defp thinking_tokens(usage) do
    case usage[:output_tokens_details] || usage["output_tokens_details"] do
      %{} = details -> details[:thinking_tokens] || details["thinking_tokens"]
      _ -> nil
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
