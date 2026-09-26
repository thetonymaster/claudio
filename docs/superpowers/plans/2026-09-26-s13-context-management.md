# S13 Context Management Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Typed context-editing builders with correct betas, threshold and on-demand compaction (request, typed `compaction` block, `:compaction` stop reason, streamed `compaction_delta`, replay beta), `Request.apply_compaction/2`, and `Response.context_management`.

**Architecture:** `Request` gains three edit builders that append to `context_management["edits"]` (clear_thinking always first), a raw-setter fix that declares `compact-2026-01-12`, a `compaction` struct field set by `request_compaction/2`, `apply_compaction/2` (replaces history with the content from the last compaction block onward), and a compaction scan in `add_message/3` that declares the replay beta. `Response` types the block (`raw:` kept and replayed verbatim), parses `:compaction`, and carries `context_management` raw. `Stream` merges `compaction_delta` into the block and captures the top-level `message_delta.context_management`.

**Tech Stack:** Elixir ≥ 1.15, ExUnit (async), Bypass, Jason.

**Spec:** `docs/superpowers/specs/2026-09-26-s13-context-management-design.md`

## Global Constraints

- Beta strings, verbatim: `context-management-2025-06-27` (clear_* edits and every `set_context_management/2`), `compact-2026-01-12` (threshold `compact_20260112` edit; unsigned compaction block replay), `compact-2026-09-04` (on-demand `compaction` field; signed compaction block replay).
- Edit type strings, verbatim: `clear_tool_uses_20250919`, `clear_thinking_20251015`, `compact_20260112`. On-demand field: `%{"type" => "summarize"}`.
- `clear_thinking_20251015` is always at index 0 of `edits` (API 400 otherwise, spec F4).
- Model-agnostic, API-authoritative: no local checks of trigger minimums (50000), value ranges, duplicate edits, model support, or the on-demand incompatibilities (spec F13). Local `ArgumentError` only for shapes that can't be meant (spec §1, §2). Unknown option keys raise via `Keyword.validate!/2` (same as `enable_adaptive_thinking/2`).
- Enumerated values are atoms (`:input_tokens`, `:tool_uses`, `:all`); errors name the function, the option and `inspect/1` of the value.
- Module attributes used by `add_message/3` (~line 121) must be defined **above** it — next to `@fallback_beta` (~line 74).
- Existing public signatures unchanged. `parse_stop_reason("compaction")` becomes `:compaction` (was the string `"compaction"`) — a CHANGELOG "Changed" entry. No `@version` bump; CHANGELOG under `## [Unreleased] — targets 0.7.0`.
- Commits: add files individually (`git add .` forbidden); **no AI attribution lines** (no Co-Authored-By, no "Generated with").
- Gates before each commit: `mix format` and `mix compile --warnings-as-errors`; Task 6 ends with `mix format --check-formatted`, the full suite, and the integration file.

## Pre-flight: re-verify facts

The spec's facts were probed on 2026-09-26. Before Task 1, re-fetch
`platform.claude.com/docs/en/build-with-claude/compaction-on-demand` and `…/compaction-threshold`
and confirm the three beta strings above still appear. If one changed, stop and ask Q.

## Review Focus

1. `apply_compaction/2` must replace **only** `messages` and `compaction`: `system`, `tools`, `thinking`, `max_tokens`, `context_management` and `betas` survive. Pinned in Task 4.
2. A raw atom-keyed `set_context_management(%{edits: [...]})` followed by a builder must not produce both `:edits` and `"edits"` keys. Pinned in Task 1.
3. A streamed compaction block must replay byte-exact: `to_assistant_content/1` of the stream-built Response is exactly `[%{"type" => "compaction", "content" => summary}]` (no `nil` leftovers, no extra keys). Pinned in Task 3.
4. `add_message/3` with string content, or a list holding non-map entries, must not crash the compaction scan and must declare no compaction beta. Pinned in Task 4.
5. `set_context_management/2` after builders replaces the edits wholesale (documented raw-setter behavior) while already-declared betas stay. Pinned in Task 1.

## Branching

Implementation branch `feat/s13-context-management`, cut from `docs/s13-s15-specs` (specs + plans).

---

### Task 1: Context-editing builders and the raw-setter compaction beta

**Files:**
- Modify: `lib/claudio/messages/request.ex` — module attributes after `@fallback_beta` (~line 74); `set_context_management/2` and its doc (~lines 658-675); three new public functions directly after it; private helpers next to `has_fallback_block?/1` (~line 135)
- Test: `test/request_test.exs` — extend `describe "set_context_management/2 beta wiring"` (~line 269) and add `describe "context-editing builders"` right after it

**Interfaces:**
- Consumes: `add_beta/2`, `maybe_put/3` (existing).
- Produces: `Request.add_clear_tool_uses(t(), keyword()) :: t()`, `Request.add_clear_thinking(t(), keyword()) :: t()`, `Request.add_compaction(t(), keyword()) :: t()`; module attributes `@context_management_beta "context-management-2025-06-27"` and `@compaction_beta "compact-2026-01-12"` (Task 4 uses `@compaction_beta`). Task 5 uses all three builders.

- [ ] **Step 1: Write the failing tests**

In `test/request_test.exs`, add inside `describe "set_context_management/2 beta wiring"` (after its last test):

```elixir
    test "a raw compact_20260112 edit also declares compact-2026-01-12" do
      for config <- [
            %{"edits" => [%{"type" => "compact_20260112"}]},
            %{edits: [%{type: "compact_20260112"}]}
          ] do
        request = Request.new("claude-opus-5-5") |> Request.set_context_management(config)

        assert Request.required_betas(request) == [
                 "context-management-2025-06-27",
                 "compact-2026-01-12"
               ]
      end
    end

    test "without a compact edit only the context-management beta is declared" do
      request =
        Request.new("claude-opus-5-5")
        |> Request.set_context_management(%{"edits" => [%{"type" => "clear_tool_uses_20250919"}]})

      assert Request.required_betas(request) == ["context-management-2025-06-27"]
    end
```

Then add a new `describe` directly after that block:

```elixir
  describe "context-editing builders" do
    defp edits(request), do: Request.to_map(request)["context_management"]["edits"]

    test "add_clear_tool_uses/2 with no options sends only the type" do
      request = Request.new("claude-opus-5-5") |> Request.add_clear_tool_uses()

      assert edits(request) == [%{"type" => "clear_tool_uses_20250919"}]
      assert Request.required_betas(request) == ["context-management-2025-06-27"]
    end

    test "add_clear_tool_uses/2 maps every option" do
      request =
        Request.new("claude-opus-5-5")
        |> Request.add_clear_tool_uses(
          trigger: {:tool_uses, 5},
          keep: 2,
          clear_at_least: 1000,
          exclude_tools: ["web_search"],
          clear_tool_inputs: false
        )

      assert edits(request) == [
               %{
                 "type" => "clear_tool_uses_20250919",
                 "trigger" => %{"type" => "tool_uses", "value" => 5},
                 "keep" => %{"type" => "tool_uses", "value" => 2},
                 "clear_at_least" => %{"type" => "input_tokens", "value" => 1000},
                 "exclude_tools" => ["web_search"],
                 "clear_tool_inputs" => false
               }
             ]
    end

    test "add_clear_tool_uses/2 input_tokens trigger" do
      request =
        Request.new("claude-opus-5-5")
        |> Request.add_clear_tool_uses(trigger: {:input_tokens, 100_000})

      assert [%{"trigger" => %{"type" => "input_tokens", "value" => 100_000}}] = edits(request)
    end

    test "add_clear_thinking/2 maps keep: :all and keep: n" do
      assert edits(Request.new("m") |> Request.add_clear_thinking(keep: :all)) ==
               [%{"type" => "clear_thinking_20251015", "keep" => "all"}]

      assert edits(Request.new("m") |> Request.add_clear_thinking(keep: 2)) ==
               [
                 %{
                   "type" => "clear_thinking_20251015",
                   "keep" => %{"type" => "thinking_turns", "value" => 2}
                 }
               ]

      assert edits(Request.new("m") |> Request.add_clear_thinking()) ==
               [%{"type" => "clear_thinking_20251015"}]
    end

    test "add_compaction/2 maps its options and declares compact-2026-01-12" do
      request =
        Request.new("claude-opus-5-5")
        |> Request.add_compaction(
          trigger: 150_000,
          pause_after_compaction: true,
          instructions: "Keep file paths."
        )

      assert edits(request) == [
               %{
                 "type" => "compact_20260112",
                 "trigger" => %{"type" => "input_tokens", "value" => 150_000},
                 "pause_after_compaction" => true,
                 "instructions" => "Keep file paths."
               }
             ]

      assert Request.required_betas(request) == ["compact-2026-01-12"]
    end

    test "clear_thinking is placed first whatever the call order; others keep their order" do
      request =
        Request.new("claude-opus-5-5")
        |> Request.add_clear_tool_uses()
        |> Request.add_compaction()
        |> Request.add_clear_thinking(keep: :all)

      assert Enum.map(edits(request), & &1["type"]) ==
               ["clear_thinking_20251015", "clear_tool_uses_20250919", "compact_20260112"]

      assert Request.required_betas(request) == [
               "context-management-2025-06-27",
               "compact-2026-01-12"
             ]
    end

    test "builders keep other keys a raw set_context_management/2 put there" do
      request =
        Request.new("claude-opus-5-5")
        |> Request.set_context_management(%{"edits" => [], "future_key" => 1})
        |> Request.add_clear_tool_uses()

      assert Request.to_map(request)["context_management"] == %{
               "edits" => [%{"type" => "clear_tool_uses_20250919"}],
               "future_key" => 1
             }
    end

    test "an atom-keyed raw config keeps a single :edits key" do
      request =
        Request.new("claude-opus-5-5")
        |> Request.set_context_management(%{edits: [%{type: "clear_tool_uses_20250919"}]})
        |> Request.add_compaction()

      cm = Request.to_map(request)["context_management"]

      refute Map.has_key?(cm, "edits")
      assert [%{type: "clear_tool_uses_20250919"}, %{"type" => "compact_20260112"}] = cm.edits
    end

    test "set_context_management/2 after builders replaces the edits; betas stay" do
      request =
        Request.new("claude-opus-5-5")
        |> Request.add_compaction()
        |> Request.set_context_management(%{"edits" => [%{"type" => "clear_tool_uses_20250919"}]})

      assert edits(request) == [%{"type" => "clear_tool_uses_20250919"}]
      assert "compact-2026-01-12" in Request.required_betas(request)
    end

    test "invalid shapes raise ArgumentError" do
      r = Request.new("claude-opus-5-5")

      assert_raise ArgumentError, ~r/add_clear_tool_uses\/2 :trigger/, fn ->
        Request.add_clear_tool_uses(r, trigger: {:turns, 3})
      end

      assert_raise ArgumentError, ~r/add_clear_tool_uses\/2 :keep/, fn ->
        Request.add_clear_tool_uses(r, keep: "3")
      end

      assert_raise ArgumentError, ~r/add_clear_thinking\/2 :keep/, fn ->
        Request.add_clear_thinking(r, keep: 0)
      end

      assert_raise ArgumentError, ~r/add_compaction\/2 :trigger/, fn ->
        Request.add_compaction(r, trigger: {:input_tokens, 50_000})
      end

      assert_raise ArgumentError, fn -> Request.add_compaction(r, bogus: 1) end
    end
  end
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `mix test test/request_test.exs`
Expected: FAIL — `UndefinedFunctionError` for `Request.add_clear_tool_uses/1` (and `/2`, `add_clear_thinking`, `add_compaction`); the two new `set_context_management/2` tests fail on `required_betas` (`["context-management-2025-06-27"]` only). The `defp edits/1` inside `describe` compiles (ExUnit allows it) — if the compiler rejects it, move it to module level and ledger the ruling.

- [ ] **Step 3: Implement**

In `lib/claudio/messages/request.ex`, directly after the `@fallback_beta` line (~line 74), add:

```elixir
  # Context editing (clear_* edits) and threshold compaction (compact_20260112; also needed
  # to replay an unsigned compaction block). Probed 2026-09-26.
  @context_management_beta "context-management-2025-06-27"
  @compaction_beta "compact-2026-01-12"
```

Replace `set_context_management/2` and its `@doc` (~lines 658-675) with:

```elixir
  @doc """
  Sets the raw `context_management` map, replacing any previous one (including edits added
  by `add_clear_tool_uses/2`, `add_clear_thinking/2`, `add_compaction/2`; betas they
  declared stay). Always declares `context-management-2025-06-27`; also declares
  `compact-2026-01-12` when `edits` holds a `compact_20260112` edit (the API rejects it
  otherwise). Prefer the builders.

  ## Example

      Request.new("claude-opus-5-5")
      |> Request.set_context_management(%{
        "edits" => [
          %{"type" => "clear_thinking_20251015", "keep" => "all"},
          %{"type" => "clear_tool_uses_20250919", "keep" => %{"type" => "tool_uses", "value" => 3}},
          %{"type" => "compact_20260112", "trigger" => %{"type" => "input_tokens", "value" => 150_000}}
        ]
      })
  """
  @spec set_context_management(t(), map()) :: t()
  def set_context_management(%__MODULE__{} = request, config) when is_map(config) do
    request = add_beta(%{request | context_management: config}, @context_management_beta)
    if has_compact_edit?(config), do: add_beta(request, @compaction_beta), else: request
  end

  @doc """
  Adds a `clear_tool_uses_20250919` context edit (declares `context-management-2025-06-27`):
  once the trigger is reached, the API clears older tool results from the prompt it sends
  to the model. Your stored history is unchanged.

  ## Options (each omitted option is left to the API default)

  - `:trigger` — `{:input_tokens, n}` or `{:tool_uses, n}`
  - `:keep` — number of most recent tool uses to keep
  - `:clear_at_least` — minimum input tokens to clear (makes the cache invalidation worth it)
  - `:exclude_tools` — tool names never cleared
  - `:clear_tool_inputs` — `true`, `false`, or a list of tool names whose inputs are cleared too

  ## Example

      Request.new("claude-opus-5-5")
      |> Request.add_clear_tool_uses(trigger: {:input_tokens, 100_000}, keep: 3)
  """
  @spec add_clear_tool_uses(t(), keyword()) :: t()
  def add_clear_tool_uses(%__MODULE__{} = request, opts \\ []) when is_list(opts) do
    opts =
      Keyword.validate!(opts, [:trigger, :keep, :clear_at_least, :exclude_tools, :clear_tool_inputs])

    fun = "add_clear_tool_uses/2"

    edit =
      %{"type" => "clear_tool_uses_20250919"}
      |> maybe_put("trigger", opts[:trigger] && clear_trigger!(opts[:trigger]))
      |> maybe_put("keep", opts[:keep] && count_map!(fun, :keep, "tool_uses", opts[:keep]))
      |> maybe_put(
        "clear_at_least",
        opts[:clear_at_least] &&
          count_map!(fun, :clear_at_least, "input_tokens", opts[:clear_at_least])
      )
      |> maybe_put("exclude_tools", opts[:exclude_tools])
      |> maybe_put("clear_tool_inputs", Keyword.get(opts, :clear_tool_inputs))

    request |> put_edit(edit, :last) |> add_beta(@context_management_beta)
  end

  @doc """
  Adds a `clear_thinking_20251015` context edit (declares `context-management-2025-06-27`).
  It is always placed **first** in `edits` — the API rejects it anywhere else.

  ## Options

  - `:keep` — `:all`, or a positive number of recent assistant turns whose thinking is kept.
    Omitted: the model's default.
  """
  @spec add_clear_thinking(t(), keyword()) :: t()
  def add_clear_thinking(%__MODULE__{} = request, opts \\ []) when is_list(opts) do
    opts = Keyword.validate!(opts, [:keep])

    keep =
      case Keyword.get(opts, :keep) do
        nil ->
          nil

        :all ->
          "all"

        n when is_integer(n) and n > 0 ->
          %{"type" => "thinking_turns", "value" => n}

        other ->
          raise ArgumentError,
                "Request.add_clear_thinking/2 :keep must be :all or a positive integer; " <>
                  "got #{inspect(other)}"
      end

    edit = maybe_put(%{"type" => "clear_thinking_20251015"}, "keep", keep)
    request |> put_edit(edit, :first) |> add_beta(@context_management_beta)
  end

  @doc """
  Adds a `compact_20260112` edit — **threshold compaction** (declares `compact-2026-01-12`).
  When the input passes the trigger, the API summarizes the conversation into a
  `compaction` block at the start of the reply; everything before that block is ignored
  on later turns. Keep this edit on every later request that replays the block (the API
  rejects a replayed threshold block without it); see `apply_compaction/2`.

  ## Options (each omitted option is left to the API default)

  - `:trigger` — input tokens that trigger compaction (API default 150000, minimum 50000)
  - `:pause_after_compaction` — `true` returns right after the summary
    (`stop_reason: :compaction`)
  - `:instructions` — summarization instructions
  """
  @spec add_compaction(t(), keyword()) :: t()
  def add_compaction(%__MODULE__{} = request, opts \\ []) when is_list(opts) do
    opts = Keyword.validate!(opts, [:trigger, :pause_after_compaction, :instructions])

    edit =
      %{"type" => "compact_20260112"}
      |> maybe_put(
        "trigger",
        opts[:trigger] && count_map!("add_compaction/2", :trigger, "input_tokens", opts[:trigger])
      )
      |> maybe_put("pause_after_compaction", Keyword.get(opts, :pause_after_compaction))
      |> maybe_put("instructions", opts[:instructions])

    request |> put_edit(edit, :last) |> add_beta(@compaction_beta)
  end

  defp clear_trigger!({kind, n}) when kind in [:input_tokens, :tool_uses] and is_integer(n),
    do: %{"type" => Atom.to_string(kind), "value" => n}

  defp clear_trigger!(other) do
    raise ArgumentError,
          "Request.add_clear_tool_uses/2 :trigger must be {:input_tokens, n} or " <>
            "{:tool_uses, n}; got #{inspect(other)}"
  end

  defp count_map!(_fun, _opt, type, n) when is_integer(n), do: %{"type" => type, "value" => n}

  defp count_map!(fun, opt, _type, other) do
    raise ArgumentError,
          "Request.#{fun} #{inspect(opt)} must be an integer; got #{inspect(other)}"
  end

  # Appends (or, for clear_thinking, prepends) an edit, keeping whichever key style
  # (`"edits"` / `:edits`) a raw set_context_management/2 used and any other keys.
  defp put_edit(%__MODULE__{context_management: cm} = request, edit, position) do
    cm = cm || %{}
    key = if Map.has_key?(cm, :edits) and not Map.has_key?(cm, "edits"), do: :edits, else: "edits"
    current = Map.get(cm, key) || []
    edits = if position == :first, do: [edit | current], else: current ++ [edit]
    %{request | context_management: Map.put(cm, key, edits)}
  end
```

Next to `has_fallback_block?/1` (~line 135), add:

```elixir
  defp has_compact_edit?(config) do
    case Map.get(config, "edits") || Map.get(config, :edits) do
      edits when is_list(edits) ->
        Enum.any?(edits, fn
          %{"type" => type} -> type in ["compact_20260112", :compact_20260112]
          %{type: type} -> type in ["compact_20260112", :compact_20260112]
          _ -> false
        end)

      _ ->
        false
    end
  end
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `mix format && mix compile --warnings-as-errors && mix test test/request_test.exs test/messages_test.exs test/batches_test.exs`
Expected: PASS, 0 failures (the existing context-management tests in `messages_test.exs` / `batches_test.exs` still pass — they only assert the beta is present).

- [ ] **Step 5: Commit**

```bash
git add lib/claudio/messages/request.ex test/request_test.exs
git commit -m "feat(s13): context-editing builders; raw setter declares compact beta"
```

---
### Task 2: Typed `compaction` block, `:compaction` stop reason, `Response.context_management`

**Files:**
- Modify: `lib/claudio/messages/response.ex` — moduledoc (~line 1-25), `@type stop_reason` (~line 28), `@type content_block` (~line 36), new `@type compaction_block` after `fallback_block` (~line 118), usage `@typedoc` (~line 121), `@type t` + `defstruct` (~lines 140-166), `from_map/1` (~line 172), new `compaction_block/1` after `served_by/1` (~line 300), parse clauses after the `fallback` clauses (~line 485), `block_to_api/1` clause after the `:fallback` one (~line 552), `parse_stop_reason/1` (~line 621)
- Test: `test/response_test.exs` — new describes after `describe "from_map/1 diagnostics"` (~line 844)

**Interfaces:**
- Consumes: nothing new.
- Produces: typed block `%{type: :compaction, content: String.t() | nil, raw: map()}`; `block_to_api/1` returns `raw` for it; stop reason `:compaction`; struct field `context_management :: map() | nil`; `Response.compaction_block(t()) :: map() | nil` (last compaction block). Tasks 3, 4, 5 rely on all of these.

- [ ] **Step 1: Write the failing tests**

Add to `test/response_test.exs`, after `describe "from_map/1 diagnostics"`:

```elixir
  describe "from_map/1 compaction blocks" do
    @signed %{"type" => "compaction", "content" => "Summary.", "signature" => "sig"}

    test "string keys parse to a typed block that keeps the original under raw" do
      response = Response.from_map(%{"content" => [@signed], "stop_reason" => "compaction"})

      assert response.stop_reason == :compaction
      assert [%{type: :compaction, content: "Summary.", raw: @signed}] = response.content
    end

    test "atom keys" do
      raw = %{type: "compaction", content: "Summary."}
      response = Response.from_map(%{content: [raw]})

      assert [%{type: :compaction, content: "Summary.", raw: ^raw}] = response.content
    end

    test "content: nil (a failed compaction) parses" do
      response = Response.from_map(%{"content" => [%{"type" => "compaction", "content" => nil}]})
      assert [%{type: :compaction, content: nil}] = response.content
    end

    test "to_assistant_content/1 replays the block byte-exact, signature included" do
      block = Map.put(@signed, "encrypted_content", "enc")

      response =
        Response.from_map(%{
          "content" => [block, %{"type" => "text", "text" => "Hi"}]
        })

      assert Response.to_assistant_content(response) == [
               block,
               %{"type" => "text", "text" => "Hi"}
             ]
    end
  end

  describe "compaction_block/1" do
    test "nil without a compaction block" do
      assert Response.compaction_block(Response.from_map(%{"content" => []})) == nil
    end

    test "returns the last compaction block" do
      response =
        Response.from_map(%{
          "content" => [
            %{"type" => "compaction", "content" => "first"},
            %{"type" => "text", "text" => "x"},
            %{"type" => "compaction", "content" => "second"}
          ]
        })

      assert %{type: :compaction, content: "second"} = Response.compaction_block(response)
    end
  end

  describe "from_map/1 context_management" do
    @applied %{
      "applied_edits" => [
        %{
          "type" => "clear_tool_uses_20250919",
          "cleared_tool_uses" => 2,
          "cleared_input_tokens" => 900
        }
      ]
    }

    test "kept raw, string and atom keys" do
      assert Response.from_map(%{"content" => [], "context_management" => @applied}).context_management ==
               @applied

      assert Response.from_map(%{content: [], context_management: @applied}).context_management ==
               @applied
    end

    test "nil when absent" do
      assert Response.from_map(%{"content" => []}).context_management == nil
    end
  end
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `mix test test/response_test.exs`
Expected: FAIL — `stop_reason` is `"compaction"` (string) not `:compaction`; the block stays a raw string-keyed map (pattern `%{type: :compaction}` fails); `UndefinedFunctionError` for `Response.compaction_block/1`; `KeyError`/struct error for `context_management` (`key :context_management not found`). The byte-exact replay test may already pass (raw pass-through today) — that is fine, it guards the new typed path.

- [ ] **Step 3: Implement**

In `lib/claudio/messages/response.ex`:

1. `@type stop_reason` — add `| :compaction` after `| :model_context_window_exceeded`.
2. `@type content_block` — add `| compaction_block()` after `| fallback_block()`.
3. After the `fallback_block` type (~line 118), add:

```elixir
  @typedoc """
  A compaction summary (`Request.add_compaction/2` threshold compaction, or
  `Request.request_compaction/2` on demand). `content` is the summary text (`nil` when
  compaction failed). `raw` is the block as received — including `signature` for on-demand
  blocks — and is what `to_assistant_content/1` replays.
  """
  @type compaction_block :: %{
          type: :compaction,
          content: String.t() | nil,
          raw: map()
        }
```

4. Usage `@typedoc`: append the sentence
   `With compaction, iterations also holds "type" => "compaction" entries; the top-level counts exclude them (the billed total is the sum over iterations).`
5. `@type t` — add `context_management: map() | nil,` after `diagnostics: map() | nil,`; `defstruct` — add `:context_management` after `:diagnostics`.
6. `from_map/1` — add after the `diagnostics:` line:

```elixir
      context_management: data[:context_management] || data["context_management"],
```

7. After `served_by/1`, add:

```elixir
  @doc """
  Returns the last `compaction` block, or `nil`. See `Request.apply_compaction/2` to
  continue from it.
  """
  @spec compaction_block(t()) :: compaction_block() | nil
  def compaction_block(%__MODULE__{content: content}) do
    content |> Enum.filter(&match?(%{type: :compaction}, &1)) |> List.last()
  end
```

8. After the two `parse_content_block` clauses for `fallback` (before the catch-all `defp parse_content_block(block), do: block`), add:

```elixir
  defp parse_content_block(%{type: "compaction"} = block),
    do: %{type: :compaction, content: block[:content], raw: block}

  defp parse_content_block(%{"type" => "compaction"} = block),
    do: %{type: :compaction, content: block["content"], raw: block}
```

9. After `defp block_to_api(%{type: :fallback, raw: raw}), do: raw`, add:

```elixir
  defp block_to_api(%{type: :compaction, raw: raw}), do: raw
```

10. `parse_stop_reason/1` — add before the `nil` clause:

```elixir
  defp parse_stop_reason("compaction"), do: :compaction
```

11. Moduledoc — append a paragraph:

```
  Context management: `context_management` is the raw response map
  (`%{"applied_edits" => [...]}`, `nil` when the request configured no edits). A
  `:compaction` content block holds a compaction summary; `stop_reason` is `:compaction`
  when the reply is only that block (on-demand compaction, or `pause_after_compaction`).
  Continue with `Request.apply_compaction/2`.
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `mix format && mix compile --warnings-as-errors && mix test test/response_test.exs`
Expected: PASS, 0 failures.

- [ ] **Step 5: Commit**

```bash
git add lib/claudio/messages/response.ex test/response_test.exs
git commit -m "feat(s13): typed compaction block, :compaction stop reason, Response.context_management"
```

---

### Task 3: Streaming — `compaction_delta` and `message_delta.context_management`

**Files:**
- Modify: `lib/claudio/messages/stream.ex` — `apply_delta/2` clauses before the catch-all `defp apply_delta(block, _delta), do: block` (~line 449); the `message_delta` reducer clause in `build_final_message/1` (~line 270)
- Test: `test/messages/stream_test.exs` — new describe at the end of the module

**Interfaces:**
- Consumes: Task 2's typed `:compaction` block, `:compaction` stop reason, `Response.context_management`.
- Produces: `build_final_message/1` output where a streamed compaction block holds the full summary under `"content"` and the message holds top-level `"context_management"`.

- [ ] **Step 1: Write the failing test**

Add at the end of `test/messages/stream_test.exs` (before the final `end`). The SSE sequence is the recorded shape of probe P5 (spec F9), with the summary shortened:

```elixir
  describe "build_final_message/1 threshold compaction" do
    test "compaction_delta fills the block; context_management and stop_reason survive" do
      sse = [
        ~s(event: message_start),
        ~s(data: {"type":"message_start","message":{"id":"m","type":"message","role":"assistant","content":[],"model":"claude-opus-5-5","container":null,"stop_reason":null,"stop_sequence":null,"stop_details":null,"usage":{"input_tokens":0,"output_tokens":0},"diagnostics":null,"context_management":null}}),
        "",
        ~s(event: content_block_start),
        ~s(data: {"type":"content_block_start","index":0,"content_block":{"type":"compaction","content":null}}),
        "",
        ~s(event: content_block_delta),
        ~s(data: {"type":"content_block_delta","index":0,"delta":{"type":"compaction_delta","content":"Summary of the session."}}),
        "",
        ~s(event: content_block_stop),
        ~s(data: {"type":"content_block_stop","index":0}),
        "",
        ~s(event: message_delta),
        ~s(data: {"type":"message_delta","delta":{"stop_reason":"compaction","stop_sequence":null,"stop_details":null,"container":null},"usage":{"input_tokens":0,"output_tokens":0,"iterations":[{"type":"compaction","input_tokens":54453,"output_tokens":883}]},"context_management":{"applied_edits":[]}}),
        "",
        ~s(event: message_stop),
        ~s(data: {"type":"message_stop"}),
        ""
      ]

      {:ok, message} =
        [Enum.join(sse, "\n") <> "\n"]
        |> ClaudioStream.parse_events()
        |> ClaudioStream.build_final_message()

      assert message["content"] == [
               %{"type" => "compaction", "content" => "Summary of the session."}
             ]

      assert message["context_management"] == %{"applied_edits" => []}

      response = Claudio.Messages.Response.from_map(message)

      assert response.stop_reason == :compaction
      assert response.context_management == %{"applied_edits" => []}
      assert [%{type: :compaction, content: "Summary of the session."}] = response.content
      assert [%{"type" => "compaction"}] = response.usage.iterations

      # Review Focus 3: the streamed block replays byte-exact.
      assert Claudio.Messages.Response.to_assistant_content(response) == [
               %{"type" => "compaction", "content" => "Summary of the session."}
             ]
    end

    test "a message_delta without context_management keeps the message_start value" do
      sse = [
        ~s(event: message_start),
        ~s(data: {"type":"message_start","message":{"id":"m","content":[],"model":"x","context_management":{"applied_edits":[]},"usage":{"input_tokens":1,"output_tokens":0}}}),
        "",
        ~s(event: message_delta),
        ~s(data: {"type":"message_delta","delta":{"stop_reason":"end_turn"},"usage":{"output_tokens":1}}),
        ""
      ]

      {:ok, message} =
        [Enum.join(sse, "\n") <> "\n"]
        |> ClaudioStream.parse_events()
        |> ClaudioStream.build_final_message()

      assert message["context_management"] == %{"applied_edits" => []}
    end
  end
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `mix test test/messages/stream_test.exs`
Expected: FAIL in the first test — `message["content"]` is `[%{"type" => "compaction", "content" => nil}]` (the catch-all drops the delta) and `message["context_management"]` is `nil` (message_start carried `null`; the delta's top-level key is ignored). The second test passes already (it pins that the new code doesn't overwrite with `nil`).

- [ ] **Step 3: Implement**

In `lib/claudio/messages/stream.ex`, before `defp apply_delta(block, _delta), do: block`, add:

```elixir
  # Threshold compaction streams the whole summary in one compaction_delta after a
  # content_block_start with "content": null (probed 2026-09-26). Every delta field but
  # "type" is written into the block, so encrypted_content/signature survive if sent.
  defp apply_delta(block, %{"type" => "compaction_delta"} = delta) do
    Map.merge(block, Map.delete(delta, "type"))
  end

  defp apply_delta(block, %{type: "compaction_delta"} = delta) do
    Map.merge(block, Map.delete(delta, :type))
  end
```

In the `message_delta` clause of `build_final_message/1`, extend the pipeline:

```elixir
          message =
            state.message
            |> maybe_update(delta, "stop_reason")
            |> maybe_update(delta, "stop_sequence")
            |> maybe_update(delta, "stop_details")
            |> maybe_put_usage(usage)
            # context_management sits at the event's top level, beside delta and usage.
            |> maybe_update(data, "context_management")
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `mix format && mix compile --warnings-as-errors && mix test test/messages/stream_test.exs`
Expected: PASS, 0 failures.

- [ ] **Step 5: Commit**

```bash
git add lib/claudio/messages/stream.ex test/messages/stream_test.exs
git commit -m "feat(s13): stream compaction_delta and message_delta context_management"
```

---
### Task 4: On-demand compaction, `apply_compaction/2`, replay beta in `add_message/3`

**Files:**
- Modify: `lib/claudio/messages/request.ex` — `@type t` + `defstruct` (add `compaction`), `@on_demand_compaction_beta` next to the Task 1 attributes, `add_message/3` and its doc (~lines 95-133), new private helpers next to `has_fallback_block?/1`, two new public functions directly after `add_compaction/2` (Task 1), `to_map/1` (~line 1295)
- Test: `test/request_test.exs` — new describes after `describe "context-editing builders"` (Task 1) and after `describe "add_message/3 with a fallback block"` (~line 66)

**Interfaces:**
- Consumes: Task 1's `@compaction_beta`, `add_compaction/2`; Task 2's typed `:compaction` block, `Response.to_assistant_content/1` returning its `raw`.
- Produces: `Request.request_compaction(t(), keyword()) :: t()`; `Request.apply_compaction(t(), Claudio.Messages.Response.t()) :: t()`; struct field `compaction :: map() | nil` emitted by `to_map/1`; `add_message/3` declares `compact-2026-09-04` for a signed compaction block and `compact-2026-01-12` for an unsigned one. Task 5 uses all of these.

- [ ] **Step 1: Write the failing tests**

In `test/request_test.exs`, after `describe "add_message/3 with a fallback block"`, add:

```elixir
  describe "add_message/3 with a compaction block" do
    test "a signed block declares compact-2026-09-04" do
      for block <- [
            %{"type" => "compaction", "content" => "s", "signature" => "sig"},
            %{type: "compaction", content: "s", signature: "sig"},
            %{type: :compaction, content: "s", raw: %{"type" => "compaction", "signature" => "sig"}}
          ] do
        request = Request.new("m") |> Request.add_message(:assistant, [block])
        assert Request.required_betas(request) == ["compact-2026-09-04"]
      end
    end

    test "an unsigned block declares compact-2026-01-12" do
      for block <- [
            %{"type" => "compaction", "content" => "s"},
            %{type: :compaction, content: "s", raw: %{"type" => "compaction", "content" => "s"}}
          ] do
        request = Request.new("m") |> Request.add_message(:assistant, [block])
        assert Request.required_betas(request) == ["compact-2026-01-12"]
      end
    end

    test "content without a compaction block declares nothing (Review Focus 4)" do
      for content <- ["hi", [%{"type" => "text", "text" => "hi"}], ["stray", 42]] do
        request = Request.new("m") |> Request.add_message(:user, content)
        assert Request.required_betas(request) == []
      end
    end
  end
```

After `describe "context-editing builders"`, add:

```elixir
  describe "request_compaction/2" do
    test "sets compaction: summarize and declares compact-2026-09-04" do
      request = Request.new("claude-opus-5-5") |> Request.request_compaction()

      assert Request.to_map(request)["compaction"] == %{"type" => "summarize"}
      assert Request.required_betas(request) == ["compact-2026-09-04"]
    end

    test "instructions are passed through" do
      request =
        Request.new("claude-opus-5-5") |> Request.request_compaction(instructions: "Keep paths.")

      assert Request.to_map(request)["compaction"] == %{
               "type" => "summarize",
               "instructions" => "Keep paths."
             }
    end

    test "unset: to_map/1 has no compaction key" do
      refute Map.has_key?(Request.to_map(Request.new("m")), "compaction")
    end

    test "unknown options raise" do
      assert_raise ArgumentError, fn -> Request.request_compaction(Request.new("m"), foo: 1) end
    end
  end

  describe "apply_compaction/2" do
    alias Claudio.Messages.Response

    @signed %{"type" => "compaction", "content" => "Summary.", "signature" => "sig"}

    test "on-demand: history becomes one assistant message holding the block; compaction cleared" do
      summary = Response.from_map(%{"stop_reason" => "compaction", "content" => [@signed]})

      request =
        Request.new("claude-opus-5-5")
        |> Request.add_message(:user, "a")
        |> Request.add_message(:assistant, "b")
        |> Request.request_compaction()
        |> Request.apply_compaction(summary)

      assert request.messages == [%{"role" => "assistant", "content" => [@signed]}]
      assert request.compaction == nil
      refute Map.has_key?(Request.to_map(request), "compaction")
      assert "compact-2026-09-04" in Request.required_betas(request)
    end

    test "threshold: keeps content from the block onward, keeps context_management" do
      thinking = %{"type" => "thinking", "thinking" => "", "signature" => "tsig"}
      text = %{"type" => "text", "text" => "Answer"}
      block = %{"type" => "compaction", "content" => "Summary."}
      response = Response.from_map(%{"stop_reason" => "end_turn", "content" => [block, thinking, text]})

      request =
        Request.new("claude-opus-5-5")
        |> Request.add_compaction(trigger: 50_000)
        |> Request.add_message(:user, "long history")
        |> Request.apply_compaction(response)

      assert request.messages == [%{"role" => "assistant", "content" => [block, thinking, text]}]

      assert Request.to_map(request)["context_management"] == %{
               "edits" => [
                 %{
                   "type" => "compact_20260112",
                   "trigger" => %{"type" => "input_tokens", "value" => 50_000}
                 }
               ]
             }

      assert Request.required_betas(request) == ["compact-2026-01-12"]
    end

    test "two compaction blocks: content from the last one" do
      first = %{"type" => "compaction", "content" => "old"}
      last = %{"type" => "compaction", "content" => "new"}
      response = Response.from_map(%{"content" => [first, %{"type" => "text", "text" => "x"}, last]})

      request = Request.new("m") |> Request.apply_compaction(response)

      assert request.messages == [%{"role" => "assistant", "content" => [last]}]
    end

    test "keeps system, tools, thinking, max_tokens and betas (Review Focus 1)" do
      summary = Response.from_map(%{"stop_reason" => "compaction", "content" => [@signed]})
      tool = %{"name" => "t", "description" => "d", "input_schema" => %{"type" => "object"}}

      before =
        Request.new("claude-opus-5-5")
        |> Request.set_system("sys")
        |> Request.add_tool(tool)
        |> Request.enable_adaptive_thinking()
        |> Request.set_max_tokens(512)
        |> Request.add_beta("x-2026-01-01")
        |> Request.add_message(:user, "a")

      after_ = Request.apply_compaction(before, summary)

      assert after_.system == "sys"
      assert after_.tools == [tool]
      assert after_.thinking == %{"type" => "adaptive"}
      assert after_.max_tokens == 512
      assert Request.required_betas(after_) == ["x-2026-01-01", "compact-2026-09-04"]
    end

    test "a response without a compaction block raises" do
      response = Response.from_map(%{"stop_reason" => "end_turn", "content" => [%{"type" => "text", "text" => "x"}]})

      assert_raise ArgumentError, ~r/apply_compaction\/2 .*no compaction block.*:end_turn/, fn ->
        Request.apply_compaction(Request.new("m"), response)
      end
    end
  end
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `mix test test/request_test.exs`
Expected: FAIL — `UndefinedFunctionError` for `request_compaction/1,2` and `apply_compaction/2`; the `add_message/3` compaction tests fail on `required_betas` (`[]`). The "declares nothing" test passes already.

- [ ] **Step 3: Implement**

In `lib/claudio/messages/request.ex`:

1. `@type t` — add `compaction: map() | nil` after `fallbacks: …` (add the comma); `defstruct` — add `compaction: nil` after `fallbacks: nil`.
2. After the Task 1 attributes, add:

```elixir
  # On-demand compaction (top-level `compaction`); also needed on every later request that
  # replays a signed compaction block (probed 2026-09-26).
  @on_demand_compaction_beta "compact-2026-09-04"
```

3. In `add_message/3`, replace the final `if has_fallback_block?(content), …` line with:

```elixir
    request =
      if has_fallback_block?(content), do: add_beta(request, @fallback_beta), else: request

    # A replayed compaction block needs its beta: signed (on-demand) blocks need
    # compact-2026-09-04, unsigned (threshold) blocks compact-2026-01-12 (probed 2026-09-26).
    add_compaction_replay_betas(request, content)
```

and append to its `@doc` (after the fallback sentence):

```
  A `compaction` block declares its replay beta: `compact-2026-09-04` when it carries a
  `signature` (on-demand), else `compact-2026-01-12` (threshold — which also needs the
  `compact_20260112` edit on the request; see `add_compaction/2`).
```

4. Next to `has_fallback_block?/1`, add:

```elixir
  defp add_compaction_replay_betas(request, content) when is_list(content) do
    Enum.reduce(content, request, fn block, acc ->
      cond do
        not compaction_block?(block) -> acc
        compaction_signature(block) -> add_beta(acc, @on_demand_compaction_beta)
        true -> add_beta(acc, @compaction_beta)
      end
    end)
  end

  defp add_compaction_replay_betas(request, _content), do: request

  defp compaction_block?(%{"type" => type}), do: type in ["compaction", :compaction]
  defp compaction_block?(%{type: type}), do: type in ["compaction", :compaction]
  defp compaction_block?(_block), do: false

  # A typed block (Response) keeps the original under :raw.
  defp compaction_signature(%{raw: raw}) when is_map(raw), do: compaction_signature(raw)
  defp compaction_signature(block), do: Map.get(block, "signature") || Map.get(block, :signature)
```

5. Directly after `add_compaction/2`, add:

```elixir
  @doc """
  Asks for an **on-demand** summary of the conversation so far (top-level
  `compaction: %{"type" => "summarize"}`; declares `compact-2026-09-04`). The reply is only
  a signed `compaction` block with `stop_reason: :compaction`; continue with
  `apply_compaction/2`. The API rejects this combined with `context_management`,
  `stop_sequences`, `output_config.format`, a forced `tool_choice`, or a last assistant
  turn ending in an unanswered `tool_use` — those are left to its 400.

  ## Options

  - `:instructions` — replaces the default summarization prompt (≤ 16384 characters)

  ## Example

      {:ok, summary} = Messages.create(client, Request.request_compaction(request))

      request =
        request
        |> Request.apply_compaction(summary)
        |> Request.add_message(:user, "Continue")
  """
  @spec request_compaction(t(), keyword()) :: t()
  def request_compaction(%__MODULE__{} = request, opts \\ []) when is_list(opts) do
    opts = Keyword.validate!(opts, [:instructions])
    compaction = maybe_put(%{"type" => "summarize"}, "instructions", opts[:instructions])
    add_beta(%{request | compaction: compaction}, @on_demand_compaction_beta)
  end

  @doc """
  Continues a conversation from a compaction summary, for either kind of compaction.

  Replaces `messages` with a single assistant message holding the response content from
  its **last** `compaction` block onward (the block first, byte-exact, as the API
  requires), and clears `compaction` so the next call is a normal turn. Everything else
  — `system`, `tools`, `thinking`, `context_management` (a threshold replay needs its
  `compact_20260112` edit), betas — is kept. The replay beta is declared by
  `add_message/3`. Add the next user turn after it.

  Raises `ArgumentError` when the response has no `compaction` block.
  """
  @spec apply_compaction(t(), Claudio.Messages.Response.t()) :: t()
  def apply_compaction(%__MODULE__{} = request, %Claudio.Messages.Response{} = response) do
    content = Claudio.Messages.Response.to_assistant_content(response)

    case last_compaction_index(content) do
      nil ->
        raise ArgumentError,
              "Request.apply_compaction/2 response has no compaction block; " <>
                "got stop_reason #{inspect(response.stop_reason)}"

      index ->
        %{request | messages: [], compaction: nil}
        |> add_message(:assistant, Enum.drop(content, index))
    end
  end

  defp last_compaction_index(content) do
    content
    |> Enum.with_index()
    |> Enum.reduce(nil, fn {block, index}, last ->
      if compaction_block?(block), do: index, else: last
    end)
  end
```

6. `to_map/1` — add `|> maybe_put("compaction", request.compaction)` after the `"fallbacks"` line.

- [ ] **Step 4: Run the tests to verify they pass**

Run: `mix format && mix compile --warnings-as-errors && mix test test/request_test.exs test/response_test.exs`
Expected: PASS, 0 failures. If `mix compile` reports a compile-time cycle between `Request` and `Response` (the `%Claudio.Messages.Response{}` pattern), keep the pattern and ledger it — `Response` never references the `Request` struct, so no cycle is expected.

- [ ] **Step 5: Commit**

```bash
git add lib/claudio/messages/request.ex test/request_test.exs
git commit -m "feat(s13): request_compaction/2, apply_compaction/2, compaction replay beta"
```

---
### Task 5: Live integration test

**Files:**
- Create: `test/integration/context_management_integration_test.exs`

**Interfaces:**
- Consumes: `add_clear_tool_uses/2`, `add_clear_thinking/2`, `add_compaction/2` (Task 1); `Response.compaction_block/1`, `:compaction` (Task 2); `request_compaction/2`, `apply_compaction/2`, the `add_message/3` replay beta (Task 4).
- Produces: nothing consumed later.

This task's tests repeat probes P3a, P1/P2c, P6b and P6d with small inputs (no 50k-token call). They are written after the code, so RED is not observable here — the unit tests in Tasks 1–4 carry the TDD gate; this task proves the betas and shapes against the live API.

- [ ] **Step 1: Write the integration test**

Create `test/integration/context_management_integration_test.exs`:

```elixir
Code.require_file("../integration/integration_helper.exs", __DIR__)

defmodule Claudio.ContextManagementIntegrationTest do
  use ExUnit.Case, async: false
  import Claudio.IntegrationHelper

  alias Claudio.APIError
  alias Claudio.Messages
  alias Claudio.Messages.{Request, Response}

  @moduletag :integration
  @moduletag timeout: 180_000

  @model "claude-opus-5-5"

  setup_all do
    case skip_if_no_api_key() do
      :ok -> {:ok, %{client: create_client()}}
      {:skip, reason} -> {:skip, reason}
    end
  end

  test "edit builders: clear_thinking lands first and both betas are accepted", %{client: client} do
    request =
      Request.new(@model)
      |> Request.add_message(:user, "Say hi.")
      |> Request.set_max_tokens(256)
      |> Request.enable_adaptive_thinking()
      |> Request.add_clear_tool_uses(keep: 3)
      |> Request.add_compaction(trigger: 50_000)
      |> Request.add_clear_thinking(keep: :all)

    # The API rejects clear_thinking anywhere but first (spec F4); a 200 proves the order.
    assert {:ok, %Response{} = response} = Messages.create(client, request)
    assert response.context_management == %{"applied_edits" => []}
  end

  test "on-demand compaction round trip", %{client: client} do
    history =
      Request.new(@model)
      |> Request.add_message(:user, "My name is Q. Remember the file lib/claudio/messages.ex.")
      |> Request.add_message(:assistant, "Noted: lib/claudio/messages.ex.")
      |> Request.set_max_tokens(1024)

    assert {:ok, %Response{stop_reason: :compaction} = summary} =
             Messages.create(client, Request.request_compaction(history))

    assert %{raw: %{"signature" => signature}} = Response.compaction_block(summary)
    assert is_binary(signature)

    next =
      history
      |> Request.request_compaction()
      |> Request.apply_compaction(summary)
      |> Request.add_message(:user, "What file did I mention? One line.")
      |> Request.set_max_tokens(64)

    assert next.compaction == nil
    assert {:ok, %Response{stop_reason: :end_turn}} = Messages.create(client, next)
  end

  defp threshold_summary do
    Response.from_map(%{
      "model" => @model,
      "stop_reason" => "compaction",
      "content" => [%{"type" => "compaction", "content" => "The user is Q."}]
    })
  end

  test "threshold replay with the compact edit is accepted", %{client: client} do
    request =
      Request.new(@model)
      |> Request.add_compaction(trigger: 50_000)
      |> Request.apply_compaction(threshold_summary())
      |> Request.add_message(:user, "Say ok.")
      |> Request.set_max_tokens(16)

    assert {:ok, %Response{}} = Messages.create(client, request)
  end

  test "control: threshold replay without the compact edit is rejected", %{client: client} do
    request =
      Request.new(@model)
      |> Request.apply_compaction(threshold_summary())
      |> Request.add_message(:user, "Say ok.")
      |> Request.set_max_tokens(16)

    # add_message/3 declared compact-2026-01-12, so the error is about the edit (spec F11).
    assert "compact-2026-01-12" in Request.required_betas(request)
    assert {:error, %APIError{status_code: 400, message: message}} = Messages.create(client, request)
    assert message =~ "compact_20260112"
  end
end
```

- [ ] **Step 2: Run it**

Run: `mix test test/integration/context_management_integration_test.exs --include integration`
Expected: 4 tests, 0 failures (needs `ANTHROPIC_API_KEY`; without it the module is skipped and ExUnit reports the tests as invalid — that is a DID NOT RUN, not a pass). If "threshold replay with the compact edit" fails with a signature/content error, the API has started validating unsigned summaries: stop and report to Q (spec F11 would be wrong).

- [ ] **Step 3: Commit**

```bash
mix format
git add test/integration/context_management_integration_test.exs
git commit -m "test(s13): live context management and compaction round trips"
```

---

### Task 6: Docs and final gates

**Files:**
- Modify: `CHANGELOG.md` (`## [Unreleased] — targets 0.7.0`: `### Fixed`, `### Changed`, `### Added`)
- Modify: `CLAUDE.md` (Request Builder bullets ~line 96; Response Handling bullets ~lines 121-137; Streaming delta list ~line 150)
- Modify: `docs/superpowers/specs/2026-06-19-anthropic-api-coverage-roadmap.md` (S13 row status)

**Interfaces:** none.

- [ ] **Step 1: CHANGELOG**

Under `### Fixed` append:

```markdown
- `Stream.build_final_message/1` keeps a streamed threshold-compaction summary
  (`compaction_delta`); it was dropped, leaving `"content": null`.
- `Request.set_context_management/2` also declares `compact-2026-01-12` when its edits hold a
  `compact_20260112` edit; with only `context-management-2025-06-27` the API rejects it. Its
  doc example (`"strategy" => "auto"`) was not a real API shape and is replaced.
```

Under `### Changed` append:

```markdown
- `Response.stop_reason` is `:compaction` (was the string `"compaction"`).
```

Under `### Added` append:

```markdown
- **Context management** (`Claudio.Messages.Request`), no local limits (the API's 400 is
  authoritative):
  - `add_clear_tool_uses/2`, `add_clear_thinking/2` (always placed first) — declare
    `context-management-2025-06-27`; `add_compaction/2` (threshold, `compact_20260112`) —
    declares `compact-2026-01-12`.
  - `request_compaction/2` — on-demand `compaction: {"type": "summarize"}`, declares
    `compact-2026-09-04`; `apply_compaction/2` continues from a compaction summary (either
    kind) by replacing the history with the block onward.
  - `add_message/3` declares the replay beta for a `compaction` block (signed →
    `compact-2026-09-04`, unsigned → `compact-2026-01-12`).
- Typed `:compaction` content blocks (original under `raw:`, replayed verbatim),
  `Response.compaction_block/1`, `Response.context_management` (raw `applied_edits`; also
  read from the streamed `message_delta`).
```

- [ ] **Step 2: CLAUDE.md**

After the `**Refusal fallbacks**` bullet in "Request Builder", add:

```markdown
- **Context management** (`add_clear_tool_uses/2`, `add_clear_thinking/2` — declare `context-management-2025-06-27`, clear_thinking always first; `add_compaction/2` — threshold `compact_20260112`, declares `compact-2026-01-12`; `request_compaction/2` — on-demand `compaction` field, declares `compact-2026-09-04`; `apply_compaction/2` replaces history with the last compaction block onward for either kind; `set_context_management/2` is the raw setter. Limits and incompatibilities are left to the API.)
```

In "Response Handling": change the parsed-block list to end `…, fallback, compaction)`, and after the `to_assistant_content/1` bullet add:

```markdown
- **`compaction` blocks** — `%{type: :compaction, content:, raw:}` (raw replayed byte-exact, keeps the on-demand `signature`); `compaction_block/1`; `stop_reason: :compaction`; `context_management` — raw `applied_edits` map, `nil` unless edits were configured; `add_message/3` declares the compaction replay beta (signed → `compact-2026-09-04`, unsigned → `compact-2026-01-12`)
```

In "Streaming", change `Delta types: text_delta, input_json_delta, thinking_delta` to
`Delta types: text_delta, input_json_delta, thinking_delta, signature_delta, citations_delta, compaction_delta`.

In "Type Safety", change `(:text, :tool_use, :thinking, :mcp_tool_use, :fallback, etc.)` to
`(:text, :tool_use, :thinking, :mcp_tool_use, :fallback, :compaction, etc.)`.

- [ ] **Step 3: Roadmap**

In the S13 row, replace `spec written: \`2026-09-26-s13-context-management-design.md\`` with
`implemented on \`feat/s13-context-management\`; spec \`2026-09-26-s13-context-management-design.md\``.

- [ ] **Step 4: Final gates**

Run: `mix format && mix format --check-formatted && mix compile --warnings-as-errors && mix test`
Expected: all pass, 0 failures (integration tests excluded).

Run: `mix test test/integration/context_management_integration_test.exs --include integration`
Expected: 4 tests, 0 failures.

- [ ] **Step 5: Commit**

```bash
git add CHANGELOG.md CLAUDE.md docs/superpowers/specs/2026-06-19-anthropic-api-coverage-roadmap.md
git commit -m "docs(s13): CHANGELOG, CLAUDE.md and roadmap for context management"
```

---

## Spec coverage (self-review)

| Spec section | Task |
|---|---|
| §1 builders, first-position rule, raises, raw-setter compact beta, doc example | 1 |
| §2 `request_compaction/2`, `apply_compaction/2` (both kinds, clears `compaction`, keeps `context_management`) | 4 |
| §3 replay beta in `add_message/3` (signed / unsigned) | 4 |
| §4 typed block, `:compaction`, `context_management` field, `compaction_block/1`, usage doc | 2 |
| §5 `compaction_delta`, `message_delta.context_management` | 3 |
| §6 count_tokens / Batches unchanged | — (no code; existing Batches beta tests stay green in Task 1 Step 4) |
| Testing — integration 1–3 (+ positive threshold replay) | 5 |
| Docs | 6 |
