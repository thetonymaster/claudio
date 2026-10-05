# CLAUDE.md

# Project: Claudio

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Claudio is an Elixir client library for the Anthropic API. It provides a comprehensive interface for interacting with Claude models, including:
- Messages API with streaming support
- Tool/function calling
- Message Batches API for large-scale processing
- Request building with validation
- Structured response handling
- Token counting
- **Prompt caching** (up to 90% cost reduction)
- **Vision/image support** (base64, URL, Files API)
- **PDF/document support**
- **MCP (Model Context Protocol)** — server-side connector + client behaviour with adapters
- **Cache metrics tracking**

## Development Commands

### Setup
```bash
mix deps.get          # Install dependencies
```

### Testing
```bash
mix test              # Run all tests (integration tests excluded by default)
mix test --include integration  # Include integration tests (needs ANTHROPIC_API_KEY)
mix test test/messages_test.exs  # Run a specific test file
mix test test/messages_test.exs:22  # Run a specific test at line 22
```

### Code Quality
```bash
mix format            # Format code according to .formatter.exs
mix format --check-formatted  # Check if files are formatted
mix credo --strict    # Lint (config: .credo.exs)
mix dialyzer          # Typespec check (PLTs under _build/plts; first run builds them)
mix precommit         # compile --warnings-as-errors, unused deps, format, credo, dialyzer, test
```

CI (`.github/workflows/ci.yml`) runs the test matrix, a `quality` job (credo, dialyzer,
`docs --warnings-as-errors`, `hex.audit`, unused deps) and an `unlocked-deps` job that
tests against the newest dependency versions `mix.exs` allows. Complexity/nesting
exceptions are inline `credo:disable-for-next-line` comments — grep for them to find
refactor candidates.

### Build
```bash
mix compile           # Compile the project
```

## Architecture

### HTTP Client Layer (lib/claudio/client.ex)
The `Claudio.Client` module wraps Req HTTP client with Anthropic-specific configuration:
- Handles authentication via `x-api-key` header (default) **or** `Authorization: Bearer` (set `auth_type: :bearer`) — for OAuth / Workload Identity Federation tokens. The `:token` field carries the credential in both modes.
- Supports API versioning via anthropic-version header
- Supports beta features via anthropic-beta header
- Uses Jason for JSON (Req's built-in encoder/decoder)

Client initialization requires:
- `token`: API key (or, with `auth_type: :bearer`, an OAuth/WIF bearer token)
- `version`: API version (e.g., "2023-06-01")
- `auth_type`: (optional) `:api_key` (default) or `:bearer`. Claude-Code-style OAuth tokens also need `beta: ["oauth-2025-04-20"]`.
- `beta`: (optional) list of beta feature flags
- `timeout`, `recv_timeout`, `retry: true | false | [delay:, max_retries:, max_delay:]`: pass per client to `new/2` (wins) or set app-wide via `config :claudio, Claudio.Client, ...` (fallback). `retry` retries 408/429/5xx/529 and connection errors on every method (Req's default only retries GET/HEAD); an invalid value or unknown key raises in both paths; `delay`/`max_delay`/`max_retries` must be non-negative integers. `Retry-After` is honoured on 429/503/529, even with `delay:`
- `new/2` takes a map or keyword list; it raises on unknown keys and on a missing/empty `:token`; `version: nil` falls back to the default
- App config: `config :claudio, default_api_version: ..., default_beta_features: [...]`. Prefer per-client options for anything new (the Elixir library guidelines discourage app-env config in libraries)
- `Claudio.APIError.from_response/2` also handles non-JSON bodies (empty 5xx, proxy HTML), typed from the HTTP status; a JSON body without `error.type` is typed from the status too

> **Alt deployments (Bedrock / Vertex):** not implemented — they need SigV4 / GCP ADC signing, model-id prefixing, and per-feature masking (large effort, deferred until demand). The OAuth token-exchange flow (`POST /v1/oauth/token`) is likewise out of scope; supply an already-obtained bearer token.

### Messages API (lib/claudio/messages.ex)
The `Claudio.Messages` module provides both legacy and new APIs:

**New API (Recommended):**
- `create/2`: Creates a message using Request structs or maps
  - Accepts `Claudio.Messages.Request` structs or raw maps
  - Returns `Claudio.Messages.Response` structs for non-streaming
  - Returns raw `Req.Response` for streaming responses
- `count_tokens/2`: Counts tokens, accepts Request or map

**Legacy API (Backward Compatible):**
- `create_message/2`: Original implementation, returns raw maps
- Maintained for backward compatibility

Both APIs support streaming and non-streaming modes. Streaming is detected via `stream: true` in the payload.

### Request Builder (lib/claudio/messages/request.ex)
The `Claudio.Messages.Request` module provides a fluent API for building requests:
- Chainable methods for setting parameters (temperature, top_p, top_k, etc.)
- Support for system prompts, stop sequences, and metadata
- Tool definitions and tool choice configuration
- Thinking mode configuration
- **Prompt caching support** (`set_system_with_cache/2`, `add_tool_with_cache/2`, plus `add_message_with_cache/4` for message-level breakpoints and `set_cache_control/2` for top-level auto-placement — all GA, no beta header; `ttl:` must be `"5m"` or `"1h"`, unknown options raise)
- **Vision/image support** (`add_message_with_image/5` — detects PNG/GIF/WebP/JPEG when no media type is given, or takes `media_type:` as a keyword; `add_message_with_image_url/4`)
- **Document support** (`add_message_with_document/5` — opts `:citations` / `:title` / `:context`; backward-compatible with the original `/4` arity)
- **Citations + search results** (`add_message_with_document/5` with `citations: true` for grounded document citations; `search_result_block/4` builds RAG `search_result` content blocks — both GA, no beta header. ⚠️ Citations are **incompatible with structured outputs** — combining them returns 400.)
- **MCP servers** (`add_mcp_server/2` — accepts `ServerConfig` structs or raw maps; adds the `mcp_toolset` and declares `mcp-client-2025-11-20`)
- **Per-feature beta headers** (`add_beta/2` — declares an `anthropic-beta` flag that the send path merges into the header; feature setters like `set_context_management/2` declare theirs automatically. `required_betas/1` returns them.)
- **Structured outputs** (`set_output_format/2` builds `output_config.format` from a JSON schema; `set_output_config/2` is the raw setter — GA, no beta header)
- **Thinking & effort** (`enable_adaptive_thinking/2` with `display:` — `:updates` declares `thinking-display-updates-2026-08-18`; `disable_thinking/1` / `disable_thinking/2` with `mode: :between_tools` (Sonnet 5.5 — sends `thinking: {"type": "between_tools"}`); `block_binding:` / `set_thinking_block_binding/2` (`:error` / `:drop_block`) declare `thinking-binding-controls-2026-08-01`; `set_effort/2` → `output_config.effort`, GA; `set_task_budget/3` → `output_config.task_budget`, declares `task-budgets-2026-03-13`. Output-config helpers merge; `set_output_config/2` replaces. No per-model validation — the API's 400 is authoritative.)
- **5.x request surface** (`add_system_message/3` — mid-conversation `role: "system"` messages, GA; `clear_at:` declares `mid-conversation-system-clear-at-2026-08-21`, `effort:` declares `mid-conversation-output-config-2026-07-01`. `set_speed/2` always declares `fast-mode-2026-02-01`; `set_inference_geo/2` and `enable_cache_diagnostics/2` are GA. Placement rules are left to the API.)
- **Refusal fallbacks** (`set_fallbacks/2` — `:default` or a list of model strings / override maps; declares `server-side-fallback-2026-07-01`. Entry cap, distinctness and `allowed_fallback_models` are left to the API; not sent by `count_tokens`; unsupported in Batches.)
- **Context management** (`add_clear_tool_uses/2`, `add_clear_thinking/2` — declare `context-management-2025-06-27`, clear_thinking always first; `add_compaction/2` — threshold `compact_20260112`, declares `compact-2026-01-12`; `request_compaction/2` — on-demand `compaction` field, declares `compact-2026-09-04`; `apply_compaction/2` replaces history with the last compaction block onward for either kind; `set_context_management/2` is the raw setter. Limits and incompatibilities are left to the API.)
- **Strict / eager tool flags** (`add_strict_tool/2` sets `strict: true`; `add_tool_with_eager_streaming/2` sets `eager_input_streaming: true` — GA, no beta header)
- **Server-side tool helpers** (each appends the correctly-versioned tool map; only computer-use declares a beta):
  - `add_web_search_tool/2` — `web_search_20260209` (default) / `web_search_20250305` (`version: :basic`); GA
  - `add_web_fetch_tool/2` — `web_fetch_20260209` (default) / `web_fetch_20250910` (`version: :basic`); `:citations`; GA
  - Web search/fetch also take `allowed_callers:` and `response_inclusion:` (the latter needs `version: :"20260318"`)
  - `add_code_execution_tool/2` — `code_execution_20260521` (default; `version:` `:"20260120"` / `:"20250825"`); GA (pairs with `set_container/2`)
  - `add_bash_tool/1` / `add_text_editor_tool/2` — schema-less client tools (`bash_20250124`, `text_editor_20250728` / `str_replace_based_edit_tool`)
  - `add_memory_tool/1` — `memory_20250818`; GA, client-side
  - `add_computer_tool/4` — `computer_20250124` (**auto-declares `computer-use-2025-01-24`** via `add_beta/2`); `version: :"20251124"` → `computer_20251124` + `computer-use-2025-11-24`
- **Tool extensions** (`add_tool/3` — `defer_loading:`, `allowed_callers:` (`:code_execution` → `code_execution_20260120`), GA; `add_tool_search_tool/2` — `:regex` / `:bm25`, GA; `add_advisor_tool/3` — declares `advisor-tool-2026-03-01`; `add_computer_toolset/2` / `add_browser_toolset/2` — GA client toolsets, results must echo `toolset_name`; `add_computer_tool/4` `version: :"20251124"` declares `computer-use-2025-11-24`. Opus 5.5 accepts only the computer toolset.)
- Converts to map via `to_map/1` for API submission

Example:
```elixir
Request.new("claude-opus-4-8")
|> Request.add_message(:user, "Hello!")
|> Request.set_max_tokens(1024)
|> Request.add_tool(tool_definition)
|> Request.set_system_with_cache("Long context...", ttl: "1h")
|> Request.add_message_with_image(:user, "Describe this", base64_image)
```

### Response Handling (lib/claudio/messages/response.ex)
The `Claudio.Messages.Response` module parses API responses into structured data:
- Parses content blocks (text, thinking, tool_use, tool_result, mcp_tool_use, mcp_tool_result, server_tool_use, web_search_tool_result, fallback, compaction, web_fetch_tool_result, code_execution_tool_result, bash_code_execution_tool_result, text_editor_code_execution_tool_result, tool_search_tool_result, advisor_tool_result, container_upload)
- Converts stop_reason strings to atoms (:end_turn, :max_tokens, :tool_use, etc.)
- **Tracks cache metrics** (cache_creation_input_tokens, cache_read_input_tokens)
- **Preserves citations** on `text` blocks (the raw citation maps — `char_location`, `page_location`, `content_block_location`, `search_result_location`, `web_search_result_location` — kept verbatim for reading; not replayed by `to_assistant_content/1`)
- Provides helper methods:
  - `get_text/1`: Extracts all text content
  - `get_tool_uses/1`: Extracts tool use requests
  - `get_citations/1`: Aggregates citations across all text blocks (document order)
  - `get_server_tool_uses/1`: Extracts `server_tool_use` requests (e.g. server-run `web_search`)
  - `get_mcp_tool_uses/1`: Extracts MCP tool use requests
  - `get_mcp_tool_uses/2`: Extracts MCP tool uses for a specific server
  - `get_thinking/1`: Non-empty thinking texts, in order (a list — one per `display: :updates` progress note)
  - `thinking_interrupted?/1`: True for the API's interrupted-update placeholder block
- **`usage.output_tokens_details`** — raw map (e.g. `thinking_tokens`), `nil` when absent; `:thinking_tokens` also appears in usage telemetry
- **`usage` keeps every field** — documented fields are atom keys (incl. `cache_creation`, `service_tier`, `inference_geo`, `speed`, `iterations`); unknown fields keep the key they arrived with
- **`diagnostics`** — raw cache-diagnostics map (`cache_miss_reason`), `nil` unless requested via `enable_cache_diagnostics/2`
- **`stop_details`** — raw refusal details map (`type`/`category`/`explanation`; with fallbacks also `recommended_model`, `fallback_credit_token`, `fallback_has_prefill_claim`), `nil` unless `stop_reason: :refusal`
- **`fallback` blocks** — `%{type: :fallback, from:, to:, trigger:, raw:}`; `fallbacks/1` lists them, `served_by/1` names the serving model (last block's `to.model`, else `model` — a streamed mid-output fallback keeps the requested model in `model`); `usage.iterations` records each attempt
- **`to_assistant_content/1`** applies the fallback continuation rules (drops / pairing before the last `fallback` block); a no-op without a mid-output fallback. `get_tool_uses/1` (and `Tools.extract_tool_uses/1`) skip `tool_use` before the last `fallback`; `add_message/3` declares the fallback beta when replaying a `fallback` block; it declares `mcp-client-2025-11-20` when replaying `mcp_tool_use` / `mcp_tool_result`
- **`compaction` blocks** — `%{type: :compaction, content:, raw:}` (raw replayed byte-exact, keeps the on-demand `signature`); `compaction_block/1`; `stop_reason: :compaction`; `context_management` — raw `applied_edits` map, `nil` unless edits were configured; `add_message/3` declares the compaction replay beta (signed → `compact-2026-09-04`, unsigned → `compact-2026-01-12`)
- **Tool-use round trip** — `tool_use` keeps `caller` / `toolset_name`, `server_tool_use` keeps `caller`, and `to_assistant_content/1` re-emits them; server-result blocks are typed shallowly (`%{type:, tool_use_id:, content: <raw>, caller:, raw:}`, replayed from `raw`); `get_server_tool_results/1,2`; `container` (raw `%{"id", "expires_at"}`)
- **`input_transformations`** — raw list of API input changes (`thinking_dropped` / `thinking_mismatch_allowed`, with `path` and `reason`); `[]` when nothing changed, `nil` without the block-binding beta
- Handles both string and atom keys from API responses

### Streaming (lib/claudio/messages/stream.ex)
The `Claudio.Messages.Stream` module parses Server-Sent Events (SSE) from streaming responses:
- `parse_events/1`: Converts raw stream to structured events
- `accumulate_text/1`: Extracts and accumulates text deltas
- `accumulate_thinking/1`: Emits `{block_index, text}` per non-empty `thinking_delta`
- `filter_events/2`: Filters to specific event types
- `build_final_message/1`: Accumulates all events into a final message
- `to_response/2`: Consumes a stream in one pass (`on_text:` / `on_event:` callbacks) into a `%Response{}`; an SSE `error` event becomes an `APIError`
- **Consume once:** a streaming body is readable once, and only by the process that called `create/2`

Event types handled:
- message_start, content_block_start, content_block_delta
- message_delta, message_stop, content_block_stop
- ping, error

Delta types: text_delta, input_json_delta, thinking_delta, signature_delta, citations_delta, compaction_delta

### Tools/Function Calling (lib/claudio/tools.ex)
The `Claudio.Tools` module provides utilities for tool use:
- `define_tool/3`: Creates tool definitions with JSON schemas
- `extract_tool_uses/1`: Extracts tool use requests from responses
- `create_tool_result/4`: Creates tool result messages (`toolset_name:` for client-toolset calls)
- `halt_result/1` / `halt_text/1`: The documented result for toolset actions skipped after a failure
- `has_tool_uses?/1`: Checks if response contains tool uses

Tool workflow:
1. Define tools with schemas
2. Add to request with `Request.add_tool/2`
3. Set tool choice with `Request.set_tool_choice/2`
4. Extract tool uses from response
5. Execute tools and create results
6. Continue conversation with tool results

### MCP Support (lib/claudio/mcp/)
MCP integration is split into two layers:

**Server-side connector (API layer):**
- `Claudio.MCP.ServerConfig`: Typed struct + builder for MCP server configs in API requests
- `Request.add_mcp_server/2`: Accepts `ServerConfig` structs or raw maps; emits the `mcp_servers` entry **and** an `mcp_toolset` in `tools`, and declares `mcp-client-2025-11-20`. `ServerConfig.allow_tools/2` takes exact names (patterns raise); legacy `tool_configuration` in raw maps is translated with a warning.
- Response parsing handles `mcp_tool_use` and `mcp_tool_result` content blocks

**Client-side behaviour + adapters:**
- `Claudio.MCP.Client`: Behaviour defining 7 callbacks (list_tools, call_tool, list_resources, read_resource, list_prompts, get_prompt, ping)
- Normalized types: `Client.Tool`, `Client.Resource`, `Client.Prompt`
- Adapters for hermes_mcp, ex_mcp, mcp_ex (optional deps)
- `Claudio.MCP.ToolAdapter`: Converts MCP tools into Claudio request format
- `Claudio.MCP.ResultMapper`: Maps response tool_use blocks back to MCP call format

### A2A Support (lib/claudio/a2a/)
Agent-to-Agent protocol support for discovering and interacting with remote agents.

**Core types:**
- `Claudio.A2A.Part`: Content unit (text, file, data) with camelCase serialization
- `Claudio.A2A.Message`: Communication turn with role, parts, and fluent builder
- `Claudio.A2A.Artifact`: Task output container
- `Claudio.A2A.Task`: Task lifecycle with state machine (submitted → working → completed/failed)
- `Claudio.A2A.AgentCard`: Agent capabilities descriptor with nested Skill, Provider, Capabilities, Interface structs

**Client:**
- `Claudio.A2A.Client`: HTTP client using Req + JSON-RPC 2.0
  - `discover/2`: Fetch agent card from `.well-known/agent-card.json`
  - `send_message/3`: Send message to agent, returns Task or Message
  - `get_task/3`, `list_tasks/2`, `cancel_task/3`: Task management
  - Bearer token auth support, timeout passthrough

### Managed Agents (lib/claudio/managed_agents/) — beta
Server-hosted agents (`managed-agents-2026-04-01`, merged into the client's betas per request by the private `Claudio.ManagedAgents.HTTP`). Raw-map returns (`{:ok, map()}` / `{:error, APIError}`), no local body validation. Roadmap: `docs/superpowers/specs/2026-09-30-managed-agents-roadmap.md` (MA1 shipped; MA2 run loop + `Claudio.Agent` deprecation, MA3 deployments/vaults/memory stores/threads, MA4 dreams/work queue/webhooks; 0.8.0 after MA4).
- `Agents`: create, get (`version:`), update (body `version` = optimistic check, stale → 409), list, archive (no delete), list_versions
- `Environments`: create, get, update, list, archive, delete (only when unreferenced)
- `Sessions`: CRUD + archive/delete (not while `running`), `send_events/3` (list of event maps), `list_events/3`, resources (mid-session add accepts only `file`, which needs the agent toolset's `read`; update = GitHub token rotation). `update/3` emits a persisted `session.updated` event
- List options: list → `key[]`, keyword → `key[sub]`, `DateTime` → ISO 8601; `nil` / `[]` / maps raise. Ids are escaped as one path segment. `Claudio.ManagedAgents.stream/2` pages lazily (stops on absent or nil `next_page`, raises on errors)
- Tests: `test/managed_agents/` (Bypass, shared helpers in `managed_agents_helper.exs`), live flow in `test/integration/managed_agents_integration_test.exs` (no model call)

### Files API (lib/claudio/files.ex)
- `upload/3` takes `expires_in_seconds:` (API range 3600..7776000) and rejects unknown options

### Message Batches API (lib/claudio/batches.ex)
The `Claudio.Batches` module handles asynchronous batch processing:
- `create/2`: Submit up to 100,000 requests in a single batch
- `get/2`: Retrieve batch status
- `get_results/2`: Download results — a list of decoded, string-keyed maps (JSONL parsed; a malformed line is `{:error, {:invalid_result_line, n, line}}`)
- `list/2`: List all batches with pagination (unknown options raise)
- `cancel/2`: Cancel in-progress batch
- `delete/2`: Delete batch and results
- `wait_for_completion/3`: Poll until batch completes (with callback support; unknown options raise)

Batch processing is asynchronous (up to 24 hours) and supports all Messages API features.

### Models API (lib/claudio/models.ex)
The `Claudio.Models` module wraps the GA Models API (no beta header):
- `list/2`: List available models, paginated (`:limit`, `:before_id`, `:after_id`)
- `get/2`: Retrieve a single model by id or alias (e.g. `"claude-opus-4-8"`)

Returns the raw decoded body (`{:ok, map()}`), consistent with `Claudio.Files` / `Claudio.Batches`; non-200 responses map to `Claudio.APIError`.

### Admin API (lib/claudio/admin.ex)
The `Claudio.Admin` module wraps the GA Admin API (`/v1/organizations/*`). It needs an **Admin API key** (`sk-ant-admin…`) — built the normal way (`Claudio.Client.new(%{token: admin_key, ...})`), since the admin key rides the same `x-api-key` header. No beta header.

One flat module with grouped functions over a shared private request helper:
- **Org:** `get_organization/1`
- **Members:** `list_users/2`, `get_user/2`, `update_user/3`, `remove_user/2`
- **Invites:** `list_invites/2`, `get_invite/2`, `create_invite/2`, `delete_invite/2`
- **Workspaces:** `list_workspaces/2`, `get_workspace/2`, `create_workspace/2`, `update_workspace/3`, `archive_workspace/2`
- **API keys:** `list_api_keys/2`, `get_api_key/2`, `update_api_key/3` (create/delete are Console-only)
- **Usage/cost:** `usage_report/2`, `cost_report/2` (opts pass through as query params)

Updates use `POST` (not PATCH). Returns raw body (`{:ok, map()}`), non-2xx → `Claudio.APIError`. Workspace-member / service-account / federation endpoints need an `org:admin` OAuth token and are not covered.

### Skills API (lib/claudio/skills.ex) — GA
The `Claudio.Skills` module wraps the Agent Skills API (`/v1/skills`). GA — no beta header is attached. `list/2` responses are `{data, next_page}` (no `has_more`); opt back into the old shape with `Claudio.Client.with_betas(client, ["skills-2025-10-02"])`.
- **Read/manage:** `list/2` (`:limit`/`:page`/`:source`), `get/2`, `delete/2`, `list_versions/3`, `get_version/3`, `delete_version/3`
- **Create (multipart):** `create/2`, `create_version/3` accept a `form_multipart`-shaped list (same shape as `Claudio.Files.upload/3`); the module supplies the endpoint + multipart transport.

Returns raw body (`{:ok, map()}`), non-2xx → `Claudio.APIError`. **Prompt-tools** (`/v1/experimental/*`) are intentionally **not** implemented — experimental, access-gated, beta header unverified.

### Error Handling (lib/claudio/api_error.ex)
The `Claudio.APIError` exception provides structured error handling:
- Parses API error responses into typed exceptions
- Error types: :authentication_error, :invalid_request_error, :rate_limit_error, :overloaded_error, :billing_error, :request_too_large, :timeout_error, etc. (atoms); a body without `error.type` is typed from the HTTP status
- Includes status code, error message, and raw response body
- Used consistently across all API modules

### Telemetry (lib/claudio/telemetry.ex)
- `[:claudio, :messages, :create]` — span for `create/2` and legacy `create_message/2` (request params incl. `output_type` / `stop_sequences`, response fields, `error_type`, token measurements)
- `[:claudio, :messages, :count_tokens]` — span for `count_tokens/2`
- `[:claudio, :messages, :stream, :start | :stop]` — per consumption in `parse_events/1` (exactly one `:stop`; linked to `create` when given the whole response; the linked `:start` carries `output_type` / `stop_sequences`; `error_type` is an atom for known API error types)
- `[:claudio, :messages, :stream, :usage]` — older single event at `message_stop`, kept
- `[:claudio, :http, :request, :start | :stop]` — per attempt, every `Client.new/2` client

Mappings live in the private `Claudio.Telemetry`; the contract is `guides/telemetry.md`. `scripts/check_otel_guide.exs` checks the guide's OTel examples; CI runs it in the `otel-guide` job.

### Testing Strategy
- Uses Bypass for mocking HTTP calls
- Tests use `async: true` for parallel execution where possible
- Integration tests excluded by default (run with `--include integration`)
- One `*_test.exs` per module at the `test/` top level (e.g. `test/request_test.exs`, `test/models_test.exs`); `test/a2a/`, `test/mcp/`, `test/messages/` hold the multi-file areas
- `test/integration/`: live-API tests, tagged `:integration` and excluded in `test/test_helper.exs`

### Configuration
- Environment-specific config loaded via `import_config "#{config_env()}.exs"`
- Client adapter overridable via Application config under `:claudio, Claudio.Client`

## Key Implementation Details

### Backward Compatibility
- Legacy `create_message/2` API maintained alongside new `create/2`
- Both string and atom keys supported in response parsing
- Error responses return structured `APIError` exceptions inside the `{:error, _}` tuple
- `add_mcp_server/2` accepts both `ServerConfig` structs and raw maps

### JSON Handling
- Jason for all JSON encoding/decoding (Req depends on it; `json:` request bodies go through it)
- JSON is decoded with **string keys** everywhere (Messages, Batches, streams); `Response` structs expose typed atom-keyed fields and blocks, raw sub-maps stay string-keyed

### Streaming Implementation
- Streaming detected by pattern matching on `stream: true`
- SSE parsing handles incomplete chunks via buffer accumulation
- Events extracted by parsing `event:` and `data:` lines
- Supports graceful handling of unknown event types (forward compatibility)
- Streamed tool input (`input_json_delta`) is decoded into `"input"` at `content_block_stop`; invalid JSON → `{:error, {:invalid_tool_input_json, index, partial_json}}`

### Type Safety
- Extensive use of `@type` and `@spec` for documentation and Dialyzer
- Stop reasons converted to atoms for pattern matching
- Content blocks typed by their :type field (:text, :tool_use, :thinking, :mcp_tool_use, :fallback, :compaction, etc.)

### Module Organization
```
lib/
├── claudio.ex                 # Top-level Claudio module
└── claudio/
    ├── a2a/                   # A2A protocol (agent_card, artifact, client, message, part, task, util, transport/{http,grpc})
    ├── admin.ex               # Admin API (organizations/*)
    ├── agent.ex               # Stateless tool-calling loop (Claudio.Agent): toolset pair dispatch, container carry, pause_turn/compaction resume; errors return {:error, reason, last_response, messages}
    ├── api_error.ex           # Error handling
    ├── batches.ex             # Batches API
    ├── client.ex              # HTTP client setup
    ├── files.ex               # Files API
    ├── managed_agents.ex      # Managed Agents overview + stream/2
    ├── managed_agents/        # http (private), agents, environments, sessions
    ├── mcp/                   # server_config, client behaviour, tool_adapter, result_mapper, adapters/{hermes_mcp,ex_mcp,mcp_ex}
    ├── messages.ex            # Main Messages API
    ├── messages/              # request.ex (builder), response.ex (parser), stream.ex (SSE)
    ├── models.ex              # Models API
    ├── skills.ex              # Agent Skills API
    └── tools.ex               # Tool utilities
```
