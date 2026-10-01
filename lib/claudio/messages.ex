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
      text = stream_response
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
  alias Claudio.Telemetry

  @doc """
  Creates a message using the new structured API.

  Accepts either a `Request` struct or a raw map (for backward compatibility).
  Returns either a `Response` struct or raw stream data for streaming requests.

  Emits the `[:claudio, :messages, :create]` span (and, per attempt, `[:claudio, :http, :request]`).
  See the [telemetry guide](telemetry.html). The `error` key on a failed `:stop` is deprecated (it
  can contain the API's error body); use `error_type`.

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

  Emits the `[:claudio, :messages, :create]` span (and, per attempt, `[:claudio, :http, :request]`).
  See the [telemetry guide](telemetry.html). The `error` key on a failed `:stop` is deprecated (it
  can contain the API's error body); use `error_type`.
  """
  @spec create_message(Req.Request.t(), map()) ::
          {:ok, map() | Req.Response.t()} | {:error, term()}
  def create_message(client, %{"stream" => true} = payload), do: create_streaming(client, payload)

  def create_message(client, payload) do
    span([:claudio, :messages, :create], client, payload, create_start(payload, false), fn _ctx ->
      case Req.post(client, url: "messages", json: payload) do
        {:ok, %Req.Response{status: 200, body: body} = resp} when is_map(body) ->
          legacy_ok(body, resp)

        # A 200 whose body isn't a JSON object: returned exactly as before (Review Focus 2).
        {:ok, %Req.Response{status: 200, body: body} = resp} ->
          ok_stop({:ok, atomize_keys_to_strings(body)}, resp, nil, %{})

        {:ok, %Req.Response{status: status, body: body} = resp} ->
          error_stop({:error, APIError.from_response(status, body)}, resp)

        {:error, reason} ->
          error_stop({:error, reason}, nil)
      end
    end)
  end

  @doc """
  Counts tokens for a message request.

  Emits the `[:claudio, :messages, :count_tokens]` span (and, per attempt, `[:claudio, :http, :request]`).
  See the [telemetry guide](telemetry.html).

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

    span([:claudio, :messages, :count_tokens], client, payload, %{}, fn _ctx ->
      case Req.post(client, url: "messages/count_tokens", json: payload) do
        {:ok, %Req.Response{status: 200, body: body} = resp} ->
          count_tokens_ok(body, resp)

        {:ok, %Req.Response{status: status, body: body} = resp} ->
          count_tokens_error_stop({:error, APIError.from_response(status, body)}, resp)

        {:error, reason} ->
          count_tokens_error_stop({:error, reason}, nil)
      end
    end)
  end

  # Private functions

  # No `error` string here: it is deprecated on create :stop and can carry the API's error body.
  defp count_tokens_error_stop(result, resp) do
    {result, measurements, metadata} = error_stop(result, resp)
    {result, measurements, Map.delete(metadata, :error)}
  end

  defp create_streaming(client, payload) do
    span([:claudio, :messages, :create], client, payload, create_start(payload, true), fn ctx ->
      # Not retried: a retried async request would leave the failed attempt's body
      # messages in the caller's mailbox.
      case Req.post(client, url: "messages", json: payload, into: :self, retry: false) do
        {:ok, %Req.Response{status: 200} = resp} ->
          resp = link_stream(resp, ctx, client, payload)
          ok_stop({:ok, resp}, resp, nil, %{})

        {:ok, %Req.Response{status: status} = resp} ->
          # On non-200, Req with `into: :self` leaves the body as an async
          # reference — drain the mailbox into a decoded body so the error
          # message from Anthropic survives instead of being lost.
          error_stop({:error, APIError.from_response(status, drain_async_body(resp))}, resp)

        {:error, reason} ->
          error_stop({:error, reason}, nil)
      end
    end)
  end

  # Drain the into: :self mailbox for a non-200 response so the JSON error
  # body from Anthropic is visible instead of silently lost. Only messages that
  # belong to this response (`{ref, _}`, the body's own ref) are received, so the
  # caller's other mailbox messages (GenServer casts, monitor DOWNs, ...) are never touched.
  defp drain_async_body(%Req.Response{body: %Req.Response.Async{ref: ref}} = resp) do
    drain_loop(resp, ref, [], System.monotonic_time(:millisecond) + 2_000)
  end

  defp drain_loop(resp, ref, acc, deadline) do
    if System.monotonic_time(:millisecond) > deadline do
      # Cancel so chunks still in flight don't reach the caller's mailbox after we return.
      Req.cancel_async_response(resp)
      finish_drain(acc)
    else
      receive do
        {^ref, _} = msg ->
          case Req.parse_message(resp, msg) do
            {:ok, [{:data, chunk} | _rest]} ->
              drain_loop(resp, ref, [acc, chunk], deadline)

            {:ok, [:done]} ->
              finish_drain(acc)

            # A transport error ends the body; keep what arrived (the status is authoritative).
            {:error, _reason} ->
              finish_drain(acc)

            _ ->
              drain_loop(resp, ref, acc, deadline)
          end
      after
        200 -> drain_loop(resp, ref, acc, deadline)
      end
    end
  end

  defp finish_drain(acc), do: acc |> IO.iodata_to_binary() |> try_decode()

  # A non-JSON (or empty) body stays a binary so APIError types it from the status.
  defp try_decode(body) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, map} when is_map(map) -> map
      _ -> body
    end
  end

  # Keys are converted to strings for backward compatibility. The body is parsed (for its
  # telemetry fields) only when Response.from_map/1 accepts it: its sole raising path is a
  # `content` that is neither a list nor absent/nil/false (any list item is accepted, unknown
  # items pass through). Anything else is returned as it always was.
  defp legacy_ok(body, resp) do
    if parseable_content?(body["content"]) do
      response = Response.from_map(body)

      ok_stop(
        {:ok, atomize_keys_to_strings(body)},
        resp,
        body["usage"],
        response_fields(response)
      )
    else
      ok_stop({:ok, atomize_keys_to_strings(body)}, resp, body["usage"], %{})
    end
  end

  defp parseable_content?(content), do: is_list(content) or content in [nil, false]

  defp payload_model(payload), do: payload["model"] || payload[:model]

  defp count_tokens_ok(body, resp) do
    tokens =
      case body do
        %{"input_tokens" => n} when is_integer(n) -> %{input_tokens: n}
        _ -> %{}
      end

    {{:ok, body}, tokens, tokens |> Map.put(:status, :ok) |> put_request_id(resp)}
  end

  defp create_non_streaming(client, payload) do
    span([:claudio, :messages, :create], client, payload, create_start(payload, false), fn _ctx ->
      case Req.post(client, url: "messages", json: payload) do
        {:ok, %Req.Response{status: 200, body: body} = resp} when is_map(body) ->
          response = Response.from_map(body)
          ok_stop({:ok, response}, resp, body["usage"], response_fields(response))

        # Includes a 200 whose body isn't a JSON object (e.g. a proxy's text page).
        {:ok, %Req.Response{status: status, body: body} = resp} ->
          error_stop({:error, APIError.from_response(status, body)}, resp)

        {:error, reason} ->
          error_stop({:error, reason}, nil)
      end
    end)
  end

  # Runs `fun` inside a :telemetry span. Claudio generates the span context (telemetry keeps a
  # caller-supplied one) so a streaming response can carry it to Stream.parse_events/1.
  # `fun` returns {result, measurements, stop_metadata}; extra stop measurements need telemetry >= 1.3.
  defp span(event, client, payload, extra_start, fun) do
    ctx = make_ref()

    start_metadata =
      %{model: payload_model(payload), telemetry_span_context: ctx}
      |> Map.merge(extra_start)
      |> Map.merge(Telemetry.server_metadata(client))

    :telemetry.span(event, start_metadata, fn ->
      {result, measurements, stop_metadata} = fun.(ctx)
      {result, measurements, Map.merge(start_metadata, stop_metadata)}
    end)
  end

  defp create_start(payload, stream?) do
    Map.put(Telemetry.request_metadata(payload), :stream, stream?)
  end

  defp response_fields(%Response{} = response) do
    %{}
    |> Telemetry.put_present(:response_id, response.id)
    |> Telemetry.put_present(:response_model, Response.served_by(response))
    |> Telemetry.put_present(:stop_reason, response.stop_reason)
  end

  defp ok_stop(result, resp, usage, metadata) do
    tokens = Telemetry.usage(usage)

    metadata =
      metadata
      |> Map.merge(tokens)
      |> Map.put(:status, :ok)
      |> put_request_id(resp)

    {result, tokens, metadata}
  end

  defp error_stop({:error, reason} = result, resp) do
    metadata =
      %{
        status: :error,
        error: inspect(reason),
        error_type: Telemetry.error_type(reason),
        status_code: status_code(reason)
      }
      |> put_request_id(resp)

    {result, %{}, metadata}
  end

  defp status_code(%APIError{status_code: code}), do: code
  defp status_code(_reason), do: nil

  defp put_request_id(metadata, nil), do: metadata

  defp put_request_id(metadata, %Req.Response{} = resp),
    do: Telemetry.put_present(metadata, :request_id, Telemetry.request_id(resp))

  # The create span's link, read by Stream.parse_events/1 to emit a linked stream span.
  # It also carries the request params and server info, which the linked stream :start repeats.
  defp link_stream(resp, ctx, client, payload) do
    Req.Response.put_private(resp, :claudio, %{
      span_context: ctx,
      model: payload_model(payload),
      request_id: Telemetry.request_id(resp),
      request_metadata:
        payload |> Telemetry.request_metadata() |> Map.merge(Telemetry.server_metadata(client))
    })
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
