# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- **`Request.disable_thinking/2` `mode: :between_tools`** — Claude Sonnet 5.5's way to turn off
  up-front thinking (`thinking: {"type": "between_tools"}`). `disable_thinking/1` still sends
  `disabled`. The `set_tool_choice/2` docs now list Sonnet 5.5 among models that 400 on forced tool use.
- **`Files.upload/3` accepts `expires_in_seconds:`** (sent as a multipart form field; the API
  documents 3600..7776000). `upload/3` now also rejects unknown options.
- **A2A HTTP transport `:headers` option**: extra request headers (`[{name, value}]`, e.g. W3C
  `traceparent`/`tracestate` for cross-service tracing) are sent on every request. They cannot
  replace the transport's own `content-type` or `authorization` (same name in any case is
  dropped).
- **Telemetry for OpenTelemetry/GenAI dashboards** (see `guides/telemetry.md`):
  `[:claudio, :messages, :create]` gains request params (`max_tokens`, `temperature`, `top_p`,
  `top_k`, `effort`), `server_address`, response fields (`response_id`, `response_model` — the
  fallback model when one served — `stop_reason`, `request_id`), a bounded `error_type` (never
  `nil` on an error stop; `:unknown` when unclassified) and `status_code`, and token counts as
  **measurements** (still also metadata).
  New `[:claudio, :messages, :count_tokens]` span; new `[:claudio, :messages, :stream, :start | :stop]`
  around each stream consumption (duration measured from the start of consumption to its end,
  tokens, exactly one `:stop`), linked to the `create` span when `parse_events/1` is given the
  whole response; new per-attempt `[:claudio, :http, :request, :start | :stop]` for every
  endpoint (retries visible as `attempt`). `create` and `count_tokens` `:start` carry
  `server_port`; a linked stream `:start` also carries `request_model`, the request params that
  were set, `server_address` and `server_port`.
  No event carries headers, bodies, the API key or message content, with two exceptions: the
  deprecated `error` key on a failed `create :stop` (an `inspect` of the error, which can include
  the API's error body or, for a malformed 200, the response body), and the `:exception` events'
  `reason` and `stacktrace` (standard `:telemetry.span` behavior), which can include request or
  response data. Exporters should use `error_type`. `error_type` and token values are bounded:
  a server-supplied type string passes only if it is an identifier (`[a-z][a-z0-9_]{0,63}`),
  else `:unknown`, and a token key is kept only when its value is a non-negative integer.

- `Claudio.Client.new/2` accepts `:timeout`, `:recv_timeout` and `:retry` per client.
  A per-client value wins over `config :claudio, Claudio.Client`, which remains the
  fallback, so one application can run clients with different retry behaviour.
- **Managed Agents foundation** (beta `managed-agents-2026-04-01`, attached per request):
  `Claudio.ManagedAgents.Agents` (create / get incl. `version:` / update / list / archive /
  list_versions), `Claudio.ManagedAgents.Environments` (create / get / update / list / archive /
  delete), `Claudio.ManagedAgents.Sessions` (create / get / update / list / archive / delete,
  `send_events/3`, `list_events/3`, session resources). List options encode the API's bracketed
  filters (`statuses: [...]` → `statuses[]=…`, `created_at: [gte: dt]` → `created_at[gte]=…`).
  `Claudio.ManagedAgents.stream/2` walks cursor-paged lists lazily. Raw-map returns, like
  `Claudio.Skills`.

### Changed

- Builder functions raise `ArgumentError` naming the fix for common mistakes
  (`add_message(:system, …)`, string roles, `nil` content, out-of-range sampling values, string
  `max_tokens` / `tool_choice`, keyword tools / thinking configs) instead of
  `FunctionClauseError`. `set_max_tokens/2` now also rejects non-positive integers.
- Cache helpers (`set_system_with_cache/3`, `add_message_with_cache/4`, `add_tool_with_cache/3`,
  `set_cache_control/2`) raise on unknown options and on a `ttl` other than `"5m"`/`"1h"`;
  `add_message_with_document/5` and `search_result_block/4` raise on unknown options
  (previously ignored).
- `APIError.type` is an atom for `billing_error`, `request_too_large` and `timeout_error` (was a
  string); a JSON error body without `error.type` is typed from the HTTP status, and its
  top-level `message` is used.
- **`Client.new/2` validates its config**: it raises `ArgumentError` on a missing/empty `:token` and on unknown config keys, and accepts a keyword list. `version: nil` now falls back to the default like the other keys (it used to drop the `anthropic-version` header).
- Legacy `Claudio.Messages.create_message/2` now emits the `[:claudio, :messages, :create]` span.
  It recognises only the string key `"stream" => true` as streaming (as before); an atom
  `stream: true` is routed, and labelled, as non-streaming.
- `create :stop` token keys (measurements and metadata) are **absent**, not `0`, when a 200
  response carries no `usage`, and a non-integer token value is dropped. Handlers that read
  `meta.input_tokens` unconditionally should use `Map.get/3`.
- A streaming `Req.Response` from `create/2` / `create_message/2` now carries
  `private.claudio` (the link `Claudio.Messages.Stream.parse_events/1` reads). Code that matches `private: %{}`
  exactly or compares whole responses will see it.
- `Claudio.Client.new/2` adds a `:claudio_telemetry` Req step (request, response and error
  steps) that emits the HTTP events. User steps and `Req.merge/2` keep working; code that
  asserts on the step lists will see it.
- `Claudio.Messages.Stream.parse_events/1` no longer raises on a malformed `message_start` /
  `message_delta` (a non-map `message` or `usage`): it passes the events through.
- `Batches.wait_for_completion/3` and `Batches.list/2` raise on unknown options.
- `Claudio.Messages.Stream.parse_events/1` also accepts the whole `%Req.Response{}`.
- **The `:telemetry` requirement is now `~> 1.3`** (was `~> 1.0`): span stop measurements need
  1.3. Applications locked to an older `:telemetry` will be asked to update it.
- An invalid `retry` value (anything but `true`, `false` or a keyword list) or an unknown
  retry key now raises `ArgumentError`, for per-client and app config alike. Previously
  it was silently ignored and Req's default (GET/HEAD-only retries) applied.
- `timeout` / `recv_timeout` must be a non-negative integer (ms) or `:infinity`; anything
  else raises `ArgumentError` when the client is built (per-client and app config alike).
  Previously a bad value failed on the first request with an error that did not name it.
- `retry:` values (`delay`, `max_delay`, `max_retries`) must be non-negative integers; anything
  else raises `ArgumentError` at `Client.new/2` (previously a bad `delay` raised `ArithmeticError`
  from inside the request).
- `Claudio.Messages.Request.add_message_with_image/5` also takes `media_type:` as a keyword option; `Claudio.Agent.run/4` raises on unknown options.

### Deprecated

- The `error` metadata key on `[:claudio, :messages, :create, :stop]` (an `inspect` string that can
  contain the API's error response body, or a malformed 200's body). It will be removed in 0.8.0; use `error_type`.

### Fixed

- Retries honour `Retry-After` on 529 (overloaded) as well as 429/503, and also when
  `retry: [delay: …]` is set (previously a configured delay overrode the server's Retry-After).
- `Claudio.Tools.tool_definition` and `tool_result` typespecs described atom-keyed maps;
  `define_tool/3` and `create_tool_result/4` return string-keyed maps. The types now match
  (documentation-only; no runtime change).
- The legacy streaming `Claudio.Messages.create_message/2` now matches `create/2`: it is
  never retried (a retried `into: :self` request left the failed attempt's body messages in
  the caller's mailbox), and a non-200 error body is drained off the mailbox, so the
  `APIError` carries the API's message instead of a generic "Streaming request failed".
- Draining a streaming error body (both streaming paths) now cancels the response when its 2s
  deadline expires, so chunks still in flight no longer land in the caller's mailbox after
  the call returns, and a transport error mid-body ends the drain at once instead of
  waiting out the deadline. The `APIError` keeps the HTTP status either way.
- Draining a streaming error body now receives only the messages of its own response (a selective
  receive on the body's ref). Unrelated messages in the caller's mailbox are no longer taken off
  and re-sent to the end, so their order is untouched.

### Security

- **The `req` requirement is now `~> 0.6 and >= 0.6.1`** (was `~> 0.5`). Every req
  release before 0.6.1 carries EEF-CVE-2026-49755 (decompression-bomb DoS) and
  everything before 0.6.0 carries EEF-CVE-2026-49756 (multipart header injection, which
  `Files.upload/3` and `Skills.create/2` uploads would reach). Applications locked to an
  older req will be asked to update it. Verified: the suite passes on req 0.6.1
  (with finch 0.22.0, mint 1.11.0) as well as the locked 0.7.4.
- Locked dependencies updated past Hex security advisories (req 0.5.15 → 0.7.4,
  mint 1.6.2 → 1.11.0, hpax 1.0.0 → 1.1.0, and the test-only plug/cowboy stack).
  `mix.lock` does not ship with the package: applications using Claudio should run
  `mix deps.update req mint hpax` themselves. Test-only cowboy/cowlib are pinned to
  2.18.0/2.19.0 (cowlib 2.20.0 does not compile on OTP 26); three cowlib advisories in
  that test-only server are acknowledged in `mix.exs` (`hex: [ignore_advisories: ...]`).

### Internal

- Added Credo (`--strict`) and Dialyxir, a `mix precommit` alias, and CI checks for
  Credo, Dialyzer, `docs --warnings-as-errors`, `hex.audit`, and unlocked dependencies.

## [0.7.0] - 2026-09-26

### Fixed

- **MCP connector** now emits a valid `mcp-client-2025-11-20` request:
  `Request.add_mcp_server/2` adds the `mcp_toolset` entry to `tools` and declares
  the beta. Previously the request had no toolset and no beta header and was rejected.
- `Response.usage` keeps `output_tokens_details` (raw map, e.g. `thinking_tokens`);
  it was dropped by the usage parser.
- `set_output_format/2` (and the new output-config helpers) no longer emit a duplicate
  key when `set_output_config/2` was given atom keys — existing keys are stringified first.
- `Claudio.Messages.Stream.build_final_message/1` merges `message_delta` usage over `message_start` usage
  instead of replacing it, so `input_tokens` (and cache counters) survive when the delta
  omits them; previously the parsed `Response.usage` came back as a raw, incomplete map.
- `Claudio.Messages.Stream.build_final_message/1` keeps a streamed threshold-compaction summary
  (`compaction_delta`); it was dropped, leaving `"content": null`.
- `Request.set_context_management/2` also declares `compact-2026-01-12` when its edits hold a
  `compact_20260112` edit; with only `context-management-2025-06-27` the API rejects it. Its
  doc example (`"strategy" => "auto"`) was not a real API shape and is replaced.
- `Response.to_assistant_content/1` re-emits `toolset_name` and `caller` on `tool_use` (and
  `caller` on `server_tool_use` / `web_search_tool_result`); replaying a client-toolset call
  without `toolset_name` was rejected.
- `Claudio.Messages.Stream.build_final_message/1` decodes streamed tool input (`input_json_delta` chunks on
  `tool_use` / `server_tool_use` / `mcp_tool_use`) into the block's `"input"`; it was left as an
  undecoded `"partial_json"` string with an empty `input`. Invalid JSON (e.g. cut off by
  `max_tokens`) returns `{:error, {:invalid_tool_input_json, index, partial_json}}`.
- **Streaming:** `Claudio.Messages.Stream.parse_events/1` no longer tears apart an event split
  across network chunks (it emitted an `event:` with no data and a `data:` with no event, which
  crashed `build_final_message/1` or silently lost the event). CRLF line endings, multi-line
  `data:` and a final event without a trailing blank line are handled. `build_final_message/1`
  keeps interleaved blocks (keyed by index) and returns an error for a truncated stream —
  `{:incomplete_stream, indexes}` for a block that never closed, `{:incomplete_stream,
  :no_message_stop}` when `message_stop` never arrived — instead of a message silently missing
  content and `stop_reason`. Streamed usage telemetry merges `message_start` usage (input
  and cache counts were lost).
- `Response.to_assistant_content/1` no longer sends `server_name` on a replayed
  `mcp_tool_result` — the API rejects it, so replaying any MCP-connector turn failed.
- `Request.add_message/3` with parsed `Response` content (e.g. `response.content`) sends each
  block in API shape (keeping a `cache_control` you added); it sent `"caller": null`, which the
  API rejects.
- `Claudio.Messages.count_tokens/2` also strips `temperature`, `top_k`, `top_p`,
  `stop_sequences`, `metadata`, `service_tier` and `container` (Request and raw-map forms) — each
  made the count endpoint return 400, so a request using them couldn't be counted.
- `Claudio.APIError.from_response/2` handles non-JSON bodies (an empty 5xx, a proxy's HTML
  page — streaming or not) and odd JSON error shapes instead of raising; the type comes from the
  HTTP status (429 → `:rate_limit_error`, 529 → `:overloaded_error`, …). A 200 whose body isn't
  a JSON object is an `APIError` too.
- **Retries actually happen:** the documented `config :claudio, Claudio.Client, retry: ...`
  was a no-op placeholder (and Req's default never retries POST). It now retries 408, 429,
  5xx, 529 and connection errors on every method; `retry: false` disables retries (Req's
  GET/HEAD default too). Streaming requests are not retried.
- `config :claudio, default_api_version: ..., default_beta_features: [...]` (the documented
  form) is honoured; only the nested `config :claudio, :claudio, ...` form was read.
- `Claudio.Batches.create/2` drops `stream` from `%Request{}` items (batch items are never
  streamed).
- `Claudio.Agent`: a handler returning `{:error, %SomeException{}}` / `{:error, {:tuple, ...}}`
  no longer crashes with a protocol error (the reason becomes text); `stream: true` requests
  and `max_turns` < 1 raise a clear `ArgumentError` (was a `CaseClauseError` / one call); a
  failed on-demand compaction no longer re-sends the compaction request every turn.
- `Claudio.MCP.ToolAdapter.to_claudio_tool/2` emits tools the API accepts: no `"description":
  null`, an `input_schema` with `"type"`, and an `ArgumentError` for names outside
  `^[a-zA-Z0-9_-]{1,128}$` (were 400s).
- MCP adapters: `HermesMCP` unwraps Hermes response structs (list functions returned
  `{:ok, []}`), passes `opts`, and documents the client-first module
  (`{Hermes.Client.Base, MyClient}` — the old `{MyClient, pid}` usage crashed); `ExMCP` requests
  `format: :map` (list functions returned `{:ok, []}` under ex_mcp 1.5's default); no adapter
  reports a bug inside the library as "not available". Version constraints corrected
  (`ex_mcp ~> 1.5`, `mcp_ex ~> 0.1`).
- `Tools.create_tool_result/4` rejects content the API would reject (an empty error result, a
  list of non-block values) and raises `ArgumentError` for unencodable values instead of a
  protocol error; `Tools.extract_tool_uses/1` normalizes a raw `tool_use` without `input`.
- `Request` tool helpers: atom-keyed tool maps no longer get a duplicate JSON key;
  `add_tool_with_cache/3` validates its options (`:ttl`, `:allowed_callers`) instead of silently
  dropping others; `add_web_search_tool/2`, `add_web_fetch_tool/2`, `add_text_editor_tool/2`
  validate options and accept dated version atoms; `add_message_with_image/5` detects PNG, GIF
  and WebP data when no media type is given (it always sent `image/jpeg`).
- Removed the `:poison` dependency and a bug where every GET/DELETE request (Models, Files,
  Batches, Admin, Skills) sent the literal body `"Elixir.Poison"` (#17). If your app used Poison
  only through Claudio, add it yourself.

### Changed

- `Claudio.MCP.ServerConfig`: `:tool_configuration` struct field removed; tool
  selection lives on the toolset (`:default_config`, `:configs`).
  `allow_tools/2` now takes **exact tool names** and raises `ArgumentError` on
  `*`/`?` patterns (the connector matches names literally; a pattern would enable
  no tools). Raw maps with legacy `tool_configuration` are translated with a warning.
- `Claudio.Skills` no longer attaches `anthropic-beta: skills-2025-10-02` (Skills API is GA).
  `Skills.list/2` responses lose `"has_more"` (verified live; `list_versions/3` not probed) — page with
  `next_page` → `:page`, or opt back in with
  `Claudio.Client.with_betas(client, ["skills-2025-10-02"])`.
- `Request.add_mcp_server/2` raises `ArgumentError` when `tools` already holds an
  `mcp_toolset` for that server and the new server carries tool config (it would
  otherwise be dropped).
- `ServerConfig.allow_tools/2` replaces any previous allowlist: tools enabled only by
  an earlier call are no longer enabled (other per-tool settings are kept).
  `set_default_config/2` / `configure_tool/3` store setting keys as strings.
- `Request.add_mcp_server/2` raises `ArgumentError` when a server with the same
  name is already on the request (the connector requires unique server names).
- `Request.add_code_execution_tool/2` defaults to `code_execution_20260521`
  (same runtime as `20260120`).
- `Response.usage` keeps every field the API returns: documented fields are atom keys
  (new: `cache_creation`, `service_tier`, `inference_geo`, `speed`, `iterations`); any other field is kept
  under the key it arrived with instead of being dropped. Documented fields the API did not
  send now appear as `nil`, so exact `usage == %{...}` comparisons need the new keys.
- `Claudio.Messages.count_tokens/2` strips every field the count endpoint rejects (see Fixed),
  for raw maps too.
- `Response.to_assistant_content/1` applies the API's continuation rules after a server-side
  fallback: before the last `fallback` block it drops `thinking`, `redacted_thinking`,
  `connector_text` and `tool_use`, and keeps `server_tool_use` / `mcp_tool_use` only when their
  result is present. Output is unchanged for responses without a `fallback` block, or with it
  first (the normal non-streaming shape).
- `Response.get_tool_uses/1`, `Tools.extract_tool_uses/1` (so `has_tool_uses?/1`) and
  `MCP.ResultMapper.extract_mcp_calls/1` skip `tool_use` blocks before the last `fallback` block —
  they came from the model that declined.
- `Request.add_message/3` declares `server-side-fallback-2026-07-01` when its content holds a
  `fallback` block; the API rejects a replayed `fallback` block without it.
- `Response.stop_reason` is `:compaction` (was the string `"compaction"`).
- `Request.add_message/3` sends a typed content block that carries `raw:` (e.g. from
  `Response.compaction_block/1`) as its original API map instead of the typed map.
- Parsed `tool_use` blocks gain `caller` and `toolset_name`, `server_tool_use` gains `caller`,
  `web_search_tool_result` gains `caller` and `raw` (`nil` when absent). Code matching the
  whole map with `==` must add them. The same holds for the maps `Tools.extract_tool_uses/1`
  returns (now with `toolset_name` and `caller`).
- `Request.add_computer_tool/4` raises `ArgumentError` on unknown options (they were ignored).
- `Claudio.Agent` resumes `pause_turn` (counts toward `:max_turns`) instead of returning it,
  carries the response `container` to the next request, and dispatches client-toolset calls
  to the handler keyed by `toolset_name`. A handler of the wrong arity is now an error result
  instead of a crash.
- `Claudio.Agent` continues after `stop_reason: :compaction` (`Request.apply_compaction/2`, then
  another call with no user turn; counts toward `:max_turns`) instead of returning the summary
  as the final reply. A handler returning anything other than `{:ok, _}` / `{:error, _}` raises
  `ArgumentError` naming the handler (was a `CaseClauseError`).
- **`Claudio.Agent.run/4` errors keep the history:** an API error mid-loop returns
  `{:error, reason, last_response_or_nil, messages}` (was `{:error, reason}`, which discarded
  executed turns). Match the 4-tuple, like `:max_turns_exceeded`.
- `Claudio.Batches.get_results/2` decodes results with **string keys** (was `keys: :atoms`),
  like every other response, and returns `{:error, {:invalid_result_line, n, line}}` for a
  malformed line instead of silently dropping it.
- Server-result blocks that were raw string-keyed maps in 0.6 (`web_fetch_tool_result`,
  `code_execution_tool_result`, `bash_code_execution_tool_result`,
  `text_editor_code_execution_tool_result`, `tool_search_tool_result`, `advisor_tool_result`,
  `container_upload`, `compaction`) now parse as typed maps (`%{type: :atom, ..., raw: map}`);
  code matching `%{"type" => "web_fetch_tool_result"}` on `response.content` must match the
  atom type or read `raw`.
- Stream parse errors carry `%Jason.DecodeError{}` (was `%Poison.ParseError{}`).
- `Claudio.MCP.ToolAdapter.to_claudio_tool/2` omits a nil `"description"` and raises on invalid
  names (see Fixed).
- The Messages streaming path requires a complete stream: a block that never closes is an error
  (see Fixed).
- Unknown-option errors name the function: `Request.add_web_search_tool/2: unknown option
  :max_use; allowed: :version, ...` (was `Keyword.validate!/2`'s "unknown keys [...]"). A
  non-keyword `opts` is an `ArgumentError` naming the function instead of a `FunctionClauseError`
  from `Keyword`. Still `ArgumentError`; code matching the old message text must update.

### Added

- `ServerConfig.to_toolset/1`, `set_default_config/2`, `configure_tool/3`, `split_raw/1`.
- `Files.list/2` GA pagination options `:page` and `:ids`.
- `add_code_execution_tool/2` `:version` option.
- `Response.stop_details` (also accumulated by `Claudio.Messages.Stream.build_final_message/1`).
- **Thinking & effort helpers** (`Claudio.Messages.Request`), no per-model validation:
  - `enable_adaptive_thinking/2` (`display:` `:summarized` / `:omitted` / `:updates`;
    `:updates` declares `thinking-display-updates-2026-08-18`) and `disable_thinking/1`.
  - `set_effort/2` (`:low` … `:max`, GA) and `set_task_budget/3` (`output_config.task_budget`,
    declares `task-budgets-2026-03-13`) — both merge into `output_config`.
- `Response.get_thinking/1`, `Response.thinking_interrupted?/1`, `Claudio.Messages.Stream.accumulate_thinking/1`.
- Telemetry: `:thinking_tokens` in `[:claudio, :messages, :create, :stop]` and
  `[:claudio, :messages, :stream, :usage]` metadata, when the API reports it.
- **5.x request surface** (`Claudio.Messages.Request`), no per-model or placement validation:
  - `add_system_message/3` — mid-conversation `role: "system"` messages (GA); `clear_at:`
    declares `mid-conversation-system-clear-at-2026-08-21`, `effort:` (per-message effort)
    declares `mid-conversation-output-config-2026-07-01`.
  - `set_speed/2` (`:fast` / `:standard`, always declares `fast-mode-2026-02-01`),
    `set_inference_geo/2` (`:global` / `:us`, GA), `enable_cache_diagnostics/2` (GA).
- `Response.diagnostics` (raw cache-diagnostics map).
- **Refusal fallbacks:** `Request.set_fallbacks/2` (`:default` or up to three models / override
  maps; declares `server-side-fallback-2026-07-01`); typed `:fallback` content blocks (original
  kept under `raw:` and replayed verbatim); `Response.fallbacks/1`, `Response.served_by/1`;
  `usage.iterations`.
- **Context management** (`Claudio.Messages.Request`), no local limits (the API's 400 is
  authoritative):
  - `add_clear_tool_uses/2`, `add_clear_thinking/2` (always placed first) — declare
    `context-management-2025-06-27`; `add_compaction/2` (threshold, `compact_20260112`) —
    declares `compact-2026-01-12`.
  - `request_compaction/2` — on-demand `compaction: {"type": "summarize"}`, declares
    `compact-2026-09-04`; `apply_compaction/2` continues from a compaction summary (either
    kind) by replacing the history with the block onward.
  - `add_message/3` declares the replay beta for a `compaction` block (signed →
    `compact-2026-09-04`, unsigned → `compact-2026-01-12`).
- Typed `:compaction` content blocks (original under `raw:`, replayed verbatim),
  `Response.compaction_block/1`, `Response.context_management` (raw `applied_edits`; also
  read from the streamed `message_delta`).
- **Tool extensions** (`Claudio.Messages.Request`): `add_tool/3` (`defer_loading:`,
  `allowed_callers:` — `:direct` / `:code_execution` → `"code_execution_20260120"`);
  `add_tool_search_tool/2` (`:regex` / `:bm25`, GA); `add_advisor_tool/3` (declares
  `advisor-tool-2026-03-01`; `add_message/3` declares it for replayed advisor blocks);
  `add_computer_toolset/2` / `add_browser_toolset/2` (`computer_toolset_20260801` /
  `browser_toolset_20260801`, GA); `add_computer_tool/4` `version: :"20251124"`.
- Shallowly typed server-result blocks (`web_fetch_tool_result`, `code_execution_tool_result`,
  `bash_code_execution_tool_result`, `text_editor_code_execution_tool_result`,
  `tool_search_tool_result`, `advisor_tool_result`, `container_upload`; `raw:` replayed
  verbatim), `Response.get_server_tool_results/1,2`, `Response.container` (also from the
  stream).
- `Tools.create_tool_result/4` (`toolset_name:`); `Tools.halt_result/1`, `Tools.halt_text/1`.
- **Thinking block binding:** `enable_adaptive_thinking/2` `block_binding:` and
  `Request.set_thinking_block_binding/2` (`:error` / `:drop_block`; declare
  `thinking-binding-controls-2026-08-01`); `Response.input_transformations` (raw list, `nil`
  without the beta; replaced by a streamed `message_delta` copy after a fallback).

### Docs

- Examples use `claude-opus-5-5` (sampling-setter examples use `claude-haiku-4-5`, since Opus 4.7+ and 5.x reject sampling params); `enable_thinking/2` and `set_tool_choice/2`
  document the 400s on current models; Files documented as GA.
- README and the getting-started guide: install snippet (`~> 0.7`), working streaming, Batches
  and telemetry examples (the old ones called functions or events that don't exist); CLAUDE.md
  arities and key-style notes corrected; the CHANGELOG is published on hexdocs; CI covers
  Elixir 1.18 / OTP 27 and 1.19 / OTP 28.

## [0.6.0] - 2026-06-19

A large coverage release closing the gap between Claudio and the current
Anthropic API surface (roadmap specs S1–S9). All additions are
backward-compatible — no breaking changes.

### Added

- **Models API** (`Claudio.Models`) — GA, no beta header.
  - `list/2` (`GET /v1/models`, paginated: `:limit`, `:before_id`, `:after_id`)
    and `get/2` (`GET /v1/models/{id}`, id or alias).
- **Structured outputs** (`Claudio.Messages.Request`) — GA.
  - `set_output_format/2` builds `output_config.format` from a JSON schema;
    `set_output_config/2` is the raw setter.
  - `add_strict_tool/2` (`strict: true`) and `add_tool_with_eager_streaming/2`
    (`eager_input_streaming: true`).
- **Message-level prompt caching** — `add_message_with_cache/4` (per-message
  `cache_control` breakpoints) and `set_cache_control/2` (top-level).
- **Per-feature beta-header management** — `Request.add_beta/2` /
  `required_betas/1` and `Client.with_betas/2`; feature setters (e.g.
  `set_context_management/2`) declare their own betas, which the send path
  merges into `anthropic-beta` automatically.
- **Citations & search results** — GA.
  - `add_message_with_document/5` threads `:citations` / `:title` / `:context`
    (backward-compatible with the `/4` arity).
  - `search_result_block/4` builds RAG `search_result` content blocks.
  - `Response.get_citations/1` aggregates citations preserved on `text` blocks
    (`char_location`, `page_location`, `content_block_location`,
    `search_result_location`, `web_search_result_location`).
  - `server_tool_use` and `web_search_tool_result` content blocks are now typed;
    `Response.get_server_tool_uses/1` extracts them.
- **Server-side tool helpers** (`Claudio.Messages.Request`) — only computer-use
  declares a beta (`computer-use-2025-01-24`, auto-declared):
  - `add_web_search_tool/2`, `add_web_fetch_tool/2`,
    `add_code_execution_tool/1`, `add_bash_tool/1`, `add_text_editor_tool/2`,
    `add_memory_tool/1`, `add_computer_tool/4`.
- **Admin API** (`Claudio.Admin`) — GA, uses an Admin API key (`sk-ant-admin…`)
  via the existing `x-api-key` header.
  - Organization (`get_organization/1`), members, invites, workspaces, API keys,
    and usage/cost reports (`usage_report/2`, `cost_report/2`).
- **Bearer / OAuth auth** (`Claudio.Client`) — `auth_type: :bearer` sends
  `Authorization: Bearer <token>` (for OAuth / Workload Identity Federation
  tokens) instead of `x-api-key`. Defaults to `:api_key` (no behavior change).
- **Agent Skills API** (`Claudio.Skills`) — beta `skills-2025-10-02` (attached
  automatically). `list/2`, `get/2`, `delete/2`, version sub-resources, and
  multipart `create/2` / `create_version/3`.

### Fixed

- **Extended-thinking multi-turn round-trips** — `thinking` blocks now preserve
  `signature`, `redacted_thinking` blocks are typed and preserved, and the
  streaming parser keeps `signature_delta` / `citations_delta`. Replaying an
  extended-thinking + tool-use turn no longer triggers `400 invalid_request_error`.
  `Response.to_assistant_content/1` is the single serializer (the divergent
  `Agent` serializer was removed).
- **Response content getters tolerate untyped blocks** — `get_text/1`,
  `get_tool_uses/1`, `get_citations/1`, `get_server_tool_uses/1`, and
  `get_mcp_tool_uses/1,2` no longer raise `KeyError` on raw blocks Claudio
  doesn't type (e.g. `code_execution_tool_result` from dynamic-filtering
  web search).

### Notes

- **Not implemented (documented):** Bedrock/Vertex transports (SigV4 / GCP ADC)
  and the OAuth token-exchange flow are out of scope (supply an already-obtained
  bearer token); prompt-tools (`/v1/experimental/*`) are deferred (experimental,
  access-gated, beta header unverified).

## [0.5.0] - 2026-05-01

### Added

- **Anthropic Files API support** (beta `files-api-2025-04-14`)
  - `Claudio.Files.upload/3` — multipart upload to `/v1/files`
  - `Claudio.Files.list/2` — paginated listing with `:limit`, `:before_id`, `:after_id`
  - `Claudio.Files.get/2` — fetch file metadata
  - `Claudio.Files.download/2` — fetch raw file bytes (binary, not JSON-decoded)
  - `Claudio.Files.delete/2` — delete a file
  - Uploaded files are referenced from messages via the existing
    `Claudio.Messages.Request.add_message_with_document/4` helper (no API change required there)
  - Module grouped under "Files API" in ex_doc
  - Callers must opt in to the beta by passing `beta: ["files-api-2025-04-14"]`
    to `Claudio.Client.new/2`, or via `config :claudio, :claudio,
    default_beta_features: ["files-api-2025-04-14"]`

## [0.4.0] - 2026-04-24

### Changed

- **BREAKING: Streaming event data now decoded with string keys**
  - `Claudio.Messages.Stream.parse_events/1` previously decoded SSE event payloads
    with `Poison.decode(keys: :atoms)`, producing atom-keyed data maps. It now
    decodes with Poison's default (string keys), matching the raw Anthropic JSON
    convention.
  - This is a **breaking change for external consumers that pattern-match on
    atom keys** inside `event.data` (e.g. `%{delta: %{type: "text_delta"}}`).
    Downstream code should switch to string keys
    (`%{"delta" => %{"type" => "text_delta"}}`).
  - Claudio's internal helpers (`accumulate_text/1`, `apply_delta/2`,
    `build_final_message/1`, `update_current_block/2`) already read
    `data["x"] || data[:x]` defensively, so this is a no-op inside Claudio.

### Fixed

- **Fail loudly on malformed SSE JSON payloads**
  - `parse_event/1` previously swallowed `Poison.decode/1` errors as
    `{:ok, %{event: ..., data: nil}}`, hiding corruption and leaving downstream
    consumers to operate on silently-missing data.
  - Decode failures now return `{:error, {:invalid_event_data_json, event_type, reason}}`,
    consistent with the existing `{:invalid_event, _}` error tag emitted by the
    same function.

## [0.3.0] - 2026-04-19

### Added

- **Messages telemetry usage metadata**
  - `[:claudio, :messages, :create, :stop]` now includes flat token usage metadata keys for non-streaming success:
    - `:input_tokens`
    - `:output_tokens`
    - `:cache_creation_input_tokens`
    - `:cache_read_input_tokens`
  - Nil usage values are omitted from telemetry metadata to keep downstream integer matching clean
- **Streaming usage telemetry event**
  - New `[:claudio, :messages, :stream, :usage]` event emitted when stream consumption reaches `message_stop` and final usage is available

### Changed

- Documented streaming telemetry contract in `Claudio.Messages.Stream` to clarify that final streaming usage is emitted separately from request-span stop metadata

## [0.2.0] - 2026-04-18

### Added

- **Full MCP (Model Context Protocol) Support**
  - Modular adapter system for different MCP server implementations
  - Integration with `ex_mcp`, `hermes_mcp`, and `mcp_ex`
  - Tool adapter for seamless conversion between MCP tools and Claudio tools
- **`Claudio.Agent` Stateless Tool-Calling Loop**
  - Autonomous agent loop that handles multiple rounds of tool execution
  - Support for custom callbacks and max iterations
- **Agent-to-Agent (A2A) Protocol Support**
  - Typed client for agent communication
  - Support for multi-agent workflows with common transport interfaces (HTTP, gRPC)
  - Extensible transport layer using the Strategy pattern
- **Cloud Observability & Telemetry**
  - Emits `:telemetry` events for all LLM API calls (`[:claudio, :request, :start | :stop | :exception]`)
    - *Correction (2026-10-01):* `[:claudio, :request, ...]` never shipped; 0.2.0 emitted
      `[:claudio, :messages, :create]`. See the telemetry guide for the current events.
  - Track request duration, token usage, and error reasons
  - Support for custom Finch connection pools to manage concurrency
- **Issue Tracking with Beads**
  - Initialized `bd` (beads) for issue and task tracking in the repository

### Changed

- Updated default model to `claude-sonnet-4-5-20250929` across documentation and examples
- Removed unused dependencies from `mix.lock`

### Fixed

- **Critical**: Fixed `UndefinedFunctionError` when streaming requests fail by ensuring async body is drained on error
- Improved error reason reporting in telemetry events

## [0.1.2] - 2025-01-26

### Added

- GitHub Actions CI workflow for automated testing
  - Test on Elixir 1.15-1.17 and OTP 26-27
  - Run unit tests on all PRs and pushes to main
  - Run integration tests on main branch (requires ANTHROPIC_API_KEY)
  - Check code formatting and unused dependencies

### Changed

- **Major README overhaul** with comprehensive documentation
  - Added "Why Claudio?" section highlighting key benefits
  - Added detailed real-world examples for all features
  - Added streaming, tool calling, vision, and batch processing examples
  - Added Best Practices section with 7 actionable tips
  - Added Contributing guidelines
  - Added badges (Hex version, docs, CI status, license)
  - Improved Quick Start guide with 3-step setup
- Updated GETTING_STARTED guide to remove broken links
- Updated LICENSE copyright to Antonio Cabrera
- Improved documentation configuration in mix.exs to include guides

## [0.1.1] - 2025-01-26

### Fixed

- **Critical**: Fixed `UndefinedFunctionError` when streaming requests fail with non-200 status codes
- `APIError.from_response/2` now properly handles `Req.Response.Async` structs from failed streaming requests
- Added pattern match for struct responses before map clause to prevent Access behaviour errors
- Returns generic error message for streaming failures instead of attempting to parse struct body

### Added

- Test case for streaming error response handling

## [0.1.0] - 2025-01-26

### Added

#### New Modules
- **`Claudio.Messages.Request`** - Fluent request builder API for constructing Messages API requests
- **`Claudio.Messages.Response`** - Structured response parsing with helper methods
- **`Claudio.Messages.Stream`** - Server-Sent Events (SSE) parser for streaming responses
- **`Claudio.Batches`** - Complete Message Batches API implementation
- **`Claudio.Tools`** - Utilities for tool/function calling
- **`Claudio.APIError`** - Structured error handling exception

#### Request Builder Features
- Chainable methods for all API parameters (temperature, top_p, top_k, etc.)
- System prompt configuration
- Stop sequences support
- Tool definitions and tool choice
- Thinking mode configuration
- Metadata support
- Streaming enablement

#### Response Parsing
- Structured content block parsing (text, thinking, tool_use, tool_result)
- Stop reason atom conversion for pattern matching
- Helper methods: `get_text/1`, `get_tool_uses/1`
- Support for both string and atom keys

#### Streaming Support
- SSE event parsing with buffer accumulation
- Event types: message_start, content_block_delta, message_delta, etc.
- Delta types: text_delta, input_json_delta, thinking_delta
- `accumulate_text/1` for extracting text streams
- `filter_events/2` for event filtering
- `build_final_message/1` for message reconstruction

#### Tool/Function Calling
- `define_tool/3` for creating tool definitions with JSON schemas
- `extract_tool_uses/1` for extracting tool requests
- `create_tool_result/3` for creating tool responses
- `has_tool_uses?/1` for checking tool usage
- Support for error tool results

#### Message Batches API
- `create/2` - Submit up to 100,000 requests per batch
- `get/2` - Retrieve batch status
- `get_results/2` - Download JSONL results
- `list/2` - List batches with pagination
- `cancel/2` - Cancel in-progress batches
- `delete/2` - Delete batches and results
- `wait_for_completion/3` - Poll with callback support

#### Error Handling
- Structured `APIError` exceptions
- Error type atoms: :authentication_error, :invalid_request_error, :rate_limit_error, etc.
- Consistent error handling across all API modules
- Preservation of raw error bodies for debugging

#### Testing
- **`test/request_test.exs`** - 23 tests for request builder
- **`test/response_test.exs`** - 13 tests for response parsing
- **`test/tools_test.exs`** - 10 tests for tool utilities
- **`test/api_error_test.exs`** - 6 tests for error handling
- Total: 55 tests, all passing

#### Documentation
- Comprehensive `@moduledoc` for all new modules
- `@doc` with examples for all public functions
- `@spec` type specifications throughout
- Updated main `Claudio` module with usage examples
- Updated `CLAUDE.md` with new architecture details

### Changed

#### HTTP Client Migration
- **Migrated from Tesla to Req** for better streaming performance and configurability
- Fixed timeout configuration - now properly respects custom settings
- Connection timeout default: 60s (configurable via `:timeout`)
- Receive timeout default: 120s (configurable via `:recv_timeout`)
- Streaming responses now complete quickly instead of timing out
- Added retry support for transient failures

#### Messages Module
- Added new `create/2` function alongside legacy `create_message/2`
- Both functions now return structured `APIError` on failure
- `create/2` returns `Response` structs for non-streaming requests
- `count_tokens/2` now accepts `Request` structs in addition to maps
- Improved error handling with consistent error types

#### Dependencies
- Replaced Tesla and Mint with Req ~> 0.5
- Added Bypass ~> 2.1 for testing (replaces Tesla mocks)
- Added Plug Cowboy ~> 2.0 for test server
- Moved Jason from test-only to production dependency
- Poison remains the primary JSON library for production
- Added ex_doc ~> 0.31 for documentation generation

### Maintained

#### Backward Compatibility
- Legacy `create_message/2` API fully maintained
- Raw map payloads still supported
- Error tuple format `{:ok, result}` / `{:error, error}` preserved
- All existing tests continue to pass

### Technical Details

#### Architecture Improvements
- Clear separation between request building, API calls, and response parsing
- Consistent error handling pattern across all modules
- Type safety with extensive `@type` and `@spec` annotations
- Support for both streaming and non-streaming in unified API

#### Code Quality
- All code formatted with `mix format`
- 55 tests with 100% pass rate
- Async tests where possible for performance
- Comprehensive test coverage of new functionality

## Configuration

### Timeout Configuration
```elixir
# config/config.exs
config :claudio, Claudio.Client,
  timeout: 60_000,        # Connection timeout (default: 60s)
  recv_timeout: 120_000   # Receive timeout (default: 120s)

# For long-running streaming operations
config :claudio, Claudio.Client,
  timeout: 60_000,
  recv_timeout: 600_000   # 10 minutes

# With retry logic for production
config :claudio, Claudio.Client,
  timeout: 30_000,
  recv_timeout: 180_000,
  retry: true
```

## Usage Examples

### Basic Request (New API)
```elixir
alias Claudio.Messages.{Request, Response}

request = Request.new("claude-3-5-sonnet-20241022")
|> Request.add_message(:user, "Hello!")
|> Request.set_max_tokens(1024)
|> Request.set_temperature(0.7)

{:ok, response} = Claudio.Messages.create(client, request)
text = Response.get_text(response)
```

### Streaming
```elixir
request = Request.new("claude-3-5-sonnet-20241022")
|> Request.add_message(:user, "Tell me a story")
|> Request.enable_streaming()

{:ok, stream} = Claudio.Messages.create(client, request)

stream
|> Claudio.Messages.Stream.parse_events()
|> Claudio.Messages.Stream.accumulate_text()
|> Enum.each(&IO.write/1)
```

### Tool Use
```elixir
tool = Claudio.Tools.define_tool(
  "get_weather",
  "Get weather for a location",
  %{"type" => "object", "properties" => %{"location" => %{"type" => "string"}}}
)

request = Request.new("claude-3-5-sonnet-20241022")
|> Request.add_message(:user, "What's the weather in Paris?")
|> Request.add_tool(tool)
|> Request.set_max_tokens(1024)

{:ok, response} = Claudio.Messages.create(client, request)

if Claudio.Tools.has_tool_uses?(response) do
  tool_uses = Claudio.Tools.extract_tool_uses(response)
  # Execute tools and continue conversation
end
```

### Batch Processing
```elixir
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
```

## Migration Guide

### From Legacy API to New API

**Before:**
```elixir
{:ok, response} = Claudio.Messages.create_message(client, %{
  "model" => "claude-3-5-sonnet-20241022",
  "max_tokens" => 1024,
  "messages" => [%{"role" => "user", "content" => "Hello"}]
})

text = response["content"]
|> Enum.filter(&(&1["type"] == "text"))
|> Enum.map(&(&1["text"]))
|> Enum.join("")
```

**After:**
```elixir
request = Request.new("claude-3-5-sonnet-20241022")
|> Request.add_message(:user, "Hello")
|> Request.set_max_tokens(1024)

{:ok, response} = Claudio.Messages.create(client, request)
text = Response.get_text(response)
```

### Error Handling

**Before:**
```elixir
case Claudio.Messages.create_message(client, payload) do
  {:ok, result} -> handle_success(result)
  {:error, body} -> handle_error(body)
end
```

**After:**
```elixir
case Claudio.Messages.create(client, request) do
  {:ok, response} -> handle_success(response)
  {:error, %Claudio.APIError{type: :rate_limit_error}} -> handle_rate_limit()
  {:error, error} -> handle_error(error)
end
```
