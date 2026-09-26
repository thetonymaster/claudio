# S12b — Refusal fallbacks (`fallbacks`, `fallback` blocks, `usage.iterations`)

- **Date:** 2026-09-25
- **Spec status:** Design approved by Q in chat (2026-09-25); written spec awaiting Q's review.
- **Scope class:** request field + new response content block + continuation (echo) rules in
  `to_assistant_content/1` + usage/stop_details typing. Ships in **0.7.0** (single bump after S15).
- **Split from:** roadmap S12 (Q, 2026-09-25). S12a (request surface) shipped first (#20).
- **Provenance:** live docs re-fetched 2026-09-25 — `build-with-claude/refusals-and-fallback`
  (RF), `api/beta/messages/create` (REF), `release-notes/overview` (RN), all under
  `platform.claude.com/docs/en/` — plus live probes P7–P15 against `claude-opus-5-5`.

## Problem

The API can retry a refused request on another model server-side, but Claudio can't ask for it
(no `fallbacks` field), and the response surface it adds is untyped: a `fallback` content block,
`usage.iterations`, and new `stop_details` fields. Worse, a **streamed** response with a
mid-output fallback contains blocks from the declining model that must be dropped before the
turn is replayed; `to_assistant_content/1` replays them verbatim today, so the next request
fails with a 400.

## Verified facts

| # | Fact | Source |
|---|------|--------|
| F1 | Request: `"fallbacks": "default"` or a list of up to three entries `[{"model": …}, …]`. Entries are tried in order, must be distinct from each other and from the requested model, and each can override `max_tokens`, `thinking`, `output_config`, `speed`. | RF; P8 → 400 "List should have at most 3 items" |
| F2 | Beta header `server-side-fallback-2026-07-01` (supports `"default"` and lists). `2026-06-01` is list-only; not used. | RF; P7 → 200 |
| F3 | Allowed targets: `allowed_fallback_models` on the model's Models API entry (with the beta header). `claude-opus-5-5` → `["claude-opus-4-8", "claude-opus-5"]`. | RF; probe |
| F4 | Top-level `model` is always the model that produced the returned message. | RF |
| F5 | A `fallback` block `{"type":"fallback","from":{"model":…},"to":{"model":…}}` marks **each** handoff point — one response can contain several. REF's `BetaFallbackBlock` adds optional `trigger: {type: "refusal", category}`. | RF, REF |
| F6 | `usage.iterations`: `"message"` entries = declined attempts, `"fallback_message"` = serving attempt. Present whenever `fallbacks` is set (P7: even with no refusal). Top-level usage covers only the returned attempt. | RF; P7 |
| F7 | `stop_details` adds `recommended_model` (only when `fallbacks` set; `null` unless the fallback attempt was skipped), and REF lists `fallback_credit_token`, `fallback_has_prefill_claim`. | RF, REF |
| F8 | **Echo table** (RF "Continuing the conversation"): `fallback` — keep exactly where it appeared; `text` — keep; any block after the final `fallback` — keep; `thinking` / `redacted_thinking` / `connector_text` before the final `fallback` — drop; client `tool_use` before it — drop; `server_tool_use` before it — keep when paired with its result, drop otherwise. | RF |
| F9 | Non-streaming mid-output decline: partial output is omitted, `fallback` is the first block. Streaming mid-output decline: earlier blocks stay; the `fallback` block is a `content_block_start`/`_stop` pair with no deltas. **So F8 only changes anything for streamed responses.** | RF |
| F10 | The API accepts a caller-built `fallback` block in history (P10 → 200). Before a `fallback`: unpaired client `tool_use` → 400 (P11); unpaired `server_tool_use` → 400 (P14), paired → 200 (P15); unpaired `mcp_tool_use` → 400 (P12b), paired `mcp_tool_use` + `mcp_tool_result` → 200 without any `mcp_servers` entry (P13). `mcp_tool_use` in history needs the `mcp-client-2025-11-20` beta (P12). | P10–P15 |
| F11 | `count_tokens` rejects `fallbacks` (P9 → 400 "Extra inputs are not permitted"). | P9 |
| F12 | Batches: a batch item with `fallbacks` comes back as an errored result (not a 400). Not on Bedrock / Google Cloud / Foundry. | RF |
| F13 | There is no documented way to trigger a refusal deliberately. | RF |
| F14 | Claudio decodes JSON with string keys; unrecognised blocks (`connector_text`, `web_fetch_tool_result`, `code_execution_tool_result`, …) pass through `parse_content_block/1` and `block_to_api/1` unchanged. | `response.ex`, `messages.ex:317` |

## Design

### 1. `Request.set_fallbacks/2`

```elixir
@spec set_fallbacks(t(), :default | [String.t() | map()]) :: t()
```

- `:default` → `"fallbacks" => "default"`.
- A list → each string entry becomes `%{"model" => m}`; each map entry is passed through
  unchanged (per-entry overrides, F1).
- Always declares `server-side-fallback-2026-07-01` via `add_beta/2`.
- New struct field `fallbacks`, emitted by `to_map/1` via `maybe_put`.
- Raises `ArgumentError` (naming the function, the allowed shapes, and `inspect/1` of the value)
  for: any value other than `:default` or a list; an empty list; an entry that is neither a
  string nor a map.
- **Not** validated locally (left to the API, consistent with S11/S12a): the three-entry cap,
  distinctness, `allowed_fallback_models`, and use inside Batches (F12).
- `Messages.count_tokens/2` (Request form) strips `"fallbacks"` (F11), like `inference_geo`.

### 2. Response parsing and readers

- A `fallback` block (string or atom keys) parses to
  `%{type: :fallback, from: map, to: map, trigger: map | nil, raw: map}`, where `raw` is the
  original block. `block_to_api/1` re-emits `raw` unchanged, so unknown sub-fields survive.
- `Response.fallbacks/1 :: [fallback_block()]` — every `fallback` block, in content order; `[]`
  when none.
- `Response.served_by/1 :: String.t() | nil` — the top-level `model` (F4). Kept as a named reader
  so callers don't have to know that `model` changes meaning under fallbacks.
- `:iterations` joins `@usage_keys` — a list of raw (string-keyed) maps, or `nil`. By the S12a
  rule, documented keys always appear, so `usage.iterations` is `nil` on responses without it;
  the existing CHANGELOG "absent documented fields appear as `nil`" line covers this.
- `stop_details` stays a raw map (S10 decision); its docs name `recommended_model`,
  `fallback_credit_token`, `fallback_has_prefill_claim`.

### 3. Continuation rules in `to_assistant_content/1`

`to_assistant_content/1` keeps its one-to-one `block_to_api/1` mapping, then applies a private,
pure echo filter implementing F8 (Q, 2026-09-25: built in, not a separate function — the
function's only purpose is replay, and a separate function would leave the familiar one silently
wrong in a rare, hard-to-test case).

- Find the **last** `fallback` block. None, or at index 0 → return the list unchanged (every
  non-streaming response; F9). This invariant is what keeps `Claudio.Agent` and all existing
  callers byte-identical.
- Blocks at or after the last `fallback`: keep.
- Blocks before it:
  - `fallback`, `text` → keep.
  - `thinking`, `redacted_thinking`, `connector_text`, `tool_use` → drop.
  - `server_tool_use` → keep only if some block in the content has `tool_use_id` equal to its
    `id`; else drop.
  - `mcp_tool_use` → same pairing rule, against `mcp_tool_result`. **Inference, not in RF's
    table** (Q, 2026-09-25): an unpaired `mcp_tool_use` makes the next request 400 (P12b), a
    paired one is accepted (P13).
  - Any other type → keep (RF lists only the drops above).
- Type and id checks read both string and atom keys (unknown blocks stay string-keyed, F14).
- Documented on `to_assistant_content/1`: output can omit blocks for streamed responses with a
  mid-output fallback; `resp.content` still holds everything.

### 4. Streaming

No new stream code: the no-delta `fallback` block goes through `build_final_message/1`'s generic
`content_block_start`/`_stop` handling. A test pins it: SSE events → `build_final_message/1` →
`Response.from_map/1` → a typed `:fallback` block at the right index, and `to.model` names the
serving model.

## Testing

- **Unit (`request_test.exs`):** `set_fallbacks/2` for `:default`, string list, map entries with
  overrides, mixed list; beta declared once; each raise case; `to_map/1` omits the key when unset.
- **Unit (`messages_test.exs`):** `count_tokens` with a Request carrying `fallbacks` sends no
  `fallbacks` key.
- **Unit (`response_test.exs`):** `fallback` block parse (string + atom keys, with and without
  `trigger`); `raw` round-trip; `fallbacks/1` with zero, one, two blocks; `served_by/1`;
  `usage.iterations`; echo filter — no fallback (unchanged), fallback first (unchanged), mid-output
  with every block kind in F8 plus `mcp_tool_use` paired/unpaired and an unknown block type, two
  fallback blocks (rules apply only before the last).
- **Unit (`stream_test.exs`):** mid-output fallback stream → final message → Response as in §4.
- **Integration (`test/integration/fallbacks_integration_test.exs`):**
  1. `set_fallbacks(:default)` request → 200, `usage.iterations` present (repeats P7).
  2. A Response built with `Response.from_map/1` from a synthetic mid-output-fallback content
     (unpaired `tool_use`, unpaired `server_tool_use`, unpaired `mcp_tool_use`, `text`,
     `fallback`, `text`) → replay `to_assistant_content/1` as the assistant turn → 200. Control:
     replaying the unfiltered raw blocks → 400. Needs betas `server-side-fallback-2026-07-01` and
     `mcp-client-2025-11-20` (F10). This validates the echo filter, including the `mcp_tool_use`
     inference, against the live API without needing a real refusal (F13).

## Out of scope

- Client-side fallback / SDK-middleware equivalents and fallback credits (`fallback-credit` doc).
- Local validation of fallback targets against the Models API.
- Sticky routing (nothing to send; readable via `usage.iterations` and `model`).
- Batches-side handling of `fallbacks` (the API reports an errored item).
