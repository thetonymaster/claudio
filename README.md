# Claudio

An Elixir client library for the Anthropic API, providing a comprehensive interface for interacting with Claude models.

## Features

- **Messages API** with streaming support
- **Tool/Function calling** with structured schemas
- **Message Batches API** for large-scale async processing
- **Prompt caching** (up to 90% cost reduction)
- **Vision/image support** (base64, URL, Files API)
- **PDF/document support**
- **MCP (Model Context Protocol) servers**
- **Request building** with fluent API and validation
- **Structured response handling** with content block parsing
- **Token counting** for cost estimation
- **Cache metrics tracking**
- **Configurable timeouts** and retry logic

## Installation

Add `claudio` to your list of dependencies in `mix.exs`:

```elixir
def deps do
  [
    {:claudio, "~> 0.1.0"}
  ]
end
```

## Quick Start

```elixir
# Create a client
client = Claudio.Client.new(%{
  token: System.get_env("ANTHROPIC_API_KEY"),
  version: "2023-06-01"
})

# Simple message
{:ok, response} = Claudio.Messages.create(client, %{
  model: "claude-3-5-sonnet-20241022",
  max_tokens: 1024,
  messages: [
    %{role: "user", content: "Hello, Claude!"}
  ]
})

IO.puts(response.content |> hd() |> Map.get(:text))
```

## Configuration

### API Client

```elixir
# config/config.exs
config :claudio,
  default_api_version: "2023-06-01",
  default_beta_features: ["prompt-caching-2024-07-31"]
```

### Timeout Configuration

Configure connection and receive timeouts (important for streaming):

```elixir
# config/config.exs
config :claudio, Claudio.Client,
  timeout: 60_000,        # Connection timeout in ms (default: 60s)
  recv_timeout: 120_000   # Receive timeout in ms (default: 120s)
```

**For long-running streaming operations:**

```elixir
config :claudio, Claudio.Client,
  timeout: 60_000,
  recv_timeout: 600_000   # 10 minutes for long streams
```

**For production environments:**

```elixir
# config/prod.exs
config :claudio, Claudio.Client,
  timeout: 30_000,
  recv_timeout: 180_000,
  retry: true  # Enable automatic retries
```

### Retry Configuration

Enable automatic retries for transient failures:

```elixir
config :claudio, Claudio.Client,
  retry: true  # Uses default retry strategy

# Or customize:
config :claudio, Claudio.Client,
  retry: [
    delay: 1000,
    max_retries: 3,
    max_delay: 10_000
  ]
```

## Usage

### Request Builder API (Recommended)

Use the fluent request builder for type-safe requests:

```elixir
alias Claudio.Messages.Request

request =
  Request.new("claude-3-5-sonnet-20241022")
  |> Request.add_message(:user, "What is the capital of France?")
  |> Request.set_max_tokens(1024)
  |> Request.set_temperature(0.7)

{:ok, response} = Claudio.Messages.create(client, request)
```

### Streaming Responses

Stream responses for real-time output:

```elixir
alias Claudio.Messages.{Request, Stream}

request =
  Request.new("claude-3-5-sonnet-20241022")
  |> Request.add_message(:user, "Write a short story")
  |> Request.set_max_tokens(1024)
  |> Request.enable_streaming()

{:ok, stream_response} = Claudio.Messages.create(client, request)

# Parse and accumulate text
text =
  stream_response.body
  |> Stream.parse_events()
  |> Stream.accumulate_text()

IO.puts(text)
```

### Prompt Caching

Reduce costs by caching large contexts:

```elixir
request =
  Request.new("claude-3-5-sonnet-20241022")
  |> Request.set_system_with_cache("""
    You are an expert on Shakespeare's works.
    Here is the full text of Hamlet...
    [large context that will be cached]
    """, ttl: "5m")
  |> Request.add_message(:user, "Analyze Hamlet's soliloquy")
  |> Request.set_max_tokens(2048)

{:ok, response} = Claudio.Messages.create(client, request)

# Check cache metrics
IO.inspect(response.usage.cache_creation_input_tokens)
IO.inspect(response.usage.cache_read_input_tokens)
```

### Vision/Image Support

Send images for analysis:

```elixir
# From base64
image_data = File.read!("image.jpg") |> Base.encode64()

request =
  Request.new("claude-3-5-sonnet-20241022")
  |> Request.add_message_with_image(:user, "Describe this image", image_data, "image/jpeg")
  |> Request.set_max_tokens(1024)
```

### Tool/Function Calling

Define and use tools:

```elixir
alias Claudio.Tools

# Define a tool
weather_tool = Tools.define_tool(
  "get_weather",
  "Get the current weather in a location",
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
  |> Request.add_message(:user, "What's the weather in Paris?")
  |> Request.add_tool(weather_tool)
  |> Request.set_max_tokens(1024)

{:ok, response} = Claudio.Messages.create(client, request)

# Extract and handle tool uses
if Tools.has_tool_uses?(response) do
  tool_uses = Tools.extract_tool_uses(response)
  # Execute your tools and continue conversation...
end
```

### Message Batches API

Process large volumes of requests asynchronously:

```elixir
# Create a batch of requests
requests = [
  %{
    custom_id: "req-1",
    params: %{
      model: "claude-3-5-sonnet-20241022",
      max_tokens: 1024,
      messages: [%{role: "user", content: "Hello"}]
    }
  }
]

# Submit batch (up to 100,000 requests)
{:ok, batch} = Claudio.Batches.create(client, requests)

# Wait for completion with progress callback
{:ok, completed_batch} = Claudio.Batches.wait_for_completion(
  client,
  batch["id"],
  fn status ->
    IO.puts("Progress: #{status["request_counts"]["succeeded"]}")
  end
)

# Get results
{:ok, results} = Claudio.Batches.get_results(client, batch["id"])
```

## Error Handling

All API calls return structured errors:

```elixir
case Claudio.Messages.create(client, request) do
  {:ok, response} ->
    # Handle success
    IO.puts("Success!")

  {:error, %Claudio.APIError{} = error} ->
    # Handle API errors
    IO.puts("Error #{error.status}: #{error.message}")
    IO.inspect(error.type)  # :rate_limit_error, :authentication_error, etc.

  {:error, reason} ->
    # Handle other errors (network, timeout, etc.)
    IO.inspect(reason)
end
```

## Testing

```bash
# Unit tests only
mix test

# Include integration tests (requires ANTHROPIC_API_KEY)
mix test --include integration
```

## Documentation

Generate documentation:

```bash
mix docs
open doc/index.html
```

## License

MIT License - see [LICENSE](LICENSE) for details.

## Links

- [Anthropic API Documentation](https://docs.anthropic.com/)
- [GitHub Repository](https://github.com/thetonymaster/claudio)
