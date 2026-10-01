# Telemetry & OpenTelemetry readiness

- **Date:** 2026-10-01
- **Spec status:** design approved in conversation (sections 1–3, Q, 2026-10-01); written spec awaiting review
- **Scope class:** new telemetry events + additive metadata on existing ones + docs. Lands under
  `[Unreleased]`; no `@version` change in this spec.
- **Provenance:** pre-release telemetry/OTel audit (three read-only auditors, 2026-09-30), every
  headline claim re-checked against this repo (main @ 5a56845). OTel GenAI semantic conventions read
  from `github.com/open-telemetry/semantic-conventions-genai` (`docs/gen-ai/anthropic.md`), status
  **Development**. Library facts below were read from `deps/` at the locked versions
  (telemetry 1.4.2, req 0.7.4, finch 0.24.0).

## Problem

Claudio emits plain `:telemetry` (dep `{:telemetry, "~> 1.0"}`, no OpenTelemetry dep) at two sites:
a `[:claudio, :messages, :create]` span around `Messages.create/2` and a
`[:claudio, :messages, :stream, :usage]` event from `Stream.parse_events/1`. The audit found:

1. **Docs promise events that don't exist.** `CHANGELOG.md:432` (0.2.0) claims
   `[:claudio, :request, :start | :stop | :exception]` "for all LLM API calls"; nothing in `lib/`
   emits it. README says "spans for message calls", but legacy `create_message/2` and
   `count_tokens/2` emit nothing.
2. **The streaming `create` span ends when headers arrive.** Probe: `create/2` returned after 42ms,
   consumption finished at 546ms, `:stop` reported 40ms, no tokens, and `status: :ok` even when the
   stream later carried an SSE `error` event.
3. **The stream usage event can't be attributed.** Metadata is token counts only (no model, id or
   span context); it doesn't fire on early halt or an `error` event; it fires once per enumeration.
4. **No response-side data.** `:stop` metadata lacks response id, `stop_reason` and the model that
   actually answered (`Response.served_by/1` — differs from the requested model with server-side
   fallbacks), so GenAI dashboards mislabel cost and latency.
5. **Errors are unbounded strings.** `error: inspect(reason)` is the only error field; it can embed
   `raw_body` (unique request ids, up to ~4KB of proxy HTML) — unusable as OTel `error.type`.
6. **Tokens are metadata, not measurements**, so `Telemetry.Metrics` `sum`/`last_value` need custom
   `measurement:` functions.
7. **No OTel guidance.** README shows a Logger handler on `:stop` only.
8. **Retries are invisible.** Req retries by re-running request steps (`deps/req/lib/req/steps.ex:1807-1820`)
   and only logs; the non-streaming span's duration silently includes backoff sleeps.
9. **Batches, Files, Models, Admin, Skills, Managed Agents emit nothing.**
10. `usage_to_metadata/1` exists twice (`lib/claudio/messages.ex`, `lib/claudio/messages/stream.ex`).
11. No tests for `:start`, `:exception`, or the streaming `:stop`.

### Verified facts this spec rests on

| # | Fact | Source |
|---|------|--------|
| F1 | `:telemetry.span/3` accepts `{result, extra_measurements, stop_metadata}` (merged with `duration`/`monotonic_time`) since **telemetry 1.3.0**. | `deps/telemetry/src/telemetry.erl:368-376`, CHANGELOG 1.3.0 |
| F2 | `merge_ctx/2` keeps a caller-supplied `telemetry_span_context` instead of generating one. | `telemetry.erl:447-448` |
| F3 | Req retry re-runs **all request steps then the adapter** (`Req.Request.run_request/1`), with `:req_retry_count` in `req.private` (0, 1, …). Retry is decided inside Req's `:retry` response/error step. | `req/steps.ex:1807-1820`, `req/request.ex:1032-1063` |
| F4 | With `into: :self`, Req returns after status + headers; the body arrives later as mailbox messages. | `req/finch.ex:410-426` |
| F5 | Every Anthropic-API module builds its requests from `Claudio.Client.build_request/2` → `Req.new/1` (`client.ex:213`). A2A uses bare URLs and is not covered. | repo |
| F6 | `Req.Response.private` is "a map reserved for libraries and frameworks"; `put_private/3` / `get_private/3`. | `req/response.ex:16,147-157` |
| F7 | `Response.served_by/1` returns the last `fallback` block's `to.model`, else `model`. | `response.ex:386-390` |
| F8 | `Claudio.Agent` is deprecated in MA2. | `2026-09-30-managed-agents-roadmap.md:38` |
| F9 | GenAI semconv (Development): `gen_ai.provider.name` MUST be `"anthropic"`; `gen_ai.usage.input_tokens` MUST equal input + cache_read + cache_creation; cache attrs `gen_ai.usage.cache_read.input_tokens` / `cache_write.input_tokens`; thinking → `gen_ai.usage.reasoning.output_tokens`; content capture is opt-in. | semconv repo (fetched by the audit agent 2026-09-30; re-check names when writing the guide) |

## Goals / non-goals

**Goals**

- An OTel user can build a GenAI-semconv span for every Messages call (request model, response model,
  response id, finish reason, tokens, bounded error type, server address) from documented events,
  with a copy-paste handler.
- Streaming calls get a full-duration span with tokens, attributable to the `create` call.
- Every HTTP attempt to the Anthropic API is visible, including retries, for every endpoint.
- The docs list every event, measurement and metadata key exactly as emitted.
- **Additive only:** every existing event name and metadata key keeps its meaning.

**Non-goals**

- `Claudio.Agent` spans (F8; dropped by Q 2026-10-01).
- A shipped OTel module or `opentelemetry_*` dependency (Q chose docs-only: semconv is Development
  status; a copied example can't break on a semconv rename).
- A2A and MCP adapter instrumentation (not Anthropic traffic / own their transport).
- Capturing prompt or response content in telemetry.
- A `stream :stop` when the consuming process dies mid-stream (would need a watcher process).

## Decisions (Q, 2026-10-01)

| # | Question | Decision |
|---|----------|----------|
| D1 | Streaming span shape | **Keep** the `create` span (documented as "request until headers") and add a separate `[:claudio, :messages, :stream]` start/stop pair emitted by `parse_events/1`; keep `:usage`. |
| D2 | Linking stream → create | `parse_events/1` gains a `%Req.Response{}` clause; `create/2` stores the link in `resp.private[:claudio]`. `parse_events(resp.body)` still works, unlinked. |
| D3 | OTel bridge | Documented handler example only (guide), plus a pointer to `OpentelemetryReq`. |
| D4 | Legacy `create_message/2` | Emits the same `create` span. |
| D5 | Agent spans | Dropped (F8). |
| D6 | `retry?` on `http :stop` | Dropped: it would duplicate Req's retry decision; the next `:start` with `attempt + 1` shows a retry. |

## Event contract

"Existing" keys keep today's meaning. Optional keys are **absent** (not `nil`) when there is no value,
except `status_code`, which is `nil` for transport errors. Measurements are native time units for
`duration` / `monotonic_time`, integers for tokens.

### Catalogue

| Event | Kind | Fires | Status |
|---|---|---|---|
| `[:claudio, :messages, :create]` | `:telemetry.span` (`:start` / `:stop` / `:exception`) | `create/2` and legacy `create_message/2`. Non-streaming: request → parsed response, **including retries and backoff**. Streaming: request → headers (F4). | exists; gains keys; legacy now covered (D4) |
| `[:claudio, :messages, :count_tokens]` | `:telemetry.span` | `count_tokens/2` | new |
| `[:claudio, :messages, :stream]` | `:start` / `:stop` via `:telemetry.execute` (the work is lazy) | Emitted by `parse_events/1` in the **consuming** process. `:start` on `message_start`; exactly one `:stop` on `message_stop`, an SSE `error` event, a parse error `{:error, _}`, or early halt. | new (D1) |
| `[:claudio, :messages, :stream, :usage]` | `:telemetry.execute` | `message_stop` with usage, unchanged | kept; documented as superseded by `stream :stop` |
| `[:claudio, :http, :request]` | `:start` / `:stop` / `:exception` per **attempt** | Req steps on every client built by `Client.new` (F5). A retry is a new `:start` / `:stop` pair. A transport error is a `:stop` with `error_type`; `:exception` only if a step raises. | new |

Guarantees:

- **One `stream :stop` per `stream :start`**, for every ending except the consuming process dying.
- Enumerating the same lazy stream twice yields two start/stop pairs (two consumptions).
- No event carries request/response headers or bodies, the API key, or message content.

### `[:claudio, :messages, :create]`

| Event | Measurements | Metadata |
|---|---|---|
| `:start` | `monotonic_time`, `system_time` | existing: `model` (requested), `stream`. Added: `telemetry_span_context` (generated by Claudio, F2); `max_tokens`, `temperature`, `top_p`, `top_k`, `effort` (from `output_config.effort`) when set; `server_address` (host of the client's `base_url`). |
| `:stop` | `duration`, `monotonic_time`; added: `input_tokens`, `output_tokens`, `cache_creation_input_tokens`, `cache_read_input_tokens`, `thinking_tokens` when present (non-streaming success only) | `:start` keys plus existing: `status` (`:ok` / `:error`), the five token keys (unchanged, still metadata), `error` (inspect string, on error). Added on success: `response_id`, `response_model` (`Response.served_by/1`, F7; non-streaming only), `stop_reason` (atom; non-streaming only), `request_id` (`request-id` response header). Added on error: `error_type`, `status_code`, `request_id` when a response had one. |
| `:exception` | `duration`, `monotonic_time` | `:start` keys plus `kind`, `reason`, `stacktrace` (telemetry's own). |

Legacy `create_message/2` returns string-keyed maps; its `:stop` keys are built from the raw body
(`id`, `model`, `stop_reason`, `usage`) with the same names and types. `response_model` there is the
body's `model` (legacy never parses `fallback` blocks).

### `[:claudio, :messages, :count_tokens]`

| Event | Measurements | Metadata |
|---|---|---|
| `:start` | `monotonic_time`, `system_time` | `model`, `server_address`, `telemetry_span_context` |
| `:stop` | `duration`, `monotonic_time`; `input_tokens` on success | `:start` keys, `status`; `input_tokens` on success; `error_type`, `status_code`, `request_id` on error |
| `:exception` | as above | telemetry's own |

### `[:claudio, :messages, :stream]`

| Event | Measurements | Metadata |
|---|---|---|
| `:start` | `monotonic_time`, `system_time` | `model` (from `message_start`), `response_id` (`message.id`), `telemetry_span_context` (fresh ref for this stream). Linked (`parse_events(resp)`, D2) only: `parent_span_context` (the `create` span's context), `request_id`. |
| `:stop` | `duration`, `monotonic_time`; token measurements as for `create :stop` | `:start` keys plus `reason` (`:completed` \| `:error` \| `:halted`), `stop_reason` (from the last `message_delta`, when seen), `response_model` (last `fallback` block's `to.model`, else `model`), the five token keys (merged `message_start` + `message_delta` usage, delta wins — same rule as `:usage`), `error_type` when `reason: :error`. |

If no `message_start` arrives before the stream ends (empty or garbage body), `:start` is emitted
lazily at the ending with whatever is known, immediately followed by `:stop`, so the pair invariant
holds and a broken stream is still visible.

### `[:claudio, :http, :request]`

| Event | Measurements | Metadata |
|---|---|---|
| `:start` | `monotonic_time`, `system_time` | `method` (atom, e.g. `:post`), `url` (scheme + host + path, **no query string**), `attempt` (`:req_retry_count`, F3: 0 first, +1 per retry), `telemetry_span_context` |
| `:stop` | `duration`, `monotonic_time` | `:start` keys plus `status_code` (`nil` on transport error), `request_id` when present, `error_type` on transport error |
| `:exception` | `duration`, `monotonic_time` | `:start` keys plus `kind`, `reason`, `stacktrace` |

For a streaming request, `http :stop` fires at headers, like the `create` span.

### `error_type` (all events)

A bounded value, never an `inspect` string — the field to map to OTel `error.type`:

| Error | `error_type` |
|---|---|
| `%Claudio.APIError{type: t}` | `t` (atom such as `:rate_limit_error`, or the API's string for an unknown type) |
| `%Req.TransportError{reason: r}` / Mint transport error | `r` when an atom (`:timeout`, `:econnrefused`, `:closed`), else the exception module |
| any other exception struct | its module (e.g. `Req.HTTPError`) |
| SSE `error` event (stream) | the event's `error.type` string, else `:stream_error` |
| parse error `{:error, _}` (stream) | `:parse_error` |
| anything else | `:unknown` |

## Implementation

### `Claudio.Telemetry` (new, `@moduledoc false`)

One private module owns every mapping, replacing both `usage_to_metadata/1` copies (problem 10):

- `usage(usage_map) :: {measurements, metadata}` — atom- or string-keyed usage (incl.
  `output_tokens_details.thinking_tokens`) → the five token keys, absent when nil.
- `error_type(term) :: atom() | String.t()` — the table above.
- `request_metadata(payload) :: map()` — `max_tokens`, `temperature`, `top_p`, `top_k`, `effort`
  from a string- or atom-keyed payload map.
- `server_address(req_or_url) :: String.t() | nil`.
- `attach_http(%Req.Request{}) :: %Req.Request{}` — the HTTP steps below.

It touches no global state; handlers are the caller's.

### HTTP steps (`Client.build_request/2`, `client.ex:213`)

`Req.new(...) |> Claudio.Telemetry.attach_http()`:

- **Request step** `:claudio_telemetry` (appended last, so it runs right before the adapter on every
  attempt, F3): records `{start_monotonic, span_ref}` in `req.private[:claudio_http]`, emits `:start`
  with `attempt = Req.Request.get_private(req, :req_retry_count, 0)`.
- **Response and error steps** `:claudio_telemetry`, **prepended** so they run before Req's `:retry`
  step: emit `:stop` for the attempt just made, then pass the response/exception through unchanged.
  Because Req's retry runs the next attempt inside its own step, prepending is what orders attempt
  *n*'s `:stop` before attempt *n+1*'s `:start`. A plan task must verify the order with a test, not
  assume it.
- A step that raises is reported as `http :exception` and re-raised.

### `Claudio.Messages`

- One private `span/4` helper (`event`, start metadata, payload, fun) used by `create_streaming`,
  `create_non_streaming`, both `create_message` clauses and `count_tokens`. It generates the
  `telemetry_span_context` ref (F2), builds start metadata (`model`, `stream`,
  `Telemetry.request_metadata/1`, `server_address`) and returns `{result, measurements, stop_metadata}`
  (F1).
- On a streaming 200 it stores `%{span_context: ref, model: model, request_id: id}` under
  `Req.Response.put_private(resp, :claudio, ...)` before returning the response (D2).
- `mix.exs`: `{:telemetry, "~> 1.3"}` (F1). Applications locked below 1.3 must update `:telemetry`;
  call this out in the CHANGELOG.

### `Claudio.Messages.Stream`

- `parse_events(%Req.Response{} = resp)` reads `Req.Response.get_private(resp, :claudio)` and runs
  the existing pipeline over `resp.body` with that link; `parse_events(enumerable)` is unchanged
  apart from emitting the unlinked stream span.
- The stream span is a `Stream.transform/5` stage (start / reducer / after):
  - accumulator: `%{started?, stopped?, start_time, ctx, link, model, response_id, usage, stop_reason, response_model}`;
  - reducer emits `:start` on `message_start`, `:stop` (`:completed`) on `message_stop`, `:stop`
    (`:error`) on an SSE `error` event or `{:error, _}` element, and marks `stopped?`;
  - the **after** function emits `:stop` (`:halted`) only when `started?` and not `stopped?`, and the
    lazy start+stop pair when nothing started.
- The existing `:usage` emission stays where it is and keeps its exact metadata.

## Testing

All handlers forward only events emitted by the test process (or filter on a unique model), as in
#28 — the modules are `async: true`.

- **create span:** `:start` / `:stop` keys for streaming and non-streaming; token measurements
  equal the metadata tokens; `response_model` is the fallback model when a `fallback` block is
  present; `stop_reason` atom; `error_type` + `status_code` for a 429 and for `:econnrefused`;
  `:exception` emitted when `Jason` can't encode the payload (re-raised to the caller); legacy
  `create_message/2` streaming and non-streaming emit the span; `telemetry_span_context` equal on
  `:start` and `:stop`.
- **count_tokens span:** success (`input_tokens` measurement) and 4xx error.
- **stream span:** one `:stop` per `:start` for each ending — `message_stop`, SSE `error`, parse
  error, `Enum.take/2` halt, empty body (lazy pair); linked via `parse_events(resp)` (has
  `parent_span_context` equal to the `create` span's ctx and `request_id`); unlinked via
  `parse_events(resp.body)`; `:usage` still emitted with today's metadata; two enumerations → two pairs.
- **http events:** one start/stop pair per attempt with a client `retry: [max_retries: 2, delay: 1]`
  against three 503s (`attempt` 0, 1, 2, each `:stop` before the next `:start`); transport error →
  `:stop` with `error_type: :econnrefused`, `status_code: nil`; a non-Messages endpoint
  (`Claudio.Models.list/2`) emits it; `url` has no query string.
- **No secrets:** a test attaches to every Claudio event, runs a create + count_tokens + Models call
  with token `"sk-test-SECRET"`, and asserts the string appears in no measurement or metadata value
  (`inspect`ed).
- `mix precommit` green; `mix docs --warnings-as-errors` green (CI runs it).

## Documentation

- **New `guides/telemetry.md`** (added to ExDoc `extras`, `mix.exs:101`): the catalogue and the four
  tables above; streaming semantics (`create` = until headers, `stream` = full consumption, pass
  `resp` to link); retries via `http` attempts; a 30–40 line `opentelemetry_telemetry` handler
  mapping `create` and `stream` to a CLIENT span named `"chat #{model}"` with
  `gen_ai.operation.name: "chat"`, `gen_ai.provider.name: "anthropic"`, `gen_ai.request.model`,
  `gen_ai.response.model`, `gen_ai.response.id`, `gen_ai.response.finish_reasons`,
  `gen_ai.usage.input_tokens` (**input + cache_read + cache_creation**, F9),
  `gen_ai.usage.output_tokens`, cache and reasoning token attributes, `server.address`, and
  `error.type`; a pointer to `OpentelemetryReq.attach/2` for HTTP client spans. The example names
  semconv's Development status and the date the attribute names were checked.
- **README:** the telemetry section becomes a short Logger example plus a link to the guide; fix the
  example that logs tokens on a streaming `:stop`; the streaming examples (`README.md:137`,
  `lib/claudio.ex:74`, `lib/claudio/messages.ex:48`, the `Stream` moduledoc) pass `resp` to
  `parse_events/1`.
- **`@doc`:** `create/2`, `create_message/2`, `count_tokens/2`, `parse_events/1` and
  `Client.new/2` name the events they emit and link the guide.
- **CHANGELOG `[Unreleased]`:** Added (count_tokens span, stream span, http events, new keys and
  measurements, guide); Changed (legacy `create_message/2` now emits `create`; `:telemetry` requirement
  `~> 1.3`); a correction note for the 0.2.0 line (`CHANGELOG.md:432`) stating that
  `[:claudio, :request, :*]` never shipped and naming the real events.
- **`CLAUDE.md`:** a Telemetry subsection listing the events and pointing at the guide.

## Risks

| Risk | Mitigation |
|---|---|
| Step ordering relative to Req's `:retry` differs from F3's reading (e.g. a Req minor release reorders steps). | The retry-ordering test pins it; the `unlocked-deps` CI job runs it against the newest Req. |
| Users with handlers on `create :stop` for streams relied on its (short) duration. | Unchanged by design (D1); the guide documents it. |
| `:telemetry ~> 1.3` forces some apps to update. | CHANGELOG callout; telemetry's CHANGELOG lists only additions for 1.3.0 (extra span measurements), no removals. |
| Semconv attribute names change (Development status). | Names live only in the guide's example, not in code (D3). |
| Per-attempt HTTP events add overhead to every request. | Two `:telemetry.execute` calls per attempt; no-ops without handlers. |
