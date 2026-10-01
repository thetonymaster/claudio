# Telemetry

Claudio emits [`:telemetry`](https://hexdocs.pm/telemetry) events for message calls, streams and every HTTP attempt. It has no OpenTelemetry dependency; the events carry what an exporter needs, and this guide lists every event and metadata key and shows an OpenTelemetry GenAI bridge. No event carries request or response headers, bodies, the API key or message content.

## Events

| Event | Kind | Fires |
|---|---|---|
| `[:claudio, :messages, :create]` | span (`:start` / `:stop` / `:exception`) | `Claudio.Messages.create/2` and legacy `create_message/2`. Non-streaming: request to parsed response, **including retries and backoff**. Streaming: request to response headers. |
| `[:claudio, :messages, :count_tokens]` | span | `Claudio.Messages.count_tokens/2` |
| `[:claudio, :messages, :stream]` | `:start` / `:stop` | `Claudio.Messages.Stream.parse_events/1`, in the **consuming** process, around each consumption of the stream |
| `[:claudio, :messages, :stream, :usage]` | single event | `message_stop` with usage. Older event, kept unchanged; superseded by `[:claudio, :messages, :stream, :stop]`. Its token counts are metadata with empty measurements. |
| `[:claudio, :http, :request]` | `:start` / `:stop`, per attempt | Every request made by a client built with `Claudio.Client.new/2` (all Anthropic endpoints). The A2A client (`Claudio.A2A.*`) is not instrumented. |

Guarantees:

- Exactly one `[:claudio, :messages, :stream, :stop]` per `:start`, whatever the ending, except when the consuming process dies. Enumerating the same lazy stream twice is two consumptions, so two start/stop pairs.
- Exactly one `[:claudio, :http, :request, :stop]` per `:start`.
- Optional keys are **absent** (not `nil`) when there is no value, except `status_code`, which is `nil` for transport errors.
- `duration` and `monotonic_time` are in native time units; token measurements are integers.

### `[:claudio, :messages, :create]`

| Event | Measurements | Metadata |
|---|---|---|
| `:start` | `monotonic_time`, `system_time` | `model` (requested; `nil` if the payload has none), `stream`, `telemetry_span_context`. When set: `max_tokens`, `temperature`, `top_p`, `top_k`, `effort` (`output_config.effort`). `server_address` (host of the client's `base_url`). |
| `:stop` | `duration`, `monotonic_time`. Token measurements `input_tokens`, `output_tokens`, `cache_creation_input_tokens`, `cache_read_input_tokens`, `thinking_tokens` appear only when the response carried usage (non-streaming success). | The `:start` keys plus `status` (`:ok` / `:error`) and the same token keys as metadata. On success: `response_id`, `response_model` (the model that served the response; the fallback model if a `fallback` block is present), `stop_reason` (see below), `request_id` (from the `request-id` header). On error: `error` (an `inspect` string, kept for compatibility), `error_type`, `status_code`, and `request_id` when the response had one. |
| `:exception` | `duration`, `monotonic_time` | The `:start` keys plus `kind`, `reason`, `stacktrace` (telemetry's own). |

`stop_reason` is an atom for the values Claudio knows (`:end_turn`, `:max_tokens`, `:tool_use`, ...). A value the API adds later is passed through as a string: Claudio never creates atoms from API input. Handle both, for example with `to_string/1`, as the OpenTelemetry example below does. The same applies to the stream `:stop`.

For streaming calls the `:stop` event fires when the response headers arrive, so it has no token keys, `response_id`, `response_model` or `stop_reason`; read those from the stream events below.

Legacy `create_message/2` with `"stream" => true` behaves like streaming `create/2`: its `:stop` fires at headers with no tokens, and passing the response to `parse_events/1` links the stream span.

Legacy `create_message/2` returns any 200 body unchanged. Its `:stop` carries the response fields (`response_id`, `response_model`, `stop_reason`, tokens) only when the body is a message.

### `[:claudio, :messages, :count_tokens]`

| Event | Measurements | Metadata |
|---|---|---|
| `:start` | `monotonic_time`, `system_time` | `model`, `server_address`, `telemetry_span_context` |
| `:stop` | `duration`, `monotonic_time`; `input_tokens` when the response carried it | The `:start` keys plus `status`. On success: `input_tokens` when present. On error: `error_type`, `status_code`, `request_id` when the response had one. |
| `:exception` | `duration`, `monotonic_time` | The `:start` keys plus `kind`, `reason`, `stacktrace` |

### `[:claudio, :messages, :stream]`

| Event | Measurements | Metadata |
|---|---|---|
| `:start` | `monotonic_time`, `system_time` | `model` (from `message_start`; falls back to the `create` span's model when linked) and `response_id` (both absent if the stream ended before `message_start`), `telemetry_span_context` (fresh for this stream). Only when linked (see below): `parent_span_context` (the `create` span's `telemetry_span_context`) and `request_id`. |
| `:stop` | `duration`, `monotonic_time`, and the token measurements as for `create :stop` | The `:start` keys plus `reason`, `stop_reason` (from the last `message_delta`, when seen), `response_model` (the last `fallback` block's target model, else `model`), the token keys (`message_start` and `message_delta` usage merged, delta wins), and `error_type` when `reason` is `:error`. |

`:start` is emitted when `message_start` arrives. If the stream ends before that (empty or garbage body), `:start` is emitted at the ending, immediately followed by `:stop`, so a broken stream is still visible.

`reason` is one of:

| `reason` | Meaning | `error_type` |
|---|---|---|
| `:completed` | `message_stop` arrived | absent |
| `:error` | an SSE `error` event | the error's `type` string from the API, else `:stream_error` |
| `:error` | a malformed data line | `:parse_error` |
| `:error` | upstream ended without `message_stop` | `:incomplete_stream` |
| `:halted` | the consumer stopped early | absent |

Two caveats. An exception raised mid-enumeration (by the consumer, or by the upstream body, for example a transport failure) also reports `:halted`, because the end-of-stream callback cannot tell it from an early stop. And a parse error ends the span while enumeration continues, so tokens and `stop_reason` seen later are not in that span.

### `[:claudio, :http, :request]`

| Event | Measurements | Metadata |
|---|---|---|
| `:start` | `monotonic_time`, `system_time` | `method` (atom, e.g. `:post`), `url` (scheme, host and path; no query string), `attempt` (0 for the first, +1 per retry), `telemetry_span_context` |
| `:stop` | `duration`, `monotonic_time` | The `:start` keys plus `status_code` (`nil` on a transport error), `request_id` when present, `error_type` on a transport error |

There is no `:exception` event for HTTP: a raise during a call surfaces as the `create` or `count_tokens` span's `:exception`.

The HTTP `:stop` reports the HTTP outcome only. If the body then fails to decode (for example malformed JSON in a 200), the HTTP `:stop` still carries the status (200); the decode error appears in the `create` / `count_tokens` span. For a streaming request the HTTP `:stop` fires when headers arrive.

### `error_type`

A bounded value, never an `inspect` string; map it to OpenTelemetry `error.type`.

| Error | `error_type` |
|---|---|
| `%Claudio.APIError{type: t}` | `t` (an atom such as `:rate_limit_error`, or the API's string for an unknown type) |
| `Req.TransportError` and other exceptions with a `reason` | the reason when it is an atom (`:timeout`, `:econnrefused`, `:closed`), else the exception module |
| any other exception struct | its module (e.g. `Req.HTTPError`) |
| SSE `error` event (stream) | the event's `type` string, else `:stream_error` |
| malformed data line (stream) | `:parse_error` |
| stream ended without `message_stop` | `:incomplete_stream` |
| anything else | `:unknown` |

## Streaming

For a streaming call, `create` measures request to headers, and `stream` measures the whole consumption and carries the tokens. Pass the **whole response** (not `response.body`) to `parse_events/1` to link the two: the stream events then carry `parent_span_context` and `request_id`.

```elixir
{:ok, resp} = Claudio.Messages.create(client, Request.enable_streaming(request))
resp |> Claudio.Messages.Stream.parse_events() |> Claudio.Messages.Stream.accumulate_text()
```

Passing `resp.body` still works and emits the same stream events, without the link.

## Retries

Each attempt is an `[:claudio, :http, :request]` start/stop pair with `attempt` 0, 1, and so on. A redirect (or a digest-auth re-run) is a new pair with the same `attempt`; `attempt` increments only on retries. The non-streaming `create` span's `duration` includes retries and backoff.

## Metrics

```elixir
[
  Telemetry.Metrics.summary("claudio.messages.create.stop.duration", unit: {:native, :millisecond}, tags: [:model, :status]),
  Telemetry.Metrics.sum("claudio.messages.create.stop.input_tokens", tags: [:response_model]),
  Telemetry.Metrics.sum("claudio.messages.stream.stop.output_tokens", tags: [:response_model]),
  Telemetry.Metrics.counter("claudio.http.request.stop.duration", tags: [:status_code])
]
```

## OpenTelemetry

The OpenTelemetry GenAI semantic conventions are in *Development* status and may change. The attribute names below were checked on 2026-10-01 against `github.com/open-telemetry/semantic-conventions-genai`, `docs/gen-ai/anthropic.md`. The handler below compiled without warnings against `opentelemetry_api` 1.5.0, `opentelemetry_telemetry` 1.1.2 and `telemetry` 1.4.2 (checked 2026-10-01).

```elixir
defmodule MyApp.ClaudioOtel do
  @moduledoc "Bridges Claudio telemetry to OpenTelemetry GenAI spans."
  require OpenTelemetry.Tracer, as: Tracer

  @tracer_id __MODULE__
  @events for kind <- [:create, :stream], phase <- [:start, :stop, :exception],
              not (kind == :stream and phase == :exception),
              do: [:claudio, :messages, kind, phase]

  def setup, do: :telemetry.attach_many("my-app-claudio-otel", @events, &__MODULE__.handle_event/4, nil)

  # Successful streaming calls are traced from the stream events (full duration and tokens), so
  # skip their create span, which ends when the headers arrive. A streaming request that fails
  # before headers (429, 401, 5xx, transport error) never reaches parse_events/1, so it has no
  # stream span: record its create :stop (status: :error) as one error span, back-dated by `duration`.
  def handle_event([:claudio, :messages, :create, :stop], %{duration: duration}, %{stream: true, status: :error} = meta, _config) do
    span =
      Tracer.start_span("chat #{meta[:model]}", %{
        kind: :client,
        start_time: :opentelemetry.timestamp() - duration,
        attributes: Map.merge(start_attributes(meta), stop_attributes(meta))
      })

    OpenTelemetry.Span.set_status(span, OpenTelemetry.status(:error, to_string(meta.error_type)))
    OpenTelemetry.Span.end_span(span)
  end

  # A raise during a streaming create (no span was started for it) is recorded the same way.
  def handle_event([:claudio, :messages, :create, :exception], %{duration: duration}, %{stream: true} = meta, _config) do
    span =
      Tracer.start_span("chat #{meta[:model]}", %{
        kind: :client,
        start_time: :opentelemetry.timestamp() - duration,
        attributes: start_attributes(meta)
      })

    OpenTelemetry.Span.record_exception(span, meta.reason, meta.stacktrace, [])
    OpenTelemetry.Span.set_status(span, OpenTelemetry.status(:error, inspect(meta.kind)))
    OpenTelemetry.Span.end_span(span)
  end

  def handle_event([:claudio, :messages, :create, _phase], _measurements, %{stream: true}, _config), do: :ok

  # Stream events carry no `stream` key; every stream span is a streaming request.
  def handle_event([:claudio, :messages, kind, :start], _measurements, meta, _config) do
    OpentelemetryTelemetry.start_telemetry_span(@tracer_id, "chat #{meta[:model]}", meta, %{
      kind: :client,
      attributes: start_attributes(Map.put_new(meta, :stream, kind == :stream))
    })
  end

  def handle_event([:claudio, :messages, _kind, :stop], _measurements, meta, _config) do
    OpentelemetryTelemetry.set_current_telemetry_span(@tracer_id, meta)
    Tracer.set_attributes(stop_attributes(meta))
    if meta[:error_type], do: Tracer.set_status(OpenTelemetry.status(:error, to_string(meta.error_type)))
    OpentelemetryTelemetry.end_telemetry_span(@tracer_id, meta)
  end

  def handle_event([:claudio, :messages, :create, :exception], _measurements, meta, _config) do
    ctx = OpentelemetryTelemetry.set_current_telemetry_span(@tracer_id, meta)
    OpenTelemetry.Span.record_exception(ctx, meta.reason, meta.stacktrace, [])
    Tracer.set_status(OpenTelemetry.status(:error, inspect(meta.kind)))
    OpentelemetryTelemetry.end_telemetry_span(@tracer_id, meta)
  end

  defp start_attributes(meta) do
    compact(%{
      "gen_ai.operation.name" => "chat",
      "gen_ai.provider.name" => "anthropic",
      "gen_ai.request.model" => meta[:model],
      "gen_ai.request.max_tokens" => meta[:max_tokens],
      "gen_ai.request.temperature" => meta[:temperature],
      "gen_ai.request.top_p" => meta[:top_p],
      "gen_ai.request.top_k" => meta[:top_k],
      # Set if and only if the request is streaming.
      "gen_ai.request.stream" => if(meta[:stream] == true, do: true),
      "server.address" => meta[:server_address]
    })
  end

  defp stop_attributes(meta) do
    # gen_ai.usage.input_tokens must include cached tokens.
    input =
      meta[:input_tokens] &&
        meta.input_tokens + (meta[:cache_read_input_tokens] || 0) + (meta[:cache_creation_input_tokens] || 0)

    compact(%{
      "gen_ai.response.id" => meta[:response_id],
      "gen_ai.response.model" => meta[:response_model],
      "gen_ai.response.finish_reasons" => meta[:stop_reason] && [to_string(meta.stop_reason)],
      "gen_ai.usage.input_tokens" => input,
      "gen_ai.usage.output_tokens" => meta[:output_tokens],
      "gen_ai.usage.cache_read.input_tokens" => meta[:cache_read_input_tokens],
      "gen_ai.usage.cache_write.input_tokens" => meta[:cache_creation_input_tokens],
      "gen_ai.usage.reasoning.output_tokens" => meta[:thinking_tokens],
      "error.type" => meta[:error_type] && to_string(meta.error_type)
    })
  end

  defp compact(map), do: map |> Enum.reject(fn {_k, v} -> is_nil(v) end) |> Map.new()
end
```

The handler skips the `create` span of a streaming call, except when it fails. A failed streaming `create` (a `:stop` with `status: :error`, or a `:exception`) is recorded as one error span, back-dated by the event's `duration`; for a `:exception` the span also records the exception. That span is started after the call has returned, so its parent is whatever OpenTelemetry context is current in the calling process: a root span unless the caller has a span open. That is expected, and it nests under the caller's span when there is one.

`gen_ai.request.stream` is set (to `true`) only for streaming requests, as the conventions require; it is absent otherwise.

HTTP client spans come from `OpentelemetryReq.attach(client, propagate_trace_headers: true)` on the client returned by `Claudio.Client.new/2`; Claudio's `[:claudio, :http, :request]` events are for metrics and logs. Finch's streaming path (`into: :self`) runs the request in a linked process, so check that HTTP spans and trace headers appear for streaming calls in your setup.
