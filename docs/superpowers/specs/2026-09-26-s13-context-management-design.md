# S13 — Context management (context editing, threshold compaction, on-demand compaction)

- **Date:** 2026-09-26
- **Spec status:** Design approved by Q in chat (2026-09-26); written spec awaiting Q's review.
- **Scope class:** request builders + new top-level request field + new response content block,
  stop reason, response field and stream delta + a history-replacement helper. Ships in **0.7.0**
  (single bump after S15).
- **Scope decision (Q, 2026-09-26):** one S13 spec covering all three mechanisms (not split into
  S13a/S13b). The roadmap row predates on-demand compaction (release notes 2026-09-14).
- **Provenance:** live docs fetched 2026-09-26 — `build-with-claude/compaction` (CO),
  `build-with-claude/compaction-threshold` (CT), `build-with-claude/compaction-on-demand` (CD),
  `build-with-claude/context-editing` (CE), `api/beta/messages/create` (REF),
  `api/beta/messages/count_tokens` (REFC), `release-notes/overview` (RN), all under
  `platform.claude.com/docs/en/` — plus live probes P1–P13 against `claude-opus-5-5`
  (2026-09-26; `anthropic-version: 2023-06-01`).

## Problem

Claudio exposes `context_management` only as a raw map (`set_context_management/2`), always
declaring `context-management-2025-06-27`. That is wrong for compaction: a `compact_20260112`
edit sent with only that beta is rejected (P3d). Its doc example (`"strategy" => "auto"`,
`"max_context_tokens"`) is not a real API shape. Streaming drops the threshold-compaction
summary (no `compaction_delta` clause in `Stream.apply_delta/2`), so a streamed compaction can
never be replayed. On-demand compaction (a top-level `compaction` field, beta
`compact-2026-09-04`) is not supported at all, and replaying either kind of `compaction` block
needs a beta that nothing declares. The response-side `context_management.applied_edits` is
dropped, and `stop_reason: "compaction"` stays a string.

## Verified facts

| # | Fact | Source |
|---|------|--------|
| F1 | Context editing: `context_management.edits` array, beta `context-management-2025-06-27`, all supported models. | CE, REF |
| F2 | `{"type":"clear_tool_uses_20250919"}` params: `trigger` `{"type":"input_tokens"\|"tool_uses","value":N≥1}` (default input_tokens 100000), `keep` `{"type":"tool_uses","value":N≥0}` (default 3), `clear_at_least` `{"type":"input_tokens","value":N}`, `exclude_tools` `[string]`, `clear_tool_inputs` `boolean \| [string]` (default false). | CE, REF |
| F3 | `{"type":"clear_thinking_20251015","keep":…}` — `keep` is `{"type":"thinking_turns","value":N≥1}`, `{"type":"all"}` or `"all"`; default is model-dependent. | CE, REF |
| F4 | `clear_thinking_20251015` must be the **first** edit: otherwise 400 "context_management: \`clear_thinking_20251015\` must be the first strategy in \`context_management.edits\` when provided" — with a `compact_20260112` first (P3b) and with `clear_tool_uses` first (P3f). `[clear_thinking, clear_tool_uses, compact]` → 200 (P3a). | P3a, P3b, P3f |
| F5 | Threshold compaction: edit `{"type":"compact_20260112","trigger":{"type":"input_tokens","value":N},"pause_after_compaction":bool,"instructions":string\|null}`; default trigger 150000. `value` < 50000 → 400 "context_management.edits.0.compact_20260112: trigger.value must be at least 50000" (P4). Guide says `instructions` replaces the default prompt; REF calls it "additional instructions" — passed through, not interpreted. | CT, REF, P4 |
| F6 | Threshold beta is `compact-2026-01-12`. With only `context-management-2025-06-27`, a `compact_20260112` edit → 400 "Input tag 'compact_20260112' … does not match any of the expected tags: 'clear_thinking_20251015', 'clear_tool_uses_20250919'" (P3d). With only `compact-2026-01-12`: `compact_20260112` alone → 200 (P3c); `clear_tool_uses` alone → 200 (P3e). Both betas together → 200 (P3a). | P3a–P3e |
| F7 | Response: top-level `context_management: {"applied_edits": [...]}` (entries `{type, cleared_tool_uses, cleared_input_tokens}` / `{type, cleared_thinking_turns, cleared_input_tokens}`); `{"applied_edits": []}` when edits were configured but none applied — including after a compaction (P3a, P5, P9). Streaming: on the final `message_delta` event at the **top level**, beside `delta` and `usage` (P5). `message_start.message.context_management` is `null` (P5). | CE, REF, P5, P9 |
| F8 | Threshold compaction block: `{"type":"compaction","content":string}` — **no `signature`, no `encrypted_content`** in practice (P5, P9). REF also allows `content: null` (compaction failed; round-trippable no-op), optional `encrypted_content`, `signature`, `tool_changes`. | P5, P9, REF |
| F9 | Threshold streaming: `content_block_start` with `{"type":"compaction","content":null}`, then one `content_block_delta` `{"type":"compaction_delta","content":"<full summary>"}`, then `content_block_stop` (P5). | CT, P5 |
| F10 | `pause_after_compaction: true` → `stop_reason: "compaction"`, content is only the block, top-level `usage.input_tokens`/`output_tokens` = 0, `usage.iterations: [{"type":"compaction",…}]` (P5). Unpaused → content `[compaction, thinking, text]`, iterations `[compaction, message]` (P9). Top-level usage excludes compaction iterations; billed total = sum of `iterations`. | CT, P5, P9 |
| F11 | Threshold replay: the API ignores all content before a `compaction` block. Replaying a threshold block needs beta `compact-2026-01-12` **and** a `compact_20260112` edit in the request: no beta → 400 "Input tag 'compaction' … does not match" (P6a); beta without the edit → 400 "\`compaction\` blocks require a \`compact_20260112\` strategy in \`context_management.edits\`." (P6b); with `compact-2026-09-04` instead → 400 "a \`compaction\` block with \`content\` requires its \`signature\`" (P6c); beta + edit → 200 (P6d). | CT, P6a–P6d |
| F12 | Pruning before a threshold block is safe: `[assistant: content from the compaction block onward, user: …]` → 200 (P8, P10), and with `thinking-binding-controls-2026-08-01` the kept `thinking` block reports `input_transformations: []` (P12). Control: editing the summary text by one word → `[{"type":"thinking_mismatch_allowed","path":"messages.0.content.1","reason":"prefix_binding_mismatch"}]` (P13). | P8, P10, P12, P13 |
| F13 | On-demand compaction: top-level `"compaction":{"type":"summarize","instructions"?: string}` (≤16384 chars), beta `compact-2026-09-04`. Response: `stop_reason: "compaction"`, content `[{"type":"compaction","content":…,"signature":…}]` (P1). Rejected combinations (400): `context_management`, `stop_sequences`, `output_config.format`, `tool_choice` `any`/`tool`, `output_config.task_budget.remaining`, a last assistant turn ending in an unresolved `tool_use`. | CD, P1 |
| F14 | On-demand streaming: one `content_block_start` carrying the complete block, then `content_block_stop`; no deltas. | CD |
| F15 | On-demand replay: send the block first (own assistant message or first block of the first message), byte-exact including `signature`; drop the summarized messages; send only the newest block. Needs `compact-2026-09-04` on every later request: none → 400 (P2a); only `compact-2026-01-12` → 400 "…\`signature\` requires anthropic-beta: compact-2026-09-04" (P2b); `compact-2026-09-04` → 200 (P2c). | CD, P2a–P2c |
| F16 | On-demand failure without a summary: 200 with empty `content` and a normal stop reason. Error codes in `error.details.error_code`: 529 `compaction_unavailable`; 400 `compaction_block_misplaced`, `compaction_signature_invalid`, `compaction_content_mismatch`, `compaction_nothing_to_summarize`. | CD |
| F17 | `count_tokens`: accepts `context_management` and returns `context_management.original_input_tokens` (P6e → 200); applies existing compaction blocks, does not trigger new ones; accepts and ignores top-level `compaction`. A replayed block without its beta → 400, same as messages (P2d). | CT, REFC, P2d, P6e |
| F18 | Batches: an item with a `compact_20260112` edit and an item with top-level `compaction` both **succeed** (P7; the on-demand item returns `stop_reason: "compaction"`, content `[compaction]`). | P7 |
| F19 | Claudio today: `Request.set_context_management/2` (`request.ex:672`) stores the raw map and declares `context-management-2025-06-27` only; `Response` has no `context_management` field; `parse_stop_reason/1` passes `"compaction"` through as a string (`response.ex:623`); unknown blocks pass through `parse_content_block/1` / `block_to_api/1` raw; `Stream.apply_delta/2` has no `compaction_delta` clause; `add_message/3` already scans content for `fallback` blocks (`request.ex:132`). | code |

## Design

### 1. Context-editing builders (`Request`)

All three append to `context_management["edits"]` (creating `%{"edits" => []}` when
`context_management` is `nil`; keeping any other keys a raw `set_context_management/2` put
there), and are chainable in any order.

```elixir
@spec add_clear_tool_uses(t(), keyword()) :: t()
@spec add_clear_thinking(t(), keyword()) :: t()
@spec add_compaction(t(), keyword()) :: t()
```

- `add_clear_tool_uses/2` → `%{"type" => "clear_tool_uses_20250919"}` plus, only when given:
  - `trigger: {:input_tokens | :tool_uses, n}` → `%{"type" => "input_tokens" | "tool_uses", "value" => n}`
  - `keep: n` → `%{"type" => "tool_uses", "value" => n}`
  - `clear_at_least: n` → `%{"type" => "input_tokens", "value" => n}`
  - `exclude_tools: [String.t()]`, `clear_tool_inputs: boolean | [String.t()]` → as-is.

  Declares `context-management-2025-06-27`.
- `add_clear_thinking/2` → `%{"type" => "clear_thinking_20251015"}` plus, when given,
  `keep: :all` → `"all"` or `keep: n` → `%{"type" => "thinking_turns", "value" => n}`.
  Declares `context-management-2025-06-27`. **Inserted at index 0** of `edits` (F4), whatever the
  call order.
- `add_compaction/2` → `%{"type" => "compact_20260112"}` plus, when given:
  `trigger: n` → `%{"type" => "input_tokens", "value" => n}`, `pause_after_compaction: boolean`,
  `instructions: String.t()`. Declares `compact-2026-01-12`.
- Omitted options are not sent (the API applies its defaults; F2, F3, F5).
- `ArgumentError` (naming the function, option and `inspect/1` of the value) for: an unknown
  option key; a `trigger` tuple whose kind is not `:input_tokens`/`:tool_uses`; a non-integer
  count; `keep` for `add_clear_thinking/2` other than `:all` or a positive integer.
- **Not** validated locally (left to the API, consistent with S11/S12): the 50000 trigger minimum
  (F5), value ranges, duplicate edits, model support.
- `set_context_management/2` stays the raw setter. It still declares
  `context-management-2025-06-27`, and **also** declares `compact-2026-01-12` when
  `config["edits"]` (string or atom keys) contains an edit with type `"compact_20260112"` (F6).
  Its doc example is replaced with a real shape (the three-edit list above).

### 2. On-demand compaction and `apply_compaction/2` (`Request`)

```elixir
@spec request_compaction(t(), keyword()) :: t()
@spec apply_compaction(t(), Response.t()) :: t()
```

- `request_compaction/2` sets new struct field `compaction` to `%{"type" => "summarize"}` plus
  `"instructions"` when given (`instructions:` is the only option; others raise
  `ArgumentError`). Declares `compact-2026-09-04`. Emitted by `to_map/1` via `maybe_put`.
  The F13 incompatibilities are **not** validated locally (Q, 2026-09-26: left to the API's 400).
- `apply_compaction/2` works for **both** kinds (Q, 2026-09-26):
  - Finds the last `:compaction` block in `response.content`; none → `ArgumentError` ("…
    response has no compaction block; got stop_reason …").
  - Replaces `messages` with one assistant message whose content is
    `Response.to_assistant_content(response)` from that block onward (so the block is first,
    byte-exact via `raw`, F15; for threshold this keeps the reply's thinking/text after the
    block, F12).
  - Sets `compaction` to `nil` — otherwise the next call would ask for another summary.
  - Keeps `context_management` untouched (a threshold replay needs its `compact_20260112` edit,
    F11) and keeps all declared betas.
  - Goes through `add_message/3`, so the replay beta (§3) is declared.
- Callers who never call `apply_compaction/2` keep today's flow — append
  `to_assistant_content/1` and resend everything; the API ignores the prefix (F11).

### 3. Replay beta in `add_message/3`

`add_message/3` already declares the fallback beta for `fallback` blocks. It now also scans list
content for a block whose type is `"compaction"` / `:compaction` (string or atom keys, raw or
typed):

- block with a non-nil `signature` (on-demand) → declare `compact-2026-09-04` (F15);
- block without one (threshold) → declare `compact-2026-01-12` (F11).

The missing-edit case for threshold replay is not repaired (Claudio can't know the caller's
trigger); the API's 400 names the fix (F11). Raw maps passed straight to `Messages.create/2` are
not scanned (same as S12b).

### 4. Response parsing

- A `compaction` block (string or atom keys) parses to
  `%{type: :compaction, content: String.t() | nil, raw: map}`; `block_to_api/1` re-emits `raw`
  unchanged (keeps `signature`, `encrypted_content`, `tool_changes`, and any `cache_control` a
  caller added before it was parsed).
- `parse_stop_reason("compaction")` → `:compaction`; the `stop_reason` type gains it.
- New struct field `context_management :: map() | nil` — the raw top-level map, `nil` when
  absent (same pattern as `diagnostics`).
- `Response.compaction_block/1 :: map() | nil` — the last `:compaction` block, or `nil`.
- `usage.iterations` is already typed (S12b); docs add the `"compaction"` entry type and note that
  top-level token counts exclude compaction iterations (F10).

### 5. Streaming (`Stream`)

- New `apply_delta/2` clauses (string and atom keys) for `"compaction_delta"`: every key except
  `"type"` is written into the block (`content`, and `encrypted_content` / `signature` if a
  future delta carries them), replacing the `nil` from `content_block_start` (F9).
- `build_final_message/1` stores top-level `message_delta["context_management"]` when present
  (F7). On-demand streaming needs no code (F14).

### 6. `count_tokens` and Batches

No change. `count_tokens` keeps `context_management` and `compaction` (both accepted, F17);
Batches need nothing (F18; `required_betas/1` already reaches Batches).

## Testing

- **Unit (`request_test.exs`):**
  - each builder with no options and with every option; exact maps; beta declared once;
  - `add_clear_thinking/2` is first whether called first or last; order of the others preserved;
  - builders after a raw `set_context_management/2` keep its other keys;
  - `set_context_management/2` with a raw `compact_20260112` edit (string and atom keys) declares
    both betas; without one, only the context-management beta;
  - each raise case;
  - `request_compaction/2` with and without `instructions`; `to_map/1` omits `compaction` when
    unset;
  - `apply_compaction/2`: on-demand response → one assistant message `[block]`, `compaction`
    cleared, `compact-2026-09-04` declared; threshold response `[compaction, thinking, text]` →
    content from the block onward, `context_management` kept, `compact-2026-01-12` declared;
    two compaction blocks → from the last one; no block → raise;
  - `add_message/3` with a signed / unsigned compaction block (typed and raw) declares the
    matching beta; without one, no compaction beta.
- **Unit (`response_test.exs`):** block parse (string + atom keys, `content: nil`, with
  `signature`); `raw` round-trip; `:compaction` stop reason; `context_management` present/absent;
  `compaction_block/1` with none/one/two.
- **Unit (`messages/stream_test.exs`):** the P5 event sequence (fixture reproduced from the probe:
  `content_block_start` `content: null` → `compaction_delta` → stop → `message_delta` with
  `stop_reason: "compaction"`, `usage.iterations`, top-level `context_management`) →
  `build_final_message/1` → `Response.from_map/1`: typed block with the full summary,
  `:compaction`, `context_management == %{"applied_edits" => []}`.
- **Integration (`test/integration/context_management_integration_test.exs`)**, small inputs only:
  1. `add_clear_thinking` + `add_clear_tool_uses` + `add_compaction(trigger: 50_000)` with
     adaptive thinking → 200, `context_management == %{"applied_edits" => []}` (repeats P3a,
     proves ordering and betas end to end).
  2. On-demand round trip: short history → `request_compaction/2` → `:compaction` with a signed
     block → `apply_compaction/2` → `add_message(:user, …)` → 200 (repeats P1/P2c).
  3. Control: a Response holding an unsigned (threshold-shaped) block replayed via
     `apply_compaction/2` on a request **without** a `compact_20260112` edit → 400 whose message
     contains "compact_20260112" (repeats P6b, no 50k call).

  A real threshold trigger (~55k input tokens) is not in the suite; it is covered by the P5/P9
  probes and the stream fixture.

## Out of scope

- Local validation of the F13 incompatibilities, trigger minimums, and per-model support.
- Deprecated SDK client-side compaction.
- Typed `applied_edits` entries (kept raw; the API adds types over time).
- `tool_changes` handling beyond round-tripping it in `raw`.
- Deciding `instructions` semantics (F5) — passed through verbatim.
