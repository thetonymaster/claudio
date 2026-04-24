# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

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
