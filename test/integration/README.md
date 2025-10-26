# Integration Tests

This directory contains integration tests that make real API calls to the Anthropic API.

## Setup

### 1. Get an API Key

Sign up for an Anthropic account and get your API key from:
https://console.anthropic.com/

### 2. Set Environment Variable

```bash
export ANTHROPIC_API_KEY="your-api-key-here"
```

Or add it to your shell profile (`~/.bashrc`, `~/.zshrc`, etc.):

```bash
echo 'export ANTHROPIC_API_KEY="your-api-key-here"' >> ~/.zshrc
source ~/.zshrc
```

## Running Integration Tests

### Run Only Integration Tests

```bash
mix test --only integration
```

### Run All Tests (Unit + Integration)

```bash
mix test --include integration
```

### Run a Specific Integration Test File

```bash
mix test test/integration/messages_integration_test.exs --include integration
```

### Run a Specific Test

```bash
mix test test/integration/messages_integration_test.exs:15 --include integration
```

## Cost Warning

⚠️ **Integration tests make real API calls and will consume API credits.**

Current test suite usage (approximate):
- Messages Integration Tests: ~10-20 API calls
- Streaming Integration Tests: ~5-10 API calls
- Total tokens: ~5,000-10,000 tokens

At current pricing (as of 2025), this costs approximately **$0.01-0.05 per test run**.

## Test Organization

- **`messages_integration_test.exs`** - Tests for basic message creation, system prompts, multi-turn conversations, token counting
- **`streaming_integration_test.exs`** - Tests for streaming responses, SSE parsing, event filtering
- **`integration_helper.exs`** - Helper functions for integration tests

## Skipping Tests Without API Key

Integration tests are automatically skipped if `ANTHROPIC_API_KEY` is not set:

```bash
$ mix test test/integration/
...
  * test simple message with request builder (skipped)
    ANTHROPIC_API_KEY not set
```

## CI/CD Integration

### GitHub Actions Example

```yaml
name: Tests

on: [push, pull_request]

jobs:
  test:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v2
      - uses: erlef/setup-beam@v1
        with:
          elixir-version: '1.15'
          otp-version: '26'

      # Run unit tests only (default)
      - run: mix test

      # Run integration tests only on main branch
      - if: github.ref == 'refs/heads/main'
        run: mix test --include integration
        env:
          ANTHROPIC_API_KEY: ${{ secrets.ANTHROPIC_API_KEY }}
```

## Best Practices

1. **Don't commit API keys** - Always use environment variables
2. **Run integration tests sparingly** - They cost money and take time
3. **Use unit tests for development** - Save integration tests for pre-release verification
4. **Monitor API usage** - Check your Anthropic console for usage
5. **Set timeouts appropriately** - Integration tests have 120s timeout by default

## Troubleshooting

### "ANTHROPIC_API_KEY not set"

Set the environment variable:
```bash
export ANTHROPIC_API_KEY="your-key"
```

### "authentication_error: invalid x-api-key"

Your API key is invalid or expired. Get a new one from https://console.anthropic.com/

### Tests timing out

Some tests may take longer depending on API response time. Increase the timeout in the test:

```elixir
@moduletag timeout: 180_000  # 3 minutes
```

### Rate limiting

If you see `rate_limit_error`, wait a few minutes before running tests again. Consider:
- Running fewer tests at once
- Adding delays between test runs
- Upgrading your API tier

## Adding New Integration Tests

When adding new integration tests:

1. Add the `@moduletag :integration` tag
2. Set appropriate timeout: `@moduletag timeout: 120_000`
3. Use `setup_all` with `skip_if_no_api_key()`
4. Document expected API usage/cost
5. Keep tests focused and minimal

Example template:

```elixir
Code.require_file("../integration/integration_helper.exs", __DIR__)

defmodule Claudio.MyFeature.IntegrationTest do
  use ExUnit.Case, async: false
  import Claudio.IntegrationHelper

  @moduletag :integration
  @moduletag timeout: 120_000

  setup_all do
    case skip_if_no_api_key() do
      :ok ->
        client = create_client()
        {:ok, %{client: client}}
      {:skip, reason} ->
        {:skip, reason}
    end
  end

  test "my feature works", %{client: client} do
    # Your test here
  end
end
```
