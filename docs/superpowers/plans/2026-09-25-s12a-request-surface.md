# S12a Request Surface Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Request helpers for mid-conversation system messages (`clear_at`, per-message effort), `speed`, `inference_geo` and cache diagnostics; `Response.usage` stops dropping fields; `Response.diagnostics`.

**Architecture:** Additive functions on `Claudio.Messages.Request` (one appends a `role: "system"` message; three set new top-level struct fields emitted by `to_map/1`), each declaring its beta via `add_beta/2`. `Response.parse_usage/1` is rewritten around one `@usage_keys` list: documented fields become atom keys, everything else keeps its original key. `Response` gains a raw `diagnostics` field.

**Tech Stack:** Elixir ≥ 1.15, ExUnit (async), Bypass, Jason.

**Spec:** `docs/superpowers/specs/2026-09-25-s12a-request-surface-design.md`

## Global Constraints

- Model-agnostic: no per-model checks; **no placement checks** for system messages. Local `ArgumentError` only for inputs the API rejects on every model.
- Enumerated values are **atoms only**; errors name the function, the allowed values and `inspect/1` of the value received; option keys via `Keyword.validate!/2`; a `nil` option means "not given".
- Beta strings, verbatim: `mid-conversation-system-clear-at-2026-08-21` (any `:clear_at`), `mid-conversation-output-config-2026-07-01` (any `:effort` on a system message), `fast-mode-2026-02-01` (every `set_speed/2`, including `:standard`). `inference_geo` and `diagnostics` are GA — no beta.
- `add_message/3` and its variants keep `role in [:user, :assistant]`.
- Existing public signatures unchanged. No `@version` bump; CHANGELOG under `## [Unreleased] — targets 0.7.0`.
- Commits: add files individually (`git add .` forbidden); **no AI attribution lines**.
- Gates before each commit: `mix format` (plan code is not pre-formatted) and `mix compile --warnings-as-errors`; Task 5 ends with the strict `mix format --check-formatted` and the full suite.

## Review Focus

1. `add_system_message/3` given `nil` for `:clear_at` / `:effort` must behave exactly as if the option were absent (no field, no beta) — pinned in Task 1.
2. A system message appended after existing user/assistant messages must leave them untouched and in order — pinned in Task 1.
3. Atom-keyed usage input with an unknown atom field keeps that field under its atom key, and string-keyed input keeps unknown string keys — no key is silently converted or dropped — pinned in Task 3.
4. A usage map that has a documented field under **both** an atom and a string key must yield one atom key (atom value wins) and no leftover string duplicate — pinned in Task 3.
5. `to_map/1` of a request with none of the new setters must be byte-identical to today's (no `"speed"`, `"inference_geo"`, `"diagnostics"` keys) — pinned in Task 2.

## Branching

Implementation branch `feat/s12a-request-surface`, cut from `docs/s12-specs` (spec + plan).

---

### Task 1: `Request.add_system_message/3`

**Files:**
- Modify: `lib/claudio/messages/request.ex` — new function directly **after** `put_output_config/3` (~835-839). It must come after `@effort_levels` (line ~761): a module attribute is only readable by code that follows its definition.
- Test: `test/request_test.exs` (new `describe` at the end of the module)

**Interfaces:**
- Consumes: `@effort_levels` (`[:low, :medium, :high, :xhigh, :max]`, from S11), `add_beta/2`, `to_map/1`, `required_betas/1`.
- Produces: `Request.add_system_message(t(), String.t() | [map()], keyword()) :: t()`.

- [ ] **Step 1: Write the failing tests** — append inside `Claudio.Messages.RequestTest`, before the final `end`:

```elixir
  describe "add_system_message/3" do
    @clear_at_beta "mid-conversation-system-clear-at-2026-08-21"
    @msg_effort_beta "mid-conversation-output-config-2026-07-01"

    test "string content appends a system message, no beta" do
      request =
        Request.new("claude-opus-5-5")
        |> Request.add_message(:user, "Hi")
        |> Request.add_message(:assistant, "Hello")
        |> Request.add_message(:user, "Continue")
        |> Request.add_system_message("Reply in French.")

      assert Request.to_map(request)["messages"] == [
               %{"role" => "user", "content" => "Hi"},
               %{"role" => "assistant", "content" => "Hello"},
               %{"role" => "user", "content" => "Continue"},
               %{"role" => "system", "content" => "Reply in French."}
             ]

      assert Request.required_betas(request) == []
    end

    test "block content is passed through unchanged" do
      blocks = [%{"type" => "text", "text" => "Be brief."}]
      request = Request.new("m") |> Request.add_system_message(blocks)

      assert [%{"role" => "system", "content" => ^blocks}] = Request.to_map(request)["messages"]
    end

    test "clear_at emits the field and declares its beta once" do
      for clear_at <- [:next_user_message, :never] do
        request =
          Request.new("m")
          |> Request.add_system_message("a", clear_at: clear_at)
          |> Request.add_system_message("b", clear_at: clear_at)

        [first, _] = Request.to_map(request)["messages"]
        assert first["clear_at"] == Atom.to_string(clear_at)
        assert Request.required_betas(request) == [@clear_at_beta]
      end
    end

    test "effort emits output_config and declares its beta" do
      for level <- [:low, :medium, :high, :xhigh, :max] do
        request = Request.new("m") |> Request.add_system_message([], effort: level)

        assert Request.to_map(request)["messages"] == [
                 %{
                   "role" => "system",
                   "content" => [],
                   "output_config" => %{"effort" => Atom.to_string(level)}
                 }
               ]

        assert Request.required_betas(request) == [@msg_effort_beta]
      end
    end

    test "content plus effort is allowed (not turn-scoped)" do
      request = Request.new("m") |> Request.add_system_message("Be brief.", effort: :low)

      assert [%{"content" => "Be brief.", "output_config" => %{"effort" => "low"}}] =
               Request.to_map(request)["messages"]
    end

    test "nil options behave as if absent" do
      request =
        Request.new("m") |> Request.add_system_message("a", clear_at: nil, effort: nil)

      assert Request.to_map(request)["messages"] == [%{"role" => "system", "content" => "a"}]
      assert Request.required_betas(request) == []
    end

    test "unknown clear_at and effort values raise" do
      assert_raise ArgumentError,
                   ~r/add_system_message\/3 :clear_at must be one of :next_user_message, :never; got/,
                   fn -> Request.new("m") |> Request.add_system_message("a", clear_at: :later) end

      assert_raise ArgumentError,
                   ~r/add_system_message\/3 :effort must be one of :low, :medium, :high, :xhigh, :max; got/,
                   fn -> Request.new("m") |> Request.add_system_message("a", effort: "low") end
    end

    test "a turn-scoped message cannot carry effort" do
      assert_raise ArgumentError,
                   ~r/add_system_message\/3 clear_at: :next_user_message cannot be combined with :effort/,
                   fn ->
                     Request.new("m")
                     |> Request.add_system_message("a", clear_at: :next_user_message, effort: :low)
                   end
    end

    test "empty content needs effort" do
      assert_raise ArgumentError,
                   ~r/add_system_message\/3 empty content \[\] requires :effort/,
                   fn -> Request.new("m") |> Request.add_system_message([]) end
    end

    test "unknown option keys raise" do
      assert_raise ArgumentError, ~r/unknown keys/, fn ->
        Request.new("m") |> Request.add_system_message("a", cache_control: %{})
      end
    end
  end
```

- [ ] **Step 2: Run to verify they fail**

Run: `mix test test/request_test.exs 2>&1 | tail -20`
Expected: FAIL — `UndefinedFunctionError` "function Claudio.Messages.Request.add_system_message/2 is undefined" (and `/3`); 10 new failures.

- [ ] **Step 3: Implement** — add directly after `put_output_config/3`:

```elixir
  @clear_at_values [:next_user_message, :never]
  @clear_at_beta "mid-conversation-system-clear-at-2026-08-21"
  @message_effort_beta "mid-conversation-output-config-2026-07-01"

  @doc """
  Appends a mid-conversation `role: "system"` message (GA — no beta header).

  `content` is a string or a list of content blocks, passed through unchanged. Where
  the message may sit (after a `user` turn, not first when it carries content, …) is
  checked by the API, not here.

  ## Options

  - `:clear_at` — `:next_user_message` (the message stops rendering once a later
    `user` message exists) or `:never`. Declares the
    `mid-conversation-system-clear-at-2026-08-21` beta.
  - `:effort` — `:low` … `:max`: per-message effort from the next `user` turn on
    (`"output_config" => %{"effort" => ...}`). Declares the
    `mid-conversation-output-config-2026-07-01` beta. With `content: []` this is an
    effort-only message, which the API accepts anywhere, including first.

  Raises `ArgumentError` for combinations the API always rejects:
  `clear_at: :next_user_message` with `:effort`, and `[]` content without `:effort`.

  ## Example

      Request.new("claude-opus-5-5")
      |> Request.add_system_message([], effort: :low)
      |> Request.add_message(:user, "Name a primary color.")
      |> Request.add_system_message("Answer in one word.", clear_at: :next_user_message)
  """
  @spec add_system_message(t(), String.t() | [map()], keyword()) :: t()
  def add_system_message(%__MODULE__{messages: messages} = request, content, opts \\ [])
      when (is_binary(content) or is_list(content)) and is_list(opts) do
    opts = Keyword.validate!(opts, [:clear_at, :effort])
    clear_at = Keyword.get(opts, :clear_at)
    effort = Keyword.get(opts, :effort)

    unless is_nil(clear_at) or clear_at in @clear_at_values do
      raise ArgumentError,
            "Request.add_system_message/3 :clear_at must be one of :next_user_message, :never; " <>
              "got #{inspect(clear_at)}"
    end

    unless is_nil(effort) or effort in @effort_levels do
      raise ArgumentError,
            "Request.add_system_message/3 :effort must be one of :low, :medium, :high, :xhigh, :max; " <>
              "got #{inspect(effort)}"
    end

    if clear_at == :next_user_message and effort do
      raise ArgumentError,
            "Request.add_system_message/3 clear_at: :next_user_message cannot be combined with " <>
              ":effort (a turn-scoped system message cannot carry output_config)"
    end

    if content == [] and is_nil(effort) do
      raise ArgumentError,
            "Request.add_system_message/3 empty content [] requires :effort " <>
              "(a system message needs content or output_config)"
    end

    message =
      %{"role" => "system", "content" => content}
      |> maybe_put("clear_at", clear_at && Atom.to_string(clear_at))
      |> maybe_put("output_config", effort && %{"effort" => Atom.to_string(effort)})

    request = %{request | messages: messages ++ [message]}
    request = if clear_at, do: add_beta(request, @clear_at_beta), else: request
    if effort, do: add_beta(request, @message_effort_beta), else: request
  end
```

- [ ] **Step 4: Run to verify they pass**

Run: `mix test test/request_test.exs 2>&1 | tail -3`
Expected: PASS — `0 failures`.

- [ ] **Step 5: Gates + commit**

```bash
mix format && mix compile --warnings-as-errors   # plan code is not pre-formatted; formatter owns layout
git add lib/claudio/messages/request.ex
git add test/request_test.exs
git commit -m "feat(request): add_system_message/3 with clear_at and per-message effort"
```

---

### Task 2: `set_speed/2`, `set_inference_geo/2`, `enable_cache_diagnostics/2`

**Files:**
- Modify: `lib/claudio/messages.ex` — `count_tokens/2` Request clause (~209-219), Steps 6-8
- Modify: `lib/claudio/messages/request.ex` — `@type t` (~21-43), `defstruct` (~44-65), `to_map/1` (~1073-1095), new functions directly after `add_system_message/3` (Task 1)
- Test: `test/request_test.exs`, `test/messages_test.exs` (Steps 6-8)

**Interfaces:**
- Consumes: `add_beta/2`, `to_map/1`, private `maybe_put/3`.
- Produces: struct fields `speed: String.t() | nil`, `inference_geo: String.t() | nil`, `diagnostics: map() | nil`; `Request.set_speed(t(), :fast | :standard) :: t()`, `Request.set_inference_geo(t(), :global | :us) :: t()`, `Request.enable_cache_diagnostics(t(), String.t() | nil) :: t()`.

- [ ] **Step 1: Write the failing tests** — append inside `Claudio.Messages.RequestTest`:

```elixir
  describe "set_speed/2" do
    test "each value is emitted and always declares the fast-mode beta" do
      for speed <- [:fast, :standard] do
        request = Request.new("claude-opus-5-5") |> Request.set_speed(speed)

        assert Request.to_map(request)["speed"] == Atom.to_string(speed)
        assert Request.required_betas(request) == ["fast-mode-2026-02-01"]
      end
    end

    test "unknown values raise" do
      for bad <- [:turbo, "fast", nil] do
        assert_raise ArgumentError, ~r/set_speed\/2 speed must be one of :fast, :standard; got/, fn ->
          Request.new("m") |> Request.set_speed(bad)
        end
      end
    end
  end

  describe "set_inference_geo/2" do
    test "each value is emitted, no beta" do
      for geo <- [:global, :us] do
        request = Request.new("claude-opus-5-5") |> Request.set_inference_geo(geo)

        assert Request.to_map(request)["inference_geo"] == Atom.to_string(geo)
        assert Request.required_betas(request) == []
      end
    end

    test "unknown values raise" do
      for bad <- [:eu, "us", nil] do
        assert_raise ArgumentError,
                     ~r/set_inference_geo\/2 geo must be one of :global, :us; got/,
                     fn -> Request.new("m") |> Request.set_inference_geo(bad) end
      end
    end
  end

  describe "enable_cache_diagnostics/2" do
    test "defaults previous_message_id to nil, no beta" do
      request = Request.new("m") |> Request.enable_cache_diagnostics()

      assert Request.to_map(request)["diagnostics"] == %{"previous_message_id" => nil}
      assert Request.required_betas(request) == []
    end

    test "carries a previous message id" do
      request = Request.new("m") |> Request.enable_cache_diagnostics("msg_01")
      assert Request.to_map(request)["diagnostics"] == %{"previous_message_id" => "msg_01"}
    end

    test "a non-string id raises" do
      for bad <- [123, :msg, %{}] do
        assert_raise ArgumentError,
                     ~r/enable_cache_diagnostics\/2 previous_message_id must be a string or nil; got/,
                     fn -> Request.new("m") |> Request.enable_cache_diagnostics(bad) end
      end
    end
  end

  describe "to_map/1 without the S12a setters" do
    test "emits no speed, inference_geo or diagnostics keys" do
      map = Request.new("m") |> Request.add_message(:user, "hi") |> Request.to_map()

      assert map == %{"model" => "m", "messages" => [%{"role" => "user", "content" => "hi"}]}
    end
  end
```

- [ ] **Step 2: Run to verify they fail**

Run: `mix test test/request_test.exs 2>&1 | tail -20`
Expected: FAIL — `UndefinedFunctionError` for `set_speed/2`, `set_inference_geo/2`, `enable_cache_diagnostics/1`/`/2`. (The `to_map/1 without the S12a setters` test already PASSES — it guards against the keys appearing; expected.)

- [ ] **Step 3: Implement** — in `lib/claudio/messages/request.ex`:

(a) `@type t` — replace

```elixir
          output_config: map() | nil,
          cache_control: map() | nil
        }
```

with

```elixir
          output_config: map() | nil,
          cache_control: map() | nil,
          speed: String.t() | nil,
          inference_geo: String.t() | nil,
          diagnostics: map() | nil
        }
```

(b) `defstruct` — replace

```elixir
    output_config: nil,
    cache_control: nil
  ]
```

with

```elixir
    output_config: nil,
    cache_control: nil,
    speed: nil,
    inference_geo: nil,
    diagnostics: nil
  ]
```

(c) `to_map/1` — replace

```elixir
    |> maybe_put("cache_control", request.cache_control)
  end
```

with

```elixir
    |> maybe_put("cache_control", request.cache_control)
    |> maybe_put("speed", request.speed)
    |> maybe_put("inference_geo", request.inference_geo)
    |> maybe_put("diagnostics", request.diagnostics)
  end
```

(d) directly after `add_system_message/3`:

```elixir
  @speeds [:fast, :standard]
  @fast_mode_beta "fast-mode-2026-02-01"

  @doc """
  Sets `speed` (`:fast` or `:standard`). Fast mode is an access-gated research
  preview. Always declares the `fast-mode-2026-02-01` beta — the API rejects the
  `speed` field without it, even for `:standard`. The response's `usage.speed`
  reports the speed used.
  """
  @spec set_speed(t(), :fast | :standard) :: t()
  def set_speed(%__MODULE__{} = request, speed) when speed in @speeds do
    add_beta(%{request | speed: Atom.to_string(speed)}, @fast_mode_beta)
  end

  def set_speed(%__MODULE__{}, speed) do
    raise ArgumentError,
          "Request.set_speed/2 speed must be one of :fast, :standard; got #{inspect(speed)}"
  end

  @inference_geos [:global, :us]

  @doc """
  Sets `inference_geo` — where the request is processed (`:global` or `:us`; GA, no
  beta). Without it the workspace default applies. `:us` is billed at 1.1× standard
  pricing. Not sent by `Claudio.Messages.count_tokens/2` (that endpoint rejects it).
  The response's `usage.inference_geo` reports where it ran.
  """
  @spec set_inference_geo(t(), :global | :us) :: t()
  def set_inference_geo(%__MODULE__{} = request, geo) when geo in @inference_geos do
    %{request | inference_geo: Atom.to_string(geo)}
  end

  def set_inference_geo(%__MODULE__{}, geo) do
    raise ArgumentError,
          "Request.set_inference_geo/2 geo must be one of :global, :us; got #{inspect(geo)}"
  end

  @doc """
  Asks for cache diagnostics (GA, no beta): the response's `diagnostics` explains a
  prompt-cache miss against `previous_message_id` (the `id` of an earlier response in
  the same conversation), or is `nil` when there is nothing to compare. Not sent by
  `Claudio.Messages.count_tokens/2` (that endpoint rejects it).
  """
  @spec enable_cache_diagnostics(t(), String.t() | nil) :: t()
  def enable_cache_diagnostics(%__MODULE__{} = request, previous_message_id \\ nil) do
    unless is_nil(previous_message_id) or is_binary(previous_message_id) do
      raise ArgumentError,
            "Request.enable_cache_diagnostics/2 previous_message_id must be a string or nil; " <>
              "got #{inspect(previous_message_id)}"
    end

    %{request | diagnostics: %{"previous_message_id" => previous_message_id}}
  end
```

- [ ] **Step 4: Run to verify they pass**

Run: `mix test test/request_test.exs 2>&1 | tail -3`
Expected: PASS — `0 failures`.

- [ ] **Step 5: Gates + commit**

```bash
mix format && mix compile --warnings-as-errors   # plan code is not pre-formatted; formatter owns layout
git add lib/claudio/messages/request.ex
git add test/request_test.exs
git commit -m "feat(request): set_speed/2, set_inference_geo/2, enable_cache_diagnostics/2"
```

- [ ] **Step 6: Failing test — `count_tokens/2` must strip `inference_geo` / `diagnostics`.** Live probe 2026-09-25: `/v1/messages/count_tokens` returns 400 `inference_geo: Extra inputs are not permitted` and the same for `diagnostics` (`speed` + its beta and system messages → 200). `count_tokens/2` already drops `"stream"` / `"max_tokens"` from a `Request`. In `test/messages_test.exs`, insert directly after the test "count_tokens/2 merges a request's declared betas" (i.e. replace the unique text

```elixir
      assert {:ok, %{"input_tokens" => 5}} = Claudio.Messages.count_tokens(client, request)
    end
  end

  defp unique_model(suffix) do
```

with)

```elixir
      assert {:ok, %{"input_tokens" => 5}} = Claudio.Messages.count_tokens(client, request)
    end

    test "count_tokens/2 strips fields the count endpoint rejects (inference_geo, diagnostics)",
         %{client: client, bypass: bypass} do
      Bypass.expect_once(bypass, "POST", "/messages/count_tokens", fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        payload = Jason.decode!(body)

        status =
          if Map.has_key?(payload, "inference_geo") or Map.has_key?(payload, "diagnostics"),
            do: 400,
            else: 200

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(status, Jason.encode!(%{"input_tokens" => 5, "speed" => payload["speed"]}))
      end)

      request =
        Request.new("claude-opus-5-5")
        |> Request.add_message(:user, "hi")
        |> Request.set_speed(:fast)
        |> Request.set_inference_geo(:us)
        |> Request.enable_cache_diagnostics()

      assert {:ok, %{"input_tokens" => 5, "speed" => "fast"}} =
               Claudio.Messages.count_tokens(client, request)
    end
  end

  defp unique_model(suffix) do
```

Run: `mix test test/messages_test.exs 2>&1 | tail -15`
Expected: FAIL — the new test gets `{:error, %Claudio.APIError{...}}` (the handler answers 400 because both keys are present), not `{:ok, ...}`.

- [ ] **Step 7: Implement** — in `lib/claudio/messages.ex` `count_tokens/2` (Request clause), replace

```elixir
      |> Map.delete("stream")
      |> Map.delete("max_tokens")
```

with

```elixir
      |> Map.delete("stream")
      |> Map.delete("max_tokens")
      # The count endpoint rejects these (400 "Extra inputs are not permitted", probed 2026-09-25).
      |> Map.delete("inference_geo")
      |> Map.delete("diagnostics")
```

Run: `mix test test/messages_test.exs 2>&1 | tail -3`
Expected: PASS — `0 failures`.

- [ ] **Step 8: Gates + commit**

```bash
mix format && mix compile --warnings-as-errors
git add lib/claudio/messages.ex
git add test/messages_test.exs
git commit -m "fix(messages): count_tokens drops inference_geo and diagnostics"
```

---

### Task 3: `Response.usage` keeps every field

**Files:**
- Modify: `lib/claudio/messages/response.ex` — `@type usage` (~90-96), the three concrete `parse_usage/1` clauses (~453-483; the fallthrough `parse_usage(other)` stays)
- Test: `test/response_test.exs`

**Interfaces:**
- Consumes: nothing new.
- Produces: `Response.usage` always has atom keys `:input_tokens`, `:output_tokens`, `:cache_creation_input_tokens`, `:cache_read_input_tokens`, `:output_tokens_details`, `:cache_creation`, `:service_tier`, `:inference_geo`, `:speed` (values raw, `nil` if absent); every other field under its original key. S12b will add `:iterations` to the same list.

- [ ] **Step 1: Write the failing tests** — append inside `Claudio.Messages.ResponseTest`:

```elixir
  describe "from_map/1 usage keeps every field" do
    test "new documented fields become atom keys (string-keyed input)" do
      usage =
        Response.from_map(%{
          "content" => [],
          "usage" => %{
            "input_tokens" => 10,
            "output_tokens" => 5,
            "cache_creation" => %{"ephemeral_5m_input_tokens" => 0},
            "service_tier" => "standard",
            "inference_geo" => "us",
            "speed" => "fast"
          }
        }).usage

      assert usage.cache_creation == %{"ephemeral_5m_input_tokens" => 0}
      assert usage.service_tier == "standard"
      assert usage.inference_geo == "us"
      assert usage.speed == "fast"
    end

    test "atom-keyed input works too" do
      usage =
        Response.from_map(%{
          content: [],
          usage: %{input_tokens: 1, output_tokens: 2, inference_geo: "global"}
        }).usage

      assert usage.inference_geo == "global"
      assert usage.speed == nil
    end

    test "unknown fields survive under their original key" do
      string_keyed =
        Response.from_map(%{
          "content" => [],
          "usage" => %{"input_tokens" => 1, "output_tokens" => 2, "iterations" => [%{"type" => "message"}]}
        }).usage

      assert string_keyed["iterations"] == [%{"type" => "message"}]

      atom_keyed =
        Response.from_map(%{content: [], usage: %{input_tokens: 1, output_tokens: 2, future_field: 7}}).usage

      assert atom_keyed[:future_field] == 7
    end

    test "a documented field under both key styles yields one atom key, atom value wins" do
      usage =
        Response.from_map(%{
          content: [],
          usage: %{:input_tokens => 1, :output_tokens => 2, :speed => "fast", "speed" => "standard"}
        }).usage

      assert usage.speed == "fast"
      refute Map.has_key?(usage, "speed")
    end

    test "nil usage has the new keys as nil" do
      usage = Response.from_map(%{"content" => []}).usage

      assert usage.input_tokens == 0
      assert usage.output_tokens == 0

      for key <- [:cache_creation, :service_tier, :inference_geo, :speed] do
        assert Map.fetch!(usage, key) == nil
      end
    end
  end
```

- [ ] **Step 2: Run to verify they fail**

Run: `mix test test/response_test.exs 2>&1 | tail -20`
Expected: FAIL — `KeyError` (e.g. "key :cache_creation not found", "key :inference_geo not found") in the new tests; the "unknown fields" test fails with `nil` for `string_keyed["iterations"]`.

- [ ] **Step 3: Implement** — in `lib/claudio/messages/response.ex`:

(a) Replace `@type usage` with (in a map type the `optional(...) =>` entry must come **before** the keyword-style keys):

```elixir
  @typedoc """
  Token usage. Documented fields are atom keys (`nil` when the API did not send
  them); any other field the API returns is kept under the key it arrived with.
  """
  @type usage :: %{
          optional(atom() | String.t()) => term(),
          input_tokens: integer(),
          output_tokens: integer(),
          cache_creation_input_tokens: integer() | nil,
          cache_read_input_tokens: integer() | nil,
          output_tokens_details: map() | nil,
          cache_creation: map() | nil,
          service_tier: String.t() | nil,
          inference_geo: String.t() | nil,
          speed: String.t() | nil
        }
```

(b) Replace the three concrete clauses — from `  defp parse_usage(%{input_tokens: input, output_tokens: output} = usage) do` through the end of `  defp parse_usage(nil) do … end` — with (keep `defp parse_usage(other), do: other` after it):

```elixir
  # Documented usage fields become atom keys; every other field keeps the key it
  # arrived with, so fields Claudio does not know about yet are not dropped.
  @usage_keys [
    :input_tokens,
    :output_tokens,
    :cache_creation_input_tokens,
    :cache_read_input_tokens,
    :output_tokens_details,
    :cache_creation,
    :service_tier,
    :inference_geo,
    :speed
  ]
  @usage_string_keys Enum.map(@usage_keys, &Atom.to_string/1)

  defp parse_usage(%{input_tokens: _, output_tokens: _} = usage), do: normalize_usage(usage)
  defp parse_usage(%{"input_tokens" => _, "output_tokens" => _} = usage), do: normalize_usage(usage)

  defp parse_usage(nil) do
    @usage_keys
    |> Map.new(&{&1, nil})
    |> Map.merge(%{input_tokens: 0, output_tokens: 0})
  end
```

and add directly after `defp parse_usage(other), do: other`:

```elixir
  defp normalize_usage(usage) do
    known = Map.new(@usage_keys, &{&1, usage_value(usage, &1)})

    usage
    |> Map.drop(@usage_keys ++ @usage_string_keys)
    |> Map.merge(known)
  end

  # Atom key wins when a field is present under both key styles.
  defp usage_value(usage, key) do
    case Map.fetch(usage, key) do
      {:ok, value} -> value
      :error -> Map.get(usage, Atom.to_string(key))
    end
  end
```

(c) Update the one exact-match assertion, `test/response_test.exs:26` ("parses basic response with string keys"), to the new shape:

```elixir
      assert response.usage == %{
               input_tokens: 10,
               output_tokens: 5,
               cache_creation_input_tokens: nil,
               cache_read_input_tokens: nil,
               output_tokens_details: nil,
               cache_creation: nil,
               service_tier: nil,
               inference_geo: nil,
               speed: nil
             }
```

- [ ] **Step 4: Run to verify they pass** — targeted, then the full suite (other tests read usage)

Run: `mix test test/response_test.exs 2>&1 | tail -3` then `mix test 2>&1 | tail -3`
Expected: PASS — `0 failures` both.

- [ ] **Step 5: Gates + commit**

```bash
mix format && mix compile --warnings-as-errors   # plan code is not pre-formatted; formatter owns layout
git add lib/claudio/messages/response.ex
git add test/response_test.exs
git commit -m "feat(response): usage keeps unknown fields; new documented usage keys"
```

---

### Task 4: `Response.diagnostics`

**Files:**
- Modify: `lib/claudio/messages/response.ex` — `@type t` (~98-108), `defstruct` (~110-120), `from_map/1` (~126-138)
- Test: `test/response_test.exs`, `test/messages/stream_test.exs`

**Interfaces:**
- Consumes: `Stream.build_final_message/1` (unchanged; keeps `message_start`'s `diagnostics`, spec F10).
- Produces: `Response` field `diagnostics :: map() | nil` (raw, keys as received).

- [ ] **Step 1: Write the failing tests**

Append inside `Claudio.Messages.ResponseTest`:

```elixir
  describe "from_map/1 diagnostics" do
    @miss %{
      "cache_miss_reason" => %{"type" => "system_changed", "cache_missed_input_tokens" => 41_850}
    }

    test "kept raw, string keys" do
      assert Response.from_map(%{"content" => [], "diagnostics" => @miss}).diagnostics == @miss
    end

    test "atom keys" do
      assert Response.from_map(%{content: [], diagnostics: @miss}).diagnostics == @miss
    end

    test "nil when absent or null" do
      assert Response.from_map(%{"content" => []}).diagnostics == nil
      assert Response.from_map(%{"content" => [], "diagnostics" => nil}).diagnostics == nil
    end
  end
```

Append inside `Claudio.Messages.StreamTest`:

```elixir
  describe "diagnostics through build_final_message/1 → Response.from_map/1" do
    test "diagnostics on message_start survive into the parsed Response" do
      sse = [
        ~s(event: message_start),
        ~s(data: {"type":"message_start","message":{"id":"msg_1","type":"message","role":"assistant","content":[],"model":"claude-opus-5-5","diagnostics":{"cache_miss_reason":null},"usage":{"input_tokens":5,"output_tokens":0}}}),
        "",
        ~s(event: message_delta),
        ~s(data: {"type":"message_delta","delta":{"stop_reason":"end_turn"},"usage":{"output_tokens":3}}),
        "",
        ~s(event: message_stop),
        ~s(data: {"type":"message_stop"}),
        ""
      ]

      {:ok, message} =
        [Enum.join(sse, "\n") <> "\n"]
        |> ClaudioStream.parse_events()
        |> ClaudioStream.build_final_message()

      assert Claudio.Messages.Response.from_map(message).diagnostics == %{"cache_miss_reason" => nil}
    end
  end
```

- [ ] **Step 2: Run to verify they fail**

Run: `mix test test/response_test.exs test/messages/stream_test.exs 2>&1 | tail -20`
Expected: FAIL — `KeyError` "key :diagnostics not found" in the three response tests and the stream test (4 failures). The "nil when absent" test fails the same way (the struct has no such field yet).

- [ ] **Step 3: Implement** — in `lib/claudio/messages/response.ex`:

(a) `@type t` — replace

```elixir
          stop_details: map() | nil,
          usage: usage()
        }
```

with

```elixir
          stop_details: map() | nil,
          diagnostics: map() | nil,
          usage: usage()
        }
```

(b) `defstruct` — replace

```elixir
    :stop_details,
    :usage
  ]
```

with

```elixir
    :stop_details,
    :diagnostics,
    :usage
  ]
```

(c) `from_map/1` — replace

```elixir
      stop_details: data[:stop_details] || data["stop_details"],
```

with

```elixir
      stop_details: data[:stop_details] || data["stop_details"],
      diagnostics: data[:diagnostics] || data["diagnostics"],
```

(d) In the moduledoc, replace

```
  `message_delta.delta` next to `stop_reason`; that location is unconfirmed in
  Anthropic's streaming docs.
  """
```

with

```
  `message_delta.delta` next to `stop_reason`; that location is unconfirmed in
  Anthropic's streaming docs.

  `diagnostics` is carried raw (see `Request.enable_cache_diagnostics/2`):
  `nil` when diagnostics were not requested, there was nothing to compare, or the
  comparison found no divergence; `%{"cache_miss_reason" => nil}` when the comparison
  was still pending (inconclusive — check the next turn); otherwise a reason map such
  as `%{"cache_miss_reason" => %{"type" => "system_changed", "cache_missed_input_tokens" => n}}`.

  `usage` keeps every field the API returns: documented fields are atom keys; any
  other field keeps the key it arrived with (so it may be a string key).
  """
```

- [ ] **Step 4: Run to verify they pass**

Run: `mix test test/response_test.exs test/messages/stream_test.exs 2>&1 | tail -3`
Expected: PASS — `0 failures`.

- [ ] **Step 5: Gates + commit**

```bash
mix format && mix compile --warnings-as-errors   # plan code is not pre-formatted; formatter owns layout
git add lib/claudio/messages/response.ex
git add test/response_test.exs
git add test/messages/stream_test.exs
git commit -m "feat(response): diagnostics field"
```

---

### Task 5: Live integration test + docs

**Files:**
- Create: `test/integration/request_surface_integration_test.exs`
- Modify: `CHANGELOG.md` (`## [Unreleased] — targets 0.7.0`), `CLAUDE.md` (Request builder ~94, Response ~130)

**Interfaces:**
- Consumes: Tasks 1-4 (`add_system_message/3`, `set_inference_geo/2`, `enable_cache_diagnostics/2`, usage keys, `diagnostics`), `Claudio.IntegrationHelper.skip_if_no_api_key/0` / `create_client/0`.
- Produces: nothing consumed later.

- [ ] **Step 1: Write the integration test** — create `test/integration/request_surface_integration_test.exs`:

```elixir
Code.require_file("../integration/integration_helper.exs", __DIR__)

defmodule Claudio.RequestSurfaceIntegrationTest do
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

  test "system messages (effort-only + clear_at), inference_geo :us, cache diagnostics", %{
    client: client
  } do
    request =
      Request.new("claude-opus-5-5")
      |> Request.add_system_message([], effort: :low)
      |> Request.add_message(:user, "Name a primary color.")
      |> Request.add_system_message("Answer in one word.", clear_at: :next_user_message)
      |> Request.set_max_tokens(256)
      |> Request.set_inference_geo(:us)
      |> Request.enable_cache_diagnostics()

    assert {:ok, %Response{} = response} = Claudio.Messages.create(client, request)
    assert response.usage.inference_geo == "us"
    assert is_binary(response.usage.service_tier)
    assert response.stop_reason in [:end_turn, :max_tokens]
  end
end
```

(This exact request shape was live-probed on 2026-09-25: HTTP 200, `inference_geo: "us"`, `service_tier: "standard"`.)

- [ ] **Step 2: Run it**

Run: `mix test test/integration/request_surface_integration_test.exs --include integration 2>&1 | tail -5`
Expected: PASS (`1 test, 0 failures`) when `ANTHROPIC_API_KEY` is set. When unset, ExUnit reports `1 test, 0 failures, 1 invalid` (the shared `setup_all` returns `{:skip, _}`, which ExUnit treats as an invalid setup) — record **DID NOT RUN**, never "passed". A failure here is data about the API: stop and report the raw error, do not loosen the assertions.

- [ ] **Step 3: CHANGELOG** — under `## [Unreleased] — targets 0.7.0`:

Append to the end of the `[Unreleased]` `### Changed` section (the first `### Changed` in the file; it ends just before the first `### Added`):

```markdown
- `Response.usage` keeps every field the API returns: documented fields are atom keys
  (new: `cache_creation`, `service_tier`, `inference_geo`, `speed`); any other field is kept
  under the key it arrived with instead of being dropped.
- `Claudio.Messages.count_tokens/2` (Request form) also drops `inference_geo` and `diagnostics`,
  which the count endpoint rejects.
```

Append to the end of the `[Unreleased]` `### Added` section (the first `### Added`; it ends just before `### Docs`):

```markdown
- **5.x request surface** (`Claudio.Messages.Request`), no per-model or placement validation:
  - `add_system_message/3` — mid-conversation `role: "system"` messages (GA); `clear_at:`
    declares `mid-conversation-system-clear-at-2026-08-21`, `effort:` (per-message effort)
    declares `mid-conversation-output-config-2026-07-01`.
  - `set_speed/2` (`:fast` / `:standard`, always declares `fast-mode-2026-02-01`),
    `set_inference_geo/2` (`:global` / `:us`, GA), `enable_cache_diagnostics/2` (GA).
- `Response.diagnostics` (raw cache-diagnostics map).
```

- [ ] **Step 4: CLAUDE.md** — two insertions:

After the line starting `- **Thinking & effort** (`, insert:

```markdown
- **5.x request surface** (`add_system_message/3` — mid-conversation `role: "system"` messages, GA; `clear_at:` declares `mid-conversation-system-clear-at-2026-08-21`, `effort:` declares `mid-conversation-output-config-2026-07-01`. `set_speed/2` always declares `fast-mode-2026-02-01`; `set_inference_geo/2` and `enable_cache_diagnostics/2` are GA. Placement rules are left to the API.)
```

After the line starting `- **\`usage.output_tokens_details\`**`, insert:

```markdown
- **`usage` keeps every field** — documented fields are atom keys (incl. `cache_creation`, `service_tier`, `inference_geo`, `speed`); unknown fields keep the key they arrived with
- **`diagnostics`** — raw cache-diagnostics map (`cache_miss_reason`), `nil` unless requested via `enable_cache_diagnostics/2`
```

- [ ] **Step 5: Full verification, then commit**

Run: `mix format --check-formatted && mix compile --warnings-as-errors && mix test 2>&1 | tail -3`
Expected: format and compile clean; `mix test` → `0 failures` (integration excluded).

```bash
git add test/integration/request_surface_integration_test.exs
git add CHANGELOG.md
git add CLAUDE.md
git commit -m "test(integration): S12a request surface; docs"
```

---

## Spec coverage (self-review)

| Spec section | Task |
|---|---|
| §1 `add_system_message/3` (content, `clear_at`, `effort`, betas, API-universal raises, no placement checks) | 1 |
| §2 `set_speed/2`, `set_inference_geo/2`, `enable_cache_diagnostics/2`, struct fields, `to_map/1` | 2 |
| §3 usage keeps every field (`@usage_keys`, atom wins, unknown kept, `nil` clause, type) | 3 |
| §4 `Response.diagnostics` (+ stream) | 4 |
| §5 docs (CHANGELOG, CLAUDE.md; roadmap already committed with the specs) | 5 |
| Testing → integration (`claude-opus-5-5`, combined system messages, `inference_geo`, diagnostics) | 5 |
