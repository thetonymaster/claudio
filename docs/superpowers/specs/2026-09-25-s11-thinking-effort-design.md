# S11 — Thinking & effort (adaptive thinking, display, effort, task budgets)

- **Date:** 2026-09-25
- **Spec status:** approved design; implementation plan to follow (writing-plans)
- **Scope class:** additive helpers + one response-parsing fix + telemetry keys. Ships in
  **0.7.0** (the single bump after S15; no `@version` change in this spec).
- **Roadmap:** `docs/superpowers/specs/2026-06-19-anthropic-api-coverage-roadmap.md` → "2026-09 refresh"
- **Provenance:** live docs fetched 2026-09-25 — `build-with-claude/thinking` (TH),
  `build-with-claude/thinking-troubleshooting` (TS), `build-with-claude/effort` (EF),
  `build-with-claude/task-budgets` (TB), `build-with-claude/thinking-steering-and-cost` (ST),
  `models/overview` (MO), all under `platform.claude.com/docs/en/`. Every code claim below
  was checked against this repo's source (main @ 92a0283) on the same date.

## Problem

Claudio exposes thinking and output controls only as raw maps:
`Request.enable_thinking/2` replaces `thinking`, and `Request.set_output_config/2` replaces
`output_config`. Current models moved to **adaptive thinking** controlled by
**`output_config.effort`**, with a `display` switch and an optional **task budget**; callers
must hand-assemble these maps, remember which need a beta header, and avoid clobbering
`output_config.format` (set by `set_output_format/2`).

Two observability gaps compound this:

1. `Response.parse_usage/1` (`lib/claudio/messages/response.ex:427-452`) keeps only four
   keys, so `usage.output_tokens_details.thinking_tokens` — the only way to see how many
   output tokens went to thinking — is dropped from every parsed `Response`.
2. Both usage-telemetry emitters keep the same four keys:
   `Claudio.Messages.usage_to_metadata/1` (`lib/claudio/messages.ex:358-368`, `:stop`
   metadata of the `[:claudio, :messages, :create]` span) and
   `Claudio.Messages.Stream.usage_to_metadata/1` (`lib/claudio/messages/stream.ex:106-112`,
   `[:claudio, :messages, :stream, :usage]`).

And `display: "updates"` produces several short `thinking` blocks as progress notes, which
callers currently have no helper to read (non-streaming or streaming) and no way to recognise
the documented "interrupted" placeholder.

### Verified facts this spec rests on

| # | Fact | Source |
|---|------|--------|
| F1 | Adaptive shape: `thinking: {"type": "adaptive", "display": ...}`; no budget field ("You don't set a thinking token budget"). | TH, ST |
| F2 | `{"type": "enabled", "budget_tokens": n}` is deprecated on 4.6 and returns 400 on 4.7+; `{"type": "disabled"}` is rejected on "Always on" models (Fable 5.x, Mythos 5.x, Opus 5.5) and on Opus 5 at effort `xhigh`/`max`. | TS |
| F3 | `display` lives inside `thinking`; valid with `adaptive` and `enabled`, **invalid with `disabled`**. Values: `"summarized"`, `"omitted"`, `"updates"`. Defaults are per-model (omitted on 4.7+ / 5.x). | TH |
| F4 | `display: "updates"` requires beta header `thinking-display-updates-2026-08-18`; without it the API returns the same 400 as an unknown `display` value. | TH |
| F5 | `omitted` returns ordinary `thinking` blocks with `"thinking": ""` plus `signature`; streams a `thinking_delta` with empty text, then `signature_delta`. No new block/delta/event type. | TH |
| F6 | Each update is its own `thinking` block with its own `signature`, placed immediately before a `tool_use`/`server_tool_use` block. "Treat a block as a progress update as soon as one of its `thinking_delta` events carries non-empty text." An interrupted update's text is exactly `This part of the response was interrupted before it finished.` | TH |
| F7 | `output_config.effort` ∈ `low`/`medium`/`high`/`xhigh`/`max`; GA, no beta header; per-model support and defaults vary (Haiku 4.5 unsupported). | EF, MO |
| F8 | Task budget: `output_config.task_budget = {"type": "tokens", "total": n, "remaining": m?}` (`remaining` defaults to `total`); beta header `task-budgets-2026-03-13`; minimum `total` 20,000 (smaller → 400); no maximum documented; no response/usage field; no new `stop_reason`. | TB |
| F9 | `usage.output_tokens_details.thinking_tokens` exists; when streaming it appears only on the final `message_delta`. | ST |
| F10 | `Stream.build_final_message/1` stores the `message_delta` usage map (`maybe_put_usage/2`), so `output_tokens_details` survives into the streamed final message. **Correction (PR #19 review):** it *replaced* the `message_start` usage wholesale, dropping `input_tokens` when the delta omits it (and `Response.parse_usage/1` then returned the raw map); fixed to merge, delta wins. | repo |
| F11 | `Request.add_beta/2` + `required_betas/1` already exist; Messages, count_tokens and Batches merge `required_betas/1` into the header. | repo |
| F12 | **Live probes, 2026-09-25, `claude-opus-5-5`:** `display: "updates"` + `thinking-display-updates-2026-08-18` → 200; without the beta → 400 `thinking.adaptive.display: Input should be 'summarized', 'omitted'`. `task_budget` + `task-budgets-2026-03-13` → 200; without → 400 `output_config.task_budget: Extra inputs are not permitted`. `total: 19999` → 400 `` `task_budget.total` must be at least 20,000 tokens for this model`` (floor is per-model). `remaining: 0` → **200**. Unknown beta strings → 400 (so the 200s prove both strings are recognised). Effort `low` + trivial prompt → no thinking block, `output_tokens_details.thinking_tokens: 0` (details present even when 0). | probe |

## Goals / non-goals

**Goals**

- Typed request helpers for adaptive thinking (+ `display`), disabling thinking, effort, and
  task budgets — each declaring its own beta header when one is needed.
- Parse and expose `usage.output_tokens_details`; surface `thinking_tokens` in both
  telemetry emitters.
- Reader helpers for thinking text: non-streaming (`Response`) and streaming (`Stream`),
  plus recognition of the interrupted-update placeholder.

**Non-goals**

- **No per-model validation.** Claudio stays model-agnostic (decided at S10): which model
  supports which effort level, thinking type, `display` default or task budget is the
  API's call; its 400 is the source of truth. Helpers validate only values the API rejects
  on *every* model.
- **No local 20,000-token floor** on `task_budget.total` (decided: option (a)); only
  "positive integer" is checked.
- No change to existing public signatures: `enable_thinking/2`, `set_output_config/2`,
  `set_output_format/2` keep their current behaviour.
- `thinking.block_binding` / `thinking-binding-controls-2026-08-01` /
  `input_transformations` → **S15**. Per-message effort (`mid-conversation-output-config-2026-07-01`) → **S12**.

## Design

All request helpers live in `lib/claudio/messages/request.ex` beside `enable_thinking/2` /
`set_output_config/2`. Enumerated values are **atoms only**; anything else raises
`ArgumentError` naming the function, the allowed values and the value received (same style as
S10's `add_code_execution_tool/2` `:version`). Option keys are checked with
`Keyword.validate!/2`, so an unknown option raises too.

### 1. Thinking helpers (replace `thinking`)

`thinking` holds exactly one mode, so both helpers **replace** the field (like
`enable_thinking/2`).

```elixir
@spec enable_adaptive_thinking(t(), keyword()) :: t()
Request.enable_adaptive_thinking(req)                      # %{"type" => "adaptive"}
Request.enable_adaptive_thinking(req, display: :omitted)   # + "display" => "omitted"
Request.enable_adaptive_thinking(req, display: :updates)   # + add_beta("thinking-display-updates-2026-08-18")

@spec disable_thinking(t()) :: t()
Request.disable_thinking(req)                              # %{"type" => "disabled"}
```

- `:display` ∈ `:summarized | :omitted | :updates`; omitted option → no `"display"` key (the
  model's default applies, F3).
- Only `:updates` declares a beta (F4).
- `disable_thinking/1` never carries `display` (F3). It does **not** remove a beta declared
  earlier (betas are append-only today; an unused beta header is harmless).
- `enable_thinking/2` stays the raw escape hatch (e.g. `enabled` + `budget_tokens` +
  `display` on 4.6-and-earlier models); its doc drops "planned (roadmap S11)" and points here.

### 2. Output-config helpers (merge into `output_config`)

Both **merge** into `output_config` exactly as `set_output_format/2` does
(`Map.put(existing || %{}, key, value)`), so `set_effort`, `set_task_budget` and
`set_output_format` compose in any order.

```elixir
@spec set_effort(t(), :low | :medium | :high | :xhigh | :max) :: t()
Request.set_effort(req, :high)                 # output_config["effort"] = "high"

@spec set_task_budget(t(), pos_integer(), keyword()) :: t()
Request.set_task_budget(req, 64_000)           # output_config["task_budget"] = %{"type" => "tokens", "total" => 64000}
Request.set_task_budget(req, 64_000, remaining: 20_000)   # + "remaining" => 20000
# both declare add_beta("task-budgets-2026-03-13")
```

- `total` must be a positive integer; `:remaining` a non-negative integer (0 = budget spent,
  a legitimate state when carrying a budget across turns). No 20,000 floor, no
  `remaining <= total` check — API's call (non-goals).
- `set_output_config/2` keeps replacing the whole map; its doc gains a warning that calling it
  after these helpers discards `effort` / `task_budget` / `format`.

### 3. Usage: `output_tokens_details`

`Response.parse_usage/1` (both the atom- and string-key clauses, and the `nil` clause) adds
`output_tokens_details`, carried **raw** (`map() | nil`, keys as received), consistent with
how `stop_details` is carried. The `usage` type gains
`output_tokens_details: map() | nil`. `parse_usage(other)` (the fallthrough) is unchanged.

### 4. Telemetry: `:thinking_tokens`

Both `usage_to_metadata/1` functions add a flat `:thinking_tokens` key read from
`output_tokens_details.thinking_tokens` (atom or string keys at either level), and omit it
when absent — the same rule they already apply to nil cache keys. Result: the
`[:claudio, :messages, :create]` `:stop` metadata and the
`[:claudio, :messages, :stream, :usage]` metadata stay identical in shape.

### 5. Reading thinking text

**Non-streaming** (`lib/claudio/messages/response.ex`):

```elixir
@spec get_thinking(t()) :: [String.t()]
Response.get_thinking(resp)   # non-empty `thinking` texts, in content order

@spec thinking_interrupted?(content_block()) :: boolean()
Response.thinking_interrupted?(block)
# true iff block is %{type: :thinking} and its text is exactly
# "This part of the response was interrupted before it finished." (F6)
```

- `get_thinking/1` returns a **list**, not a joined string (unlike `get_text/1`): under
  `display: :updates` each block is a separate progress note (F6). Empty texts (`omitted`,
  F5) and `redacted_thinking` blocks are excluded. The interrupted placeholder is kept — it
  is the block's text; callers filter with `thinking_interrupted?/1`.
- The placeholder string is a module attribute with a one-line provenance comment (TH).

**Streaming** (`lib/claudio/messages/stream.ex`):

```elixir
@spec accumulate_thinking(Enumerable.t()) :: Enumerable.t()
response |> Stream.parse_events() |> Stream.accumulate_thinking()
# emits {index, text} for every thinking_delta whose text is non-empty
```

- Mirrors `accumulate_text/1` (both key styles, lazy `Stream` pipeline), but emits
  `{content_block_index, text}` tuples: the index is what distinguishes one update block from
  the next, and a block's first emission is exactly the docs' "treat it as a progress update"
  signal (F6). Empty deltas (`omitted`, F5) emit nothing.

### 6. Docs

- CHANGELOG `[Unreleased] — targets 0.7.0`: **Added** (the seven new functions; `:thinking_tokens`
  telemetry key), **Fixed** (`usage.output_tokens_details` no longer dropped).
- CLAUDE.md: Request-builder bullets for the thinking/effort/task-budget helpers; Response
  bullets for `get_thinking/1`, `thinking_interrupted?/1`, `output_tokens_details`; Streaming
  bullet for `accumulate_thinking/1`.
- Roadmap: S11 row → spec written; new **S15** row (thinking block-binding controls:
  `thinking.block_binding.prefix_mismatch_behavior`, beta `thinking-binding-controls-2026-08-01`,
  response-level `input_transformations`); release line → one 0.7.0 bump after **S15**;
  0.8.0 = Managed Agents.

## Testing

TDD, unit tests first (Bypass not needed except where noted):

- `test/request_test.exs`
  - `enable_adaptive_thinking/2`: no opts → `%{"type" => "adaptive"}`, no betas; each
    `:display` value → string in map; `:updates` → `required_betas/1` contains
    `thinking-display-updates-2026-08-18` (once, when called twice); unknown display
    (`:full`, `"omitted"`) and unknown option key raise `ArgumentError`.
  - `disable_thinking/1`: `%{"type" => "disabled"}`; replaces a prior adaptive config
    (no `"display"` survives).
  - `set_effort/2`: each level → string; unknown (`:ultra`, `"high"`) raises.
  - `set_task_budget/3`: shape with/without `:remaining`; beta declared; `total` of `0`,
    `-1`, `1.5`, `"64000"` raise; `remaining: -1` raises, `remaining: 0` accepted.
  - Composition: `set_effort` + `set_task_budget` + `set_output_format` in two different
    orders produce the same `output_config`; `set_output_config/2` afterwards replaces it.
  - `to_map/1` carries `thinking` / `output_config` unchanged from the helpers.
- `test/response_test.exs`
  - `output_tokens_details` parsed with atom keys, string keys, absent (`nil`), and `nil` usage.
  - `get_thinking/1`: mixed content (text, thinking with text, thinking `""`,
    redacted_thinking, two update blocks around a tool_use) → only the non-empty thinking
    texts, in order.
  - `thinking_interrupted?/1`: placeholder → true; other thinking text, text block with the
    placeholder string, redacted_thinking → false.
- `test/messages/stream_test.exs`
  - `accumulate_thinking/1`: two thinking blocks with non-empty deltas plus an empty-delta
    (omitted) block and interleaved text deltas → `[{0, "a"}, {0, "b"}, {2, "c"}]`-style
    tuples only; both key styles.
- `test/messages_test.exs` (where both telemetry tests already live, Bypass)
  - `[:claudio, :messages, :create, :stop]` metadata carries `:thinking_tokens` when the
    response has `output_tokens_details.thinking_tokens`, omits it otherwise.
  - `[:claudio, :messages, :stream, :usage]` metadata: same rule, from the final
    `message_delta` usage.
- Integration (`test/integration/`, tagged `:integration`, opt-in): `claude-opus-5-5` with
  `enable_adaptive_thinking(display: :omitted)` + `set_effort(:high)` (not `:low`: adaptive thinking may skip thinking on an easy prompt at low effort, which would make the block assertion flaky) and a multi-step arithmetic prompt → 200, at least one
  `:thinking` block with `""` text and a signature, and
  `usage.output_tokens_details` containing `thinking_tokens`. (Task budgets and `:updates`
  are not live-tested: they need betas that may not be enabled on the test key.)

## Risks

| Risk | Effect if it bites | Mitigation |
|------|--------------------|------------|
| Beta strings change (`thinking-display-updates-2026-08-18`, `task-budgets-2026-03-13`) | 400 from API | Pinned from live docs and verified by live probe 2026-09-25 (F12); one constant each; re-pin at 0.7.0 release prep. |
| Effort/display value set grows (e.g. a new level) | Local `ArgumentError` blocks a valid value | `set_output_config/2` / `enable_thinking/2` remain raw escape hatches; add the value in a patch. |
| `remaining: 0` rejected by the API | — | **Resolved:** live probe (F12) → 200. |
| Interrupted-placeholder text changes | `thinking_interrupted?/1` returns false | Exact string with provenance comment; one attribute to update. |
| `output_tokens_details` streamed only on final `message_delta` (F9) and callers read `message_start` usage | Missing `thinking_tokens` | `build_final_message/1` already uses the `message_delta` usage (F10); stream telemetry reads the latest `message_delta`. |
