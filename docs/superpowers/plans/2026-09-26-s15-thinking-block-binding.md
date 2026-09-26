# S15 Thinking Block-Binding Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let callers choose what the API does with a thinking block whose conversation prefix changed (`thinking.block_binding.prefix_mismatch_behavior`), and expose what it did (`Response.input_transformations`), streaming included.

**Architecture:** `enable_adaptive_thinking/2` gains a `block_binding:` option and a new `set_thinking_block_binding/2` merges the setting into any existing `thinking` map; both declare `thinking-binding-controls-2026-08-01`. `Response` carries `input_transformations` raw. `Stream` lets a `message_delta` replace it (post-fallback copy).

**Tech Stack:** Elixir ≥ 1.15, ExUnit (async), Bypass, Jason.

**Spec:** `docs/superpowers/specs/2026-09-26-s15-thinking-block-binding-design.md`

## Global Constraints

- Builds on S13 and S14: assumes both are merged to `main` (Task 3's doc pointer goes on S13's `apply_compaction/2`).
- Beta string, verbatim: `thinking-binding-controls-2026-08-01`. Request shape, verbatim: `"block_binding" => %{"prefix_mismatch_behavior" => "error" | "drop_block"}` inside `thinking`.
- Behaviors are atoms `:error` / `:drop_block`; errors name the function and `inspect/1` of the value.
- API-authoritative: `"disabled"` + `block_binding` (API 400, spec F2) and model support are not validated locally.
- `enable_adaptive_thinking/2`'s existing behavior and its `:display` error message stay byte-identical.
- `input_transformations` stays raw (string-keyed entries); no typed entries or readers.
- No `@version` bump here — S15 is the last spec before the 0.7.0 release prep; CHANGELOG under `## [Unreleased] — targets 0.7.0`.
- Commits: add files individually (`git add .` forbidden); **no AI attribution lines**.
- Gates before each commit: `mix format` and `mix compile --warnings-as-errors`; Task 4 ends with `mix format --check-formatted`, the full suite and the integration file.

## Pre-flight: re-verify facts

Before Task 1: `git log main --oneline -5` shows the S13 and S14 merges. Re-fetch
`platform.claude.com/docs/en/build-with-claude/preserved-thinking` and confirm the beta string,
the two behavior values and the `input_transformations` entry types still appear. If anything
changed, stop and ask Q.

## Review Focus

1. `set_thinking_block_binding/2` on an atom-keyed raw thinking map (`%{type: "enabled", budget_tokens: 2048}`) adds the string key without touching the others. Pinned in Task 1.
2. `enable_adaptive_thinking(display: :updates, block_binding: :drop_block)` declares **both** betas, in that order. Pinned in Task 1.
3. A later `enable_adaptive_thinking/2` without `block_binding:` removes it from `thinking` (wholesale replace, documented) while the beta stays declared. Pinned in Task 1.
4. A stream whose `message_delta` has no `input_transformations` keeps the `message_start` value; `[]` in a delta replaces a non-empty start value (the serving model dropped nothing). Pinned in Task 2.
5. A response without the beta has no key → `input_transformations: nil`, not `[]`. Pinned in Task 2.

## Branching

Implementation branch `feat/s15-thinking-block-binding`, cut from `main` after S14 is merged.

---

### Task 1: Request — `block_binding:` option and `set_thinking_block_binding/2`

**Files:**
- Modify: `lib/claudio/messages/request.ex` — attributes next to `@thinking_display_updates_beta` (~line 535); `enable_adaptive_thinking/2` (~lines 537-575); new `set_thinking_block_binding/2` directly after it
- Test: `test/request_test.exs` — extend `describe "enable_adaptive_thinking/2"`; new `describe "set_thinking_block_binding/2"` after it

**Interfaces:**
- Consumes: `add_beta/2`, `maybe_put/3`.
- Produces: `enable_adaptive_thinking(t(), keyword())` accepting `block_binding: :error | :drop_block | nil`; `set_thinking_block_binding(t(), :error | :drop_block) :: t()`. Task 3 uses both.

- [ ] **Step 1: Write the failing tests**

Inside `describe "enable_adaptive_thinking/2"`, add:

```elixir
    test "block_binding: puts prefix_mismatch_behavior in thinking and declares the beta" do
      for behavior <- [:error, :drop_block] do
        request =
          Request.new("claude-opus-5-5") |> Request.enable_adaptive_thinking(block_binding: behavior)

        assert Request.to_map(request)["thinking"] == %{
                 "type" => "adaptive",
                 "block_binding" => %{"prefix_mismatch_behavior" => Atom.to_string(behavior)}
               }

        assert Request.required_betas(request) == ["thinking-binding-controls-2026-08-01"]
      end
    end

    test "block_binding composes with display: :updates — both betas (Review Focus 2)" do
      request =
        Request.new("claude-opus-5-5")
        |> Request.enable_adaptive_thinking(display: :updates, block_binding: :drop_block)

      assert Request.to_map(request)["thinking"] == %{
               "type" => "adaptive",
               "display" => "updates",
               "block_binding" => %{"prefix_mismatch_behavior" => "drop_block"}
             }

      assert Request.required_betas(request) == [
               "thinking-display-updates-2026-08-18",
               "thinking-binding-controls-2026-08-01"
             ]
    end

    test "re-calling without block_binding drops it; the beta stays (Review Focus 3)" do
      request =
        Request.new("claude-opus-5-5")
        |> Request.enable_adaptive_thinking(block_binding: :error)
        |> Request.enable_adaptive_thinking()

      assert Request.to_map(request)["thinking"] == %{"type" => "adaptive"}
      assert Request.required_betas(request) == ["thinking-binding-controls-2026-08-01"]
    end

    test "block_binding: nil is the same as omitting it" do
      request = Request.new("m") |> Request.enable_adaptive_thinking(block_binding: nil)

      assert Request.to_map(request)["thinking"] == %{"type" => "adaptive"}
      assert Request.required_betas(request) == []
    end

    test "unknown block_binding values raise" do
      for bad <- [:strict, "drop_block"] do
        assert_raise ArgumentError,
                     ~r/enable_adaptive_thinking\/2 :block_binding must be :error or :drop_block; got/,
                     fn -> Request.enable_adaptive_thinking(Request.new("m"), block_binding: bad) end
      end
    end
```

After that describe, add:

```elixir
  describe "set_thinking_block_binding/2" do
    @binding %{"prefix_mismatch_behavior" => "drop_block"}

    test "merges into adaptive thinking set earlier, keeping display" do
      request =
        Request.new("claude-opus-5-5")
        |> Request.enable_adaptive_thinking(display: :summarized)
        |> Request.set_thinking_block_binding(:drop_block)

      assert Request.to_map(request)["thinking"] == %{
               "type" => "adaptive",
               "display" => "summarized",
               "block_binding" => @binding
             }

      assert Request.required_betas(request) == ["thinking-binding-controls-2026-08-01"]
    end

    test "merges into a raw enabled thinking map" do
      request =
        Request.new("claude-sonnet-4-6")
        |> Request.enable_thinking(%{"type" => "enabled", "budget_tokens" => 2048})
        |> Request.set_thinking_block_binding(:error)

      assert Request.to_map(request)["thinking"] == %{
               "type" => "enabled",
               "budget_tokens" => 2048,
               "block_binding" => %{"prefix_mismatch_behavior" => "error"}
             }
    end

    test "an atom-keyed raw map gains the string key only (Review Focus 1)" do
      request =
        Request.new("m")
        |> Request.enable_thinking(%{type: "enabled", budget_tokens: 2048})
        |> Request.set_thinking_block_binding(:drop_block)

      assert request.thinking == %{type: "enabled", budget_tokens: 2048, "block_binding" => @binding}
    end

    test "a later disable_thinking/1 replaces it" do
      request =
        Request.new("m")
        |> Request.enable_adaptive_thinking()
        |> Request.set_thinking_block_binding(:error)
        |> Request.disable_thinking()

      assert Request.to_map(request)["thinking"] == %{"type" => "disabled"}
    end

    test "no thinking set, or a bad value, raises" do
      assert_raise ArgumentError, ~r/set_thinking_block_binding\/2 needs thinking/, fn ->
        Request.set_thinking_block_binding(Request.new("m"), :error)
      end

      assert_raise ArgumentError,
                   ~r/set_thinking_block_binding\/2 :block_binding must be :error or :drop_block; got/,
                   fn ->
                     Request.new("m")
                     |> Request.enable_adaptive_thinking()
                     |> Request.set_thinking_block_binding(:strict)
                   end
    end
  end
```

- [ ] **Step 2: Run to verify it fails**

Run: `mix test test/request_test.exs`
Expected: FAIL — `Keyword.validate!` rejects `:block_binding` (`ArgumentError` "unknown keys [:block_binding]") in the new `enable_adaptive_thinking/2` tests; `UndefinedFunctionError` for `set_thinking_block_binding/2`. The existing `enable_adaptive_thinking/2` tests still pass.

- [ ] **Step 3: Implement**

After `@thinking_display_updates_beta` (~line 535), add:

```elixir
  @block_binding_behaviors [:error, :drop_block]
  @block_binding_beta "thinking-binding-controls-2026-08-01"
```

Replace `enable_adaptive_thinking/2`'s body (keep the existing `:display` error text exactly):

```elixir
  def enable_adaptive_thinking(%__MODULE__{} = request, opts \\ []) when is_list(opts) do
    opts = Keyword.validate!(opts, [:display, :block_binding])

    display =
      case Keyword.get(opts, :display) do
        nil ->
          nil

        display when display in @thinking_displays ->
          display

        other ->
          raise ArgumentError,
                "Request.enable_adaptive_thinking/2 :display must be one of " <>
                  ":summarized, :omitted, :updates; got #{inspect(other)}"
      end

    binding = block_binding!("enable_adaptive_thinking/2", Keyword.get(opts, :block_binding))

    thinking =
      %{"type" => "adaptive"}
      |> maybe_put("display", display && Atom.to_string(display))
      |> maybe_put("block_binding", binding)

    request = %{request | thinking: thinking}

    request =
      if display == :updates, do: add_beta(request, @thinking_display_updates_beta), else: request

    if binding, do: add_beta(request, @block_binding_beta), else: request
  end
```

Add to its `@doc` options list:

```
  - `:block_binding` — `:error` or `:drop_block`: what the API does with a `thinking` block
    whose conversation prefix changed since it was produced (an edited earlier message, a
    block removed from the middle). `:error` rejects the request (400); `:drop_block` drops
    that block and every later thinking block and reports it in
    `Response.input_transformations`. Declares `thinking-binding-controls-2026-08-01`.
    Unset: accounts created on/after 2026-08-31 behave as `:error`; older accounts are not
    enforced. See `set_thinking_block_binding/2`.
```

Directly after `enable_adaptive_thinking/2`, add:

```elixir
  @doc """
  Sets `thinking.block_binding.prefix_mismatch_behavior` (`:error` or `:drop_block`) on the
  thinking config already set — adaptive or a raw `enable_thinking/2` `"enabled"` map —
  and declares `thinking-binding-controls-2026-08-01`. Raises if no thinking config is set.
  A later thinking setter replaces the whole map (the beta stays declared). The API rejects
  `block_binding` on `"disabled"` thinking.
  """
  @spec set_thinking_block_binding(t(), :error | :drop_block) :: t()
  def set_thinking_block_binding(%__MODULE__{} = request, behavior)
      when behavior in @block_binding_behaviors do
    case request.thinking do
      nil ->
        raise ArgumentError,
              "Request.set_thinking_block_binding/2 needs thinking set first " <>
                "(enable_adaptive_thinking/2 or enable_thinking/2)"

      thinking ->
        binding = block_binding!("set_thinking_block_binding/2", behavior)
        add_beta(%{request | thinking: Map.put(thinking, "block_binding", binding)}, @block_binding_beta)
    end
  end

  def set_thinking_block_binding(%__MODULE__{}, other) do
    raise ArgumentError,
          "Request.set_thinking_block_binding/2 :block_binding must be :error or :drop_block; " <>
            "got #{inspect(other)}"
  end

  defp block_binding!(_fun, nil), do: nil

  defp block_binding!(_fun, behavior) when behavior in @block_binding_behaviors,
    do: %{"prefix_mismatch_behavior" => Atom.to_string(behavior)}

  defp block_binding!(fun, other) do
    raise ArgumentError,
          "Request.#{fun} :block_binding must be :error or :drop_block; got #{inspect(other)}"
  end
```

(The catch-all clause also covers `nil`, which must raise here — unlike the option, where `nil` means unset.)

- [ ] **Step 4: Run to verify it passes**

Run: `mix format && mix compile --warnings-as-errors && mix test test/request_test.exs`
Expected: PASS, 0 failures.

- [ ] **Step 5: Commit**

```bash
git add lib/claudio/messages/request.ex test/request_test.exs
git commit -m "feat(s15): thinking block_binding option and set_thinking_block_binding/2"
```

---

### Task 2: Response and Stream — `input_transformations`

**Files:**
- Modify: `lib/claudio/messages/response.ex` — moduledoc, `@type t`, `defstruct`, `from_map/1`
- Modify: `lib/claudio/messages/stream.ex` — the `message_delta` clause of `build_final_message/1`
- Test: `test/response_test.exs`, `test/messages/stream_test.exs` — new describes at the end

**Interfaces:**
- Consumes: nothing new.
- Produces: struct field `input_transformations :: [map()] | nil`; `build_final_message/1` replaces the stored value from a `message_delta` carrying the key (event top level first, else `delta`). Task 3 asserts it live.

- [ ] **Step 1: Write the failing tests**

`test/response_test.exs`:

```elixir
  describe "from_map/1 input_transformations (S15)" do
    @dropped [
      %{
        "type" => "thinking_dropped",
        "path" => "messages.1.content.0",
        "reason" => "prefix_binding_mismatch"
      }
    ]

    test "kept raw: one entry, empty list, atom top-level key" do
      assert Response.from_map(%{"content" => [], "input_transformations" => @dropped}).input_transformations ==
               @dropped

      assert Response.from_map(%{"content" => [], "input_transformations" => []}).input_transformations ==
               []

      assert Response.from_map(%{content: [], input_transformations: @dropped}).input_transformations ==
               @dropped
    end

    test "nil when absent — the beta was not sent (Review Focus 5)" do
      assert Response.from_map(%{"content" => []}).input_transformations == nil
    end
  end
```

`test/messages/stream_test.exs`:

```elixir
  describe "build_final_message/1 input_transformations (S15)" do
    @start_entry ~s([{"type":"thinking_dropped","path":"messages.1.content.0","reason":"prefix_binding_mismatch"}])

    defp binding_stream(delta_event) do
      [
        ~s(event: message_start),
        ~s(data: {"type":"message_start","message":{"id":"m","content":[],"model":"x","input_transformations":#{@start_entry},"usage":{"input_tokens":1,"output_tokens":0}}}),
        "",
        ~s(event: message_delta),
        "data: " <> delta_event,
        ""
      ]
      |> Enum.join("\n")
      |> Kernel.<>("\n")
      |> List.wrap()
      |> ClaudioStream.parse_events()
      |> ClaudioStream.build_final_message()
    end

    test "message_start value survives a delta without the key (Review Focus 4)" do
      {:ok, message} =
        binding_stream(~s({"type":"message_delta","delta":{"stop_reason":"end_turn"},"usage":{"output_tokens":1}}))

      assert [%{"type" => "thinking_dropped"}] =
               Claudio.Messages.Response.from_map(message).input_transformations
    end

    test "a top-level key on message_delta replaces it (post-fallback copy)" do
      {:ok, message} =
        binding_stream(
          ~s({"type":"message_delta","delta":{"stop_reason":"end_turn"},"usage":{"output_tokens":1},"input_transformations":[]})
        )

      assert message["input_transformations"] == []
    end

    test "a key inside delta replaces it too (nesting unverified, spec F8)" do
      {:ok, message} =
        binding_stream(
          ~s({"type":"message_delta","delta":{"stop_reason":"end_turn","input_transformations":[{"type":"thinking_dropped","path":"messages.3.content.0","reason":"model_binding_mismatch"}]},"usage":{"output_tokens":1}})
        )

      assert [%{"reason" => "model_binding_mismatch"}] = message["input_transformations"]
    end
  end
```

- [ ] **Step 2: Run to verify it fails**

Run: `mix test test/response_test.exs test/messages/stream_test.exs`
Expected: FAIL — `KeyError` for `:input_transformations` on the Response struct; the two replace tests keep the start entry. "survives a delta without the key" fails only on the struct field.

- [ ] **Step 3: Implement**

`response.ex`: add `input_transformations: [map()] | nil,` to `@type t` (after `container`), `:input_transformations` to `defstruct`, and to `from_map/1`:

```elixir
      input_transformations: data[:input_transformations] || data["input_transformations"],
```

Moduledoc — append:

```
  `input_transformations` (only with the `thinking-binding-controls-2026-08-01` beta, see
  `Request.set_thinking_block_binding/2`) is the raw list of what the API changed in the
  input: entries `%{"type" => "thinking_dropped" | "thinking_mismatch_allowed", "path" =>
  "messages.N.content.M", "reason" => "prefix_binding_mismatch" | "model_binding_mismatch"}`.
  `[]` when nothing changed; `nil` without the beta. Ignore unknown `type`/`reason` values.
```

`stream.ex`, in the `message_delta` clause pipeline, add after the usage merge:

```elixir
            # After a mid-stream fallback the final message_delta repeats input_transformations
            # with the serving model's entries (preserved-thinking docs). Its nesting is not
            # observable on demand, so read delta first and let the event's top level win.
            |> maybe_update(delta, "input_transformations")
            |> maybe_update(data, "input_transformations")
```

(`maybe_update/3` skips only `nil`, so `[]` replaces.)

- [ ] **Step 4: Run to verify it passes**

Run: `mix format && mix compile --warnings-as-errors && mix test`
Expected: PASS, 0 failures.

- [ ] **Step 5: Commit**

```bash
git add lib/claudio/messages/response.ex lib/claudio/messages/stream.ex test/response_test.exs test/messages/stream_test.exs
git commit -m "feat(s15): Response.input_transformations, streamed and replaced by message_delta"
```

---

### Task 3: Live integration test and doc pointers

**Files:**
- Create: `test/integration/block_binding_integration_test.exs`
- Modify: `lib/claudio/messages/request.ex` (`apply_compaction/2` `@doc`), `lib/claudio/messages/response.ex` (`to_assistant_content/1` `@doc`)

**Interfaces:**
- Consumes: Tasks 1–2.
- Produces: nothing consumed later.

Repeats probes B2/B3. RED is not observable (written after the code). The probe account does not enforce the prefix check by default (spec F5), so both tests set the behavior explicitly.

- [ ] **Step 1: Write the integration test**

```elixir
Code.require_file("../integration/integration_helper.exs", __DIR__)

defmodule Claudio.BlockBindingIntegrationTest do
  use ExUnit.Case, async: false
  import Claudio.IntegrationHelper

  alias Claudio.APIError
  alias Claudio.Messages
  alias Claudio.Messages.{Request, Response}

  @moduletag :integration
  @moduletag timeout: 180_000

  @model "claude-opus-5-5"
  @question "Think step by step: what is 17*23? Answer with the number."

  setup_all do
    case skip_if_no_api_key() do
      :ok ->
        client = create_client()

        request =
          Request.new(@model)
          |> Request.enable_adaptive_thinking()
          |> Request.add_message(:user, @question)
          |> Request.set_max_tokens(1024)

        {:ok, response} = Messages.create(client, request)
        {:ok, %{client: client, first: response}}

      {:skip, reason} ->
        {:skip, reason}
    end
  end

  # Same assistant turn, but the user message before it was edited: the thinking block's
  # signature no longer matches its prefix.
  defp edited_history(first, behavior) do
    Request.new(@model)
    |> Request.enable_adaptive_thinking(block_binding: behavior)
    |> Request.add_message(:user, @question <> " Please.")
    |> Request.add_message(:assistant, Response.to_assistant_content(first))
    |> Request.add_message(:user, "Now add 1. Number only.")
    |> Request.set_max_tokens(256)
  end

  test "the first reply carries a signed thinking block", %{first: first} do
    assert Enum.any?(first.content, &match?(%{type: :thinking, signature: sig} when is_binary(sig), &1))
  end

  test ":error rejects an edited prefix", %{client: client, first: first} do
    assert {:error, %APIError{status_code: 400, message: message}} =
             Messages.create(client, edited_history(first, :error))

    assert message =~ "bound to a different conversation"
  end

  test ":drop_block drops the block and reports it", %{client: client, first: first} do
    assert {:ok, %Response{input_transformations: transformations}} =
             Messages.create(client, edited_history(first, :drop_block))

    assert [%{"type" => "thinking_dropped", "reason" => "prefix_binding_mismatch"}] =
             transformations
  end
end
```

- [ ] **Step 2: Run it**

Run: `mix test test/integration/block_binding_integration_test.exs --include integration`
Expected: 3 tests, 0 failures. If the first test fails (adaptive thinking produced no thinking block), rerun once; a second failure is reported to Q — the other two tests depend on it.

- [ ] **Step 3: Doc pointers**

Append to `Request.apply_compaction/2`'s `@doc`:

```
  Editing the history yourself (rather than through this function) can invalidate the
  signatures of kept `thinking` blocks; `set_thinking_block_binding(:drop_block)` makes the
  API drop such blocks instead of rejecting the request.
```

Append to `Response.to_assistant_content/1`'s `@doc`:

```
  If you edit earlier messages before replaying, a `thinking` block's signature may no longer
  match; see `Request.set_thinking_block_binding/2`.
```

- [ ] **Step 4: Commit**

```bash
mix format
git add test/integration/block_binding_integration_test.exs lib/claudio/messages/request.ex lib/claudio/messages/response.ex
git commit -m "test(s15): live block_binding :error and :drop_block; doc pointers"
```

---

### Task 4: Docs and final gates

**Files:**
- Modify: `CHANGELOG.md`, `CLAUDE.md`, `docs/superpowers/specs/2026-06-19-anthropic-api-coverage-roadmap.md`

- [ ] **Step 1: CHANGELOG** — under `### Added`:

```markdown
- **Thinking block binding:** `enable_adaptive_thinking/2` `block_binding:` and
  `Request.set_thinking_block_binding/2` (`:error` / `:drop_block`; declare
  `thinking-binding-controls-2026-08-01`); `Response.input_transformations` (raw list, `nil`
  without the beta; replaced by a streamed `message_delta` copy after a fallback).
```

- [ ] **Step 2: CLAUDE.md**

In the Request Builder `**Thinking & effort**` bullet, after `disable_thinking/1;`, insert:
`` `block_binding:` / `set_thinking_block_binding/2` (`:error` / `:drop_block`) declare `thinking-binding-controls-2026-08-01`; ``

In Response Handling, add:

```markdown
- **`input_transformations`** — raw list of API input changes (`thinking_dropped` / `thinking_mismatch_allowed`, with `path` and `reason`); `[]` when nothing changed, `nil` without the block-binding beta
```

- [ ] **Step 3: Roadmap** — S15 row status: `implemented on \`feat/s15-thinking-block-binding\`; spec \`2026-09-26-s15-thinking-block-binding-design.md\``. Under the table, note: `S10–S15 complete: next is 0.7.0 release prep (single version bump).`

- [ ] **Step 4: Final gates**

Run: `mix format && mix format --check-formatted && mix compile --warnings-as-errors && mix test`
Expected: all pass.

Run: `mix test test/integration/block_binding_integration_test.exs --include integration`
Expected: 3 tests, 0 failures.

- [ ] **Step 5: Commit**

```bash
git add CHANGELOG.md CLAUDE.md docs/superpowers/specs/2026-06-19-anthropic-api-coverage-roadmap.md
git commit -m "docs(s15): CHANGELOG, CLAUDE.md and roadmap for thinking block binding"
```

---

## Spec coverage (self-review)

| Spec section | Task |
|---|---|
| §1 option + merging setter, beta, raises, wholesale replace | 1 |
| §2 `Response.input_transformations` | 2 |
| §3 stream `message_start` (no code) + `message_delta` replace, both locations | 2 |
| §4 docs incl. `apply_compaction/2` / `to_assistant_content/1` pointers | 3, 4 |
| Testing — integration :error / :drop_block | 3 |
