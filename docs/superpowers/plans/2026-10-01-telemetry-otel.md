# Telemetry & OpenTelemetry Readiness Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Give every Claudio API call documented, bounded, OTel-mappable `:telemetry` events — a
complete `create` span, a `count_tokens` span, a full-duration stream span, and per-attempt HTTP
events — plus a guide with a GenAI-semconv handler example.

**Architecture:** A private `Claudio.Telemetry` module owns every mapping (usage → tokens, error →
bounded `error_type`, request params, HTTP Req steps). `Claudio.Messages` routes all calls through one
`span/5` helper; streaming responses carry a link in `resp.private[:claudio]` that
`Stream.parse_events/1` reads to emit a linked `[:claudio, :messages, :stream]` start/stop pair from a
`Stream.transform/5` stage. HTTP events are Req steps attached in `Client.build_request/2`.

**Tech Stack:** Elixir ≥ 1.15, `:telemetry ~> 1.3`, Req 0.7 (Finch adapter), Bypass for tests.

**Spec:** `docs/superpowers/specs/2026-10-01-telemetry-otel-design.md`

## Global Constraints

- Additive only: every existing event name and metadata key keeps its meaning (spec Goals).
- `{:telemetry, "~> 1.3"}` in `mix.exs` (spec F1).
- No event carries request/response headers or bodies, the API key, or message content.
- `error_type` is always an atom or a short string from the API — never an `inspect` string.
- Optional metadata keys are absent (not `nil`) when there is no value, except `status_code`, which is `nil` for transport errors.
- `Claudio.Telemetry` is `@moduledoc false`, holds no state, attaches no handlers.
- Tests are `async: true`; every handler forwards only events emitted by the test process (or matching a unique model) via `test/telemetry_helper.exs`.
- No new runtime or test dependency (no `opentelemetry_*`).
- CHANGELOG lines go under `[Unreleased]`; no `@version` change.
- Commits: `git add` named files only; no AI attribution lines.
- Each task ends with `mix test` (full suite) green and `mix format --check-formatted` clean; the last task runs `mix precommit` and `mix docs --warnings-as-errors`.

## Review Focus

1. **A non-async `%Req.Response{}` passed to `parse_events/1`** (e.g. a `Req.Test` plug or a cached body whose `body` is a binary) must parse it as one chunk, not crash — test in Task 5.
2. **Legacy `create_message/2` with a 200 whose body isn't a JSON object** must still return `{:ok, body}` as today; building stop metadata must not crash — test in Task 2.
3. **Two sequential calls on one client each start at `attempt: 0`** (the retry counter must not leak across calls) — test in Task 4.
4. **A stream consumed in another process** (`Task.async`) emits its stream events from that process, still linked to the `create` span — test in Task 5.
5. **Atom-keyed payload maps** (`create(client, %{model: "m", max_tokens: 8, ...})`) report `model` and `max_tokens` in `create :start` — test in Task 2.

## File Structure

| File | Responsibility |
|---|---|
| `lib/claudio/telemetry.ex` (new) | Pure mappings + HTTP Req steps. |
| `lib/claudio/messages.ex` | `span/5` helper; create (both paths), legacy, count_tokens spans; stream link. Deletes its `usage_to_metadata/1`. |
| `lib/claudio/messages/stream.ex` | `parse_events/1` `%Req.Response{}` clause; stream span stage. Its `usage_to_metadata/1` delegates to `Claudio.Telemetry.usage/1`. |
| `lib/claudio/client.ex` | Pipes `Req.new/1` through `Claudio.Telemetry.attach_http/1`. |
| `mix.exs` | `:telemetry ~> 1.3`; guide in ExDoc extras. |
| `test/telemetry_helper.exs` (new) | `Claudio.TelemetryTestSupport.attach/2`. |
| `test/telemetry_test.exs` (new) | Unit tests for `Claudio.Telemetry`; HTTP events; no-secrets test. |
| `test/messages_test.exs` | create / legacy / count_tokens span tests. |
| `test/messages/stream_test.exs` | stream span tests. |
| `guides/telemetry.md` (new) | Event reference + OTel example. |
| `README.md`, `CHANGELOG.md`, `CLAUDE.md`, `lib/claudio.ex` | Docs. |

---

### Task 1: `Claudio.Telemetry` mappings and the shared test helper

**Files:**
- Create: `lib/claudio/telemetry.ex`, `test/telemetry_helper.exs`, `test/telemetry_test.exs`
- Modify: `lib/claudio/messages.ex` (delete `usage_to_metadata/1` + `thinking_tokens/1`, ~lines 361-380), `lib/claudio/messages/stream.ex` (`usage_to_metadata/1` + `maybe_put_thinking_tokens/2` + `maybe_put_usage_key/2`, ~lines 117-146)

**Interfaces:**
- Produces:
  - `Claudio.Telemetry.usage(map() | nil) :: map()` — the five token keys (`:input_tokens`, `:output_tokens`, `:cache_creation_input_tokens`, `:cache_read_input_tokens`, `:thinking_tokens`), absent when nil; accepts atom or string keys; used as both measurements and metadata.
  - `Claudio.Telemetry.error_type(term()) :: atom() | String.t()`
  - `Claudio.Telemetry.request_metadata(map()) :: map()` — `:max_tokens`, `:temperature`, `:top_p`, `:top_k`, `:effort`.
  - `Claudio.Telemetry.server_address(Req.Request.t()) :: String.t() | nil`
  - `Claudio.Telemetry.request_id(Req.Response.t()) :: String.t() | nil`
  - `Claudio.Telemetry.put_present(map(), atom(), term()) :: map()`
  - `Claudio.TelemetryTestSupport.attach([event_name], keyword()) :: :ok` — sends `{:telemetry, event, measurements, metadata}` to the test process; option `filter: (metadata -> boolean)` replaces the default "emitted by the test process" filter.

- [ ] **Step 1: Write the test helper**

`test/telemetry_helper.exs`:

```elixir
defmodule Claudio.TelemetryTestSupport do
  @moduledoc false
  import ExUnit.Callbacks, only: [on_exit: 1]

  # Forwards the given events to the test process as {:telemetry, event, measurements, metadata}.
  # Handlers run in the emitting process and test modules are async, so by default only events
  # emitted by the test process itself are forwarded; pass `filter:` (metadata -> boolean) for
  # events emitted elsewhere (e.g. a stream consumed in a Task).
  def attach(events, opts \\ []) do
    id = "claudio-telemetry-test-#{System.unique_integer([:positive])}"
    :ok = :telemetry.attach_many(id, events, &__MODULE__.forward/4, {self(), opts[:filter]})
    on_exit(fn -> :telemetry.detach(id) end)
  end

  def forward(event, measurements, metadata, {pid, nil}) do
    if self() == pid, do: send(pid, {:telemetry, event, measurements, metadata})
  end

  def forward(event, measurements, metadata, {pid, filter}) do
    if filter.(metadata), do: send(pid, {:telemetry, event, measurements, metadata})
  end
end
```

- [ ] **Step 2: Write the failing unit tests**

`test/telemetry_test.exs`:

```elixir
Code.require_file("telemetry_helper.exs", __DIR__)

defmodule Claudio.TelemetryTest do
  use ExUnit.Case, async: true

  alias Claudio.Telemetry

  describe "usage/1" do
    test "maps atom-keyed usage, dropping nils, with thinking tokens" do
      usage = %{
        input_tokens: 10,
        output_tokens: 20,
        cache_creation_input_tokens: nil,
        cache_read_input_tokens: 4,
        output_tokens_details: %{thinking_tokens: 7}
      }

      assert Telemetry.usage(usage) == %{
               input_tokens: 10,
               output_tokens: 20,
               cache_read_input_tokens: 4,
               thinking_tokens: 7
             }
    end

    test "maps string-keyed usage" do
      usage = %{
        "input_tokens" => 1,
        "output_tokens" => 2,
        "output_tokens_details" => %{"thinking_tokens" => 3}
      }

      assert Telemetry.usage(usage) == %{input_tokens: 1, output_tokens: 2, thinking_tokens: 3}
    end

    test "nil or non-map usage is empty" do
      assert Telemetry.usage(nil) == %{}
      assert Telemetry.usage("x") == %{}
    end
  end

  describe "error_type/1" do
    test "APIError → its type" do
      assert Telemetry.error_type(%Claudio.APIError{type: :rate_limit_error}) == :rate_limit_error
      assert Telemetry.error_type(%Claudio.APIError{type: "new_error"}) == "new_error"
    end

    test "transport errors → their atom reason" do
      assert Telemetry.error_type(%Req.TransportError{reason: :econnrefused}) == :econnrefused
      assert Telemetry.error_type(%Req.TransportError{reason: :timeout}) == :timeout
    end

    test "other exceptions → their module; anything else → :unknown" do
      assert Telemetry.error_type(%RuntimeError{message: "x"}) == RuntimeError
      assert Telemetry.error_type({:weird, "tuple"}) == :unknown
    end
  end

  describe "request_metadata/1" do
    test "string-keyed payload, effort from output_config" do
      payload = %{
        "model" => "m",
        "max_tokens" => 8,
        "temperature" => 0,
        "output_config" => %{"effort" => "high"}
      }

      assert Telemetry.request_metadata(payload) == %{max_tokens: 8, temperature: 0, effort: "high"}
    end

    test "atom-keyed payload" do
      assert Telemetry.request_metadata(%{model: "m", max_tokens: 8, top_k: 5}) ==
               %{max_tokens: 8, top_k: 5}
    end
  end

  test "server_address/1 is the base_url host" do
    client = Claudio.Client.new(%{token: "t", version: "2023-06-01"}, "http://api.example.test:4000/v1/")
    assert Telemetry.server_address(client) == "api.example.test"
  end

  test "request_id/1 reads the request-id header" do
    assert Telemetry.request_id(Req.Response.new(headers: [{"request-id", "req_1"}])) == "req_1"
    assert Telemetry.request_id(Req.Response.new()) == nil
  end
end
```

- [ ] **Step 3: Run to verify it fails**

Run: `mix test test/telemetry_test.exs`
Expected: FAIL — `Claudio.Telemetry.usage/1 is undefined (module Claudio.Telemetry is not available)`.

- [ ] **Step 4: Implement the mappings**

`lib/claudio/telemetry.ex`:

```elixir
defmodule Claudio.Telemetry do
  @moduledoc false
  # Shared mappings for Claudio's :telemetry events (see guides/telemetry.md). Holds no state and
  # attaches no handlers.

  @token_keys [:input_tokens, :output_tokens, :cache_creation_input_tokens, :cache_read_input_tokens]
  @request_keys [:max_tokens, :temperature, :top_p, :top_k]

  @doc false
  # Token counts from a usage map (atom or string keys). Used as both measurements and metadata.
  @spec usage(term()) :: map()
  def usage(usage) when is_map(usage) do
    @token_keys
    |> Enum.reduce(%{}, fn key, acc -> put_present(acc, key, get(usage, key)) end)
    |> put_present(:thinking_tokens, thinking_tokens(usage))
  end

  def usage(_usage), do: %{}

  # usage.output_tokens_details is carried raw (atom or string keys).
  defp thinking_tokens(usage) do
    case get(usage, :output_tokens_details) do
      %{} = details -> get(details, :thinking_tokens)
      _ -> nil
    end
  end

  @doc false
  # A bounded error classification, safe to use as OTel `error.type`.
  @spec error_type(term()) :: atom() | String.t()
  def error_type(%Claudio.APIError{type: type}) when is_atom(type) or is_binary(type), do: type

  def error_type(%{__exception__: true, reason: reason})
      when is_atom(reason) and reason not in [nil, true, false],
      do: reason

  def error_type(%{__exception__: true, __struct__: module}), do: module
  def error_type(_other), do: :unknown

  @doc false
  @spec request_metadata(map()) :: map()
  def request_metadata(payload) when is_map(payload) do
    base = Enum.reduce(@request_keys, %{}, fn key, acc -> put_present(acc, key, get(payload, key)) end)

    effort =
      case get(payload, :output_config) do
        %{} = output_config -> get(output_config, :effort)
        _ -> nil
      end

    put_present(base, :effort, effort)
  end

  @doc false
  @spec server_address(Req.Request.t()) :: String.t() | nil
  def server_address(%Req.Request{options: options}) do
    case options[:base_url] do
      url when is_binary(url) -> URI.parse(url).host
      _ -> nil
    end
  end

  @doc false
  @spec request_id(Req.Response.t()) :: String.t() | nil
  def request_id(%Req.Response{} = response) do
    case Req.Response.get_header(response, "request-id") do
      [id | _] -> id
      [] -> nil
    end
  end

  @doc false
  @spec put_present(map(), atom(), term()) :: map()
  def put_present(map, _key, nil), do: map
  def put_present(map, key, value), do: Map.put(map, key, value)

  defp get(map, key), do: Map.get(map, key) || Map.get(map, Atom.to_string(key))
end
```

- [ ] **Step 5: Run to verify it passes**

Run: `mix test test/telemetry_test.exs`
Expected: PASS (10 tests).

- [ ] **Step 6: Replace both `usage_to_metadata/1` copies**

In `lib/claudio/messages.ex`, change `maybe_put_usage_metadata/2` to call the shared mapping and delete `usage_to_metadata/1` and `thinking_tokens/1`:

```elixir
  defp maybe_put_usage_metadata(metadata, {:ok, %Response{usage: usage}}) when is_map(usage) do
    Map.merge(metadata, Claudio.Telemetry.usage(usage))
  end
```

In `lib/claudio/messages/stream.ex`, replace the body of `maybe_emit_stream_usage_telemetry/1` and delete `usage_to_metadata/1`, `maybe_put_thinking_tokens/2` and `maybe_put_usage_key/2`:

```elixir
  defp maybe_emit_stream_usage_telemetry(usage) when is_map(usage) do
    metadata = Claudio.Telemetry.usage(usage)

    if map_size(metadata) > 0 do
      :telemetry.execute([:claudio, :messages, :stream, :usage], %{}, metadata)
    end
  end
```

(Task 2 rewrites `messages.ex`'s span code; this step only proves the shared mapping is a drop-in.)

- [ ] **Step 7: Run the full suite**

Run: `mix test && mix format --check-formatted && mix compile --warnings-as-errors`
Expected: all tests pass (the existing `:stop` / `:usage` token tests in `test/messages_test.exs` ~lines 380-600 and `test/messages/stream_test.exs` ~line 164 pin unchanged output); no warnings.

- [ ] **Step 8: Commit**

```bash
git add lib/claudio/telemetry.ex lib/claudio/messages.ex lib/claudio/messages/stream.ex test/telemetry_helper.exs test/telemetry_test.exs
git commit -m "refactor(telemetry): one Claudio.Telemetry module for usage, error and request mappings"
```

---

### Task 2: The `create` span — full metadata, measurements, legacy path, stream link

**Files:**
- Modify: `mix.exs:69` (`{:telemetry, "~> 1.3"}`), `lib/claudio/messages.ex` (`create_message/2` ~168-194, `create_streaming/2` ~239-262, `create_non_streaming/2` ~322-341, `enrich_stop_metadata/2` + `maybe_put_usage_metadata/2` ~343-359)
- Test: `test/messages_test.exs`

**Interfaces:**
- Consumes: `Claudio.Telemetry.usage/1`, `error_type/1`, `request_metadata/1`, `server_address/1`, `request_id/1`, `put_present/3`; `Claudio.TelemetryTestSupport.attach/2` (Task 1).
- Produces:
  - private `span(event :: [atom()], client :: Req.Request.t(), payload :: map(), extra_start :: map(), fun :: (reference() -> {result, measurements :: map(), stop_metadata :: map()})) :: result` — Task 3 reuses it.
  - private `ok_stop(result, resp :: Req.Response.t() | nil, usage :: map() | nil, metadata :: map())` and `error_stop({:error, reason}, resp :: Req.Response.t() | nil)`, both returning `{result, measurements, stop_metadata}` — Task 3 reuses them.
  - A streaming 200 from `create/2` / `create_message/2` returns a `%Req.Response{}` with `private.claudio == %{span_context: reference(), model: String.t() | nil, request_id: String.t() | nil}` — Task 5 reads it.

- [ ] **Step 1: Write the failing tests**

At the top of `test/messages_test.exs` add `Code.require_file("telemetry_helper.exs", __DIR__)` above `defmodule`, and `import Claudio.TelemetryTestSupport, only: [attach: 1, attach: 2]` inside the module. Append this `describe` block before the final `end`:

```elixir
  describe "create span (telemetry/OTel readiness)" do
    @create [[:claudio, :messages, :create, :start], [:claudio, :messages, :create, :stop],
             [:claudio, :messages, :create, :exception]]

    defp json_resp(conn, status, body) do
      conn
      |> Plug.Conn.put_resp_header("request-id", "req_test_1")
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(status, Jason.encode!(body))
    end

    defp message_body(extra \\ %{}) do
      Map.merge(
        %{
          "id" => "msg_span_1",
          "type" => "message",
          "role" => "assistant",
          "model" => "claude-span-model",
          "content" => [%{"type" => "text", "text" => "ok"}],
          "stop_reason" => "end_turn",
          "usage" => %{"input_tokens" => 11, "output_tokens" => 3}
        },
        extra
      )
    end

    defp span_request(model \\ "claude-span-model") do
      Request.new(model)
      |> Request.add_message(:user, "hi")
      |> Request.set_max_tokens(16)
      |> Request.set_temperature(0.5)
    end

    test "non-streaming start/stop carry request, response and token data", %{client: client, bypass: bypass} do
      attach(@create)
      Bypass.expect_once(bypass, "POST", "/messages", &json_resp(&1, 200, message_body()))

      assert {:ok, _} = Claudio.Messages.create(client, span_request())

      assert_receive {:telemetry, [:claudio, :messages, :create, :start], _, start}
      assert start.model == "claude-span-model"
      assert start.stream == false
      assert start.max_tokens == 16
      assert start.temperature == 0.5
      assert start.server_address == "localhost"
      assert is_reference(start.telemetry_span_context)

      assert_receive {:telemetry, [:claudio, :messages, :create, :stop], measurements, stop}
      assert stop.telemetry_span_context == start.telemetry_span_context
      assert stop.status == :ok
      assert stop.response_id == "msg_span_1"
      assert stop.response_model == "claude-span-model"
      assert stop.stop_reason == :end_turn
      assert stop.request_id == "req_test_1"
      assert stop.input_tokens == 11
      assert measurements.input_tokens == 11
      assert measurements.output_tokens == 3
      assert is_integer(measurements.duration)
    end

    test "response_model is the fallback model that served the request", %{client: client, bypass: bypass} do
      attach(@create)

      body =
        message_body(%{
          "model" => "claude-opus-5-5",
          "content" => [
            %{"type" => "fallback", "from" => %{"model" => "claude-opus-5-5"},
              "to" => %{"model" => "claude-opus-4-8"}, "trigger" => "refusal"},
            %{"type" => "text", "text" => "ok"}
          ]
        })

      Bypass.expect_once(bypass, "POST", "/messages", &json_resp(&1, 200, body))
      assert {:ok, _} = Claudio.Messages.create(client, span_request("claude-opus-5-5"))

      assert_receive {:telemetry, [:claudio, :messages, :create, :stop], _, stop}
      assert stop.model == "claude-opus-5-5"
      assert stop.response_model == "claude-opus-4-8"
    end

    test "an API error has a bounded error_type, status_code and request_id", %{client: client, bypass: bypass} do
      attach(@create)

      Bypass.expect_once(bypass, "POST", "/messages", fn conn ->
        json_resp(conn, 429, %{"type" => "error", "error" => %{"type" => "rate_limit_error", "message" => "slow down"}})
      end)

      assert {:error, %Claudio.APIError{}} = Claudio.Messages.create(client, span_request())

      assert_receive {:telemetry, [:claudio, :messages, :create, :stop], measurements, stop}
      assert stop.status == :error
      assert stop.error_type == :rate_limit_error
      assert stop.status_code == 429
      assert stop.request_id == "req_test_1"
      assert is_binary(stop.error)
      refute Map.has_key?(measurements, :input_tokens)
    end

    test "a transport error has its reason as error_type and a nil status_code", %{client: client, bypass: bypass} do
      attach(@create)
      Bypass.down(bypass)

      assert {:error, %Req.TransportError{}} = Claudio.Messages.create(client, span_request())

      assert_receive {:telemetry, [:claudio, :messages, :create, :stop], _, stop}
      assert stop.error_type == :econnrefused
      assert Map.has_key?(stop, :status_code)
      assert stop.status_code == nil
    end

    test "a raise inside the call emits :exception and reaches the caller", %{client: client} do
      attach(@create)
      payload = %{"model" => "m", "max_tokens" => 8, "messages" => [self()]}

      assert_raise Protocol.UndefinedError, fn -> Claudio.Messages.create(client, payload) end
      assert_receive {:telemetry, [:claudio, :messages, :create, :exception], _, meta}
      assert meta.model == "m"
      assert meta.kind == :error
    end

    test "streaming stop fires at headers and the response carries the span link", %{client: client, bypass: bypass} do
      attach(@create)

      Bypass.expect_once(bypass, "POST", "/messages", fn conn ->
        conn
        |> Plug.Conn.put_resp_header("request-id", "req_stream_1")
        |> Plug.Conn.put_resp_content_type("text/event-stream")
        |> Plug.Conn.resp(200, "event: ping\ndata: {}\n\n")
      end)

      assert {:ok, %Req.Response{} = resp} =
               Claudio.Messages.create(client, Request.enable_streaming(span_request()))

      assert_receive {:telemetry, [:claudio, :messages, :create, :stop], _, stop}
      assert stop.stream == true
      assert stop.status == :ok
      assert stop.request_id == "req_stream_1"
      refute Map.has_key?(stop, :input_tokens)

      assert resp.private.claudio == %{
               span_context: stop.telemetry_span_context,
               model: "claude-span-model",
               request_id: "req_stream_1"
             }
    end

    test "legacy create_message/2 emits the create span", %{client: client, bypass: bypass} do
      attach(@create)
      Bypass.expect_once(bypass, "POST", "/messages", &json_resp(&1, 200, message_body()))

      assert {:ok, %{"id" => "msg_span_1"}} =
               Claudio.Messages.create_message(client, %{
                 "model" => "claude-span-model",
                 "max_tokens" => 8,
                 "messages" => [%{"role" => "user", "content" => "hi"}]
               })

      assert_receive {:telemetry, [:claudio, :messages, :create, :stop], measurements, stop}
      assert stop.stream == false
      assert stop.response_id == "msg_span_1"
      assert stop.stop_reason == :end_turn
      assert measurements.input_tokens == 11
    end

    test "legacy create_message/2 with a non-object 200 body still returns it", %{client: client, bypass: bypass} do
      attach(@create)

      Bypass.expect_once(bypass, "POST", "/messages", fn conn ->
        conn |> Plug.Conn.put_resp_content_type("text/plain") |> Plug.Conn.resp(200, "plain text")
      end)

      assert {:ok, "plain text"} =
               Claudio.Messages.create_message(client, %{"model" => "m", "max_tokens" => 8, "messages" => []})

      assert_receive {:telemetry, [:claudio, :messages, :create, :stop], _, stop}
      assert stop.status == :ok
      refute Map.has_key?(stop, :response_id)
    end

    test "legacy streaming create_message/2 emits the create span", %{client: client, bypass: bypass} do
      attach(@create)

      Bypass.expect_once(bypass, "POST", "/messages", fn conn ->
        conn |> Plug.Conn.put_resp_content_type("text/event-stream") |> Plug.Conn.resp(200, "")
      end)

      assert {:ok, %Req.Response{}} =
               Claudio.Messages.create_message(client, %{
                 "model" => "m", "max_tokens" => 8, "stream" => true, "messages" => []
               })

      assert_receive {:telemetry, [:claudio, :messages, :create, :stop], _, %{stream: true, status: :ok}}
    end

    test "atom-keyed payload maps report model and request params", %{client: client, bypass: bypass} do
      attach(@create)
      Bypass.expect_once(bypass, "POST", "/messages", &json_resp(&1, 200, message_body()))

      assert {:ok, _} =
               Claudio.Messages.create(client, %{
                 model: "claude-atom", max_tokens: 9, messages: [%{role: "user", content: "hi"}]
               })

      assert_receive {:telemetry, [:claudio, :messages, :create, :start], _, start}
      assert start.model == "claude-atom"
      assert start.max_tokens == 9
    end
  end
```

- [ ] **Step 2: Run to verify the new tests fail**

Run: `mix test test/messages_test.exs --only describe:"create span (telemetry/OTel readiness)"`
Expected: the start-metadata, response-field, error_type, link and legacy tests FAIL (e.g. `key :max_tokens not found`); the `:exception` and atom-key `model` assertions may already pass — that is fine, they pin existing behaviour.

- [ ] **Step 3: Bump the telemetry requirement**

`mix.exs:69`: `{:telemetry, "~> 1.3"},` then run `mix deps.get` (lock already has 1.4.2; expect no lock change).

- [ ] **Step 4: Implement the span helper and route every create path through it**

In `lib/claudio/messages.ex`, add `alias Claudio.Telemetry` next to the existing aliases, then:

Replace both `create_message/2` clauses with:

```elixir
  def create_message(client, %{"stream" => true} = payload), do: create_streaming(client, payload)

  def create_message(client, payload) do
    span([:claudio, :messages, :create], client, payload, create_start(payload, false), fn _ctx ->
      case Req.post(client, url: "messages", json: payload) do
        {:ok, %Req.Response{status: 200, body: body} = resp} when is_map(body) ->
          # Convert atom keys to string keys for backward compatibility
          response = Response.from_map(body)
          ok_stop({:ok, atomize_keys_to_strings(body)}, resp, response.usage, response_fields(response))

        # A 200 whose body isn't a JSON object: returned exactly as before (Review Focus 2).
        {:ok, %Req.Response{status: 200, body: body} = resp} ->
          ok_stop({:ok, atomize_keys_to_strings(body)}, resp, nil, %{})

        {:ok, %Req.Response{status: status, body: body} = resp} ->
          error_stop({:error, APIError.from_response(status, body)}, resp)

        {:error, reason} ->
          error_stop({:error, reason}, nil)
      end
    end)
  end
```

(The streaming clause now *is* `create_streaming/2`: after PR #28 the two were identical. The old
non-streaming clause passed every 200 body through `atomize_keys_to_strings/1`, which has a
catch-all clause (`messages.ex:397`) and maps lists, so the second `200` clause keeps that exact
behaviour for a non-object body.)

Replace `create_streaming/2`:

```elixir
  defp create_streaming(client, payload) do
    span([:claudio, :messages, :create], client, payload, create_start(payload, true), fn ctx ->
      # Not retried: a retried async request would leave the failed attempt's body
      # messages in the caller's mailbox.
      case Req.post(client, url: "messages", json: payload, into: :self, retry: false) do
        {:ok, %Req.Response{status: 200} = resp} ->
          resp = link_stream(resp, ctx, payload)
          ok_stop({:ok, resp}, resp, nil, %{})

        {:ok, %Req.Response{status: status} = resp} ->
          # On non-200, Req with `into: :self` leaves the body as an async
          # reference — drain the mailbox into a decoded body so the error
          # message from Anthropic survives instead of being lost.
          error_stop({:error, APIError.from_response(status, drain_async_body(resp))}, resp)

        {:error, reason} ->
          error_stop({:error, reason}, nil)
      end
    end)
  end
```

Replace `create_non_streaming/2`:

```elixir
  defp create_non_streaming(client, payload) do
    span([:claudio, :messages, :create], client, payload, create_start(payload, false), fn _ctx ->
      case Req.post(client, url: "messages", json: payload) do
        {:ok, %Req.Response{status: 200, body: body} = resp} when is_map(body) ->
          response = Response.from_map(body)
          ok_stop({:ok, response}, resp, response.usage, response_fields(response))

        # Includes a 200 whose body isn't a JSON object (e.g. a proxy's text page).
        {:ok, %Req.Response{status: status, body: body} = resp} ->
          error_stop({:error, APIError.from_response(status, body)}, resp)

        {:error, reason} ->
          error_stop({:error, reason}, nil)
      end
    end)
  end
```

Replace `enrich_stop_metadata/2` and `maybe_put_usage_metadata/2` with:

```elixir
  # Runs `fun` inside a :telemetry span. Claudio generates the span context (telemetry keeps a
  # caller-supplied one) so a streaming response can carry it to Stream.parse_events/1.
  # `fun` returns {result, measurements, stop_metadata}; extra stop measurements need telemetry >= 1.3.
  defp span(event, client, payload, extra_start, fun) do
    ctx = make_ref()

    start_metadata =
      %{model: payload["model"] || payload[:model], telemetry_span_context: ctx}
      |> Map.merge(extra_start)
      |> Telemetry.put_present(:server_address, Telemetry.server_address(client))

    :telemetry.span(event, start_metadata, fn ->
      {result, measurements, stop_metadata} = fun.(ctx)
      {result, measurements, Map.merge(start_metadata, stop_metadata)}
    end)
  end

  defp create_start(payload, stream?) do
    Map.put(Telemetry.request_metadata(payload), :stream, stream?)
  end

  defp response_fields(%Response{} = response) do
    %{}
    |> Telemetry.put_present(:response_id, response.id)
    |> Telemetry.put_present(:response_model, Response.served_by(response))
    |> Telemetry.put_present(:stop_reason, response.stop_reason)
  end

  defp ok_stop(result, resp, usage, metadata) do
    tokens = Telemetry.usage(usage)

    metadata =
      metadata
      |> Map.merge(tokens)
      |> Map.put(:status, :ok)
      |> put_request_id(resp)

    {result, tokens, metadata}
  end

  defp error_stop({:error, reason} = result, resp) do
    metadata =
      %{
        status: :error,
        error: inspect(reason),
        error_type: Telemetry.error_type(reason),
        status_code: status_code(reason)
      }
      |> put_request_id(resp)

    {result, %{}, metadata}
  end

  defp status_code(%APIError{status_code: code}), do: code
  defp status_code(_reason), do: nil

  defp put_request_id(metadata, nil), do: metadata

  defp put_request_id(metadata, %Req.Response{} = resp),
    do: Telemetry.put_present(metadata, :request_id, Telemetry.request_id(resp))

  # The create span's link, read by Stream.parse_events/1 to emit a linked stream span.
  defp link_stream(resp, ctx, payload) do
    Req.Response.put_private(resp, :claudio, %{
      span_context: ctx,
      model: payload["model"] || payload[:model],
      request_id: Telemetry.request_id(resp)
    })
  end
```

- [ ] **Step 5: Run the new tests, then the whole file**

Run: `mix test test/messages_test.exs`
Expected: PASS — the new block and every pre-existing test (the pre-existing telemetry tests assert individual keys, so the added keys don't break them).

- [ ] **Step 6: Full suite, format, warnings, dialyzer**

Run: `mix test && mix format --check-formatted && mix compile --warnings-as-errors && mix dialyzer`
Expected: all green. If credo flags `create_message/2` complexity, extract the `case` into `legacy_result/2` rather than adding a disable comment.

- [ ] **Step 7: Commit**

```bash
git add mix.exs mix.lock lib/claudio/messages.ex test/messages_test.exs
git commit -m "feat(telemetry): complete create span — request/response metadata, token measurements, error_type, legacy path, stream link"
```

---

### Task 3: The `count_tokens` span

**Files:**
- Modify: `lib/claudio/messages.ex` (`count_tokens/2` map clause, ~224-235)
- Test: `test/messages_test.exs`

**Interfaces:**
- Consumes: `span/5`, `ok_stop/4`, `error_stop/2` (Task 2); `Claudio.TelemetryTestSupport.attach/2`.
- Produces: `[:claudio, :messages, :count_tokens, :start | :stop | :exception]`.

- [ ] **Step 1: Write the failing tests**

Append to `test/messages_test.exs` before the final `end` (the `json_resp/3` helper from Task 2 is a module-level `defp`, usable here):

```elixir
  describe "count_tokens span" do
    @count [[:claudio, :messages, :count_tokens, :start], [:claudio, :messages, :count_tokens, :stop]]

    test "success reports input_tokens as measurement and metadata", %{client: client, bypass: bypass} do
      attach(@count)
      Bypass.expect_once(bypass, "POST", "/messages/count_tokens", &json_resp(&1, 200, %{"input_tokens" => 42}))

      assert {:ok, %{"input_tokens" => 42}} =
               Claudio.Messages.count_tokens(client, %{"model" => "claude-count", "messages" => []})

      assert_receive {:telemetry, [:claudio, :messages, :count_tokens, :start], _, start}
      assert start.model == "claude-count"
      assert start.server_address == "localhost"
      refute Map.has_key?(start, :stream)

      assert_receive {:telemetry, [:claudio, :messages, :count_tokens, :stop], measurements, stop}
      assert stop.status == :ok
      assert stop.input_tokens == 42
      assert measurements.input_tokens == 42
      assert stop.request_id == "req_test_1"
    end

    test "an API error carries error_type and status_code", %{client: client, bypass: bypass} do
      attach(@count)

      Bypass.expect_once(bypass, "POST", "/messages/count_tokens", fn conn ->
        json_resp(conn, 400, %{"type" => "error", "error" => %{"type" => "invalid_request_error", "message" => "bad"}})
      end)

      assert {:error, %Claudio.APIError{}} =
               Claudio.Messages.count_tokens(client, %{"model" => "m", "messages" => []})

      assert_receive {:telemetry, [:claudio, :messages, :count_tokens, :stop], _, stop}
      assert stop.status == :error
      assert stop.error_type == :invalid_request_error
      assert stop.status_code == 400
    end
  end
```

- [ ] **Step 2: Run to verify they fail**

Run: `mix test test/messages_test.exs --only describe:"count_tokens span"`
Expected: FAIL — no `count_tokens` events received (`assert_receive` timeout).

- [ ] **Step 3: Implement**

Replace the body of the map clause of `count_tokens/2` after the `Map.drop/2` line:

```elixir
    span([:claudio, :messages, :count_tokens], client, payload, %{}, fn _ctx ->
      case Req.post(client, url: "messages/count_tokens", json: payload) do
        {:ok, %Req.Response{status: 200, body: body} = resp} ->
          tokens =
            case body do
              %{"input_tokens" => n} when is_integer(n) -> %{input_tokens: n}
              _ -> %{}
            end

          {{:ok, body}, tokens, tokens |> Map.put(:status, :ok) |> put_request_id(resp)}

        {:ok, %Req.Response{status: status, body: body} = resp} ->
          error_stop({:error, APIError.from_response(status, body)}, resp)

        {:error, reason} ->
          error_stop({:error, reason}, nil)
      end
    end)
```

- [ ] **Step 4: Run to verify they pass, then the full suite**

Run: `mix test test/messages_test.exs && mix test && mix format --check-formatted`
Expected: PASS; all green.

- [ ] **Step 5: Commit**

```bash
git add lib/claudio/messages.ex test/messages_test.exs
git commit -m "feat(telemetry): count_tokens span"
```

---

### Task 4: Per-attempt HTTP events

**Files:**
- Modify: `lib/claudio/telemetry.ex` (add `attach_http/1` and its steps), `lib/claudio/client.ex:213`
- Test: `test/telemetry_test.exs`

**Interfaces:**
- Consumes: `error_type/1`, `request_id/1`, `put_present/3` (Task 1).
- Produces: `Claudio.Telemetry.attach_http(Req.Request.t()) :: Req.Request.t()`; events `[:claudio, :http, :request, :start | :stop]` (no `:exception` — see spec amendment A1).

Facts this task rests on (verified 2026-10-01 against req 0.7.4):
- A Claudio client's request steps run `[:put_user_agent, :compressed, :encode_body, :put_base_url, :auth, :put_params, …]`; a step appended last sees the full URL.
- Response steps run `[:retry, :handle_http_errors, :redirect, …, :decode_body]`; error steps `[:retry]`.
- Req's retry re-runs every request step, then the adapter, with `:req_retry_count` incremented in `req.private` (`deps/req/lib/req/steps.ex:1807-1820`), *inside* the `:retry` step. So a prepended response/error step emits attempt *n*'s `:stop` before attempt *n+1*'s `:start`.

- [ ] **Step 1: Write the failing tests**

Append to `test/telemetry_test.exs` before the final `end` (add `import Claudio.TelemetryTestSupport, only: [attach: 1]` under `alias Claudio.Telemetry`):

```elixir
  describe "[:claudio, :http, :request] events" do
    @http [[:claudio, :http, :request, :start], [:claudio, :http, :request, :stop]]

    setup do
      {:ok, bypass: Bypass.open()}
    end

    defp http_client(bypass, extra \\ %{}) do
      Claudio.Client.new(
        Map.merge(%{token: "t", version: "2023-06-01"}, extra),
        "http://localhost:#{bypass.port}/"
      )
    end

    # The next n telemetry messages, in arrival order.
    defp collect(n) do
      for _ <- 1..n do
        assert_receive {:telemetry, event, measurements, metadata}
        {List.last(event), measurements, metadata}
      end
    end

    @tag capture_log: true
    test "one start/stop pair per attempt, each :stop before the next :start", %{bypass: bypass} do
      attach(@http)

      Bypass.expect(bypass, "POST", "/messages", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(503, ~s({"type":"error","error":{"type":"overloaded_error","message":"busy"}}))
      end)

      client = http_client(bypass, %{retry: [max_retries: 2, delay: 1]})

      assert {:error, %Claudio.APIError{status_code: 503}} =
               Claudio.Messages.create(client, %{"model" => "m", "max_tokens" => 8, "messages" => []})

      events = collect(6)

      assert Enum.map(events, fn {kind, _, meta} -> {kind, meta.attempt} end) ==
               [start: 0, stop: 0, start: 1, stop: 1, start: 2, stop: 2]

      for {:stop, measurements, meta} <- events do
        assert meta.status_code == 503
        assert meta.method == :post
        assert is_integer(measurements.duration)
      end

      refute_receive {:telemetry, _, _, _}, 50
    end

    test "each call starts at attempt 0", %{bypass: bypass} do
      attach(@http)
      Bypass.expect(bypass, "GET", "/models", &Plug.Conn.resp(&1, 200, ~s({"data":[]})))
      client = http_client(bypass)

      assert {:ok, _} = Claudio.Models.list(client)
      assert {:ok, _} = Claudio.Models.list(client)

      assert [{:start, _, %{attempt: 0}}, {:stop, _, _}, {:start, _, %{attempt: 0}}, {:stop, _, _}] =
               collect(4)
    end

    test "url drops the query string; non-Messages endpoints are covered", %{bypass: bypass} do
      attach(@http)

      Bypass.expect_once(bypass, "GET", "/models", fn conn ->
        conn |> Plug.Conn.put_resp_header("request-id", "req_models") |> Plug.Conn.resp(200, ~s({"data":[]}))
      end)

      assert {:ok, _} = Claudio.Models.list(http_client(bypass), limit: 5)

      assert [{:start, _, start}, {:stop, _, stop}] = collect(2)
      assert start.method == :get
      assert start.url == "http://localhost:#{bypass.port}/models"
      assert is_reference(start.telemetry_span_context)
      assert stop.telemetry_span_context == start.telemetry_span_context
      assert stop.status_code == 200
      assert stop.request_id == "req_models"
    end

    test "a transport error is a :stop with error_type and nil status_code", %{bypass: bypass} do
      attach(@http)
      Bypass.down(bypass)

      assert {:error, %Req.TransportError{}} = Claudio.Models.list(http_client(bypass, %{retry: false}))

      assert [{:start, _, _}, {:stop, _, stop}] = collect(2)
      assert stop.error_type == :econnrefused
      assert Map.has_key?(stop, :status_code)
      assert stop.status_code == nil
    end
  end
```

- [ ] **Step 2: Run to verify they fail**

Run: `mix test test/telemetry_test.exs --only describe:"[:claudio, :http, :request] events"`
Expected: FAIL — `assert_receive` timeouts (no http events yet).

- [ ] **Step 3: Implement the steps**

Add to `lib/claudio/telemetry.ex`:

```elixir
  @doc false
  # Per-attempt [:claudio, :http, :request] :start/:stop events. The request step is appended
  # (it runs right before the adapter, after :put_base_url); the response/error steps are
  # prepended so they run before Req's :retry step, which runs the next attempt inside itself.
  @spec attach_http(Req.Request.t()) :: Req.Request.t()
  def attach_http(%Req.Request{} = request) do
    request
    |> Req.Request.append_request_steps(claudio_telemetry: &http_start/1)
    |> Req.Request.prepend_response_steps(claudio_telemetry: &http_stop/1)
    |> Req.Request.prepend_error_steps(claudio_telemetry: &http_stop/1)
  end

  defp http_start(%Req.Request{} = request) do
    start = System.monotonic_time()

    metadata = %{
      method: request.method,
      url: URI.to_string(%{request.url | query: nil}),
      attempt: Req.Request.get_private(request, :req_retry_count, 0),
      telemetry_span_context: make_ref()
    }

    :telemetry.execute(
      [:claudio, :http, :request, :start],
      %{monotonic_time: start, system_time: System.system_time()},
      metadata
    )

    Req.Request.put_private(request, :claudio_http, {start, metadata})
  end

  defp http_stop({request, response_or_exception}) do
    case Req.Request.get_private(request, :claudio_http) do
      {start, metadata} ->
        stop = System.monotonic_time()

        :telemetry.execute(
          [:claudio, :http, :request, :stop],
          %{duration: stop - start, monotonic_time: stop},
          Map.merge(metadata, http_result(response_or_exception))
        )

      nil ->
        :ok
    end

    {request, response_or_exception}
  end

  defp http_result(%Req.Response{status: status} = response),
    do: put_present(%{status_code: status}, :request_id, request_id(response))

  defp http_result(exception), do: %{status_code: nil, error_type: error_type(exception)}
```

In `lib/claudio/client.ex:213` replace `Req.new(opts ++ req_retry_options(retry_opts))` with:

```elixir
    (opts ++ req_retry_options(retry_opts))
    |> Req.new()
    |> Claudio.Telemetry.attach_http()
```

- [ ] **Step 4: Run to verify they pass**

Run: `mix test test/telemetry_test.exs`
Expected: PASS. If the ordering test shows `[start: 0, start: 1, …]`, the prepend did not land before `:retry` — print `Keyword.keys(client.response_steps)` and fix the step placement; do not loosen the assertion.

- [ ] **Step 5: Full suite**

Run: `mix test && mix format --check-formatted && mix compile --warnings-as-errors`
Expected: all green. (Existing `client_test.exs` retry tests still pass: the steps return the response/exception unchanged.)

- [ ] **Step 6: Commit**

```bash
git add lib/claudio/telemetry.ex lib/claudio/client.ex test/telemetry_test.exs
git commit -m "feat(telemetry): per-attempt [:claudio, :http, :request] events for every endpoint"
```

---

### Task 5: The stream span, the linked `parse_events/1`, and the no-secrets test

**Files:**
- Modify: `lib/claudio/messages/stream.ex` (`parse_events/1` ~54-61; new private span stage), `lib/claudio/messages/response.ex:796` (`parse_stop_reason/1` → `@doc false def`)
- Test: `test/messages/stream_test.exs`, `test/telemetry_test.exs`

**Interfaces:**
- Consumes: `resp.private.claudio` = `%{span_context:, model:, request_id:}` (Task 2); `Claudio.Telemetry.usage/1`, `put_present/3` (Task 1); `Claudio.TelemetryTestSupport.attach/2`.
- Produces: `Claudio.Messages.Stream.parse_events(Req.Response.t() | Enumerable.t()) :: Enumerable.t()`; events `[:claudio, :messages, :stream, :start | :stop]`; `Claudio.Messages.Response.parse_stop_reason/1` (public, `@doc false`).

- [ ] **Step 1: Write the failing stream tests**

At the top of `test/messages/stream_test.exs` add `Code.require_file("../telemetry_helper.exs", __DIR__)`; inside the module add `import Claudio.TelemetryTestSupport, only: [attach: 1, attach: 2]`. Append before the final `end`:

```elixir
  describe "stream span" do
    @span [[:claudio, :messages, :stream, :start], [:claudio, :messages, :stream, :stop]]

    defp sse(frames) do
      Enum.map_join(frames, "", fn {event, data} -> "event: #{event}\ndata: #{Jason.encode!(data)}\n\n" end)
    end

    defp full_stream(model \\ "claude-stream") do
      sse([
        {"message_start", %{"type" => "message_start", "message" => %{"id" => "msg_s1", "model" => model, "content" => [], "usage" => %{"input_tokens" => 5, "output_tokens" => 1}}}},
        {"content_block_start", %{"type" => "content_block_start", "index" => 0, "content_block" => %{"type" => "text", "text" => ""}}},
        {"content_block_delta", %{"type" => "content_block_delta", "index" => 0, "delta" => %{"type" => "text_delta", "text" => "hi"}}},
        {"content_block_stop", %{"type" => "content_block_stop", "index" => 0}},
        {"message_delta", %{"type" => "message_delta", "delta" => %{"stop_reason" => "end_turn"}, "usage" => %{"output_tokens" => 9}}},
        {"message_stop", %{"type" => "message_stop"}}
      ])
    end

    defp stops do
      receive do
        {:telemetry, [:claudio, :messages, :stream, :stop], m, meta} -> [{m, meta} | stops()]
      after
        100 -> []
      end
    end

    test "a completed stream emits one start and one stop with tokens and duration" do
      attach(@span)
      [full_stream()] |> ClaudioStream.parse_events() |> Stream.run()

      assert_receive {:telemetry, [:claudio, :messages, :stream, :start], _, start}
      assert start.model == "claude-stream"
      assert start.response_id == "msg_s1"
      assert is_reference(start.telemetry_span_context)
      refute Map.has_key?(start, :parent_span_context)

      assert [{measurements, stop}] = stops()
      assert stop.reason == :completed
      assert stop.stop_reason == :end_turn
      assert stop.response_model == "claude-stream"
      assert stop.telemetry_span_context == start.telemetry_span_context
      assert stop.input_tokens == 5
      assert stop.output_tokens == 9
      assert measurements.output_tokens == 9
      assert is_integer(measurements.duration)
    end

    test "an SSE error event stops with reason :error and the API's error type" do
      attach(@span)

      body =
        sse([
          {"message_start", %{"type" => "message_start", "message" => %{"id" => "m", "model" => "x", "content" => []}}},
          {"error", %{"type" => "error", "error" => %{"type" => "overloaded_error", "message" => "busy"}}}
        ])

      [body] |> ClaudioStream.parse_events() |> Stream.run()
      assert [{_, %{reason: :error, error_type: "overloaded_error"}}] = stops()
    end

    test "a malformed data line stops with :parse_error" do
      attach(@span)
      ["event: message_start\ndata: {not json\n\n"] |> ClaudioStream.parse_events() |> Stream.run()
      assert [{_, %{reason: :error, error_type: :parse_error}}] = stops()
    end

    test "halting early emits :halted exactly once" do
      attach(@span)
      _ = [full_stream()] |> ClaudioStream.parse_events() |> Enum.take(2)
      assert [{_, %{reason: :halted}}] = stops()
    end

    test "a stream that ends without message_stop is :incomplete_stream, once" do
      attach(@span)

      truncated =
        sse([{"message_start", %{"type" => "message_start", "message" => %{"id" => "m", "model" => "x", "content" => []}}}])

      [truncated] |> ClaudioStream.parse_events() |> Stream.run()
      assert [{_, %{reason: :error, error_type: :incomplete_stream}}] = stops()
    end

    test "an empty body still emits a start/stop pair" do
      attach(@span)
      [] |> ClaudioStream.parse_events() |> Stream.run()
      assert_receive {:telemetry, [:claudio, :messages, :stream, :start], _, _}
      assert [{_, %{reason: :error, error_type: :incomplete_stream}}] = stops()
    end

    test "a mid-stream fallback block sets response_model" do
      attach(@span)

      body =
        sse([
          {"message_start", %{"type" => "message_start", "message" => %{"id" => "m", "model" => "claude-opus-5-5", "content" => []}}},
          {"content_block_start", %{"type" => "content_block_start", "index" => 0, "content_block" => %{"type" => "fallback", "from" => %{"model" => "claude-opus-5-5"}, "to" => %{"model" => "claude-opus-4-8"}}}},
          {"message_stop", %{"type" => "message_stop"}}
        ])

      [body] |> ClaudioStream.parse_events() |> Stream.run()
      assert [{_, %{response_model: "claude-opus-4-8", model: "claude-opus-5-5"}}] = stops()
    end

    test "enumerating twice gives two pairs; the :usage event is unchanged" do
      attach(@span ++ [[:claudio, :messages, :stream, :usage]])
      events = ClaudioStream.parse_events([full_stream()])
      Stream.run(events)
      Stream.run(events)

      assert length(stops()) == 2
      assert_received {:telemetry, [:claudio, :messages, :stream, :usage], %{}, %{input_tokens: 5, output_tokens: 9}}
    end

    test "a %Req.Response{} with a link emits a linked span; a binary body parses as one chunk" do
      attach(@span)
      ctx = make_ref()
      resp = %Req.Response{status: 200, body: full_stream(), private: %{claudio: %{span_context: ctx, model: "claude-stream", request_id: "req_link"}}}

      resp |> ClaudioStream.parse_events() |> Stream.run()

      assert_receive {:telemetry, [:claudio, :messages, :stream, :start], _, start}
      assert start.parent_span_context == ctx
      assert start.request_id == "req_link"
      assert [{_, %{reason: :completed, parent_span_context: ^ctx}}] = stops()
    end

    test "a stream consumed in another process emits from that process, still linked" do
      model = "claude-task-#{System.unique_integer([:positive])}"
      attach(@span, filter: &(&1[:model] == model))
      ctx = make_ref()
      resp = %Req.Response{status: 200, body: [full_stream(model)], private: %{claudio: %{span_context: ctx, model: model, request_id: nil}}}

      Task.async(fn -> resp |> ClaudioStream.parse_events() |> Stream.run() end) |> Task.await()

      assert_receive {:telemetry, [:claudio, :messages, :stream, :start], _, %{parent_span_context: ^ctx}}
      assert [{_, %{reason: :completed}}] = stops()
    end
  end
```

- [ ] **Step 2: Run to verify they fail**

Run: `mix test test/messages/stream_test.exs --only describe:"stream span"`
Expected: FAIL — no `stream :start` / `:stop` events; the `%Req.Response{}` test fails with `Protocol.UndefinedError` (`Enumerable not implemented for Req.Response`).

- [ ] **Step 3: Make `parse_stop_reason/1` callable**

In `lib/claudio/messages/response.ex:796-805`, change every `defp parse_stop_reason(` to `def parse_stop_reason(` and put `@doc false` above the first clause.

- [ ] **Step 4: Implement the span stage**

In `lib/claudio/messages/stream.ex`, add `alias Claudio.Messages.Response` and replace `parse_events/1`:

```elixir
  @spec parse_events(Req.Response.t() | Enumerable.t()) :: Enumerable.t()
  def parse_events(%Req.Response{body: body} = response) do
    # A non-async body (e.g. a Req.Test plug) is the whole SSE payload as one binary.
    body = if is_binary(body), do: [body], else: body
    do_parse_events(body, Req.Response.get_private(response, :claudio))
  end

  def parse_events(stream), do: do_parse_events(stream, nil)

  defp do_parse_events(stream, link) do
    stream
    |> Stream.transform(fn -> "" end, &parse_chunk/2, &flush_buffer/1, fn _ -> :ok end)
    |> Stream.map(&parse_event/1)
    |> emit_usage_telemetry()
    |> halt_after_message_stop()
    |> stream_span(link)
  end
```

Update the `parse_events` `@doc` example to `response |> Stream.parse_events()` and add one sentence: "Pass the whole `%Req.Response{}` from `Claudio.Messages.create/2` to link the stream span to the `create` span; passing `response.body` still works, unlinked."

Add the stage (below `halt_after_message_stop/1`):

```elixir
  # [:claudio, :messages, :stream] :start/:stop around one consumption. Exactly one :stop per
  # :start: on message_stop, an SSE error, a parse error, the upstream ending without
  # message_stop (last fun), or the consumer halting (after fun).
  defp stream_span(events, link) do
    Stream.transform(
      events,
      fn -> new_span(link) end,
      &span_event/2,
      fn span -> {[], finish_span(span, :error, :incomplete_stream)} end,
      fn span -> finish_span(span, :halted, nil) end
    )
  end

  defp new_span(link) do
    %{link: link, started?: false, stopped?: false, start_time: nil, metadata: %{}, usage: nil,
      stop_reason: nil, fallback_model: nil}
  end

  defp span_event({:ok, %{event: "message_start", data: %{"message" => %{} = message}}} = event, %{started?: false} = span) do
    span = start_span(span, message["model"], message["id"])
    {[event], %{span | usage: merge_usage(nil, message["usage"])}}
  end

  defp span_event({:ok, %{event: "message_delta", data: %{} = data}} = event, span) do
    stop_reason =
      case data do
        %{"delta" => %{"stop_reason" => reason}} when is_binary(reason) -> reason
        _ -> span.stop_reason
      end

    {[event], %{span | usage: merge_usage(span.usage, data["usage"]), stop_reason: stop_reason}}
  end

  defp span_event({:ok, %{event: "content_block_start", data: %{"content_block" => %{"type" => "fallback", "to" => %{"model" => model}}}}} = event, span)
       when is_binary(model),
       do: {[event], %{span | fallback_model: model}}

  defp span_event({:ok, %{event: "message_stop"}} = event, span),
    do: {[event], finish_span(span, :completed, nil)}

  defp span_event({:ok, %{event: "error", data: data}} = event, span) do
    error_type =
      case data do
        %{"error" => %{"type" => type}} when is_binary(type) -> type
        _ -> :stream_error
      end

    {[event], finish_span(span, :error, error_type)}
  end

  defp span_event({:error, _reason} = event, span), do: {[event], finish_span(span, :error, :parse_error)}
  defp span_event(event, span), do: {[event], span}

  defp start_span(span, model, response_id) do
    now = System.monotonic_time()
    link_model = if span.link, do: span.link[:model]

    metadata =
      %{telemetry_span_context: make_ref()}
      |> Claudio.Telemetry.put_present(:model, model || link_model)
      |> Claudio.Telemetry.put_present(:response_id, response_id)
      |> put_link(span.link)

    :telemetry.execute(
      [:claudio, :messages, :stream, :start],
      %{monotonic_time: now, system_time: System.system_time()},
      metadata
    )

    %{span | started?: true, start_time: now, metadata: metadata}
  end

  defp put_link(metadata, %{span_context: ctx} = link) do
    metadata
    |> Map.put(:parent_span_context, ctx)
    |> Claudio.Telemetry.put_present(:request_id, link[:request_id])
  end

  defp put_link(metadata, _link), do: metadata

  defp finish_span(%{stopped?: true} = span, _reason, _error_type), do: span

  defp finish_span(%{started?: false} = span, reason, error_type),
    do: span |> start_span(nil, nil) |> finish_span(reason, error_type)

  defp finish_span(span, reason, error_type) do
    now = System.monotonic_time()
    tokens = Claudio.Telemetry.usage(span.usage)

    metadata =
      span.metadata
      |> Map.merge(tokens)
      |> Map.put(:reason, reason)
      |> Claudio.Telemetry.put_present(:stop_reason, Response.parse_stop_reason(span.stop_reason))
      |> Claudio.Telemetry.put_present(:response_model, span.fallback_model || span.metadata[:model])
      |> Claudio.Telemetry.put_present(:error_type, error_type)

    :telemetry.execute(
      [:claudio, :messages, :stream, :stop],
      Map.merge(tokens, %{duration: now - span.start_time, monotonic_time: now}),
      metadata
    )

    %{span | stopped?: true}
  end
```

- [ ] **Step 5: Run to verify they pass**

Run: `mix test test/messages/stream_test.exs`
Expected: PASS, including every pre-existing stream test. The "exactly once" assertions (`assert [{_, _}] = stops()`) check that `Stream.transform/5` hands the accumulator returned by the last fun to the after fun. If the truncated-stream test sees **two** stops, it doesn't. In that case track `stopped?` in the process dictionary keyed by the span's `telemetry_span_context` — and report it in the task summary; don't silently change the design.

- [ ] **Step 6: Write the no-secrets test**

Append to `test/telemetry_test.exs` before the final `end`:

```elixir
  test "no event carries the API key", %{} do
    bypass = Bypass.open()
    secret = "sk-test-SECRET-#{System.unique_integer([:positive])}"

    events =
      for prefix <- [[:claudio, :messages, :create], [:claudio, :messages, :count_tokens],
                     [:claudio, :http, :request], [:claudio, :messages, :stream]],
          suffix <- [:start, :stop, :exception],
          do: prefix ++ [suffix]

    attach(events)

    Bypass.expect(bypass, "POST", "/messages", fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(200, ~s({"id":"m","type":"message","role":"assistant","model":"x","content":[],"stop_reason":"end_turn","usage":{"input_tokens":1,"output_tokens":1}}))
    end)

    Bypass.expect(bypass, "POST", "/messages/count_tokens", &Plug.Conn.resp(&1, 200, ~s({"input_tokens":1})))
    Bypass.expect(bypass, "GET", "/models", &Plug.Conn.resp(&1, 200, ~s({"data":[]})))

    client = Claudio.Client.new(%{token: secret, version: "2023-06-01"}, "http://localhost:#{bypass.port}/")
    payload = %{"model" => "x", "max_tokens" => 8, "messages" => [%{"role" => "user", "content" => "hi"}]}

    assert {:ok, _} = Claudio.Messages.create(client, payload)
    assert {:ok, _} = Claudio.Messages.count_tokens(client, payload)
    assert {:ok, _} = Claudio.Models.list(client)

    received = Stream.repeatedly(fn -> receive do msg -> msg after 50 -> :done end end) |> Enum.take_while(&(&1 != :done))
    assert length(received) >= 8

    for {:telemetry, event, measurements, metadata} <- received do
      refute inspect({measurements, metadata}, limit: :infinity, printable_limit: :infinity) =~ secret,
             "#{inspect(event)} leaked the API key"
    end
  end
```

Run: `mix test test/telemetry_test.exs`
Expected: PASS (it fails only if a future change puts headers into metadata — that's its job).

- [ ] **Step 7: Full suite and dialyzer**

Run: `mix test && mix format --check-formatted && mix compile --warnings-as-errors && mix credo --strict && mix dialyzer`
Expected: all green. If credo flags `span_event/2` arity-clause count or nesting, split the `case` blocks into named private functions (`delta_stop_reason/2`, `sse_error_type/1`); no disable comments.

- [ ] **Step 8: Commit**

```bash
git add lib/claudio/messages/stream.ex lib/claudio/messages/response.ex test/messages/stream_test.exs test/telemetry_test.exs
git commit -m "feat(telemetry): stream span with exactly-one stop, linked parse_events/1, no-secrets test"
```

---

### Task 6: Guide, README, `@doc`s, CHANGELOG, CLAUDE.md

**Files:**
- Create: `guides/telemetry.md`
- Modify: `mix.exs:101` (extras), `README.md` (telemetry section ~442-466; streaming example ~137), `lib/claudio.ex:74`, `lib/claudio/messages.ex` (moduledoc ~48, `@doc` of `create/2`, `create_message/2`, `count_tokens/2`), `lib/claudio/messages/stream.ex` (moduledoc lines 1-30), `lib/claudio/client.ex` (`new/2` `@doc`), `CHANGELOG.md`, `CLAUDE.md`

**Interfaces:**
- Consumes: every event and key from Tasks 2-5, exactly as implemented. Before writing, print them from the code (`grep -n ":telemetry.execute\|:telemetry.span\|put_present(" lib/claudio/telemetry.ex lib/claudio/messages.ex lib/claudio/messages/stream.ex`) and make the guide's tables match; the spec's "Event contract" plus amendments A1-A3 is the reference.

- [ ] **Step 1: Write `guides/telemetry.md`**

Content, in this order:

1. **Intro** (3 sentences): Claudio emits `:telemetry` events; no OpenTelemetry dependency; this guide lists every event and shows an OTel bridge.
2. **Events** — the catalogue table and the four per-event tables from the spec's "Event contract", with A1 applied (no `http :exception`) and A2/A3 applied (`:incomplete_stream`; legacy `response_model` via `served_by/1`), plus the `error_type` table. State the guarantees: one `stream :stop` per `:start` (except when the consuming process dies); no headers, bodies, API key or message content in any event.
3. **Streaming** — `create` measures request → headers; `stream` measures the whole consumption and carries tokens; pass the whole response to link them:

   ```elixir
   {:ok, resp} = Claudio.Messages.create(client, Request.enable_streaming(request))
   resp |> Claudio.Messages.Stream.parse_events() |> Claudio.Messages.Stream.accumulate_text()
   ```

4. **Retries** — each attempt is an `[:claudio, :http, :request]` start/stop pair with `attempt` 0, 1, …; the non-streaming `create` span's `duration` includes retries and backoff.
5. **Metrics example** (`Telemetry.Metrics`):

   ```elixir
   [
     Telemetry.Metrics.summary("claudio.messages.create.stop.duration", unit: {:native, :millisecond}, tags: [:model, :status]),
     Telemetry.Metrics.sum("claudio.messages.create.stop.input_tokens", tags: [:response_model]),
     Telemetry.Metrics.sum("claudio.messages.stream.stop.output_tokens", tags: [:response_model]),
     Telemetry.Metrics.counter("claudio.http.request.stop.duration", tags: [:status_code])
   ]
   ```

6. **OpenTelemetry** — note: GenAI semantic conventions are *Development* status; write the date you fetched the page into the guide ("names checked on YYYY-MM-DD against `github.com/open-telemetry/semantic-conventions-genai` `docs/gen-ai/anthropic.md`") — **re-fetch that page and confirm each attribute name before writing**. Then the handler:

   ```elixir
   defmodule MyApp.ClaudioOtel do
     @moduledoc "Bridges Claudio telemetry to OpenTelemetry GenAI spans."
     require OpenTelemetry.Tracer, as: Tracer

     @tracer_id __MODULE__
     @events for kind <- [:create, :stream], phase <- [:start, :stop, :exception],
                 not (kind == :stream and phase == :exception),
                 do: [:claudio, :messages, kind, phase]

     def setup, do: :telemetry.attach_many("my-app-claudio-otel", @events, &__MODULE__.handle_event/4, nil)

     # Streaming calls are traced from the stream events (full duration and tokens), so skip
     # their create span, which ends when the headers arrive.
     def handle_event([:claudio, :messages, :create, _phase], _measurements, %{stream: true}, _config), do: :ok

     def handle_event([:claudio, :messages, _kind, :start], _measurements, meta, _config) do
       OpentelemetryTelemetry.start_telemetry_span(@tracer_id, "chat #{meta[:model]}", meta, %{
         kind: :client,
         attributes: start_attributes(meta)
       })
     end

     def handle_event([:claudio, :messages, _kind, :stop], _measurements, meta, _config) do
       OpentelemetryTelemetry.set_current_telemetry_span(@tracer_id, meta)
       Tracer.set_attributes(stop_attributes(meta))
       if meta[:error_type], do: Tracer.set_status(OpenTelemetry.status(:error, to_string(meta.error_type)))
       OpentelemetryTelemetry.end_telemetry_span(@tracer_id, meta)
     end

     def handle_event([:claudio, :messages, :create, :exception], _measurements, meta, _config) do
       ctx = OpentelemetryTelemetry.set_current_telemetry_span(@tracer_id, meta)
       OpenTelemetry.Span.record_exception(ctx, meta.reason, meta.stacktrace, [])
       Tracer.set_status(OpenTelemetry.status(:error, inspect(meta.kind)))
       OpentelemetryTelemetry.end_telemetry_span(@tracer_id, meta)
     end

     defp start_attributes(meta) do
       compact(%{
         "gen_ai.operation.name" => "chat",
         "gen_ai.provider.name" => "anthropic",
         "gen_ai.request.model" => meta[:model],
         "gen_ai.request.max_tokens" => meta[:max_tokens],
         "gen_ai.request.temperature" => meta[:temperature],
         "gen_ai.request.top_p" => meta[:top_p],
         "gen_ai.request.top_k" => meta[:top_k],
         "server.address" => meta[:server_address]
       })
     end

     defp stop_attributes(meta) do
       # gen_ai.usage.input_tokens must include cached tokens.
       input =
         meta[:input_tokens] &&
           meta.input_tokens + (meta[:cache_read_input_tokens] || 0) + (meta[:cache_creation_input_tokens] || 0)

       compact(%{
         "gen_ai.response.id" => meta[:response_id],
         "gen_ai.response.model" => meta[:response_model],
         "gen_ai.response.finish_reasons" => meta[:stop_reason] && [to_string(meta.stop_reason)],
         "gen_ai.usage.input_tokens" => input,
         "gen_ai.usage.output_tokens" => meta[:output_tokens],
         "gen_ai.usage.cache_read.input_tokens" => meta[:cache_read_input_tokens],
         "gen_ai.usage.cache_write.input_tokens" => meta[:cache_creation_input_tokens],
         "gen_ai.usage.reasoning.output_tokens" => meta[:thinking_tokens],
         "error.type" => meta[:error_type] && to_string(meta.error_type)
       })
     end

     defp compact(map), do: map |> Enum.reject(fn {_k, v} -> is_nil(v) end) |> Map.new()
   end
   ```

   Follow it with: HTTP client spans come from `OpentelemetryReq.attach(client, propagate_trace_headers: true)` on the client returned by `Claudio.Client.new/2`; Claudio's `[:claudio, :http, :request]` events are for metrics and logs. Note that Finch's streaming path (`into: :self`) runs the request in a linked process, so check that HTTP spans and trace headers appear for streaming calls in your setup.

- [ ] **Step 2: Verify the OTel example compiles**

The repo has no OTel deps (spec non-goal), so compile it in a scratch project:

```bash
S=$(mktemp -d) && cd "$S" && mix new otel_check >/dev/null && cd otel_check
# deps: {:opentelemetry_api, ">= 0.0.0"}, {:opentelemetry_telemetry, ">= 0.0.0"}, {:telemetry, "~> 1.3"}
# paste the MyApp.ClaudioOtel module into lib/otel_check.ex, then:
mix deps.get && mix compile --warnings-as-errors
```

Expected: compiles with no warnings. If an `OpentelemetryTelemetry` or `OpenTelemetry.Span` function signature differs, fix the guide to match the installed versions and name those versions in the guide.

- [ ] **Step 3: Wire the guide into ExDoc and fix examples**

- `mix.exs:101`: add `"guides/telemetry.md"` to `extras` after `"guides/GETTING_STARTED.md"`.
- `README.md` telemetry section (~442-466): replace with one paragraph naming the five event prefixes, a 10-line Logger handler on `[:claudio, :messages, :create, :stop]` that logs `model`, `response_model`, `status` and duration (no token counts — they are absent for streams), and a link: `See [the telemetry guide](guides/telemetry.md) for every event, metadata key and an OpenTelemetry example.`
- `README.md:137`, `lib/claudio.ex:74`, `lib/claudio/messages.ex:48` (moduledoc), and the `Stream` moduledoc example: change `response.body |> Stream.parse_events()` / `stream_response.body |> ...` to pass the response itself.
- `Stream` moduledoc lines 5-8: replace the usage-telemetry paragraph with: "`parse_events/1` emits `[:claudio, :messages, :stream, :start | :stop]` around each consumption (and the older `[:claudio, :messages, :stream, :usage]`); see the telemetry guide."
- `@doc` of `create/2`, `create_message/2`, `count_tokens/2`, `Client.new/2`: one sentence each naming the events emitted, ending "See the telemetry guide."

- [ ] **Step 4: CHANGELOG and CLAUDE.md**

Under `## [Unreleased]`:

`### Added`:
```markdown
- **Telemetry for OpenTelemetry/GenAI dashboards** (see `guides/telemetry.md`):
  `[:claudio, :messages, :create]` gains request params (`max_tokens`, `temperature`, `top_p`,
  `top_k`, `effort`), `server_address`, response fields (`response_id`, `response_model` — the
  fallback model when one served — `stop_reason`, `request_id`), a bounded `error_type` and
  `status_code`, and token counts as **measurements** (still also metadata).
  New `[:claudio, :messages, :count_tokens]` span; new `[:claudio, :messages, :stream, :start | :stop]`
  around each stream consumption (full duration, tokens, exactly one `:stop`), linked to the
  `create` span when `parse_events/1` is given the whole response; new per-attempt
  `[:claudio, :http, :request, :start | :stop]` for every endpoint (retries visible as `attempt`).
  No event carries headers, bodies, the API key or message content.
```

`### Changed`:
```markdown
- Legacy `Claudio.Messages.create_message/2` now emits the `[:claudio, :messages, :create]` span.
- `Claudio.Messages.Stream.parse_events/1` also accepts the whole `%Req.Response{}`.
- **The `:telemetry` requirement is now `~> 1.3`** (was `~> 1.0`): span stop measurements need
  1.3. Applications locked to an older `:telemetry` will be asked to update it.
```

At the 0.2.0 line (`CHANGELOG.md:432` before your edits — find it with `grep -n "claudio, :request" CHANGELOG.md`), append on the next line, indented as a sub-bullet:
```markdown
    - *Correction (2026-10-01):* `[:claudio, :request, ...]` never shipped; 0.2.0 emitted
      `[:claudio, :messages, :create]`. See the telemetry guide for the current events.
```

`CLAUDE.md`: under "### Error Handling", add a "### Telemetry (lib/claudio/telemetry.ex)" subsection listing the five event prefixes in one line each and "Mappings live in the private `Claudio.Telemetry`; the contract is `guides/telemetry.md`."

- [ ] **Step 5: Full verification**

Run: `mix precommit && mix docs --warnings-as-errors`
Expected: exit 0 for both; `doc/telemetry.html` exists.

- [ ] **Step 6: Commit**

```bash
git add guides/telemetry.md mix.exs README.md lib/claudio.ex lib/claudio/messages.ex lib/claudio/messages/stream.ex lib/claudio/client.ex CHANGELOG.md CLAUDE.md
git commit -m "docs(telemetry): telemetry guide with OTel GenAI example; README, docs and CHANGELOG"
```
