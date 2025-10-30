# Getting Started with Claudio

This guide will help you get up and running with Claudio, the Elixir client for the Anthropic API.

## Installation

Add `claudio` to your list of dependencies in `mix.exs`:

```elixir
def deps do
  [
    {:claudio, "~> 0.1.2"}
  ]
end
```

Then run:

```bash
mix deps.get
```

## Configuration

### Basic Configuration

Set up your API key and default settings in `config/config.exs`:

```elixir
config :claudio,
  default_api_version: "2023-06-01",
  default_beta_features: []

config :claudio, Claudio.Client,
  timeout: 60_000,        # Connection timeout in ms (default: 60s)
  recv_timeout: 120_000   # Receive timeout in ms (default: 120s)
```

### Optional: Enable Retry Logic

For production environments, you can enable automatic retries:

```elixir
config :claudio, Claudio.Client,
  retry: true  # Uses sensible defaults

# Or with custom options:
config :claudio, Claudio.Client,
  retry: [
    delay: 1000,
    max_retries: 3,
    max_delay: 10_000,
    should_retry: fn
      {:ok, %{status: status}} when status in [429, 500, 502, 503, 504] -> true
      {:ok, _} -> false
      {:error, _} -> true
    end
  ]
```

## Quick Start

### Creating a Client

```elixir
# Using environment variable
api_key = System.get_env("ANTHROPIC_API_KEY")

client = Claudio.Client.new(%{
  token: api_key
})

# Version and beta features are set from config by default
# Or override them:
client = Claudio.Client.new(%{
  token: api_key,
  version: "2023-06-01",
  beta: ["prompt-caching-2024-07-31"]
})
```

### Sending Your First Message

#### Using the Simple API

```elixir
alias Claudio.Messages

{:ok, response} = Messages.create_message(client, %{
  "model" => "claude-sonnet-4-5-20250929",
  "max_tokens" => 1024,
  "messages" => [
    %{"role" => "user", "content" => "Hello, Claude!"}
  ]
})

# Access the response
text = response["content"]
|> Enum.find(&(&1["type"] == "text"))
|> Map.get("text")

IO.puts(text)
```

#### Using the Request Builder (Recommended)

```elixir
alias Claudio.Messages.{Request, Response}

# Build the request
request = Request.new("claude-sonnet-4-5-20250929")
|> Request.add_message(:user, "Hello, Claude!")
|> Request.set_max_tokens(1024)

# Send it
{:ok, response} = Messages.create(client, request)

# Extract text easily
text = Response.get_text(response)
IO.puts(text)
```

### Multi-turn Conversation

```elixir
request = Request.new("claude-sonnet-4-5-20250929")
|> Request.add_message(:user, "What's 2+2?")
|> Request.add_message(:assistant, "2+2 equals 4.")
|> Request.add_message(:user, "What about 3+3?")
|> Request.set_max_tokens(100)

{:ok, response} = Messages.create(client, request)
```

### With System Prompt

```elixir
request = Request.new("claude-sonnet-4-5-20250929")
|> Request.set_system("You are a helpful math tutor. Always show your work.")
|> Request.add_message(:user, "What's 15 * 23?")
|> Request.set_max_tokens(200)

{:ok, response} = Messages.create(client, request)
```

### Adjusting Model Parameters

```elixir
request = Request.new("claude-sonnet-4-5-20250929")
|> Request.add_message(:user, "Write a creative story.")
|> Request.set_max_tokens(1024)
|> Request.set_temperature(0.8)  # More creative
|> Request.set_top_p(0.9)

{:ok, response} = Messages.create(client, request)
```

## Error Handling

```elixir
alias Claudio.APIError

case Messages.create(client, request) do
  {:ok, response} ->
    IO.puts("Success: #{Response.get_text(response)}")

  {:error, %APIError{type: :rate_limit_error} = error} ->
    IO.puts("Rate limited: #{error.message}")
    # Maybe wait and retry

  {:error, %APIError{type: :invalid_request_error} = error} ->
    IO.puts("Invalid request: #{error.message}")
    # Fix the request

  {:error, %APIError{} = error} ->
    IO.puts("API error [#{error.status_code}]: #{error.message}")
end
```

## Counting Tokens

Before sending a large request, you can count tokens:

```elixir
request = Request.new("claude-sonnet-4-5-20250929")
|> Request.add_message(:user, "Long message here...")

{:ok, count} = Messages.count_tokens(client, request)
IO.puts("Input tokens: #{count["input_tokens"]}")
```

## Common Patterns

### Helper Function for Simple Queries

```elixir
defmodule MyApp.Claude do
  alias Claudio.Messages.{Request, Response}
  alias Claudio.Messages

  def ask(client, question, opts \\ []) do
    model = Keyword.get(opts, :model, "claude-sonnet-4-5-20250929")
    max_tokens = Keyword.get(opts, :max_tokens, 1024)
    system = Keyword.get(opts, :system)

    request = Request.new(model)
    |> Request.add_message(:user, question)
    |> Request.set_max_tokens(max_tokens)
    |> maybe_set_system(system)

    case Messages.create(client, request) do
      {:ok, response} -> {:ok, Response.get_text(response)}
      error -> error
    end
  end

  defp maybe_set_system(request, nil), do: request
  defp maybe_set_system(request, system), do: Request.set_system(request, system)
end

# Usage
{:ok, answer} = MyApp.Claude.ask(client, "What is the capital of France?")
```

### Creating a GenServer Client

```elixir
defmodule MyApp.ClaudeClient do
  use GenServer

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  def ask(question) do
    GenServer.call(__MODULE__, {:ask, question}, 30_000)
  end

  @impl true
  def init(opts) do
    api_key = Keyword.fetch!(opts, :api_key)

    client = Claudio.Client.new(%{
      token: api_key
    })

    {:ok, %{client: client}}
  end

  @impl true
  def handle_call({:ask, question}, _from, state) do
    alias Claudio.Messages.{Request, Response}

    request = Request.new("claude-sonnet-4-5-20250929")
    |> Request.add_message(:user, question)
    |> Request.set_max_tokens(1024)

    result = case Claudio.Messages.create(state.client, request) do
      {:ok, response} -> {:ok, Response.get_text(response)}
      error -> error
    end

    {:reply, result, state}
  end
end

# In your application.ex
children = [
  {MyApp.ClaudeClient, api_key: System.get_env("ANTHROPIC_API_KEY")}
]

# Usage
{:ok, answer} = MyApp.ClaudeClient.ask("Hello!")
```

## Next Steps

- **[Full Documentation](https://hexdocs.pm/claudio)** - Complete API reference
- **[README Examples](../README.md)** - More code examples including streaming, tools, and batching
- **[Anthropic API Docs](https://docs.anthropic.com)** - Official API documentation

## Best Practices

1. **Store API keys securely** - Use environment variables, never commit keys
2. **Use the Request builder** - It's more maintainable than raw maps
3. **Handle errors properly** - Always pattern match on error types
4. **Set appropriate timeouts** - Long-running requests need longer timeouts
5. **Use system prompts** - They help guide the model's behavior
6. **Count tokens first** - For large requests, check token count before sending
7. **Enable retries in production** - Handle transient network errors automatically

## Troubleshooting

### "authentication_error: invalid x-api-key"

Your API key is incorrect or not set. Check:
```elixir
System.get_env("ANTHROPIC_API_KEY")
```

### "rate_limit_error"

You've exceeded your rate limit. Either wait or implement exponential backoff:

```elixir
defp retry_with_backoff(fun, attempt \\ 1, max_attempts \\ 3) do
  case fun.() do
    {:error, %APIError{type: :rate_limit_error}} when attempt < max_attempts ->
      delay = :math.pow(2, attempt) * 1000 |> round()
      Process.sleep(delay)
      retry_with_backoff(fun, attempt + 1, max_attempts)

    result -> result
  end
end
```

### "model_context_window_exceeded"

Your input is too large. Try:
- Reducing the input length
- Using a model with a larger context window
- Implementing prompt caching for repeated context

## Support

- **Documentation**: [https://hexdocs.pm/claudio](https://hexdocs.pm/claudio)
- **GitHub Issues**: [Report bugs or request features](https://github.com/thetonymaster/claudio/issues)
- **Anthropic API Reference**: [https://docs.anthropic.com](https://docs.anthropic.com)
