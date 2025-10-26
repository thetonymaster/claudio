# Proposed Improvements for Claudio

Based on the official Anthropic API documentation, here are missing features and improvements for the Claudio library.

## Missing API Features

### 1. Request Parameters

The current implementation only passes through raw payloads without validation or helper functions. Consider adding support for:

#### Core Parameters (Currently Missing)
- **`system`** (string or array): System prompts for context and instructions
- **`temperature`** (number, 0.0-1.0): Controls randomness in responses
- **`top_p`** (number, 0-1): Nucleus sampling threshold
- **`top_k`** (integer): Sample from top K options per token
- **`stop_sequences`** (array of strings): Custom sequences that trigger generation stop
- **`metadata`** (object): Request metadata for tracking purposes

#### Advanced Features
- **`tools`** (array): Tool/function calling definitions with schemas
- **`tool_choice`** (object): Controls tool selection - auto, any, specific tool, or none
- **`thinking`** (object): Extended thinking configuration with budget specification
- **`context_management`** (object): Controls context strategies across requests
- **`container`** (string/object): Container identifier for tool reuse
- **`service_tier`** (enum): "auto" or "standard_only" for capacity selection

### 2. Streaming Implementation Issues

Current implementation in `lib/claudio/messages.ex:3-13`:
```elixir
def create_message(client, payload = %{"stream" => true}) do
  url = "messages"

  case Tesla.post(client, url, payload, opts: [adapter: [body_as: :stream]]) do
    {:ok, result} ->
      {:ok, result}
    {:error, %Tesla.Env{status: _, body: body}} ->
      {:error, body}
  end
end
```

**Problems:**
- Returns raw stream without parsing Server-Sent Events (SSE)
- No event type handling
- No utilities for consuming the stream

**Missing Event Types:**
According to the API, streaming responses include:
- `message_start`: Initial message with empty content
- `content_block_start`: Beginning of a content block
- `content_block_delta`: Incremental content updates
  - `text_delta`: Text chunks
  - `input_json_delta`: Partial JSON for tool parameters
  - `thinking_delta`: Extended thinking content
- `content_block_stop`: End of content block
- `message_delta`: Top-level message changes (usage updates)
- `message_stop`: Stream completion
- `ping`: Keep-alive events
- `error`: Error events (e.g., overloaded_error)

**Recommended Improvement:**
Add a streaming parser module that:
1. Parses SSE format (`event:`, `data:` lines)
2. Decodes JSON data for each event
3. Provides a Stream/Enumerable interface
4. Handles error events gracefully

### 3. Message Batches API (Completely Missing)

The Batches API is a major feature for processing multiple requests efficiently:

**Endpoints needed:**
- `POST /v1/messages/batches` - Create a batch
- `GET /v1/messages/batches/:batch_id` - Retrieve batch status
- `GET /v1/messages/batches/:batch_id/results` - Get results
- `GET /v1/messages/batches` - List all batches
- `POST /v1/messages/batches/:batch_id/cancel` - Cancel a batch
- `DELETE /v1/messages/batches/:batch_id` - Delete a batch

**Key features:**
- Submit up to 100,000 requests per batch (256 MB limit)
- Asynchronous processing (up to 24 hours)
- Results provided as `.jsonl` file
- Each request needs a `custom_id` for tracking
- Status tracking: `in_progress`, `canceling`, `ended`

### 4. Response Field Support

Current implementation doesn't provide typed access to response fields. Consider adding:

**Stop Reasons:**
- `end_turn`: Natural conversation end
- `max_tokens`: Hit token limit
- `stop_sequence`: Matched custom stop sequence
- `tool_use`: Model wants to use a tool
- `pause_turn`: Context management pause
- `refusal`: Model refused to respond
- `model_context_window_exceeded`: Input too large

**Additional Response Fields:**
- `context_management`: Information about applied context strategies
- `container`: Container tool details
- Content block types: `text`, `thinking`, `tool_use`, `tool_result`

## Suggested Architecture Improvements

### 1. Request Builder Pattern

Instead of requiring users to build raw maps, provide a request builder:

```elixir
alias Claudio.Messages.Request

Request.new("claude-sonnet-4-5-20250929")
|> Request.add_message(:user, "Hello!")
|> Request.set_system("You are a helpful assistant")
|> Request.set_max_tokens(1024)
|> Request.set_temperature(0.7)
|> Request.add_tool(tool_definition)
|> Request.set_tool_choice(:auto)
|> Messages.create_message(client, _)
```

### 2. Response Structs

Define Elixir structs for type safety:

```elixir
defmodule Claudio.Messages.Response do
  @type t :: %__MODULE__{
    id: String.t(),
    type: String.t(),
    role: String.t(),
    model: String.t(),
    content: list(content_block()),
    stop_reason: stop_reason(),
    stop_sequence: String.t() | nil,
    usage: usage()
  }

  @type stop_reason ::
    :end_turn | :max_tokens | :stop_sequence |
    :tool_use | :pause_turn | :refusal |
    :model_context_window_exceeded

  # ... etc
end
```

### 3. Streaming Module

Create `Claudio.Messages.Stream`:

```elixir
defmodule Claudio.Messages.Stream do
  @moduledoc """
  Utilities for consuming streaming responses from the Messages API.
  """

  @doc """
  Parses SSE stream into structured events.
  Returns a Stream of {:ok, event} or {:error, reason}.
  """
  def parse_events(response)

  @doc """
  Accumulates text deltas into complete messages.
  """
  def accumulate_text(event_stream)

  @doc """
  Filters stream to only specific event types.
  """
  def filter_events(event_stream, event_types)
end
```

### 4. Error Handling

Create structured error types instead of returning raw bodies:

```elixir
defmodule Claudio.APIError do
  defexception [:type, :message, :status_code]

  @type error_type ::
    :invalid_request_error |
    :authentication_error |
    :permission_error |
    :not_found_error |
    :rate_limit_error |
    :api_error |
    :overloaded_error
end
```

### 5. Tool/Function Calling Support

Add dedicated modules for tool definitions and execution:

```elixir
defmodule Claudio.Tools do
  @doc """
  Defines a tool with JSON schema for input validation.
  """
  def define_tool(name, description, input_schema)

  @doc """
  Extracts tool use requests from response content.
  """
  def extract_tool_uses(response)

  @doc """
  Creates a tool result message to continue conversation.
  """
  def create_tool_result(tool_use_id, result)
end
```

## Configuration Enhancements

### 1. Default API Version

Add configuration for default API version:

```elixir
# config/config.exs
config :claudio,
  default_api_version: "2023-06-01",
  default_beta_features: []
```

### 2. Client Configuration

Allow configuring timeouts, retry logic, and other HTTP options:

```elixir
config :claudio, Claudio.Client,
  adapter: Tesla.Adapter.Mint,
  timeout: 60_000,
  recv_timeout: 120_000,
  retry_attempts: 3
```

## Testing Improvements

### 1. Test Fixtures

Add reusable test fixtures for common response types:
- Standard message responses
- Tool use responses
- Streaming event sequences
- Error responses for each error type

### 2. Stream Testing

The current `test/messages_test.exs:124-126` has an empty streaming test. Implement:
```elixir
test "stream messages", %{client: client} do
  # Mock SSE stream with multiple events
  # Verify event parsing
  # Verify text accumulation
end
```

## Documentation Needs

1. Add `@moduledoc` to all modules
2. Add `@doc` with examples to all public functions
3. Add `@spec` type specifications to all public functions (some are already present)
4. Create guides for:
   - Getting started
   - Streaming responses
   - Tool/function calling
   - Batch processing
   - Error handling

## Priority Recommendations

**High Priority:**
1. Streaming event parser (current implementation unusable)
2. Tool/function calling support (major API feature)
3. Request builder pattern (usability)
4. Proper error handling with structured errors

**Medium Priority:**
5. Response structs and type safety
6. Message Batches API
7. Complete test coverage including streaming

**Low Priority:**
8. Advanced parameters (thinking, context_management, container)
9. Configuration enhancements
10. Comprehensive documentation

## Breaking Changes Considerations

Some improvements would require breaking changes:
- Changing return types from raw maps to structs
- Changing error tuples from `{:error, body}` to `{:error, %APIError{}}`

Consider maintaining backward compatibility with a v2 API or providing both interfaces during a transition period.
