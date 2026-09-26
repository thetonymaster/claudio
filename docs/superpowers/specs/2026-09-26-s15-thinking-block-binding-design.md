# S15 — Thinking block-binding controls (`thinking.block_binding`, `input_transformations`)

- **Date:** 2026-09-26
- **Spec status:** Design approved by Q in chat (2026-09-26); written spec awaiting Q's review.
- **Scope class:** one nested request option + setter, one response field, stream carry-over.
  Ships in **0.7.0** — the last spec before the single version bump.
- **Provenance:** live docs fetched 2026-09-26 — `build-with-claude/preserved-thinking` (PT,
  section "Set the mismatch behavior and read `input_transformations`"),
  `release-notes/overview` (RN), under `platform.claude.com/docs/en/` — plus live probes B0–B9
  (2026-09-26, `claude-opus-5-5`) and S13 probes P12/P13.

## Problem

A signed `thinking` block is bound to the conversation prefix it was produced under. When a
caller edits history (rewrites an earlier message, removes a block from the middle), the API
either rejects the request or — on older accounts — silently accepts it. Claudio can't choose the
behavior (`block_binding` has no setter, and `enable_adaptive_thinking/2` would overwrite a
hand-set one) and can't see what the API did (`input_transformations` is dropped by
`Response.from_map/1`).

## Verified facts

| # | Fact | Source |
|---|------|--------|
| F1 | Request: `"thinking": {"type": "adaptive" \| "enabled", …, "block_binding": {"prefix_mismatch_behavior": "error" \| "drop_block"}}`; beta `thinking-binding-controls-2026-08-01` (RN 2026-09-01; `thinking_mismatch_allowed` added RN 2026-09-14). | PT, RN |
| F2 | Without the beta → 400 "thinking.adaptive.block_binding: Extra inputs are not permitted" (B5). With `"type": "disabled"` → 400 "thinking.disabled.block_binding: Extra inputs are not permitted" (B6). | B5, B6 |
| F3 | `"error"` on a mismatched prefix → 400: "messages.1.content.0: Invalid \`signature\` in \`thinking\` block. The block is bound to a different conversation. Remove the block, or set \`thinking.block_binding.prefix_mismatch_behavior\` to \"drop_block\". Content before this block differs from when it was created, first at \`messages.0.content.0\`." (B2). | B2 |
| F4 | `"drop_block"` → 200; the failing block and every later thinking block are dropped; `input_transformations: [{"type":"thinking_dropped","path":"messages.1.content.0","reason":"prefix_binding_mismatch"}]`; dropped blocks aren't billed (123 input tokens vs 135 unset, B3/B4). | PT, B3, B4 |
| F5 | Unset: accounts created on/after 2026-08-31 00:00 UTC behave as `"error"`; older accounts aren't enforced — with the beta the mismatch is reported as `thinking_mismatch_allowed` (B4). **The probe key is an older account** (B4, S13 P13), so integration tests must set `:error` explicitly to observe enforcement. | PT, B4 |
| F6 | `input_transformations`: top-level array on every response **when the beta is sent** (`[]` when nothing happened, B0); **absent** (no key) without the beta (B1). Entry `{type, path, reason}`; `type` ∈ `thinking_dropped`, `thinking_mismatch_allowed`; `reason` ∈ `prefix_binding_mismatch`, `model_binding_mismatch`; docs: ignore unknown `type`/`reason` values. | PT, B0, B1 |
| F7 | Model binding (Fable 5.1 / Mythos 5.1 blocks read by earlier models, e.g. after a fallback) always drops, regardless of `prefix_mismatch_behavior`; reported as `model_binding_mismatch` with the beta. | PT |
| F8 | Streaming: the array is on `message_start.message` (B9). PT: "After a mid-stream server-side fallback, the final `message_delta` event carries it again with the serving model's entries." A normal `message_delta` carries no such key (B9: event keys `type, delta, usage`). The post-fallback nesting (event top level vs `delta`) is **unverified** — a refusal can't be triggered on purpose (S12b F13). | PT, B9 |
| F9 | `count_tokens` runs the same check: `"error"` → the same 400 (B7); `"drop_block"` → 200 `{"input_tokens": 123}` with no `input_transformations` (B8). | PT, B7, B8 |
| F10 | Batches: an item failing under explicit `"error"` resolves `errored`; unset items don't fail (enforced accounts drop instead). | PT |
| F11 | Safe edits (no mismatch): appending, removing blocks from the start or end, server-side compaction/editing. Pruning before a threshold `compaction` block keeps the kept `thinking` block valid (S13 P12 → `[]`); editing the summary text is reported (S13 P13). | PT, S13 P12/P13 |
| F12 | Claudio today: `enable_adaptive_thinking/2` (`request.ex` ~556) builds a fresh `thinking` map (`Keyword.validate!(opts, [:display])`); `enable_thinking/2` is the raw setter; `Response.from_map/1` reads `diagnostics`/`stop_details` raw but not `input_transformations`; `Stream.build_final_message/1` stores `message_start.message` (so the key survives into `from_map`) and reads only `stop_reason`/`stop_sequence`/`stop_details` from `message_delta.delta`. | code |

## Design

### 1. Request (`Q, 2026-09-26`: option + merging setter)

```elixir
@spec set_thinking_block_binding(t(), :error | :drop_block) :: t()
```

- `enable_adaptive_thinking/2` accepts `block_binding: :error | :drop_block` (added to its
  `Keyword.validate!/2` list). When given, the built map gains
  `"block_binding" => %{"prefix_mismatch_behavior" => "error" | "drop_block"}` and the beta is
  declared. Composes with `display:` (both keys in one map). `nil`/omitted → unchanged behavior.
- `set_thinking_block_binding/2` merges `"block_binding"` into the current `thinking` map
  (string or atom-keyed maps: the key is added as a string) and declares the beta — covers the
  raw `enable_thinking/2` `"enabled"` form and ordering after `enable_adaptive_thinking/2`.
  `thinking == nil` → `ArgumentError` ("…call a thinking setter first").
- Any other behavior value → `ArgumentError` naming the function and `inspect/1` of the value.
- **Not** validated locally: `"disabled"` + `block_binding` (F2, API 400 is clear), model support.
- A later `enable_adaptive_thinking/2` / `enable_thinking/2` / `disable_thinking/1` still replaces
  `thinking` wholesale (documented); the declared beta stays (as with `display: :updates`).
- `count_tokens`: no change — `thinking` is kept, and the API applies the same check (F9).

### 2. Response

- New struct field `input_transformations :: [map()] | nil` — the raw list (string-keyed
  entries), `nil` when the key is absent (F6). No typed entries and no helper (F6: new `type` /
  `reason` values are expected).

### 3. Streaming

- `message_start`: no code — the stored message carries the key into `from_map/1` (F8, B9).
- `message_delta`: when the event has `"input_transformations"` at its top level, or else in
  `"delta"`, it replaces the stored value (the serving model's entries after a fallback, F8). The
  two-location read is deliberate: the nesting is unverified (F8); the code comment says so.

### 4. Docs

- `enable_adaptive_thinking/2`, `set_thinking_block_binding/2`: behaviors, beta, F5 default note.
- `Response` moduledoc: `input_transformations` (present only with the beta).
- `Request.apply_compaction/2` (S13) and `Response.to_assistant_content/1`: a one-line pointer
  that `:drop_block` is the escape hatch for histories the caller edits.
- CHANGELOG `[Unreleased]`, CLAUDE.md (Request + Response bullets), roadmap row.

## Testing

- **Unit (`request_test.exs`):** `enable_adaptive_thinking(block_binding: :drop_block)` exact map
  and beta; with `display: :summarized` too; omitted → map unchanged, no beta;
  `set_thinking_block_binding/2` after `enable_adaptive_thinking/2`, after
  `enable_thinking(%{"type" => "enabled", "budget_tokens" => 2048})`, after an atom-keyed raw map;
  `nil` thinking raises; bad value raises (both functions); a later `disable_thinking/1` replaces
  it.
- **Unit (`response_test.exs`):** field present (`[]` and one entry) and absent (`nil`), string and
  atom top-level keys.
- **Unit (`messages/stream_test.exs`):** `message_start` with one entry → field set; a
  `message_delta` carrying the key at the top level replaces it; one carrying it inside `delta`
  replaces it; a `message_delta` without it keeps the `message_start` value.
- **Integration (`test/integration/block_binding_integration_test.exs`):** one live call to get a
  signed thinking block (adaptive thinking, tiny prompt), then the same history with the first
  user message edited:
  1. `set_thinking_block_binding(:error)` → `{:error, %APIError{}}` whose message contains
     "bound to a different conversation" (B2).
  2. `:drop_block` → 200, `input_transformations` has exactly one `thinking_dropped` /
     `prefix_binding_mismatch` entry (B3).

## Out of scope

- Detecting or repairing prefix mismatches client-side.
- Typed `input_transformations` entries or readers.
- Model-binding behavior (not configurable, F7).
