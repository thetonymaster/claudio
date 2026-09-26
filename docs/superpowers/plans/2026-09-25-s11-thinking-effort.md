# S11 Thinking & Effort Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Typed request helpers for adaptive thinking / effort / task budgets, `usage.output_tokens_details` parsing + `:thinking_tokens` telemetry, and thinking-text readers (non-streaming + streaming).

**Architecture:** Additive functions on `Claudio.Messages.Request` (thinking helpers replace `thinking`; output-config helpers merge into `output_config` through one private `put_output_config/3`), one extra key in `Response.parse_usage/1`, a flat `:thinking_tokens` key in both usage-telemetry emitters, and three reader functions (`Response.get_thinking/1`, `Response.thinking_interrupted?/1`, `Stream.accumulate_thinking/1`). No per-model validation.

**Tech Stack:** Elixir ≥ 1.15, ExUnit (async), Bypass + Plug for HTTP tests, Jason, `:telemetry`.

**Spec:** `docs/superpowers/specs/2026-09-25-s11-thinking-effort-design.md`

## Global Constraints

- Library stays **model-agnostic**: helpers validate only values the API rejects on every model; never check model support.
- Enumerated values are **atoms only**; invalid values raise `ArgumentError` naming the function, the allowed values and `inspect/1` of the value received. Option keys are checked with `Keyword.validate!/2`.
- Beta strings, verbatim: `thinking-display-updates-2026-08-18` (only for `display: :updates`), `task-budgets-2026-03-13` (every `set_task_budget/3`). Effort is GA — no beta.
- No local 20,000-token floor on `task_budget.total`; `total` positive integer, `:remaining` non-negative integer.
- Existing public signatures unchanged: `enable_thinking/2`, `set_output_config/2` (still replaces the whole map), `set_output_format/2`.
- No `@version` bump; CHANGELOG entries go under `## [Unreleased] — targets 0.7.0`.
- Interrupted-update placeholder, verbatim: `This part of the response was interrupted before it finished.`
- Commits: add files individually (`git add .` forbidden); **no AI attribution lines** in commit messages.
- Gates before each commit: run `mix format` (the plan's code blocks are not pre-formatted) and `mix compile --warnings-as-errors` clean; Task 7 ends with the strict `mix format --check-formatted`.

## Review Focus

1. A **streamed** response (`Stream.build_final_message/1` → `Response.from_map/1`) must carry `usage.output_tokens_details` end-to-end — pinned in Task 3.
2. A `thinking` block with **no `thinking` key** (or `nil` text) must be skipped by `get_thinking/1`, not crash — pinned in Task 5.
3. `{:error, _}` items in the event stream must pass through `accumulate_thinking/1` as nothing, not crash — pinned in Task 6.
4. Calling `set_task_budget/3` **twice** replaces the budget and declares the beta once — pinned in Task 2.
5. Re-calling `enable_adaptive_thinking/2` without `:display` after `display: :updates` replaces `thinking` (no stale `"display"`) while the beta stays declared (append-only, documented) — pinned in Task 1.

## Branching

Implementation branch `feat/s11-thinking-effort`, cut from `docs/s11-thinking-effort-spec` (which holds the spec + this plan).

---

### Task 1: Thinking helpers — `enable_adaptive_thinking/2`, `disable_thinking/1`

**Files:**
- Modify: `lib/claudio/messages/request.ex` (the `enable_thinking/2` doc at ~488-503; new functions directly after it)
- Test: `test/request_test.exs` (new `describe` blocks at the end of the module)

**Interfaces:**
- Consumes: existing `Request.add_beta/2`, `Request.required_betas/1`, `Request.to_map/1`.
- Produces: `Request.enable_adaptive_thinking(t(), keyword()) :: t()`, `Request.disable_thinking(t()) :: t()`.

- [ ] **Step 1: Write the failing tests** — append inside `Claudio.Messages.RequestTest`, before the final `end`:

```elixir
  describe "enable_adaptive_thinking/2" do
    test "no opts emits type adaptive only, no betas" do
      request = Request.new("claude-opus-5-5") |> Request.enable_adaptive_thinking()

      assert Request.to_map(request)["thinking"] == %{"type" => "adaptive"}
      assert Request.required_betas(request) == []
    end

    test "each display value is emitted as a string" do
      for display <- [:summarized, :omitted, :updates] do
        request =
          Request.new("claude-opus-5-5") |> Request.enable_adaptive_thinking(display: display)

        assert Request.to_map(request)["thinking"] == %{
                 "type" => "adaptive",
                 "display" => Atom.to_string(display)
               }
      end
    end

    test "only display: :updates declares the updates beta, once" do
      updates =
        Request.new("claude-opus-5-5")
        |> Request.enable_adaptive_thinking(display: :updates)
        |> Request.enable_adaptive_thinking(display: :updates)

      assert Request.required_betas(updates) == ["thinking-display-updates-2026-08-18"]

      omitted =
        Request.new("claude-opus-5-5") |> Request.enable_adaptive_thinking(display: :omitted)

      assert Request.required_betas(omitted) == []
    end

    test "re-calling without display replaces thinking; the beta stays declared" do
      request =
        Request.new("claude-opus-5-5")
        |> Request.enable_adaptive_thinking(display: :updates)
        |> Request.enable_adaptive_thinking()

      assert Request.to_map(request)["thinking"] == %{"type" => "adaptive"}
      assert Request.required_betas(request) == ["thinking-display-updates-2026-08-18"]
    end

    test "unknown display values raise" do
      for bad <- [:full, "omitted", nil] do
        assert_raise ArgumentError,
                     ~r/enable_adaptive_thinking\/2 :display must be one of :summarized, :omitted, :updates; got/,
                     fn ->
                       Request.new("claude-opus-5-5")
                       |> Request.enable_adaptive_thinking(display: bad)
                     end
      end
    end

    test "unknown option keys raise" do
      assert_raise ArgumentError, fn ->
        Request.new("claude-opus-5-5") |> Request.enable_adaptive_thinking(budget_tokens: 1024)
      end
    end
  end

  describe "disable_thinking/1" do
    test "emits type disabled" do
      request = Request.new("claude-opus-5") |> Request.disable_thinking()
      assert Request.to_map(request)["thinking"] == %{"type" => "disabled"}
    end

    test "replaces a prior adaptive config (no display survives)" do
      request =
        Request.new("claude-opus-5")
        |> Request.enable_adaptive_thinking(display: :summarized)
        |> Request.disable_thinking()

      assert Request.to_map(request)["thinking"] == %{"type" => "disabled"}
    end
  end
```

- [ ] **Step 2: Run to verify they fail**

Run: `mix test test/request_test.exs 2>&1 | tail -20`
Expected: FAIL — `UndefinedFunctionError` / "function Claudio.Messages.Request.enable_adaptive_thinking/1 is undefined" (and `disable_thinking/1`).

- [ ] **Step 3: Implement** — in `lib/claudio/messages/request.ex`, replace the last paragraph of the `enable_thinking/2` `@doc`

```
  `%{"type" => "enabled", "budget_tokens" => n}` returns 400 on Claude Opus 4.7+,
  Opus 5.x, Sonnet 5 and Fable models; use `"adaptive"` there. Dedicated
  thinking/effort helpers are planned (roadmap S11).
```

with

```
  `%{"type" => "enabled", "budget_tokens" => n}` returns 400 on Claude Opus 4.7+,
  Opus 5.x, Sonnet 5 and Fable models; use `"adaptive"` there. This is the raw
  setter (replaces `thinking`); prefer `enable_adaptive_thinking/2` /
  `disable_thinking/1`, and `set_effort/2` to steer how much the model thinks.
```

then add directly after the `enable_thinking/2` function body:

```elixir
  @thinking_displays [:summarized, :omitted, :updates]
  @thinking_display_updates_beta "thinking-display-updates-2026-08-18"

  @doc """
  Enables adaptive thinking (`thinking: %{"type" => "adaptive"}`), replacing any
  previous `thinking` config. The model decides how much to think; steer it with
  `set_effort/2`.

  ## Options

  - `:display` — `:summarized`, `:omitted` or `:updates`. Omit it to use the
    model's default. `:updates` (progress notes as separate `thinking` blocks)
    also declares the `thinking-display-updates-2026-08-18` beta. A beta declared
    here stays declared if `thinking` is later replaced.

  ## Example

      Request.new("claude-opus-5-5")
      |> Request.enable_adaptive_thinking(display: :summarized)
      |> Request.set_effort(:high)
  """
  @spec enable_adaptive_thinking(t(), keyword()) :: t()
  def enable_adaptive_thinking(%__MODULE__{} = request, opts \\ []) when is_list(opts) do
    opts = Keyword.validate!(opts, [:display])

    case Keyword.fetch(opts, :display) do
      :error ->
        %{request | thinking: %{"type" => "adaptive"}}

      {:ok, display} when display in @thinking_displays ->
        thinking = %{"type" => "adaptive", "display" => Atom.to_string(display)}
        request = %{request | thinking: thinking}

        if display == :updates,
          do: add_beta(request, @thinking_display_updates_beta),
          else: request

      {:ok, other} ->
        raise ArgumentError,
              "Request.enable_adaptive_thinking/2 :display must be one of " <>
                ":summarized, :omitted, :updates; got #{inspect(other)}"
    end
  end

  @doc """
  Turns thinking off (`thinking: %{"type" => "disabled"}`), replacing any previous
  `thinking` config. Models that always think reject this with a 400.
  """
  @spec disable_thinking(t()) :: t()
  def disable_thinking(%__MODULE__{} = request) do
    %{request | thinking: %{"type" => "disabled"}}
  end
```

- [ ] **Step 4: Run to verify they pass**

Run: `mix test test/request_test.exs 2>&1 | tail -5`
Expected: PASS — `0 failures`.

- [ ] **Step 5: Gates + commit**

```bash
mix format && mix compile --warnings-as-errors   # plan code is not pre-formatted; formatter owns layout
git add lib/claudio/messages/request.ex
git add test/request_test.exs
git commit -m "feat(request): enable_adaptive_thinking/2 and disable_thinking/1"
```

---

### Task 2: Output-config helpers — `set_effort/2`, `set_task_budget/3`

**Files:**
- Modify: `lib/claudio/messages/request.ex` (`set_output_config/2` doc + `set_output_format/2` body at ~665-705; new functions directly after `set_output_format/2`)
- Test: `test/request_test.exs`

**Interfaces:**
- Consumes: `Request.add_beta/2`, `Request.set_output_format/2`, `Request.set_output_config/2`.
- Produces: `Request.set_effort(t(), :low | :medium | :high | :xhigh | :max) :: t()`, `Request.set_task_budget(t(), pos_integer(), keyword()) :: t()`, private `put_output_config(t(), String.t(), term()) :: t()`.

- [ ] **Step 1: Write the failing tests** — append inside `Claudio.Messages.RequestTest`:

```elixir
  describe "set_effort/2" do
    test "each level is emitted as a string under output_config.effort, no beta" do
      for level <- [:low, :medium, :high, :xhigh, :max] do
        request = Request.new("claude-opus-5-5") |> Request.set_effort(level)

        assert Request.to_map(request)["output_config"] == %{"effort" => Atom.to_string(level)}
        assert Request.required_betas(request) == []
      end
    end

    test "unknown levels raise" do
      for bad <- [:ultra, "high", nil] do
        assert_raise ArgumentError,
                     ~r/set_effort\/2 level must be one of :low, :medium, :high, :xhigh, :max; got/,
                     fn -> Request.new("claude-opus-5-5") |> Request.set_effort(bad) end
      end
    end
  end

  describe "set_task_budget/3" do
    @beta "task-budgets-2026-03-13"

    test "emits a tokens budget and declares the beta" do
      request = Request.new("claude-opus-5-5") |> Request.set_task_budget(64_000)

      assert Request.to_map(request)["output_config"] == %{
               "task_budget" => %{"type" => "tokens", "total" => 64_000}
             }

      assert Request.required_betas(request) == [@beta]
    end

    test "remaining is included when given; 0 is accepted" do
      for remaining <- [20_000, 0] do
        request =
          Request.new("claude-opus-5-5")
          |> Request.set_task_budget(64_000, remaining: remaining)

        assert Request.to_map(request)["output_config"]["task_budget"] == %{
                 "type" => "tokens",
                 "total" => 64_000,
                 "remaining" => remaining
               }
      end
    end

    test "calling twice replaces the budget and declares the beta once" do
      request =
        Request.new("claude-opus-5-5")
        |> Request.set_task_budget(64_000, remaining: 10_000)
        |> Request.set_task_budget(30_000)

      assert Request.to_map(request)["output_config"]["task_budget"] == %{
               "type" => "tokens",
               "total" => 30_000
             }

      assert Request.required_betas(request) == [@beta]
    end

    test "total must be a positive integer (no local 20k floor)" do
      assert Request.new("m") |> Request.set_task_budget(1) |> Request.to_map()

      for bad <- [0, -1, 1.5, "64000", nil] do
        assert_raise ArgumentError,
                     ~r/set_task_budget\/3 total must be a positive integer; got/,
                     fn -> Request.new("m") |> Request.set_task_budget(bad) end
      end
    end

    test "remaining must be a non-negative integer" do
      for bad <- [-1, 2.5, "10", nil] do
        assert_raise ArgumentError,
                     ~r/set_task_budget\/3 :remaining must be a non-negative integer; got/,
                     fn -> Request.new("m") |> Request.set_task_budget(64_000, remaining: bad) end
      end
    end

    test "unknown option keys raise" do
      assert_raise ArgumentError, fn ->
        Request.new("m") |> Request.set_task_budget(64_000, max: 1)
      end
    end
  end

  describe "output_config composition" do
    @schema %{
      "type" => "object",
      "properties" => %{"a" => %{"type" => "string"}},
      "required" => ["a"],
      "additionalProperties" => false
    }

    test "effort, task budget and format merge in any order" do
      a =
        Request.new("m")
        |> Request.set_effort(:high)
        |> Request.set_task_budget(64_000)
        |> Request.set_output_format(@schema)

      b =
        Request.new("m")
        |> Request.set_output_format(@schema)
        |> Request.set_task_budget(64_000)
        |> Request.set_effort(:high)

      assert Request.to_map(a)["output_config"] == Request.to_map(b)["output_config"]
      assert Map.keys(Request.to_map(a)["output_config"]) |> Enum.sort() ==
               ["effort", "format", "task_budget"]
    end

    test "set_output_config/2 afterwards replaces the whole map" do
      request =
        Request.new("m")
        |> Request.set_effort(:high)
        |> Request.set_task_budget(64_000)
        |> Request.set_output_config(%{"effort" => "low"})

      assert Request.to_map(request)["output_config"] == %{"effort" => "low"}
    end
  end
```

- [ ] **Step 2: Run to verify they fail**

Run: `mix test test/request_test.exs 2>&1 | tail -20`
Expected: FAIL — "function Claudio.Messages.Request.set_effort/2 is undefined" (and `set_task_budget`).

- [ ] **Step 3: Implement** — in `lib/claudio/messages/request.ex`:

(a) In the `set_output_config/2` `@doc`, replace

```
  supported models `effort` / `task_budget`). This replaces the whole map; for
  structured JSON output prefer `set_output_format/2`, which merges.
```

with

```
  supported models `effort` / `task_budget`). This **replaces the whole map** —
  calling it after `set_effort/2`, `set_task_budget/3` or `set_output_format/2`
  discards what they set. Prefer those helpers; they merge.
```

(b) Replace the body of `set_output_format/2`

```elixir
    format = %{"type" => "json_schema", "schema" => schema}
    %{request | output_config: Map.put(existing || %{}, "format", format)}
```

with (and change its head from `%__MODULE__{output_config: existing} = request` to `%__MODULE__{} = request`):

```elixir
    put_output_config(request, "format", %{"type" => "json_schema", "schema" => schema})
```

(c) Add directly after `set_output_format/2`:

```elixir
  @effort_levels [:low, :medium, :high, :xhigh, :max]
  @task_budgets_beta "task-budgets-2026-03-13"

  @doc """
  Sets `output_config.effort` — how much the model thinks and spends overall.
  GA, no beta header. Merges into `output_config`.

  `level` is `:low`, `:medium`, `:high`, `:xhigh` or `:max`. Which levels a model
  accepts (and its default) varies; the API rejects unsupported ones.

  ## Example

      Request.new("claude-opus-5-5")
      |> Request.enable_adaptive_thinking()
      |> Request.set_effort(:xhigh)
  """
  @spec set_effort(t(), :low | :medium | :high | :xhigh | :max) :: t()
  def set_effort(%__MODULE__{} = request, level) when level in @effort_levels do
    put_output_config(request, "effort", Atom.to_string(level))
  end

  def set_effort(%__MODULE__{}, level) do
    raise ArgumentError,
          "Request.set_effort/2 level must be one of :low, :medium, :high, :xhigh, :max; " <>
            "got #{inspect(level)}"
  end

  @doc """
  Sets an advisory token budget for the whole task
  (`output_config.task_budget = %{"type" => "tokens", "total" => total}`) and
  declares the `task-budgets-2026-03-13` beta. Merges into `output_config`;
  calling it again replaces the budget. `max_tokens` stays the hard cap.

  `total` must be a positive integer (the API enforces its own minimum, 20,000 as
  of 2026-09). Options:

  - `:remaining` — tokens left when carrying a budget across requests
    (non-negative integer; the API defaults it to `total`).

  ## Example

      Request.new("claude-opus-5-5")
      |> Request.set_task_budget(64_000, remaining: 40_000)
  """
  @spec set_task_budget(t(), pos_integer(), keyword()) :: t()
  def set_task_budget(%__MODULE__{} = request, total, opts \\ []) when is_list(opts) do
    opts = Keyword.validate!(opts, [:remaining])

    unless is_integer(total) and total > 0 do
      raise ArgumentError,
            "Request.set_task_budget/3 total must be a positive integer; got #{inspect(total)}"
    end

    budget =
      case Keyword.fetch(opts, :remaining) do
        :error ->
          %{"type" => "tokens", "total" => total}

        {:ok, remaining} when is_integer(remaining) and remaining >= 0 ->
          %{"type" => "tokens", "total" => total, "remaining" => remaining}

        {:ok, other} ->
          raise ArgumentError,
                "Request.set_task_budget/3 :remaining must be a non-negative integer; " <>
                  "got #{inspect(other)}"
      end

    request
    |> put_output_config("task_budget", budget)
    |> add_beta(@task_budgets_beta)
  end

  defp put_output_config(%__MODULE__{output_config: existing} = request, key, value) do
    %{request | output_config: Map.put(existing || %{}, key, value)}
  end
```

- [ ] **Step 4: Run to verify they pass** (incl. the pre-existing `set_output_format` merge tests)

Run: `mix test test/request_test.exs 2>&1 | tail -5`
Expected: PASS — `0 failures`.

- [ ] **Step 5: Gates + commit**

```bash
mix format && mix compile --warnings-as-errors   # plan code is not pre-formatted; formatter owns layout
git add lib/claudio/messages/request.ex
git add test/request_test.exs
git commit -m "feat(request): set_effort/2 and set_task_budget/3 merge into output_config"
```

---

### Task 3: `usage.output_tokens_details`

**Files:**
- Modify: `lib/claudio/messages/response.ex` (`@type usage` ~90-95; `parse_usage/1` ~427-452)
- Test: `test/response_test.exs`, `test/messages/stream_test.exs`

**Interfaces:**
- Consumes: nothing new.
- Produces: `Response.usage` map gains key `:output_tokens_details :: map() | nil` (raw, keys as received). Task 4 reads it.

- [ ] **Step 1: Write the failing tests**

Append inside `Claudio.Messages.ResponseTest`:

```elixir
  describe "from_map/1 usage.output_tokens_details" do
    test "string keys: carried raw" do
      response =
        Response.from_map(%{
          "content" => [],
          "usage" => %{
            "input_tokens" => 10,
            "output_tokens" => 50,
            "output_tokens_details" => %{"thinking_tokens" => 30}
          }
        })

      assert response.usage.output_tokens_details == %{"thinking_tokens" => 30}
    end

    test "atom keys: carried raw" do
      response =
        Response.from_map(%{
          content: [],
          usage: %{input_tokens: 10, output_tokens: 50, output_tokens_details: %{thinking_tokens: 30}}
        })

      assert response.usage.output_tokens_details == %{thinking_tokens: 30}
    end

    test "nil when absent, and when usage itself is absent" do
      with_usage =
        Response.from_map(%{"content" => [], "usage" => %{"input_tokens" => 1, "output_tokens" => 2}})

      assert with_usage.usage.output_tokens_details == nil
      assert Response.from_map(%{"content" => []}).usage.output_tokens_details == nil
    end
  end
```

Append inside `Claudio.Messages.StreamTest` (Review Focus 1 — streamed end-to-end):

```elixir
  describe "output_tokens_details through build_final_message/1 → Response.from_map/1" do
    test "final message_delta usage details survive into the parsed Response" do
      sse = [
        ~s(event: message_start),
        ~s(data: {"type":"message_start","message":{"id":"msg_1","type":"message","role":"assistant","content":[],"model":"claude-opus-5-5","stop_reason":null,"usage":{"input_tokens":5,"output_tokens":0}}}),
        "",
        ~s(event: message_delta),
        ~s(data: {"type":"message_delta","delta":{"stop_reason":"end_turn"},"usage":{"input_tokens":5,"output_tokens":40,"output_tokens_details":{"thinking_tokens":25}}}),
        "",
        ~s(event: message_stop),
        ~s(data: {"type":"message_stop"}),
        ""
      ]

      {:ok, message} =
        [Enum.join(sse, "\n") <> "\n"]
        |> ClaudioStream.parse_events()
        |> ClaudioStream.build_final_message()

      response = Claudio.Messages.Response.from_map(message)
      assert response.usage.output_tokens_details == %{"thinking_tokens" => 25}
    end
  end
```

- [ ] **Step 2: Run to verify they fail**

Run: `mix test test/response_test.exs test/messages/stream_test.exs 2>&1 | tail -20`
Expected: FAIL — `KeyError` "key :output_tokens_details not found" in the string/atom/nil tests and the stream test.

- [ ] **Step 3: Implement** — in `lib/claudio/messages/response.ex`:

`@type usage` gains a field:

```elixir
  @type usage :: %{
          input_tokens: integer(),
          output_tokens: integer(),
          cache_creation_input_tokens: integer() | nil,
          cache_read_input_tokens: integer() | nil,
          output_tokens_details: map() | nil
        }
```

and the three concrete `parse_usage/1` clauses each gain one key (the `parse_usage(other)` fallthrough is unchanged):

```elixir
  defp parse_usage(%{input_tokens: input, output_tokens: output} = usage) do
    %{
      input_tokens: input,
      output_tokens: output,
      cache_creation_input_tokens: usage[:cache_creation_input_tokens],
      cache_read_input_tokens: usage[:cache_read_input_tokens],
      output_tokens_details: usage[:output_tokens_details]
    }
  end

  defp parse_usage(%{"input_tokens" => input, "output_tokens" => output} = usage) do
    %{
      input_tokens: input,
      output_tokens: output,
      cache_creation_input_tokens: usage["cache_creation_input_tokens"],
      cache_read_input_tokens: usage["cache_read_input_tokens"],
      output_tokens_details: usage["output_tokens_details"]
    }
  end

  defp parse_usage(nil) do
    %{
      input_tokens: 0,
      output_tokens: 0,
      cache_creation_input_tokens: nil,
      cache_read_input_tokens: nil,
      output_tokens_details: nil
    }
  end
```

Then update the one pre-existing exact-match assertion, `test/response_test.exs:26` ("parses basic response with string keys"), which pins the four-key map — the new key is intended:

```elixir
      assert response.usage == %{
               input_tokens: 10,
               output_tokens: 5,
               cache_creation_input_tokens: nil,
               cache_read_input_tokens: nil,
               output_tokens_details: nil
             }
```

(The moduledoc does not list usage keys — nothing to update there.)

- [ ] **Step 4: Run to verify they pass** — then the whole suite, since other tests may pattern-match the exact usage map

Run: `mix test test/response_test.exs test/messages/stream_test.exs 2>&1 | tail -5` then `mix test 2>&1 | tail -5`
Expected: PASS — `0 failures` both (grep on 2026-09-25 found `response_test.exs:26` as the only exact usage-map assertion).

- [ ] **Step 5: Gates + commit**

```bash
mix format && mix compile --warnings-as-errors   # plan code is not pre-formatted; formatter owns layout
git add lib/claudio/messages/response.ex
git add test/response_test.exs
git add test/messages/stream_test.exs
git commit -m "fix(response): keep usage.output_tokens_details"
```

---

### Task 4: `:thinking_tokens` in both usage-telemetry emitters

**Files:**
- Modify: `lib/claudio/messages.ex` (`usage_to_metadata/1` ~358-368), `lib/claudio/messages/stream.ex` (`usage_to_metadata/1` ~106-112, moduledoc line 5-7)
- Test: `test/messages_test.exs` (both telemetry tests already live here)

**Interfaces:**
- Consumes: `Response.usage.output_tokens_details` (Task 3; raw map, atom or string keys). Stream side reads the raw `message_delta` usage map (string keys from `Jason.decode/1`).
- Produces: telemetry metadata key `:thinking_tokens :: non_neg_integer()`, present only when the API sent `output_tokens_details.thinking_tokens`, on `[:claudio, :messages, :create, :stop]` and `[:claudio, :messages, :stream, :usage]`.

- [ ] **Step 1: Write the failing tests** — in `test/messages_test.exs`:

(a) In the existing test "telemetry stop metadata includes token usage for non-streaming success", after `assert metadata.cache_read_input_tokens == 5`, add:

```elixir
    refute Map.has_key?(metadata, :thinking_tokens)
```

(b) In the existing test "streaming emits final usage telemetry event when stream is consumed", replace its unfiltered

```elixir
    attach_telemetry_handler([:claudio, :messages, :stream, :usage])
```

with a filtered one (`:telemetry.attach` is global and other async modules fire this event — `stream_test.exs` and Task 3's new stream test — so an unfiltered `assert_receive` can match a foreign event):

```elixir
    attach_telemetry_handler(
      [:claudio, :messages, :stream, :usage],
      fn metadata -> metadata[:input_tokens] == 123 end
    )
```

and after its `assert metadata.cache_read_input_tokens == 5`, add the same line:

```elixir
    refute Map.has_key?(metadata, :thinking_tokens)
```

(c) Add two new tests directly before `defp attach_telemetry_handler`:

```elixir
  test "telemetry stop metadata includes thinking_tokens when usage reports them", %{
    client: client,
    bypass: bypass
  } do
    model = unique_model("thinking-tokens")

    Bypass.expect_once(bypass, "POST", "/messages", fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(
        200,
        Jason.encode!(%{
          "content" => [%{"type" => "text", "text" => "ok"}],
          "id" => "msg_thinking_tokens",
          "model" => model,
          "role" => "assistant",
          "stop_reason" => "end_turn",
          "stop_sequence" => nil,
          "type" => "message",
          "usage" => %{
            "input_tokens" => 12,
            "output_tokens" => 80,
            "output_tokens_details" => %{"thinking_tokens" => 64}
          }
        })
      )
    end)

    attach_telemetry_handler(
      [:claudio, :messages, :create, :stop],
      fn metadata -> metadata.model == model end
    )

    request =
      Request.new(model)
      |> Request.add_message(:user, "hello")
      |> Request.set_max_tokens(64)

    assert {:ok, _response} = Claudio.Messages.create(client, request)
    assert_receive {:telemetry_event, [:claudio, :messages, :create, :stop], metadata}
    assert metadata.thinking_tokens == 64
    assert metadata.output_tokens == 80
  end

  test "stream usage telemetry includes thinking_tokens from the final message_delta", %{
    client: client,
    bypass: bypass
  } do
    model = unique_model("stream-thinking-tokens")

    Bypass.expect_once(bypass, "POST", "/messages", fn conn ->
      conn =
        conn
        |> Plug.Conn.put_resp_content_type("text/event-stream")
        |> Plug.Conn.send_chunked(200)

      sse =
        [
          "event: message_start\n",
          "data: {\"type\":\"message_start\",\"message\":{\"id\":\"msg_st\",\"type\":\"message\",\"role\":\"assistant\",\"model\":\"#{model}\",\"content\":[]}}\n\n",
          "event: message_delta\n",
          "data: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"end_turn\",\"stop_sequence\":null},\"usage\":{\"input_tokens\":12,\"output_tokens\":80,\"output_tokens_details\":{\"thinking_tokens\":64}}}\n\n",
          "event: message_stop\n",
          "data: {\"type\":\"message_stop\"}\n\n"
        ]
        |> IO.iodata_to_binary()

      {:ok, conn} = Plug.Conn.chunk(conn, sse)
      conn
    end)

    attach_telemetry_handler(
      [:claudio, :messages, :stream, :usage],
      fn metadata -> metadata[:output_tokens] == 80 end
    )

    request =
      Request.new(model)
      |> Request.add_message(:user, "hello")
      |> Request.set_max_tokens(64)
      |> Request.enable_streaming()

    assert {:ok, stream_response} = Claudio.Messages.create(client, request)
    _events = stream_response.body |> Claudio.Messages.Stream.parse_events() |> Enum.to_list()

    assert_receive {:telemetry_event, [:claudio, :messages, :stream, :usage], metadata}
    assert metadata.thinking_tokens == 64
  end
```

- [ ] **Step 2: Run to verify they fail**

Run: `mix test test/messages_test.exs 2>&1 | tail -20`
Expected: the two new tests FAIL with `KeyError` "key :thinking_tokens not found"; the two `refute` lines already PASS (the key is absent today) — that is expected, they guard against the key appearing spuriously.

- [ ] **Step 3: Implement**

`lib/claudio/messages.ex` — replace `usage_to_metadata/1` with:

```elixir
  defp usage_to_metadata(usage) when is_map(usage) do
    usage
    |> Map.take([
      :input_tokens,
      :output_tokens,
      :cache_creation_input_tokens,
      :cache_read_input_tokens
    ])
    |> Map.put(:thinking_tokens, thinking_tokens(usage))
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end

  # usage.output_tokens_details is carried raw by Response (atom or string keys).
  defp thinking_tokens(usage) do
    case usage[:output_tokens_details] || usage["output_tokens_details"] do
      %{} = details -> details[:thinking_tokens] || details["thinking_tokens"]
      _ -> nil
    end
  end
```

`lib/claudio/messages/stream.ex` — replace `usage_to_metadata/1` with (and keep `maybe_put_usage_key/3` as is):

```elixir
  defp usage_to_metadata(usage) when is_map(usage) do
    %{}
    |> maybe_put_usage_key(:input_tokens, usage)
    |> maybe_put_usage_key(:output_tokens, usage)
    |> maybe_put_usage_key(:cache_creation_input_tokens, usage)
    |> maybe_put_usage_key(:cache_read_input_tokens, usage)
    |> maybe_put_thinking_tokens(usage)
  end

  # The final message_delta carries usage.output_tokens_details.thinking_tokens.
  defp maybe_put_thinking_tokens(metadata, usage) do
    case usage["output_tokens_details"] || usage[:output_tokens_details] do
      %{} = details ->
        case details["thinking_tokens"] || details[:thinking_tokens] do
          nil -> metadata
          tokens -> Map.put(metadata, :thinking_tokens, tokens)
        end

      _ ->
        metadata
    end
  end
```

and in the stream moduledoc replace

```
  when `parse_events/1` reaches the terminal `message_stop` event and final usage
  is available from `message_delta` frames.
```

with

```
  when `parse_events/1` reaches the terminal `message_stop` event and final usage
  is available from `message_delta` frames. Metadata carries `:input_tokens`,
  `:output_tokens`, the cache counters and `:thinking_tokens` when present.
```

- [ ] **Step 4: Run to verify they pass**

Run: `mix test test/messages_test.exs 2>&1 | tail -5`
Expected: PASS — `0 failures`.

- [ ] **Step 5: Gates + commit**

```bash
mix format && mix compile --warnings-as-errors   # plan code is not pre-formatted; formatter owns layout
git add lib/claudio/messages.ex
git add lib/claudio/messages/stream.ex
git add test/messages_test.exs
git commit -m "feat(telemetry): thinking_tokens in create and stream usage metadata"
```

---

### Task 5: `Response.get_thinking/1`, `Response.thinking_interrupted?/1`

**Files:**
- Modify: `lib/claudio/messages/response.ex` (new functions directly after `get_text/1`, ~143-148)
- Test: `test/response_test.exs`

**Interfaces:**
- Consumes: parsed thinking blocks `%{type: :thinking, thinking: String.t() | nil, signature: String.t() | nil}` (existing `parse_content_block/1`).
- Produces: `Response.get_thinking(t()) :: [String.t()]`, `Response.thinking_interrupted?(content_block()) :: boolean()`.

- [ ] **Step 1: Write the failing tests** — append inside `Claudio.Messages.ResponseTest`:

```elixir
  describe "get_thinking/1" do
    test "returns non-empty thinking texts in content order" do
      response =
        Response.from_map(%{
          "content" => [
            %{"type" => "thinking", "thinking" => "", "signature" => "s0"},
            %{"type" => "thinking", "thinking" => "Checking the config", "signature" => "s1"},
            %{"type" => "tool_use", "id" => "t1", "name" => "read", "input" => %{}},
            %{"type" => "redacted_thinking", "data" => "opaque"},
            %{"type" => "text", "text" => "not thinking"},
            %{"type" => "thinking", "thinking" => "Now writing the fix", "signature" => "s2"}
          ]
        })

      assert Response.get_thinking(response) == ["Checking the config", "Now writing the fix"]
    end

    test "skips a thinking block with no thinking text instead of crashing" do
      response =
        Response.from_map(%{"content" => [%{"type" => "thinking", "signature" => "s"}]})

      assert Response.get_thinking(response) == []
    end

    test "keeps the interrupted placeholder (filter with thinking_interrupted?/1)" do
      placeholder = "This part of the response was interrupted before it finished."

      response =
        Response.from_map(%{
          "content" => [%{"type" => "thinking", "thinking" => placeholder, "signature" => "s"}]
        })

      assert Response.get_thinking(response) == [placeholder]
    end
  end

  describe "thinking_interrupted?/1" do
    @placeholder "This part of the response was interrupted before it finished."

    test "true only for a thinking block whose text is exactly the placeholder" do
      assert Response.thinking_interrupted?(%{type: :thinking, thinking: @placeholder, signature: "s"})
    end

    test "false for other thinking text, a text block with the same string, and redacted_thinking" do
      refute Response.thinking_interrupted?(%{type: :thinking, thinking: "working", signature: "s"})
      refute Response.thinking_interrupted?(%{type: :thinking, thinking: @placeholder <> " ", signature: "s"})
      refute Response.thinking_interrupted?(%{type: :text, text: @placeholder})
      refute Response.thinking_interrupted?(%{type: :redacted_thinking, data: "x"})
    end
  end
```

- [ ] **Step 2: Run to verify they fail**

Run: `mix test test/response_test.exs 2>&1 | tail -20`
Expected: FAIL — "function Claudio.Messages.Response.get_thinking/1 is undefined" (and `thinking_interrupted?/1`).

- [ ] **Step 3: Implement** — add directly after `get_text/1`:

```elixir
  # Exact text of an interrupted `display: "updates"` thinking block
  # (platform.claude.com/docs/en/build-with-claude/thinking, fetched 2026-09-25).
  @interrupted_thinking "This part of the response was interrupted before it finished."

  @doc """
  Returns the non-empty `thinking` texts, in content order.

  A list, not a joined string: with `display: :updates` each `thinking` block is a
  separate progress note. Empty texts (`display: :omitted`) and `redacted_thinking`
  blocks are skipped. An interrupted update's placeholder text is kept — filter it
  with `thinking_interrupted?/1`.
  """
  @spec get_thinking(t()) :: [String.t()]
  def get_thinking(%__MODULE__{content: content}) do
    for %{type: :thinking, thinking: text} <- content, is_binary(text), text != "", do: text
  end

  @doc """
  True when `block` is a `thinking` block holding the API's placeholder for an
  update that was cut off: `"#{@interrupted_thinking}"`.
  """
  @spec thinking_interrupted?(content_block()) :: boolean()
  def thinking_interrupted?(%{type: :thinking, thinking: @interrupted_thinking}), do: true
  def thinking_interrupted?(_block), do: false
```

- [ ] **Step 4: Run to verify they pass**

Run: `mix test test/response_test.exs 2>&1 | tail -5`
Expected: PASS — `0 failures`.

- [ ] **Step 5: Gates + commit**

```bash
mix format && mix compile --warnings-as-errors   # plan code is not pre-formatted; formatter owns layout
git add lib/claudio/messages/response.ex
git add test/response_test.exs
git commit -m "feat(response): get_thinking/1 and thinking_interrupted?/1"
```

---

### Task 6: `Stream.accumulate_thinking/1`

**Files:**
- Modify: `lib/claudio/messages/stream.ex` (new function directly after `accumulate_text/1`, ~131-149; moduledoc delta list)
- Test: `test/messages/stream_test.exs`

**Interfaces:**
- Consumes: the event stream from `Stream.parse_events/1` — items `{:ok, %{event: String.t(), data: map()}}` or `{:error, term()}`; `content_block_delta` data carries `"index"` and `"delta"`.
- Produces: `Stream.accumulate_thinking(Enumerable.t()) :: Enumerable.t()` emitting `{non_neg_integer(), String.t()}`.

- [ ] **Step 1: Write the failing tests** — append inside `Claudio.Messages.StreamTest`:

```elixir
  describe "accumulate_thinking/1" do
    test "emits {index, text} for non-empty thinking deltas only" do
      sse = [
        ~s(event: content_block_start),
        ~s(data: {"type":"content_block_start","index":0,"content_block":{"type":"thinking","thinking":""}}),
        "",
        ~s(event: content_block_delta),
        ~s(data: {"type":"content_block_delta","index":0,"delta":{"type":"thinking_delta","thinking":"a"}}),
        "",
        ~s(event: content_block_delta),
        ~s(data: {"type":"content_block_delta","index":0,"delta":{"type":"thinking_delta","thinking":"b"}}),
        "",
        ~s(event: content_block_delta),
        ~s(data: {"type":"content_block_delta","index":0,"delta":{"type":"signature_delta","signature":"s0"}}),
        "",
        ~s(event: content_block_delta),
        ~s(data: {"type":"content_block_delta","index":1,"delta":{"type":"thinking_delta","thinking":""}}),
        "",
        ~s(event: content_block_delta),
        ~s(data: {"type":"content_block_delta","index":2,"delta":{"type":"text_delta","text":"hello"}}),
        "",
        ~s(event: content_block_delta),
        ~s(data: {"type":"content_block_delta","index":3,"delta":{"type":"thinking_delta","thinking":"c"}}),
        "",
        ~s(event: message_stop),
        ~s(data: {"type":"message_stop"}),
        ""
      ]

      result =
        [Enum.join(sse, "\n") <> "\n"]
        |> ClaudioStream.parse_events()
        |> ClaudioStream.accumulate_thinking()
        |> Enum.to_list()

      assert result == [{0, "a"}, {0, "b"}, {3, "c"}]
    end

    test "atom-keyed event data works too" do
      events = [
        {:ok,
         %{
           event: "content_block_delta",
           data: %{index: 4, delta: %{type: "thinking_delta", thinking: "x"}}
         }}
      ]

      assert events |> ClaudioStream.accumulate_thinking() |> Enum.to_list() == [{4, "x"}]
    end

    test "error items and other events are skipped, not raised on" do
      events = [
        {:error, :boom},
        {:ok, %{event: "ping", data: %{}}},
        {:ok,
         %{
           event: "content_block_delta",
           data: %{"index" => 0, "delta" => %{"type" => "thinking_delta", "thinking" => "y"}}
         }}
      ]

      assert events |> ClaudioStream.accumulate_thinking() |> Enum.to_list() == [{0, "y"}]
    end
  end
```

- [ ] **Step 2: Run to verify they fail**

Run: `mix test test/messages/stream_test.exs 2>&1 | tail -20`
Expected: FAIL — "function Claudio.Messages.Stream.accumulate_thinking/1 is undefined".

- [ ] **Step 3: Implement** — add directly after `accumulate_text/1` (bare `Stream` here is Elixir's `Stream`, as in `accumulate_text/1`):

```elixir
  @doc ~S"""
  Emits `{block_index, text}` for every `thinking_delta` with non-empty text.

  The index tells one `thinking` block from the next: with `display: :updates` each
  block is a separate progress note, and a block's first emission is the point the
  API docs say to treat it as an update. Empty deltas (`display: :omitted`),
  other deltas, other events and `{:error, _}` items emit nothing.

  ## Example

      response
      |> Stream.parse_events()
      |> Stream.accumulate_thinking()
      |> Enum.each(fn {index, text} -> IO.puts("[#{index}] #{text}") end)
  """
  @spec accumulate_thinking(Enumerable.t()) :: Enumerable.t()
  def accumulate_thinking(event_stream) do
    Stream.flat_map(event_stream, fn
      {:ok, %{event: "content_block_delta", data: data}} when is_map(data) ->
        delta = data["delta"] || data[:delta] || %{}
        type = delta["type"] || delta[:type]
        text = delta["thinking"] || delta[:thinking]

        if type == "thinking_delta" and is_binary(text) and text != "" do
          [{data["index"] || data[:index], text}]
        else
          []
        end

      _ ->
        []
    end)
  end
```

and in the moduledoc replace the bullet

```
  - `content_block_delta` - Incremental content updates (text, JSON, thinking)
```

with

```
  - `content_block_delta` - Incremental content updates (text, JSON, thinking);
    read them with `accumulate_text/1` / `accumulate_thinking/1`
```

- [ ] **Step 4: Run to verify they pass**

Run: `mix test test/messages/stream_test.exs 2>&1 | tail -5`
Expected: PASS — `0 failures`.

- [ ] **Step 5: Gates + commit**

```bash
mix format && mix compile --warnings-as-errors   # plan code is not pre-formatted; formatter owns layout
git add lib/claudio/messages/stream.ex
git add test/messages/stream_test.exs
git commit -m "feat(stream): accumulate_thinking/1 emits {index, text} per thinking delta"
```

---

### Task 7: Live integration test + docs (CHANGELOG, CLAUDE.md)

**Files:**
- Create: `test/integration/thinking_integration_test.exs`
- Modify: `CHANGELOG.md` (`## [Unreleased] — targets 0.7.0`), `CLAUDE.md` (Request builder list ~92-93, Response helpers ~126-127, Streaming ~133)

**Interfaces:**
- Consumes: `Request.enable_adaptive_thinking/2`, `Request.set_effort/2` (Tasks 1-2), `Response.usage.output_tokens_details` (Task 3), `Claudio.IntegrationHelper.skip_if_no_api_key/0` / `create_client/0`.
- Produces: nothing consumed later.

- [ ] **Step 1: Write the integration test** — create `test/integration/thinking_integration_test.exs`:

```elixir
Code.require_file("../integration/integration_helper.exs", __DIR__)

defmodule Claudio.ThinkingIntegrationTest do
  use ExUnit.Case, async: false
  import Claudio.IntegrationHelper

  alias Claudio.Messages.{Request, Response}

  @moduletag :integration
  @moduletag timeout: 120_000

  setup_all do
    case skip_if_no_api_key() do
      :ok -> {:ok, %{client: create_client()}}
      {:skip, reason} -> {:skip, reason}
    end
  end

  test "adaptive thinking with display: :omitted and effort :high", %{client: client} do
    request =
      Request.new("claude-opus-5-5")
      |> Request.add_message(
        :user,
        "A train leaves at 09:47 and the trip takes 3 h 38 min with a 17 min delay. " <>
          "What time does it arrive? Answer with the time only."
      )
      |> Request.set_max_tokens(4096)
      |> Request.enable_adaptive_thinking(display: :omitted)
      |> Request.set_effort(:high)

    assert {:ok, %Response{} = response} = Claudio.Messages.create(client, request)

    thinking = Enum.filter(response.content, &(&1.type == :thinking))
    assert thinking != [], "expected at least one thinking block at effort :high"

    for block <- thinking do
      assert block.thinking == ""
      assert is_binary(block.signature) and block.signature != ""
    end

    assert Response.get_thinking(response) == []
    assert %{} = details = response.usage.output_tokens_details
    assert is_integer(details["thinking_tokens"] || details[:thinking_tokens])
  end
end
```

- [ ] **Step 2: Run it**

Run: `mix test test/integration/thinking_integration_test.exs --include integration 2>&1 | tail -15`
Expected: PASS (`1 test, 0 failures`) when `ANTHROPIC_API_KEY` is set. When unset, ExUnit reports `1 test, 0 failures, 1 invalid` (the shared `setup_all` returns `{:skip, _}`, which ExUnit treats as an invalid setup — pre-existing helper pattern, not fixed here) — record **DID NOT RUN** in the ledger and in the final report, never "passed". A failure here is data about the API (e.g. no thinking block at `:high`, `output_tokens_details` absent): stop and report the raw response, do not loosen the assertions.

- [ ] **Step 3: CHANGELOG** — in `CHANGELOG.md` under `## [Unreleased] — targets 0.7.0`:

Append to the end of `### Fixed`:

```markdown
- `Response.usage` keeps `output_tokens_details` (raw map, e.g. `thinking_tokens`);
  it was dropped by the usage parser.
```

Append to the end of the `[Unreleased]` section's `### Added` (the first `### Added` in the file, ~line 38 — it ends just before `### Docs`; the second one belongs to `[0.6.0]`):

```markdown
- **Thinking & effort helpers** (`Claudio.Messages.Request`), no per-model validation:
  - `enable_adaptive_thinking/2` (`display:` `:summarized` / `:omitted` / `:updates`;
    `:updates` declares `thinking-display-updates-2026-08-18`) and `disable_thinking/1`.
  - `set_effort/2` (`:low` … `:max`, GA) and `set_task_budget/3` (`output_config.task_budget`,
    declares `task-budgets-2026-03-13`) — both merge into `output_config`.
- `Response.get_thinking/1`, `Response.thinking_interrupted?/1`, `Stream.accumulate_thinking/1`.
- Telemetry: `:thinking_tokens` in `[:claudio, :messages, :create, :stop]` and
  `[:claudio, :messages, :stream, :usage]` metadata, when the API reports it.
```

- [ ] **Step 4: CLAUDE.md** — three insertions:

After the line starting `- **Structured outputs** (\`set_output_format/2\``, insert:

```markdown
- **Thinking & effort** (`enable_adaptive_thinking/2` with `display:` — `:updates` declares `thinking-display-updates-2026-08-18`; `disable_thinking/1`; `set_effort/2` → `output_config.effort`, GA; `set_task_budget/3` → `output_config.task_budget`, declares `task-budgets-2026-03-13`. Output-config helpers merge; `set_output_config/2` replaces. No per-model validation — the API's 400 is authoritative.)
```

After the line `  - \`get_mcp_tool_uses/2\`: Extracts MCP tool uses for a specific server`, insert:

```markdown
  - `get_thinking/1`: Non-empty thinking texts, in order (a list — one per `display: :updates` progress note)
  - `thinking_interrupted?/1`: True for the API's interrupted-update placeholder block
- **`usage.output_tokens_details`** — raw map (e.g. `thinking_tokens`), `nil` when absent; `:thinking_tokens` also appears in usage telemetry
```

After the line `- \`accumulate_text/1\`: Extracts and accumulates text deltas`, insert:

```markdown
- `accumulate_thinking/1`: Emits `{block_index, text}` per non-empty `thinking_delta`
```

- [ ] **Step 5: Full verification, then commit**

Run: `mix format --check-formatted && mix compile --warnings-as-errors && mix test 2>&1 | tail -5`
Expected: format and compile clean; `mix test` → `0 failures` (integration tests excluded).

```bash
git add test/integration/thinking_integration_test.exs
git add CHANGELOG.md
git add CLAUDE.md
git commit -m "test(integration): adaptive thinking + effort; docs for S11"
```

---

## Spec coverage (self-review)

| Spec section | Task |
|---|---|
| §1 thinking helpers (replace, `:updates` beta, `disable` has no display, `enable_thinking` doc) | 1 |
| §2 output-config helpers (merge, validation, no 20k floor, `set_output_config` warning) | 2 |
| §3 `output_tokens_details` (both key styles, nil clause, type) | 3 |
| §4 `:thinking_tokens` telemetry (both emitters, omitted when absent) | 4 |
| §5 `get_thinking/1`, `thinking_interrupted?/1`, `accumulate_thinking/1` | 5, 6 |
| §6 docs (CHANGELOG, CLAUDE.md; roadmap already committed with the spec) | 7 |
| Testing → integration (`claude-opus-5-5`, `:omitted`, effort `:high`) | 7 |
