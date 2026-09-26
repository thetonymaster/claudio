# S12b Refusal Fallbacks Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let callers request server-side refusal fallbacks (`Request.set_fallbacks/2`), type the `fallback` content block and `usage.iterations`, and make `Response.to_assistant_content/1` apply the API's continuation rules so a streamed mid-output fallback can be replayed without a 400.

**Architecture:** One new request setter + struct field emitted by `to_map/1` (declares `server-side-fallback-2026-07-01`); `count_tokens` strips the field. `Response` gains a typed `:fallback` block that keeps its original map under `raw:` (re-emitted verbatim), two readers (`fallbacks/1`, `served_by/1`), and `:iterations` in `@usage_keys`. `to_assistant_content/1` keeps its one-to-one `block_to_api/1` mapping, then runs a private pure echo filter that is a no-op unless a `fallback` block sits after index 0.

**Tech Stack:** Elixir ≥ 1.15, ExUnit (async), Bypass, Jason.

**Spec:** `docs/superpowers/specs/2026-09-25-s12b-refusal-fallbacks-design.md`

## Global Constraints

- Model-agnostic: no per-model checks. Local `ArgumentError` only for shapes that can't be meant (`set_fallbacks/2`: not `:default`/list, empty list, entry neither string nor map). The three-entry cap, distinctness, `allowed_fallback_models` and Batches use are left to the API.
- Enumerated values are **atoms only** (`:default`); errors name the function, the allowed shapes and `inspect/1` of the value received.
- Beta string, verbatim: `server-side-fallback-2026-07-01` (every `set_fallbacks/2`). The integration test additionally needs `mcp-client-2025-11-20` for `mcp_tool_use` in history.
- Echo rules (spec §3, from RF's table): before the **last** `fallback` block drop `thinking`, `redacted_thinking`, `connector_text`, `tool_use`; keep `server_tool_use` / `mcp_tool_use` only when some block's `tool_use_id` equals their `id`; keep everything else. Blocks at/after the last `fallback` are kept. No `fallback`, or last `fallback` at index 0 → output unchanged.
- Replay beta (spec §1, F15): `Request.add_message/3` declares `server-side-fallback-2026-07-01` when its list content holds a block typed `"fallback"` / `:fallback` (string or atom key).
- Tool readers (spec §2): `Response.get_tool_uses/1` and `Tools.extract_tool_uses/1` return only `tool_use` blocks at or after the last `fallback` block, via the `@doc false` helper `Response.since_last_fallback/1`.
- Existing public signatures unchanged. No `@version` bump; CHANGELOG under `## [Unreleased] — targets 0.7.0`.
- Commits: add files individually (`git add .` forbidden); **no AI attribution lines** (no Co-Authored-By, no "Generated with").
- Gates before each commit: `mix format` (plan code is not pre-formatted) and `mix compile --warnings-as-errors`; Task 6 ends with the strict `mix format --check-formatted` and the full suite.

## Review Focus

1. A response with **no** `fallback` block, or with it at index 0 (the normal non-streaming shape), must give `to_assistant_content/1` output identical to today's — including thinking + tool_use blocks, which the filter would drop if it misfired. Pinned in Task 4.
2. Streamed mid-output fallback: `model` names the declining model, so `served_by/1` must read the last `fallback` block's `to.model` — pinned in Task 2 (stream test + reader tests).
3. Two `fallback` blocks: rules apply only before the **last** one; a `thinking` block between the two is dropped, one after the last is kept. Pinned in Task 4.
4. Atom-keyed input (`Response.from_map/1` with atom keys, and unknown atom-keyed blocks passed through) must be filtered by the same rules as string-keyed input. Pinned in Task 4.
5. Calling `set_fallbacks/2` twice replaces the value and declares the beta once. Pinned in Task 1.

## Branching

Implementation branch `feat/s12b-refusal-fallbacks`, cut from `docs/s12b-fallbacks-spec` (spec + plan).

---

### Task 1: `Request.set_fallbacks/2` and the `count_tokens` strip

**Files:**
- Modify: `lib/claudio/messages/request.ex` — `@type t` (~line 44), `defstruct` (~line 70) plus `@fallback_beta` directly after it, new function directly **after** `enable_cache_diagnostics/2` (~line 975), `to_map/1` (~line 1232)
- Modify: `lib/claudio/messages.ex:218-220` — `count_tokens/2` Request clause
- Test: `test/request_test.exs` (new `describe` after `describe "set_inference_geo/2"`), `test/messages_test.exs:566-598`

**Interfaces:**
- Consumes: `add_beta/2`, `required_betas/1`, `maybe_put/3` (existing, `request.ex`).
- Produces: `Request.set_fallbacks(t(), :default | [String.t() | map(), ...]) :: t()`; struct field `fallbacks :: String.t() | [map()] | nil`; `to_map/1` emits `"fallbacks"`. Task 6 uses `set_fallbacks(:default)`.

- [ ] **Step 1: Write the failing request tests**

Add to `test/request_test.exs`, after the `describe "set_inference_geo/2"` block:

```elixir
  describe "set_fallbacks/2" do
    test ":default is emitted as \"default\" and declares the fallback beta" do
      request = Request.new("claude-opus-5-5") |> Request.set_fallbacks(:default)

      assert Request.to_map(request)["fallbacks"] == "default"
      assert Request.required_betas(request) == ["server-side-fallback-2026-07-01"]
    end

    test "model strings become model entries, maps pass through, order kept" do
      override = %{"model" => "claude-opus-5", "max_tokens" => 512}

      request =
        Request.new("claude-opus-5-5")
        |> Request.set_fallbacks(["claude-opus-4-8", override])

      assert Request.to_map(request)["fallbacks"] == [
               %{"model" => "claude-opus-4-8"},
               override
             ]
    end

    test "calling twice replaces the value and declares the beta once" do
      request =
        Request.new("claude-opus-5-5")
        |> Request.set_fallbacks(["claude-opus-4-8"])
        |> Request.set_fallbacks(:default)

      assert Request.to_map(request)["fallbacks"] == "default"
      assert Request.required_betas(request) == ["server-side-fallback-2026-07-01"]
    end

    test "four entries are sent as-is (the three-entry cap is the API's)" do
      models = ["a", "b", "c", "d"]
      request = Request.new("m") |> Request.set_fallbacks(models)

      assert length(Request.to_map(request)["fallbacks"]) == 4
    end

    test "without set_fallbacks/2 there is no fallbacks key and no beta" do
      request = Request.new("m") |> Request.add_message(:user, "hi")

      refute Map.has_key?(Request.to_map(request), "fallbacks")
      assert Request.required_betas(request) == []
    end

    test "shapes other than :default or a non-empty list raise" do
      for bad <- ["default", :auto, nil, [], %{"model" => "x"}] do
        assert_raise ArgumentError,
                     ~r/set_fallbacks\/2 fallbacks must be :default or a non-empty list of model strings or maps; got/,
                     fn -> Request.new("m") |> Request.set_fallbacks(bad) end
      end
    end

    test "an entry that is neither a string nor a map raises" do
      for bad <- [:"claude-opus-4-8", nil, 1] do
        assert_raise ArgumentError,
                     ~r/set_fallbacks\/2 each entry must be a model string or a map; got/,
                     fn -> Request.new("m") |> Request.set_fallbacks(["ok", bad]) end
      end
    end
  end
```

- [ ] **Step 2: Run them to verify they fail**

Run: `mix test test/request_test.exs 2>&1 | tail -15`
Expected: FAIL — `UndefinedFunctionError` / "function Claudio.Messages.Request.set_fallbacks/2 is undefined" in the new tests; every pre-existing test still passes.

- [ ] **Step 3: Implement**

In `@type t`, after `diagnostics: map() | nil`, add (fix the preceding comma):

```elixir
          diagnostics: map() | nil,
          fallbacks: String.t() | [map()] | nil
```

In `defstruct`, after `diagnostics: nil`:

```elixir
    diagnostics: nil,
    fallbacks: nil
```

Directly after the closing `]` of `defstruct` (module level — Task 5's `add_message/3`, near the top of the module, reads it too, and an attribute is only readable by code that follows it):

```elixir
  # Server-side refusal fallbacks; also needed to replay a `fallback` block (probed 2026-09-25).
  @fallback_beta "server-side-fallback-2026-07-01"
```

Directly after `enable_cache_diagnostics/2`:

```elixir
  @doc """
  Sets `fallbacks` — server-side retry of a refused request on another model (beta;
  declares `server-side-fallback-2026-07-01`).

    * `:default` — the API picks the recommended fallback for the refusal category.
    * a non-empty list — tried in order; a model string becomes `%{"model" => model}`,
      a map is sent unchanged (it may override `max_tokens`, `thinking`,
      `output_config` and `speed` for that attempt).

  The API allows up to three entries, each distinct and listed in the requested
  model's `allowed_fallback_models`; those rules are left to it. Not supported by the
  Message Batches API (the item errors). Not sent by `Claudio.Messages.count_tokens/2`
  when given a `Request` (that endpoint rejects it). See `Claudio.Messages.Response`
  for the `fallback` block, `Response.served_by/1` and `usage.iterations`.
  """
  @spec set_fallbacks(t(), :default | [String.t() | map(), ...]) :: t()
  def set_fallbacks(%__MODULE__{} = request, :default) do
    add_beta(%{request | fallbacks: "default"}, @fallback_beta)
  end

  def set_fallbacks(%__MODULE__{} = request, [_ | _] = entries) do
    add_beta(%{request | fallbacks: Enum.map(entries, &fallback_entry/1)}, @fallback_beta)
  end

  def set_fallbacks(%__MODULE__{}, other) do
    raise ArgumentError,
          "Request.set_fallbacks/2 fallbacks must be :default or a non-empty list of " <>
            "model strings or maps; got #{inspect(other)}"
  end

  defp fallback_entry(model) when is_binary(model), do: %{"model" => model}
  defp fallback_entry(entry) when is_map(entry), do: entry

  defp fallback_entry(entry) do
    raise ArgumentError,
          "Request.set_fallbacks/2 each entry must be a model string or a map; " <>
            "got #{inspect(entry)}"
  end
```

In `to_map/1`, after `|> maybe_put("diagnostics", request.diagnostics)`:

```elixir
    |> maybe_put("fallbacks", request.fallbacks)
```

- [ ] **Step 4: Run the request tests to verify they pass**

Run: `mix test test/request_test.exs 2>&1 | tail -5`
Expected: PASS, `0 failures`.

- [ ] **Step 5: Extend the `count_tokens` strip test (failing first)**

In `test/messages_test.exs`, the test at ~566 (`"count_tokens/2 strips fields the count endpoint rejects (inference_geo, diagnostics)"`): rename it to `"count_tokens/2 strips fields the count endpoint rejects (inference_geo, diagnostics, fallbacks)"`, add `Map.has_key?(payload, "fallbacks") or` to the 400 condition, and add `|> Request.set_fallbacks(:default)` to the request pipeline:

```elixir
        status =
          if Map.has_key?(payload, "inference_geo") or Map.has_key?(payload, "diagnostics") or
               Map.has_key?(payload, "fallbacks") or
               not String.contains?(beta_header, "fast-mode-2026-02-01"),
             do: 400,
             else: 200
```

```elixir
      request =
        Request.new("claude-opus-5-5")
        |> Request.add_message(:user, "hi")
        |> Request.set_speed(:fast)
        |> Request.set_inference_geo(:us)
        |> Request.enable_cache_diagnostics()
        |> Request.set_fallbacks(:default)
```

Run: `mix test test/messages_test.exs 2>&1 | tail -15`
Expected: FAIL — that test gets `{:error, %Claudio.APIError{status_code: 400 ...}}` instead of `{:ok, ...}`.

- [ ] **Step 6: Strip `fallbacks` in `count_tokens/2`**

In `lib/claudio/messages.ex`, the Request clause (~218):

```elixir
      # The count endpoint rejects these (400 "Extra inputs are not permitted", probed 2026-09-25).
      |> Map.delete("inference_geo")
      |> Map.delete("diagnostics")
      |> Map.delete("fallbacks")
```

Run: `mix test test/messages_test.exs 2>&1 | tail -5`
Expected: PASS, `0 failures`.

- [ ] **Step 7: Gates and commit**

Run: `mix format && mix compile --warnings-as-errors && mix test 2>&1 | tail -3`
Expected: compile clean; `0 failures`.

```bash
git add lib/claudio/messages/request.ex
git add lib/claudio/messages.ex
git add test/request_test.exs
git add test/messages_test.exs
git commit -m "feat(request): set_fallbacks/2 — server-side refusal fallbacks; count_tokens strips fallbacks"
```

---
### Task 2: Typed `fallback` block, `fallbacks/1`, `served_by/1`

**Files:**
- Modify: `lib/claudio/messages/response.ex` — `@type content_block` union (~31-40), new `@type fallback_block` after `web_search_tool_result_block` (~98), readers after `get_mcp_tool_uses/2` (~247), `parse_content_block/1` clauses before the catch-all `defp parse_content_block(block), do: block` (~402), `block_to_api/1` clause before the catch-all `defp block_to_api(block), do: block` (~465)
- Test: `test/response_test.exs` (new `describe` blocks at the end), `test/messages/stream_test.exs` (new `describe` at the end)

**Interfaces:**
- Consumes: nothing from Task 1.
- Produces: parsed block `%{type: :fallback, from: map() | nil, to: map() | nil, trigger: map() | nil, raw: map()}`; `block_to_api/1` returns `raw` for it; `Response.fallbacks(t()) :: [fallback_block()]`; `Response.served_by(t()) :: String.t() | nil`. Task 4's filter recognises the re-emitted block by its `"type"`/`:type` value `"fallback"`.

- [ ] **Step 1: Write the failing response tests**

Append to `test/response_test.exs`, before the final `end`:

```elixir
  # RF's documented example block (refusals-and-fallback, fetched 2026-09-25).
  @fallback_block %{
    "type" => "fallback",
    "from" => %{"model" => "claude-fable-5"},
    "to" => %{"model" => "claude-opus-4-8"}
  }

  describe "from_map/1 fallback blocks" do
    test "string-keyed block parses to a typed map that keeps the original" do
      [block] = Response.from_map(%{"content" => [@fallback_block]}).content

      assert block == %{
               type: :fallback,
               from: %{"model" => "claude-fable-5"},
               to: %{"model" => "claude-opus-4-8"},
               trigger: nil,
               raw: @fallback_block
             }
    end

    test "optional trigger is kept" do
      trigger = %{"type" => "refusal", "category" => "cyber"}

      [block] =
        Response.from_map(%{"content" => [Map.put(@fallback_block, "trigger", trigger)]}).content

      assert block.trigger == trigger
    end

    test "atom-keyed block parses too" do
      raw = %{type: "fallback", from: %{model: "a"}, to: %{model: "b"}}
      [block] = Response.from_map(%{content: [raw]}).content

      assert %{type: :fallback, from: %{model: "a"}, to: %{model: "b"}, raw: ^raw} = block
    end

    test "to_assistant_content/1 re-emits the original block, unknown sub-fields included" do
      raw = Map.put(@fallback_block, "future", %{"x" => 1})

      response =
        Response.from_map(%{
          "content" => [raw, %{"type" => "text", "text" => "Hi"}]
        })

      assert Response.to_assistant_content(response) == [
               raw,
               %{"type" => "text", "text" => "Hi"}
             ]
    end
  end

  describe "fallbacks/1" do
    test "returns [] without fallback blocks" do
      response = Response.from_map(%{"content" => [%{"type" => "text", "text" => "x"}]})
      assert Response.fallbacks(response) == []
    end

    test "returns every fallback block in content order" do
      second = %{
        "type" => "fallback",
        "from" => %{"model" => "claude-opus-4-8"},
        "to" => %{"model" => "claude-opus-5"}
      }

      response =
        Response.from_map(%{
          "content" => [
            @fallback_block,
            %{"type" => "text", "text" => "x"},
            second
          ]
        })

      assert [%{raw: @fallback_block}, %{raw: ^second}] = Response.fallbacks(response)
    end
  end

  describe "served_by/1" do
    test "is the top-level model when there is no fallback block" do
      response = Response.from_map(%{"model" => "claude-opus-5-5", "content" => []})
      assert Response.served_by(response) == "claude-opus-5-5"
    end

    test "is the last fallback block's to.model, even when model names the declining model" do
      second = %{
        "type" => "fallback",
        "from" => %{"model" => "claude-opus-4-8"},
        "to" => %{"model" => "claude-opus-5"}
      }

      response =
        Response.from_map(%{
          "model" => "claude-fable-5",
          "content" => [@fallback_block, second]
        })

      assert Response.served_by(response) == "claude-opus-5"
    end

    test "reads an atom-keyed to.model" do
      response =
        Response.from_map(%{
          model: "a",
          content: [%{type: "fallback", from: %{model: "a"}, to: %{model: "b"}}]
        })

      assert Response.served_by(response) == "b"
    end

    test "falls back to model when the block has no to.model" do
      response =
        Response.from_map(%{"model" => "m", "content" => [%{"type" => "fallback"}]})

      assert Response.served_by(response) == "m"
    end
  end
```

- [ ] **Step 2: Write the failing stream test**

Append to `test/messages/stream_test.exs`, before the final `end`:

```elixir
  describe "build_final_message/1 mid-output fallback" do
    # RF "Streaming": on a mid-output decline the fallback block is a
    # content_block_start/stop pair with no deltas; message_start named the
    # requested model, so the serving model is read from the block's to.model.
    test "the no-delta fallback block survives and parses into the Response" do
      sse = [
        ~s(event: message_start),
        ~s(data: {"type":"message_start","message":{"id":"m","type":"message","role":"assistant","content":[],"model":"claude-opus-5-5","usage":{"input_tokens":5,"output_tokens":1}}}),
        "",
        ~s(event: content_block_start),
        ~s(data: {"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}),
        "",
        ~s(event: content_block_delta),
        ~s(data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Part"}}),
        "",
        ~s(event: content_block_stop),
        ~s(data: {"type":"content_block_stop","index":0}),
        "",
        ~s(event: content_block_start),
        ~s(data: {"type":"content_block_start","index":1,"content_block":{"type":"fallback","from":{"model":"claude-opus-5-5"},"to":{"model":"claude-opus-4-8"}}}),
        "",
        ~s(event: content_block_stop),
        ~s(data: {"type":"content_block_stop","index":1}),
        "",
        ~s(event: content_block_start),
        ~s(data: {"type":"content_block_start","index":2,"content_block":{"type":"text","text":""}}),
        "",
        ~s(event: content_block_delta),
        ~s(data: {"type":"content_block_delta","index":2,"delta":{"type":"text_delta","text":"Hello"}}),
        "",
        ~s(event: content_block_stop),
        ~s(data: {"type":"content_block_stop","index":2}),
        "",
        ~s(event: message_delta),
        ~s(data: {"type":"message_delta","delta":{"stop_reason":"end_turn"},"usage":{"output_tokens":3,"iterations":[{"type":"message","model":"claude-opus-5-5","input_tokens":5,"output_tokens":1},{"type":"fallback_message","model":"claude-opus-4-8","input_tokens":7,"output_tokens":3}]}}),
        "",
        ~s(event: message_stop),
        ~s(data: {"type":"message_stop"}),
        ""
      ]

      {:ok, message} =
        [Enum.join(sse, "\n") <> "\n"]
        |> ClaudioStream.parse_events()
        |> ClaudioStream.build_final_message()

      # RF: the serving model is also in the final message_delta's usage.iterations.
      assert [%{"type" => "message"}, %{"type" => "fallback_message", "model" => "claude-opus-4-8"}] =
               message["usage"]["iterations"]

      response = Claudio.Messages.Response.from_map(message)

      assert [%{type: :text, text: "Part"}, %{type: :fallback}, %{type: :text, text: "Hello"}] =
               response.content

      assert response.model == "claude-opus-5-5"
      assert Claudio.Messages.Response.served_by(response) == "claude-opus-4-8"
    end
  end
```

- [ ] **Step 3: Run them to verify they fail**

Run: `mix test test/response_test.exs test/messages/stream_test.exs 2>&1 | tail -20`
Expected: FAIL — the `from_map/1 fallback blocks` parse tests fail on the match (block is still the raw string-keyed map), except "to_assistant_content/1 re-emits the original block, unknown sub-fields included", which already PASSES (an unknown block passes through both catch-alls; it pins that the typed block keeps doing so); `fallbacks/1` / `served_by/1` tests with `UndefinedFunctionError`, the stream test with a `MatchError` on `%{type: :fallback}` (or `UndefinedFunctionError` for `served_by/1`). If the stream test fails **before** reaching `from_map/1` (e.g. the fallback block is missing from `message["content"]`), stop: `build_final_message/1` does not handle no-delta blocks as the spec assumes (spec §4) — report the raw failure before changing stream code.

- [ ] **Step 4: Implement**

`@type content_block` union — add a line after `| web_search_tool_result_block()`:

```elixir
          | web_search_tool_result_block()
          | fallback_block()
```

After `@type web_search_tool_result_block`:

```elixir
  @typedoc """
  A server-side fallback handoff (`Request.set_fallbacks/2`). `raw` is the block as
  received; `Response.to_assistant_content/1` re-emits it unchanged.
  """
  @type fallback_block :: %{
          type: :fallback,
          from: map() | nil,
          to: map() | nil,
          trigger: map() | nil,
          raw: map()
        }
```

After `get_mcp_tool_uses/2`:

```elixir
  @doc """
  Returns every `fallback` block, in content order (`[]` when the request was not
  retried on a fallback model). One block marks each handoff between models.
  """
  @spec fallbacks(t()) :: [fallback_block()]
  def fallbacks(%__MODULE__{content: content}) do
    for %{type: :fallback} = block <- content, do: block
  end

  @doc """
  Returns the model that produced the returned message: the last `fallback` block's
  `to.model`, else `model`.

  Not simply `model`: a streamed response that fell back mid-output keeps the
  requested (declining) model from `message_start` in `model`. When every model in
  the chain declined (`stop_reason: :refusal`), it names the model whose refusal was
  returned.
  """
  @spec served_by(t()) :: String.t() | nil
  def served_by(%__MODULE__{model: model} = response) do
    case List.last(fallbacks(response)) do
      %{to: to} when is_map(to) -> Map.get(to, "model") || Map.get(to, :model) || model
      _ -> model
    end
  end
```

Before the catch-all `defp parse_content_block(block), do: block`:

```elixir
  defp parse_content_block(%{type: "fallback"} = block) do
    fallback_block(block, block[:from], block[:to], block[:trigger])
  end

  defp parse_content_block(%{"type" => "fallback"} = block) do
    fallback_block(block, block["from"], block["to"], block["trigger"])
  end
```

After `defp text_block(text, citations), ...`:

```elixir
  defp fallback_block(raw, from, to, trigger) do
    %{type: :fallback, from: from, to: to, trigger: trigger, raw: raw}
  end
```

Before the catch-all `defp block_to_api(block), do: block`:

```elixir
  defp block_to_api(%{type: :fallback, raw: raw}), do: raw
```

- [ ] **Step 5: Run to verify they pass**

Run: `mix test test/response_test.exs test/messages/stream_test.exs 2>&1 | tail -5`
Expected: PASS, `0 failures`.

- [ ] **Step 6: Gates and commit**

Run: `mix format && mix compile --warnings-as-errors && mix test 2>&1 | tail -3`
Expected: compile clean; `0 failures`.

```bash
git add lib/claudio/messages/response.ex
git add test/response_test.exs
git add test/messages/stream_test.exs
git commit -m "feat(response): typed fallback block, fallbacks/1, served_by/1"
```

---
### Task 3: `usage.iterations` as a documented key; `stop_details` docs

**Files:**
- Modify: `lib/claudio/messages/response.ex` — moduledoc (~1-19), `@typedoc`/`@type usage` (~100-117), `@usage_keys` (~478-488)
- Test: `test/response_test.exs` — exact usage assertion (~26-36), `"unknown fields survive under their original key"` (~747-766), `"nil usage has the new keys as nil"` (~783-793), new tests in `describe "from_map/1 usage keeps every field"`; `test/messages/stream_test.exs` — Task 2's mid-output fallback test

**Interfaces:**
- Consumes: nothing from Tasks 1-2.
- Produces: `usage.iterations :: [map()] | nil` (entries stay raw, string-keyed as the API sends them). Task 6's integration test reads it.

- [ ] **Step 1: Update the tests that pin today's behaviour (failing first)**

1. Exact assertion (~26): add `iterations: nil` as the last key:

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
               speed: nil,
               iterations: nil
             }
```

2. `"unknown fields survive under their original key"` uses `"iterations"` as its example of an **unknown** field; that stops being true. Replace the string-keyed half with `"future_field"`:

```elixir
      string_keyed =
        Response.from_map(%{
          "content" => [],
          "usage" => %{
            "input_tokens" => 1,
            "output_tokens" => 2,
            "future_field" => [%{"type" => "message"}]
          }
        }).usage

      assert string_keyed["future_field"] == [%{"type" => "message"}]
```

3. `"nil usage has the new keys as nil"`: extend the key list to `[:cache_creation, :service_tier, :inference_geo, :speed, :iterations]`.

4. Add inside `describe "from_map/1 usage keeps every field"`:

```elixir
    test "iterations becomes an atom key with raw entries (RF example)" do
      iterations = [
        %{
          "type" => "message",
          "model" => "claude-fable-5",
          "input_tokens" => 535,
          "output_tokens" => 0,
          "cache_read_input_tokens" => 0,
          "cache_creation_input_tokens" => 0
        },
        %{
          "type" => "fallback_message",
          "model" => "claude-opus-4-8",
          "input_tokens" => 412,
          "output_tokens" => 264,
          "cache_read_input_tokens" => 0,
          "cache_creation_input_tokens" => 0
        }
      ]

      usage =
        Response.from_map(%{
          "content" => [],
          "usage" => %{"input_tokens" => 412, "output_tokens" => 264, "iterations" => iterations}
        }).usage

      assert usage.iterations == iterations
      refute Map.has_key?(usage, "iterations")
    end
```

5. In `test/messages/stream_test.exs`, Task 2's `"the no-delta fallback block survives and parses into the Response"`: after `assert Claudio.Messages.Response.served_by(response) == "claude-opus-4-8"` add

```elixir
      assert [_, %{"type" => "fallback_message"}] = response.usage.iterations
```

Run: `mix test test/response_test.exs test/messages/stream_test.exs 2>&1 | tail -15`
Expected: FAIL — the exact assertion (no `:iterations` key), the nil-usage test (`KeyError` on `:iterations`), the new iterations test and the stream test (`usage.iterations` → `KeyError`). The rewritten `future_field` test passes (behaviour unchanged for unknown keys).

- [ ] **Step 2: Implement**

`@usage_keys` — add `:iterations` after `:speed`:

```elixir
    :inference_geo,
    :speed,
    :iterations
  ]
```

`@type usage` — after `speed: String.t() | nil`:

```elixir
          speed: String.t() | nil,
          iterations: [map()] | nil
```

`@typedoc` for usage — append a sentence:

```elixir
  @typedoc """
  Token usage. Documented fields are atom keys (`nil` when the API did not send
  them); any other field the API returns is kept under the key it arrived with.
  A usage map missing `input_tokens` or `output_tokens` is returned as received.
  `iterations` (present when `fallbacks` was set) lists each attempt as the raw
  API map: `"type" => "message"` for a model that declined, `"fallback_message"`
  for the one that served; the top-level counts cover only the returned attempt.
  """
```

Moduledoc — replace the `stop_details` paragraph and add a fallback paragraph after the `diagnostics` one:

```elixir
  `stop_details` is the raw API map (`"type"`, `"category"`, `"explanation"`), set only
  when `stop_reason` is `:refusal`. With `Request.set_fallbacks/2` it can also carry
  `"recommended_model"` (a model to retry directly when the fallback attempt was
  skipped), `"fallback_credit_token"` and `"fallback_has_prefill_claim"`. For streamed
  responses it is read from `message_delta.delta` next to `stop_reason`; that location
  is unconfirmed in Anthropic's streaming docs.
```

```elixir
  With `Request.set_fallbacks/2`, a refused request may be retried on another model.
  Each handoff is a `:fallback` content block (`fallbacks/1`); `served_by/1` names the
  model that produced the message, and `usage.iterations` records every attempt.
```

- [ ] **Step 3: Run to verify they pass**

Run: `mix test test/response_test.exs test/messages/stream_test.exs 2>&1 | tail -5`
Expected: PASS, `0 failures`.

- [ ] **Step 4: Gates and commit**

Run: `mix format && mix compile --warnings-as-errors && mix test 2>&1 | tail -3`
Expected: compile clean; `0 failures`.

```bash
git add lib/claudio/messages/response.ex
git add test/response_test.exs
git add test/messages/stream_test.exs
git commit -m "feat(response): usage.iterations as a documented key; document fallback stop_details"
```

---
### Task 4: Continuation rules in `to_assistant_content/1`

**Files:**
- Modify: `lib/claudio/messages/response.ex` — `to_assistant_content/1` and its `@doc` (~249-264); new private helpers directly after the last `block_to_api/1` clause (~466)
- Test: `test/response_test.exs` (new `describe` at the end)

**Interfaces:**
- Consumes: Task 2's `block_to_api(%{type: :fallback, raw: raw})` → `raw` (string- or atom-keyed map whose type is `"fallback"`).
- Produces: `to_assistant_content(t()) :: [map()]` — same signature; output filtered per spec §3. Task 6's integration test replays it.

- [ ] **Step 1: Write the failing tests**

Append to `test/response_test.exs`, before the final `end`:

```elixir
  defp fb(from, to) do
    %{"type" => "fallback", "from" => %{"model" => from}, "to" => %{"model" => to}}
  end

  defp content(blocks), do: Response.from_map(%{"content" => blocks})

  describe "to_assistant_content/1 continuation rules after a fallback" do
    # RF "Continuing the conversation" (fetched 2026-09-25); mcp_tool_use follows the
    # server_tool_use pairing rule (spec §3, probes P12b/P13).
    test "no fallback block: unchanged, thinking and tool_use included" do
      blocks = [
        %{"type" => "thinking", "thinking" => "t", "signature" => "s"},
        %{"type" => "tool_use", "id" => "toolu_1", "name" => "x", "input" => %{}},
        %{"type" => "text", "text" => "a"}
      ]

      assert Response.to_assistant_content(content(blocks)) == blocks
    end

    test "fallback first (every non-streaming response): unchanged" do
      blocks = [
        fb("claude-fable-5", "claude-opus-4-8"),
        %{"type" => "thinking", "thinking" => "t", "signature" => "s"},
        %{"type" => "tool_use", "id" => "toolu_1", "name" => "x", "input" => %{}},
        %{"type" => "text", "text" => "a"}
      ]

      assert Response.to_assistant_content(content(blocks)) == blocks
    end

    test "mid-output fallback: drops and pairing apply before it, everything after is kept" do
      paired_srv = %{"type" => "server_tool_use", "id" => "srv_1", "name" => "web_search", "input" => %{}}
      srv_result = %{"type" => "web_search_tool_result", "tool_use_id" => "srv_1", "content" => []}
      unpaired_srv = %{"type" => "server_tool_use", "id" => "srv_2", "name" => "web_search", "input" => %{}}

      paired_mcp = %{
        "type" => "mcp_tool_use",
        "id" => "mcp_1",
        "name" => "x",
        "server_name" => "s",
        "input" => %{}
      }

      mcp_result = %{
        "type" => "mcp_tool_result",
        "tool_use_id" => "mcp_1",
        "server_name" => "s",
        "content" => [],
        "is_error" => false
      }

      unpaired_mcp = %{paired_mcp | "id" => "mcp_2"}
      unknown = %{"type" => "container_upload", "file_id" => "file_1"}
      fallback = fb("claude-opus-5-5", "claude-opus-4-8")
      after_tool_use = %{"type" => "tool_use", "id" => "toolu_9", "name" => "x", "input" => %{}}

      blocks = [
        %{"type" => "thinking", "thinking" => "t", "signature" => "s"},
        %{"type" => "redacted_thinking", "data" => "enc"},
        %{"type" => "connector_text", "text" => "narration"},
        %{"type" => "tool_use", "id" => "toolu_1", "name" => "x", "input" => %{}},
        paired_srv,
        srv_result,
        unpaired_srv,
        paired_mcp,
        mcp_result,
        unpaired_mcp,
        %{"type" => "text", "text" => "partial"},
        unknown,
        fallback,
        %{"type" => "thinking", "thinking" => "u", "signature" => "s2"},
        %{"type" => "text", "text" => "Hello"},
        after_tool_use
      ]

      assert Response.to_assistant_content(content(blocks)) == [
               paired_srv,
               srv_result,
               paired_mcp,
               mcp_result,
               %{"type" => "text", "text" => "partial"},
               unknown,
               fallback,
               %{"type" => "thinking", "thinking" => "u", "signature" => "s2"},
               %{"type" => "text", "text" => "Hello"},
               after_tool_use
             ]
    end

    test "a result after the fallback still pairs a server_tool_use before it" do
      srv = %{"type" => "server_tool_use", "id" => "srv_1", "name" => "web_fetch", "input" => %{}}
      result = %{"type" => "web_fetch_tool_result", "tool_use_id" => "srv_1", "content" => %{}}
      blocks = [%{"type" => "text", "text" => "a"}, srv, fb("a", "b"), result]

      assert Response.to_assistant_content(content(blocks)) == blocks
    end

    test "two fallback blocks: rules apply only before the last one" do
      first = fb("claude-opus-5-5", "claude-opus-4-8")
      last = fb("claude-opus-4-8", "claude-opus-5")

      blocks = [
        %{"type" => "text", "text" => "a"},
        first,
        %{"type" => "thinking", "thinking" => "t", "signature" => "s"},
        %{"type" => "text", "text" => "b"},
        last,
        %{"type" => "thinking", "thinking" => "u", "signature" => "s2"},
        %{"type" => "text", "text" => "c"}
      ]

      assert Response.to_assistant_content(content(blocks)) == [
               %{"type" => "text", "text" => "a"},
               first,
               %{"type" => "text", "text" => "b"},
               last,
               %{"type" => "thinking", "thinking" => "u", "signature" => "s2"},
               %{"type" => "text", "text" => "c"}
             ]
    end

    test "non-map entries pass through without crashing the filter" do
      blocks = ["stray", %{"type" => "text", "text" => "a"}, fb("a", "b"), %{"type" => "text", "text" => "b"}]

      assert Response.to_assistant_content(content(blocks)) == blocks
    end

    test "atom-keyed input follows the same rules" do
      fallback = %{type: "fallback", from: %{model: "a"}, to: %{model: "b"}}
      connector = %{type: "connector_text", text: "narration"}
      srv = %{type: "server_tool_use", id: "srv_1", name: "web_fetch", input: %{}}
      result = %{type: "web_fetch_tool_result", tool_use_id: "srv_1", content: %{}}

      response =
        Response.from_map(%{
          content: [connector, srv, result, %{type: "text", text: "p"}, fallback]
        })

      assert Response.to_assistant_content(response) == [
               %{"type" => "server_tool_use", "id" => "srv_1", "name" => "web_fetch", "input" => %{}},
               result,
               %{"type" => "text", "text" => "p"},
               fallback
             ]
    end
  end
```

- [ ] **Step 2: Run to verify they fail**

Run: `mix test test/response_test.exs 2>&1 | tail -20`
Expected: the two "unchanged" tests and the "result after the fallback" test PASS already (nothing to drop — they pin the no-op invariant); "mid-output fallback", "two fallback blocks" and "atom-keyed input" FAIL with the dropped blocks still present in the left-hand side. "non-map entries pass through" also PASSES now (there is no filter yet); it guards Step 3's `field/2`.

- [ ] **Step 3: Implement**

Replace `to_assistant_content/1` and its `@doc`:

```elixir
  @doc """
  Converts the response content into API-shaped assistant content blocks for
  replaying as the assistant turn in a follow-up request:

      request
      |> Request.add_message(:assistant, Response.to_assistant_content(response))

  Emits string-keyed blocks that preserve `signature` (thinking) and `data`
  (redacted_thinking) — both required by the API when continuing an
  extended-thinking + tool-use conversation. Unknown block types are passed
  through unchanged (coverage grows in later specs).

  After a server-side fallback (`Request.set_fallbacks/2`) it applies the API's
  continuation rules: before the last `fallback` block it drops `thinking`,
  `redacted_thinking`, `connector_text` and `tool_use` blocks, and keeps a
  `server_tool_use` or `mcp_tool_use` only when its result block is present.
  `fallback` blocks stay where they are. In practice this only changes a streamed
  response that fell back mid-output; a non-streaming response normally puts the
  `fallback` block first. `response.content` still holds every block.
  """
  @spec to_assistant_content(t()) :: [map()]
  def to_assistant_content(%__MODULE__{content: content}) do
    content
    |> Enum.map(&block_to_api/1)
    |> apply_fallback_continuation_rules()
  end
```

Directly after the catch-all `defp block_to_api(block), do: block`:

```elixir
  # Continuation rules after a server-side fallback (platform.claude.com/docs/en/
  # build-with-claude/refusals-and-fallback, "Continuing the conversation", fetched
  # 2026-09-25). mcp_tool_use is not in that table; it follows the server_tool_use
  # pairing rule because an unpaired one is rejected (probed 2026-09-25).
  @dropped_before_fallback ~w(thinking redacted_thinking connector_text tool_use)
  @paired_before_fallback ~w(server_tool_use mcp_tool_use)

  defp apply_fallback_continuation_rules(blocks) do
    case last_fallback_index(blocks) do
      index when is_integer(index) and index > 0 ->
        {before, rest} = Enum.split(blocks, index)
        result_ids = for block <- blocks, id = field(block, "tool_use_id"), into: MapSet.new(), do: id
        Enum.filter(before, &keep_before_fallback?(&1, result_ids)) ++ rest

      _none_or_first ->
        blocks
    end
  end

  defp last_fallback_index(blocks) do
    blocks
    |> Enum.with_index()
    |> Enum.reduce(nil, fn {block, index}, last ->
      if block_type(block) == "fallback", do: index, else: last
    end)
  end

  defp keep_before_fallback?(block, result_ids) do
    type = block_type(block)

    cond do
      type in @dropped_before_fallback -> false
      type in @paired_before_fallback -> MapSet.member?(result_ids, field(block, "id"))
      true -> true
    end
  end

  # Replayed blocks are string-keyed, but unknown blocks pass through with whatever
  # keys they arrived with, and a typed block Claudio does not re-emit (e.g.
  # :tool_result) keeps an atom type.
  defp block_type(block) do
    case field(block, "type") do
      type when is_atom(type) and not is_nil(type) -> Atom.to_string(type)
      type -> type
    end
  end

  defp field(block, key) when is_map(block) do
    case Map.fetch(block, key) do
      {:ok, value} -> value
      :error -> Map.get(block, String.to_existing_atom(key))
    end
  end

  defp field(_not_a_map, _key), do: nil
```

Note: `String.to_existing_atom/1` is safe here — `key` is always one of the literals `"type"`, `"id"`, `"tool_use_id"`, whose atoms exist in this module.

- [ ] **Step 4: Run to verify they pass**

Run: `mix test test/response_test.exs 2>&1 | tail -5`
Expected: PASS, `0 failures`.

- [ ] **Step 5: Mutation check of the no-op invariant**

One mutation at a time; run `mix test test/response_test.exs 2>&1 | tail -8` after each, then restore:
1. Add `"text"` to `@dropped_before_fallback`. Expected: "mid-output fallback", "two fallback blocks", "atom-keyed input", "a result after the fallback still pairs a server_tool_use before it" and "non-map entries pass through" FAIL.
2. Replace the pairing branch with `type in @paired_before_fallback -> true`. Expected: "mid-output fallback" FAILS (unpaired `srv_2` / `mcp_2` kept).
3. In `last_fallback_index/1`, return the **first** fallback index (`last || index`). Expected: "two fallback blocks" FAILS.

After restoring all three: `0 failures`. A mutation that does not fail its expected test is a finding about the test — stop and fix the test.

- [ ] **Step 6: Gates and commit**

Run: `mix format && mix compile --warnings-as-errors && mix test 2>&1 | tail -3`
Expected: compile clean; `0 failures`.

```bash
git add lib/claudio/messages/response.ex
git add test/response_test.exs
git commit -m "feat(response): apply fallback continuation rules in to_assistant_content/1"
```

---
### Task 5: Tool readers skip superseded tool calls; `add_message/3` declares the replay beta

**Files:**
- Modify: `lib/claudio/messages/response.ex` — `get_tool_uses/1` (~200-206) and its `@doc`; new `@doc false` `since_last_fallback/1` directly after `served_by/1` (Task 2)
- Modify: `lib/claudio/tools.ex:125-138` — both `extract_tool_uses/1` list clauses, and its `@doc`
- Modify: `lib/claudio/messages/request.ex:113-121` — `add_message/3`; new private `has_fallback_block?/1` directly after it
- Test: `test/response_test.exs` (new `describe` at the end), `test/tools_test.exs` (inside `describe "extract_tool_uses/1"`), `test/request_test.exs` (new `describe` after `describe "add_message/3"`)

**Interfaces:**
- Consumes: Task 4's private `last_fallback_index/1` (reads `"type"`/`:type`, string or atom value, non-maps → no type); Task 1's `@fallback_beta` (defined right after `defstruct`); Task 4's test helpers `fb/2` and `content/1` in `response_test.exs`.
- Produces: `@doc false def since_last_fallback(list()) :: list()` in `Claudio.Messages.Response`; `get_tool_uses/1`, `Tools.extract_tool_uses/1` (and `has_tool_uses?/1`, which calls it) skip `tool_use` before the last `fallback`; `add_message/3` declares `server-side-fallback-2026-07-01` for content holding a `fallback` block. Task 6's replay relies on the latter.

- [ ] **Step 1: Write the failing tests**

Append to `test/response_test.exs`, before the final `end`:

```elixir
  describe "get_tool_uses/1 after a fallback" do
    test "skips tool_use blocks before the last fallback block" do
      response =
        content([
          %{"type" => "tool_use", "id" => "toolu_1", "name" => "x", "input" => %{}},
          fb("a", "b"),
          %{"type" => "tool_use", "id" => "toolu_2", "name" => "y", "input" => %{}}
        ])

      assert [%{id: "toolu_2"}] = Response.get_tool_uses(response)
    end

    test "without a fallback block every tool_use is returned" do
      response =
        content([
          %{"type" => "tool_use", "id" => "toolu_1", "name" => "x", "input" => %{}},
          %{"type" => "tool_use", "id" => "toolu_2", "name" => "y", "input" => %{}}
        ])

      assert [%{id: "toolu_1"}, %{id: "toolu_2"}] = Response.get_tool_uses(response)
    end
  end
```

Add inside `describe "extract_tool_uses/1"` in `test/tools_test.exs`:

```elixir
    test "skips tool_use blocks before the last fallback block (raw maps and Response)" do
      raw = %{
        "content" => [
          %{"type" => "tool_use", "id" => "toolu_1", "name" => "x", "input" => %{}},
          %{"type" => "fallback", "from" => %{"model" => "a"}, "to" => %{"model" => "b"}},
          %{"type" => "tool_use", "id" => "toolu_2", "name" => "y", "input" => %{}}
        ]
      }

      assert [%{id: "toolu_2"}] = Tools.extract_tool_uses(raw)
      assert [%{id: "toolu_2"}] = Tools.extract_tool_uses(Claudio.Messages.Response.from_map(raw))

      atom_keyed = %{
        content: [%{type: "tool_use", id: "toolu_1", name: "x", input: %{}}, %{type: "fallback"}]
      }

      assert Tools.extract_tool_uses(atom_keyed) == []
      refute Tools.has_tool_uses?(atom_keyed)
    end
```

Add to `test/request_test.exs`, after `describe "add_message/3"`:

```elixir
  describe "add_message/3 with a fallback block" do
    test "declares the fallback beta (the API rejects a replayed fallback block without it)" do
      for block <- [
            %{"type" => "fallback", "from" => %{"model" => "a"}, "to" => %{"model" => "b"}},
            %{type: "fallback"},
            %{type: :fallback}
          ] do
        request =
          Request.new("m")
          |> Request.add_message(:assistant, [block, %{"type" => "text", "text" => "hi"}])

        assert Request.required_betas(request) == ["server-side-fallback-2026-07-01"]
      end
    end

    test "content without a fallback block declares nothing" do
      for content <- ["hi", [%{"type" => "text", "text" => "hi"}], ["stray"]] do
        request = Request.new("m") |> Request.add_message(:user, content)
        assert Request.required_betas(request) == []
      end
    end
  end
```

- [ ] **Step 2: Run to verify they fail**

Run: `mix test test/response_test.exs test/tools_test.exs test/request_test.exs 2>&1 | tail -20`
Expected: FAIL — "skips tool_use blocks before the last fallback block" (both files: `toolu_1` still returned) and "declares the fallback beta" (`[]` instead of the beta). "without a fallback block every tool_use is returned" and "content without a fallback block declares nothing" PASS already — they pin today's behaviour.

- [ ] **Step 3: Implement**

In `response.ex`, directly after `served_by/1`:

```elixir
  # Blocks from the last `fallback` block on — every block when there is none. Earlier
  # blocks belong to a model that declined (see to_assistant_content/1). Reads parsed
  # and raw (string- or atom-keyed) content alike; shared with Claudio.Tools.
  @doc false
  @spec since_last_fallback(list()) :: list()
  def since_last_fallback(blocks) when is_list(blocks) do
    case last_fallback_index(blocks) do
      nil -> blocks
      index -> Enum.drop(blocks, index)
    end
  end
```

Replace `get_tool_uses/1` and its `@doc`:

```elixir
  @doc """
  Extracts the tool use requests to execute. After a server-side fallback, `tool_use`
  blocks before the last `fallback` block came from the model that declined; they are
  skipped here, as `to_assistant_content/1` drops them from the replay.
  """
  @spec get_tool_uses(t()) :: list(tool_use_block())
  def get_tool_uses(%__MODULE__{content: content}) do
    content
    |> since_last_fallback()
    |> Enum.filter(&(&1[:type] == :tool_use))
  end
```

In `tools.ex`, both list clauses of `extract_tool_uses/1`:

```elixir
  def extract_tool_uses(%{content: content}) when is_list(content) do
    content
    |> Claudio.Messages.Response.since_last_fallback()
    |> Enum.filter(&is_tool_use?/1)
    |> Enum.map(&normalize_tool_use/1)
  end

  def extract_tool_uses(%{"content" => content}) when is_list(content) do
    content
    |> Claudio.Messages.Response.since_last_fallback()
    |> Enum.filter(&is_tool_use?/1)
    |> Enum.map(&normalize_tool_use/1)
  end
```

and append to its `@doc` (before the closing `"""`):

```markdown
  After a server-side fallback, `tool_use` blocks before the last `fallback` block
  came from the model that declined and are skipped (see
  `Claudio.Messages.Response.to_assistant_content/1`).
```

In `request.ex`, replace `add_message/3`'s body and add the helper after it:

```elixir
  def add_message(%__MODULE__{messages: messages} = request, role, content)
      when role in [:user, :assistant] do
    message = %{
      "role" => to_string(role),
      "content" => normalize_content(content)
    }

    request = %{request | messages: messages ++ [message]}

    # Replaying a `fallback` block (Response.to_assistant_content/1) needs the beta even
    # on a turn that does not set fallbacks (400 without it, probed 2026-09-25).
    if has_fallback_block?(content), do: add_beta(request, @fallback_beta), else: request
  end

  defp has_fallback_block?(content) when is_list(content) do
    Enum.any?(content, fn
      %{"type" => type} -> type in ["fallback", :fallback]
      %{type: type} -> type in ["fallback", :fallback]
      _ -> false
    end)
  end

  defp has_fallback_block?(_content), do: false
```

Also add one sentence to `add_message/3`'s `@doc`: "A list `content` holding a `fallback` block (from `Response.to_assistant_content/1`) declares `server-side-fallback-2026-07-01`, which the API requires to accept it."

- [ ] **Step 4: Run to verify they pass**

Run: `mix test test/response_test.exs test/tools_test.exs test/request_test.exs 2>&1 | tail -5`
Expected: PASS, `0 failures`.

- [ ] **Step 5: Gates and commit**

Run: `mix format && mix compile --warnings-as-errors && mix test 2>&1 | tail -3`
Expected: compile clean; `0 failures`.

```bash
git add lib/claudio/messages/response.ex
git add lib/claudio/tools.ex
git add lib/claudio/messages/request.ex
git add test/response_test.exs
git add test/tools_test.exs
git add test/request_test.exs
git commit -m "feat: tool readers skip superseded tool calls; add_message/3 declares the replay beta"
```

---

### Task 6: Live integration test + docs

**Files:**
- Create: `test/integration/fallbacks_integration_test.exs`
- Modify: `CHANGELOG.md` (`## [Unreleased] — targets 0.7.0`), `CLAUDE.md` (Request builder, after the "5.x request surface" bullet; Response bullets — locate every CLAUDE.md edit by its quoted text, not by line number)

**Interfaces:**
- Consumes: `Request.set_fallbacks/2` (Task 1), `Response.served_by/1` (Task 2), `usage.iterations` (Task 3), filtered `Response.to_assistant_content/1` (Task 4), `add_message/3` declaring the replay beta (Task 5); existing `Request.add_beta/2`, `Claudio.APIError` (`status_code`, `message`).
- Produces: nothing consumed later.

- [ ] **Step 1: Write the integration test**

Create `test/integration/fallbacks_integration_test.exs`:

```elixir
Code.require_file("../integration/integration_helper.exs", __DIR__)

defmodule Claudio.FallbacksIntegrationTest do
  use ExUnit.Case, async: false
  import Claudio.IntegrationHelper

  alias Claudio.APIError
  alias Claudio.Messages.{Request, Response}

  @moduletag :integration
  @moduletag timeout: 120_000

  @model "claude-opus-5-5"
  # mcp_tool_use blocks in history need the MCP connector beta (probed 2026-09-25).
  @mcp_beta "mcp-client-2025-11-20"

  # Content as a streamed mid-output fallback leaves it (RF "Continuing the
  # conversation"). A refusal can't be triggered on demand, but the API validates a
  # caller-built fallback block in history, so the echo rules can be checked live.
  @fallback %{
    "type" => "fallback",
    "from" => %{"model" => "claude-opus-5-5"},
    "to" => %{"model" => "claude-opus-4-8"}
  }

  @unpaired [
    tool_use: %{"type" => "tool_use", "id" => "toolu_01", "name" => "x", "input" => %{}},
    server_tool_use: %{
      "type" => "server_tool_use",
      "id" => "srvtoolu_01",
      "name" => "web_search",
      "input" => %{"query" => "x"}
    },
    mcp_tool_use: %{
      "type" => "mcp_tool_use",
      "id" => "mcptoolu_01",
      "name" => "x",
      "server_name" => "s",
      "input" => %{}
    }
  ]

  setup_all do
    case skip_if_no_api_key() do
      :ok -> {:ok, %{client: create_client()}}
      {:skip, reason} -> {:skip, reason}
    end
  end

  defp replay(client, assistant_content) do
    request =
      Request.new(@model)
      |> Request.add_message(:user, "hi")
      |> Request.add_message(:assistant, assistant_content)
      |> Request.add_message(:user, "Say ok.")
      |> Request.set_max_tokens(16)
      # No set_fallbacks/2: the fallback beta must come from add_message/3 (spec F15).
      |> Request.add_beta(@mcp_beta)

    Claudio.Messages.create(client, request)
  end

  defp mid_output(blocks) do
    blocks ++
      [%{"type" => "text", "text" => "Partial"}, @fallback, %{"type" => "text", "text" => "Hello!"}]
  end

  test "fallbacks: :default is accepted and usage.iterations is reported", %{client: client} do
    request =
      Request.new(@model)
      |> Request.add_message(:user, "Name a primary color.")
      |> Request.set_max_tokens(64)
      |> Request.set_fallbacks(:default)

    assert {:ok, %Response{} = response} = Claudio.Messages.create(client, request)
    assert [%{"type" => _} | _] = response.usage.iterations
    assert is_binary(Response.served_by(response))
  end

  test "to_assistant_content/1 output replays after a mid-output fallback", %{client: client} do
    response =
      Response.from_map(%{"model" => @model, "content" => mid_output(Keyword.values(@unpaired))})

    content = Response.to_assistant_content(response)

    assert Enum.map(content, & &1["type"]) == ["text", "fallback", "text"]
    assert {:ok, %Response{}} = replay(client, content)
  end

  for type <- [:tool_use, :server_tool_use, :mcp_tool_use] do
    @tag block_type: type
    test "control: replaying an unpaired #{type} before the fallback is rejected", %{
      client: client,
      block_type: block_type
    } do
      raw = mid_output([Keyword.fetch!(@unpaired, block_type)])

      assert {:error, %APIError{status_code: 400, message: message}} = replay(client, raw)
      assert message =~ "tool_result"
    end
  end
end
```

The three control tests prove each dropped block type really makes the next request fail, so the 200 in the second test is evidence the filter did its job (including the `mcp_tool_use` inference) rather than evidence the API is lenient. The replay requests do not call `set_fallbacks/2`, so they also prove `add_message/3` supplies the beta a replayed `fallback` block needs (P16 → 400 without it). The `"tool_result"` assertion rests on the error texts quoted in spec F10.

- [ ] **Step 2: Run it**

Run: `mix test test/integration/fallbacks_integration_test.exs --include integration 2>&1 | tail -8`
Expected: PASS (`5 tests, 0 failures`) when `ANTHROPIC_API_KEY` is set. When unset, ExUnit reports `5 tests, 0 failures, 5 invalid` — record **DID NOT RUN**, never "passed". A failure here is data about the API: stop and report the raw error, do not loosen the assertions.

- [ ] **Step 3: CHANGELOG**

Under `## [Unreleased] — targets 0.7.0`:

In `### Changed`, extend the `Response.usage` bullet's list of new documented fields to include `iterations`, change the `count_tokens/2` bullet to "also drops `inference_geo`, `diagnostics` and `fallbacks`", and add:

```markdown
- `Response.to_assistant_content/1` applies the API's continuation rules after a server-side
  fallback: before the last `fallback` block it drops `thinking`, `redacted_thinking`,
  `connector_text` and `tool_use`, and keeps `server_tool_use` / `mcp_tool_use` only when their
  result is present. Output is unchanged for responses without a `fallback` block, or with it
  first (the normal non-streaming shape).
- `Response.get_tool_uses/1` and `Tools.extract_tool_uses/1` (so `has_tool_uses?/1`) skip
  `tool_use` blocks before the last `fallback` block — they came from the model that declined.
- `Request.add_message/3` declares `server-side-fallback-2026-07-01` when its content holds a
  `fallback` block; the API rejects a replayed `fallback` block without it.
```

In `### Added`:

```markdown
- **Refusal fallbacks:** `Request.set_fallbacks/2` (`:default` or up to three models / override
  maps; declares `server-side-fallback-2026-07-01`); typed `:fallback` content blocks (original
  kept under `raw:` and replayed verbatim); `Response.fallbacks/1`, `Response.served_by/1`;
  `usage.iterations`.
```

- [ ] **Step 4: CLAUDE.md**

After the "5.x request surface" bullet:

```markdown
- **Refusal fallbacks** (`set_fallbacks/2` — `:default` or a list of model strings / override maps; declares `server-side-fallback-2026-07-01`. Entry cap, distinctness and `allowed_fallback_models` are left to the API; not sent by `count_tokens`; unsupported in Batches.)
```

Replace the `stop_details` bullet and add two after it:

```markdown
- **`stop_details`** — raw refusal details map (`type`/`category`/`explanation`; with fallbacks also `recommended_model`, `fallback_credit_token`), `nil` unless `stop_reason: :refusal`
- **`fallback` blocks** — `%{type: :fallback, from:, to:, trigger:, raw:}`; `fallbacks/1` lists them, `served_by/1` names the serving model (last block's `to.model`, else `model` — a streamed mid-output fallback keeps the requested model in `model`); `usage.iterations` records each attempt
- **`to_assistant_content/1`** applies the fallback continuation rules (drops / pairing before the last `fallback` block); a no-op without a mid-output fallback. `get_tool_uses/1` (and `Tools.extract_tool_uses/1`) skip `tool_use` before the last `fallback`; `add_message/3` declares the fallback beta when replaying a `fallback` block
```

Also update three existing lines:
- "Parses content blocks (…)": add `fallback` to the list.
- "documented fields are atom keys (incl. `cache_creation`, `service_tier`, `inference_geo`, `speed`)": add `iterations`.
- "Content blocks typed by their :type field (…)": add `:fallback`.

- [ ] **Step 5: Final gates and commit**

Run: `mix format && mix format --check-formatted && mix compile --warnings-as-errors && mix test 2>&1 | tail -3`
Expected: format and compile clean (the integration file's code block is not pre-formatted); `mix test` → `0 failures` (integration excluded).

```bash
git add test/integration/fallbacks_integration_test.exs
git add CHANGELOG.md
git add CLAUDE.md
git commit -m "test(integration): live fallback replay checks; docs for S12b"
```

---

## Spec coverage (self-review)

| Spec item | Task |
|---|---|
| §1 `set_fallbacks/2` shapes, beta, raises, no local cap | 1 |
| §1 `count_tokens` strips `fallbacks` (F11) | 1 |
| §2 typed `fallback` block with `raw`, re-emitted verbatim | 2 |
| §2 `fallbacks/1`, `served_by/1` (last `to.model`, else `model`) | 2 |
| §2 `usage.iterations` atom key; `nil` when absent | 3 |
| §2 `stop_details` new keys documented | 3 |
| §3 echo filter incl. `mcp_tool_use` pairing, both key styles, no-op invariant | 4 |
| §4 no-delta stream block → Response | 2 |
| §1 `add_message/3` declares the replay beta (F15) | 5 |
| §2 `get_tool_uses/1` / `Tools.extract_tool_uses/1` skip superseded tool calls | 5 |
| §4 known limitation (`partial_json`) — documented only, no task | — |
| Testing: integration default call + filtered replay (no `set_fallbacks`) + controls | 6 |
| CHANGELOG / CLAUDE.md | 6 |
