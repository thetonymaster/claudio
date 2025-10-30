# Claudio

[![Hex.pm](https://img.shields.io/hexpm/v/claudio.svg)](https://hex.pm/packages/claudio)
[![Documentation](https://img.shields.io/badge/docs-hexdocs-blue.svg)](https://hexdocs.pm/claudio)
[![CI](https://github.com/thetonymaster/claudio/workflows/CI/badge.svg)](https://github.com/thetonymaster/claudio/actions)
[![License](https://img.shields.io/hexpm/l/claudio.svg)](https://github.com/thetonymaster/claudio/blob/main/LICENSE)

> A modern, feature-complete Elixir client for the Anthropic API

Claudio provides a comprehensive, idiomatic Elixir interface for Claude AI models with support for streaming, tool calling, prompt caching, vision, and batch processing.

## Why Claudio?

- **🚀 Production Ready**: Configurable timeouts, automatic retries, and comprehensive error handling
- **⚡ High Performance**: Built on Req for fast HTTP operations with excellent streaming support
- **💎 Idiomatic Elixir**: Fluent API, pattern matching on errors, and proper supervision tree integration
- **📦 Feature Complete**: Messages, Batches, Tools, Caching, Vision - everything you need
- **🧪 Well Tested**: 76 tests covering unit and integration scenarios
- **📚 Fully Documented**: Complete API documentation with examples on HexDocs

## Features

- ✅ **Messages API** - Send messages with streaming support
- ✅ **Request Builder** - Type-safe, fluent API for building requests
- ✅ **Tool/Function Calling** - Integrate external tools with structured schemas
- ✅ **Message Batches** - Process up to 100,000 requests asynchronously
- ✅ **Prompt Caching** - Cache large contexts for up to 90% cost reduction
- ✅ **Vision Support** - Analyze images (base64, URL, Files API)
- ✅ **PDF/Document Support** - Process documents directly
- ✅ **Streaming Responses** - Real-time Server-Sent Events (SSE) streaming
- ✅ **Token Counting** - Estimate costs before making requests
- ✅ **Configurable Timeouts** - Fine-tune connection and receive timeouts
- ✅ **Automatic Retries** - Handle transient failures gracefully
- ✅ **Structured Errors** - Pattern match on error types
- ✅ **Cache Metrics** - Track cache hits and creation

## Installation

Add `claudio` to your list of dependencies in `mix.exs`:

```elixir
def deps do
  [
    {:claudio, "~> 0.1.1"}
  ]
end
```

Then fetch dependencies:

```bash
mix deps.get
```

## Quick Start

### 1. Get an API Key

Sign up for an Anthropic API key at [console.anthropic.com](https://console.anthropic.com/)

### 2. Set Your API Key

```bash
export ANTHROPIC_API_KEY="your-api-key-here"
```

### 3. Send Your First Message

```elixir
# Create a client
client = Claudio.Client.new(%{
  token: System.get_env("ANTHROPIC_API_KEY")
})

# Use the Request builder (recommended)
alias Claudio.Messages.{Request, Response}

request =
  Request.new("claude-3-5-sonnet-20241022")
  |> Request.add_message(:user, "Explain quantum computing in simple terms")
  |> Request.set_max_tokens(1024)

{:ok, response} = Claudio.Messages.create(client, request)

# Extract the text
text = Response.get_text(response)
IO.puts(text)
```

## Examples

### Multi-Turn Conversation

```elixir
alias Claudio.Messages.{Request, Response}

request =
  Request.new("claude-3-5-sonnet-20241022")
  |> Request.set_system("You are a helpful Python tutor")
  |> Request.add_message(:user, "How do I read a file in Python?")
  |> Request.add_message(:assistant, "You can use the open() function...")
  |> Request.add_message(:user, "What about writing to a file?")
  |> Request.set_max_tokens(500)

{:ok, response} = Claudio.Messages.create(client, request)
IO.puts(Response.get_text(response))
```

### Streaming Responses

Perfect for chat interfaces or real-time applications:

```elixir
alias Claudio.Messages.{Request, Stream}

request =
  Request.new("claude-3-5-sonnet-20241022")
  |> Request.add_message(:user, "Write a haiku about Elixir")
  |> Request.set_max_tokens(100)
  |> Request.enable_streaming()

{:ok, stream_response} = Claudio.Messages.create(client, request)

# Stream text in real-time
stream_response.body
|> Stream.parse_events()
|> Stream.filter_events(:content_block_delta)
|> Enum.each(fn event ->
  IO.write(event.delta.text)
end)
```

### Tool/Function Calling

Let Claude use your functions:

```elixir
alias Claudio.{Tools, Messages.Request}

# Define a weather tool
weather_tool = Tools.define_tool(
  "get_weather",
  "Get current weather for a location",
  %{
    type: "object",
    properties: %{
      location: %{type: "string", description: "City name"},
      unit: %{type: "string", enum: ["celsius", "fahrenheit"]}
    },
    required: ["location"]
  }
)

# Create request with tool
request =
  Request.new("claude-3-5-sonnet-20241022")
  |> Request.add_message(:user, "What's the weather in Tokyo?")
  |> Request.add_tool(weather_tool)
  |> Request.set_max_tokens(500)

{:ok, response} = Claudio.Messages.create(client, request)

# Check if Claude wants to use the tool
if Tools.has_tool_uses?(response) do
  tool_uses = Tools.extract_tool_uses(response)

  Enum.each(tool_uses, fn tool_use ->
    # Execute your function
    result = get_weather(tool_use.input["location"])

    # Send result back to Claude
    tool_result = Tools.create_tool_result(tool_use.id, Jason.encode!(result))

    request =
      Request.new("claude-3-5-sonnet-20241022")
      |> Request.add_messages(response.content)
      |> Request.add_message(:user, [tool_result])
      |> Request.set_max_tokens(500)

    {:ok, final_response} = Claudio.Messages.create(client, request)
    IO.puts(Response.get_text(final_response))
  end)
end

defp get_weather(location) do
  # Your weather API implementation
  %{temp: 72, condition: "sunny", location: location}
end
```

### Vision - Analyze Images

```elixir
# From a file
image_data = File.read!("screenshot.png") |> Base.encode64()

request =
  Request.new("claude-3-5-sonnet-20241022")
  |> Request.add_message_with_image(
    :user,
    "What's in this image?",
    image_data,
    "image/png"
  )
  |> Request.set_max_tokens(500)

{:ok, response} = Claudio.Messages.create(client, request)
IO.puts(Response.get_text(response))

# Or from a URL
request =
  Request.new("claude-3-5-sonnet-20241022")
  |> Request.add_message_with_image_url(
    :user,
    "Describe this diagram",
    "https://example.com/diagram.jpg"
  )
  |> Request.set_max_tokens(500)
```

### Prompt Caching - Save 90% on Costs

Cache large contexts like documentation or code:

```elixir
large_codebase = File.read!("lib/my_app.ex")

request =
  Request.new("claude-3-5-sonnet-20241022")
  |> Request.set_system_with_cache("""
    You are a code reviewer. Here is the codebase:

    #{large_codebase}

    Review code changes carefully for bugs and style.
    """, ttl: "5m")
  |> Request.add_message(:user, "Review this function: def foo(x), do: x + 1")
  |> Request.set_max_tokens(1000)

{:ok, response} = Claudio.Messages.create(client, request)

# Check cache savings
IO.inspect(response.usage.cache_read_input_tokens, label: "Tokens from cache")
IO.inspect(response.usage.cache_creation_input_tokens, label: "Tokens cached")
```

### Batch Processing

Process thousands of requests asynchronously:

```elixir
alias Claudio.Batches

# Create a batch of analysis tasks
requests =
  Enum.map(1..1000, fn i ->
    %{
      custom_id: "review-#{i}",
      params: %{
        model: "claude-3-5-sonnet-20241022",
        max_tokens: 500,
        messages: [
          %{role: "user", content: "Analyze pull request ##{i}"}
        ]
      }
    }
  end)

# Submit batch (processes asynchronously)
{:ok, batch} = Batches.create(client, requests)
IO.puts("Batch created: #{batch["id"]}")

# Wait for completion with progress updates
{:ok, completed} = Batches.wait_for_completion(
  client,
  batch["id"],
  fn status ->
    counts = status["request_counts"]
    progress = counts["succeeded"] + counts["errored"]
    total = counts["processing"]
    IO.puts("Progress: #{progress}/#{total}")
  end,
  poll_interval: 10_000  # Check every 10 seconds
)

# Download results as JSONL
{:ok, results_jsonl} = Batches.get_results(client, batch["id"])

# Parse results
results =
  results_jsonl
  |> String.split("\n", trim: true)
  |> Enum.map(&Jason.decode!/1)

Enum.each(results, fn result ->
  case result["result"]["type"] do
    "succeeded" ->
      message = result["result"]["message"]
      IO.puts("#{result["custom_id"]}: Success")

    "errored" ->
      error = result["result"]["error"]
      IO.puts("#{result["custom_id"]}: Error - #{error["message"]}")
  end
end)
```

## Configuration

### Basic Setup

```elixir
# config/config.exs
config :claudio,
  default_api_version: "2023-06-01",
  default_beta_features: []
```

### Timeout Configuration

Configure timeouts for different use cases:

```elixir
# config/config.exs
config :claudio, Claudio.Client,
  timeout: 60_000,        # Connection timeout: 60s
  recv_timeout: 120_000   # Receive timeout: 120s (important for streaming)

# For long-running operations
config :claudio, Claudio.Client,
  timeout: 60_000,
  recv_timeout: 600_000   # 10 minutes

# Production with retries
config :claudio, Claudio.Client,
  timeout: 30_000,
  recv_timeout: 180_000,
  retry: true  # Automatic retry on transient failures
```

### Custom Retry Logic

```elixir
config :claudio, Claudio.Client,
  retry: [
    delay: 1000,          # Initial delay: 1s
    max_retries: 3,       # Retry up to 3 times
    max_delay: 10_000     # Max delay: 10s
  ]
```

## Error Handling

Claudio provides structured error types for pattern matching:

```elixir
alias Claudio.APIError

case Claudio.Messages.create(client, request) do
  {:ok, response} ->
    # Success
    handle_response(response)

  {:error, %APIError{type: :rate_limit_error} = error} ->
    # Rate limited - wait and retry
    Logger.warning("Rate limited: #{error.message}")
    Process.sleep(60_000)
    retry_request()

  {:error, %APIError{type: :authentication_error}} ->
    # Invalid API key
    Logger.error("Authentication failed - check your API key")

  {:error, %APIError{type: :invalid_request_error} = error} ->
    # Bad request - fix and retry
    Logger.error("Invalid request: #{error.message}")
    fix_and_retry()

  {:error, %APIError{type: :overloaded_error}} ->
    # Service overloaded - retry with backoff
    exponential_backoff_retry()

  {:error, %APIError{} = error} ->
    # Other API error
    Logger.error("API error [#{error.status_code}]: #{error.message}")

  {:error, reason} ->
    # Network or timeout error
    Logger.error("Request failed: #{inspect(reason)}")
end
```

### Error Types

- `:authentication_error` - Invalid API key
- `:invalid_request_error` - Malformed request
- `:rate_limit_error` - Too many requests
- `:overloaded_error` - Service overloaded
- `:permission_error` - Insufficient permissions
- `:not_found_error` - Resource not found
- `:api_error` - General API error

## Best Practices

### 1. Use the Request Builder

The fluent Request API is more maintainable than raw maps:

```elixir
# Good ✓
request =
  Request.new("claude-3-5-sonnet-20241022")
  |> Request.add_message(:user, "Hello")
  |> Request.set_max_tokens(100)

# Works, but less maintainable
request = %{
  "model" => "claude-3-5-sonnet-20241022",
  "messages" => [%{"role" => "user", "content" => "Hello"}],
  "max_tokens" => 100
}
```

### 2. Handle Errors Properly

Always pattern match on error types:

```elixir
# Good ✓
case Claudio.Messages.create(client, request) do
  {:ok, response} -> handle_success(response)
  {:error, %APIError{type: :rate_limit_error}} -> retry_with_backoff()
  {:error, error} -> handle_error(error)
end

# Bad ✗
{:ok, response} = Claudio.Messages.create(client, request)  # Crashes on error
```

### 3. Use System Prompts

Guide the model's behavior with system prompts:

```elixir
request =
  Request.new("claude-3-5-sonnet-20241022")
  |> Request.set_system("You are a helpful coding assistant. Always explain your code.")
  |> Request.add_message(:user, "Write a function to reverse a string")
```

### 4. Set Appropriate Timeouts

Long operations need longer timeouts:

```elixir
# For batch processing or large responses
config :claudio, Claudio.Client,
  recv_timeout: 600_000  # 10 minutes
```

### 5. Enable Retries in Production

Handle transient failures automatically:

```elixir
config :claudio, Claudio.Client,
  retry: true
```

### 6. Cache Large Contexts

Use prompt caching for repeated contexts:

```elixir
# Cache documentation or code for multiple queries
request =
  Request.new("claude-3-5-sonnet-20241022")
  |> Request.set_system_with_cache(large_documentation, ttl: "5m")
```

### 7. Count Tokens for Cost Control

```elixir
{:ok, count} = Claudio.Messages.count_tokens(client, request)
estimated_cost = count["input_tokens"] * 0.003 / 1000
IO.puts("Estimated cost: $#{estimated_cost}")
```

## Testing

```bash
# Run unit tests
mix test

# Run with integration tests (requires ANTHROPIC_API_KEY)
export ANTHROPIC_API_KEY="your-key"
mix test --include integration

# Run specific test file
mix test test/messages_test.exs

# Check code formatting
mix format --check-formatted
```

## Documentation

Full API documentation is available on HexDocs:

- **[Main Documentation](https://hexdocs.pm/claudio)** - Complete API reference
- **[Getting Started Guide](guides/GETTING_STARTED.md)** - Detailed tutorial
- **[GitHub Repository](https://github.com/thetonymaster/claudio)** - Source code

Generate documentation locally:

```bash
mix docs
open doc/index.html
```

## Contributing

Contributions are welcome! Please feel free to submit a Pull Request.

1. Fork the repository
2. Create your feature branch (`git checkout -b feature/amazing-feature`)
3. Write tests for your changes
4. Ensure all tests pass (`mix test`)
5. Commit your changes (`git commit -am 'Add amazing feature'`)
6. Push to the branch (`git push origin feature/amazing-feature`)
7. Open a Pull Request

## License

This project is licensed under the MIT License - see the [LICENSE](LICENSE) file for details.

## Links

- **[Hex Package](https://hex.pm/packages/claudio)** - Latest releases
- **[Documentation](https://hexdocs.pm/claudio)** - Full API reference
- **[GitHub](https://github.com/thetonymaster/claudio)** - Source code
- **[Anthropic API Docs](https://docs.anthropic.com/)** - Official API documentation
- **[Anthropic Console](https://console.anthropic.com/)** - Get your API key

## Acknowledgments

Built with ❤️ using [Req](https://github.com/wojtekmach/req) for HTTP client operations.

---

**Made with Elixir** 💜
