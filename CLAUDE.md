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
```

### Build
```bash
mix compile           # Compile the project
```

## Architecture

### HTTP Client Layer (lib/claudio/client.ex)
The `Claudio.Client` module wraps Req HTTP client with Anthropic-specific configuration:
- Uses Mint adapter (configured in config/config.exs)
- Handles authentication via x-api-key header
- Supports API versioning via anthropic-version header
- Supports beta features via anthropic-beta header
- Uses Poison for JSON encoding/decoding

Client initialization requires:
- `token`: API key
- `version`: API version (e.g., "2023-06-01")
- `beta`: (optional) list of beta feature flags

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
- **Prompt caching support** (`set_system_with_cache/2`, `add_tool_with_cache/2`)
- **Vision/image support** (`add_message_with_image/4`, `add_message_with_image_url/3`)
- **Document support** (`add_message_with_document/3`)
- **MCP servers** (`add_mcp_server/2` — accepts `ServerConfig` structs or raw maps)
- Converts to map via `to_map/1` for API submission

Example:
```elixir
Request.new("claude-sonnet-4-5-20250929")
|> Request.add_message(:user, "Hello!")
|> Request.set_max_tokens(1024)
|> Request.set_temperature(0.7)
|> Request.add_tool(tool_definition)
|> Request.set_system_with_cache("Long context...", ttl: "1h")
|> Request.add_message_with_image(:user, "Describe this", base64_image)
```

### Response Handling (lib/claudio/messages/response.ex)
The `Claudio.Messages.Response` module parses API responses into structured data:
- Parses content blocks (text, thinking, tool_use, tool_result, mcp_tool_use, mcp_tool_result)
- Converts stop_reason strings to atoms (:end_turn, :max_tokens, :tool_use, etc.)
- **Tracks cache metrics** (cache_creation_input_tokens, cache_read_input_tokens)
- Provides helper methods:
  - `get_text/1`: Extracts all text content
  - `get_tool_uses/1`: Extracts tool use requests
  - `get_mcp_tool_uses/1`: Extracts MCP tool use requests
  - `get_mcp_tool_uses/2`: Extracts MCP tool uses for a specific server
- Handles both string and atom keys from API responses

### Streaming (lib/claudio/messages/stream.ex)
The `Claudio.Messages.Stream` module parses Server-Sent Events (SSE) from streaming responses:
- `parse_events/1`: Converts raw stream to structured events
- `accumulate_text/1`: Extracts and accumulates text deltas
- `filter_events/2`: Filters to specific event types
- `build_final_message/1`: Accumulates all events into a final message

Event types handled:
- message_start, content_block_start, content_block_delta
- message_delta, message_stop, content_block_stop
- ping, error

Delta types: text_delta, input_json_delta, thinking_delta

### Tools/Function Calling (lib/claudio/tools.ex)
The `Claudio.Tools` module provides utilities for tool use:
- `define_tool/3`: Creates tool definitions with JSON schemas
- `extract_tool_uses/1`: Extracts tool use requests from responses
- `create_tool_result/3`: Creates tool result messages
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
- `Request.add_mcp_server/2`: Accepts `ServerConfig` structs or raw maps
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

### Message Batches API (lib/claudio/batches.ex)
The `Claudio.Batches` module handles asynchronous batch processing:
- `create/2`: Submit up to 100,000 requests in a single batch
- `get/2`: Retrieve batch status
- `get_results/2`: Download results as JSONL
- `list/2`: List all batches with pagination
- `cancel/2`: Cancel in-progress batch
- `delete/2`: Delete batch and results
- `wait_for_completion/3`: Poll until batch completes (with callback support)

Batch processing is asynchronous (up to 24 hours) and supports all Messages API features.

### Error Handling (lib/claudio/api_error.ex)
The `Claudio.APIError` exception provides structured error handling:
- Parses API error responses into typed exceptions
- Error types: :authentication_error, :invalid_request_error, :rate_limit_error, :overloaded_error, etc.
- Includes status code, error message, and raw response body
- Used consistently across all API modules

### Testing Strategy
- Uses Bypass for mocking HTTP calls
- Tests use `async: true` for parallel execution where possible
- Integration tests excluded by default (run with `--include integration`)
- Comprehensive test coverage:
  - `test/messages_test.exs`: Legacy Messages API tests
  - `test/request_test.exs`: Request builder tests
  - `test/response_test.exs`: Response parsing tests
  - `test/tools_test.exs`: Tool utilities tests
  - `test/api_error_test.exs`: Error handling tests
  - `test/mcp/`: MCP module tests (server_config, response, request, client, tool_adapter, result_mapper)

### Configuration
- Req client configured globally in config/config.exs
- Environment-specific config loaded via `import_config "#{config_env()}.exs"`
- Client adapter overridable via Application config under `:claudio, Claudio.Client`

## Key Implementation Details

### Backward Compatibility
- Legacy `create_message/2` API maintained alongside new `create/2`
- Both string and atom keys supported in response parsing
- Error responses now return structured `APIError` exceptions but maintain `:error` tuple pattern
- `add_mcp_server/2` accepts both `ServerConfig` structs and raw maps

### JSON Handling
- Poison used for production JSON encoding/decoding
- Jason used in addition to Poison for JSON handling
- All API responses parsed with atom keys for easier access

### Streaming Implementation
- Streaming detected by pattern matching on `stream: true`
- SSE parsing handles incomplete chunks via buffer accumulation
- Events extracted by parsing `event:` and `data:` lines
- Supports graceful handling of unknown event types (forward compatibility)

### Type Safety
- Extensive use of `@type` and `@spec` for documentation and Dialyzer
- Stop reasons converted to atoms for pattern matching
- Content blocks typed by their :type field (:text, :tool_use, :thinking, :mcp_tool_use, etc.)

### Module Organization
```
lib/claudio/
├── api_error.ex           # Error handling
├── batches.ex             # Batches API
├── client.ex              # HTTP client setup
├── messages.ex            # Main Messages API
├── messages/
│   ├── request.ex         # Request builder
│   ├── response.ex        # Response parser
│   └── stream.ex          # SSE streaming
├── mcp/
│   ├── server_config.ex   # API-level MCP server config
│   ├── client.ex          # MCP client behaviour
│   ├── tool_adapter.ex    # MCP tools → Claudio tools
│   ├── result_mapper.ex   # Response → MCP calls
│   └── adapters/
│       ├── hermes_mcp.ex  # hermes_mcp adapter
│       ├── ex_mcp.ex      # ex_mcp adapter
│       └── mcp_ex.ex      # mcp_ex adapter
└── tools.ex               # Tool utilities
```
