# S1 — Extended-thinking round-trip correctness

- **Date:** 2026-06-19
- **Beads:** `claudio-hms` (epic `claudio-8rv`)
- **Spec status:** approved design; implementation plan to follow (writing-plans)
- **Scope class:** correctness bugfix, **additive only** (no breaking changes)

## Problem

`Claudio.Messages.create/2` returns a *parsed* `Claudio.Messages.Response` whose
`content` is a **lossy** projection of the API's content blocks. Callers feed that
parsed content back into the next request's assistant turn to continue a
conversation. For extended-thinking + tool-use loops this drops data the API
requires on replay, producing a hard `400 invalid_request_error`.

Three concrete losses (all verified against source this session):

1. **`thinking` blocks drop `signature`.** `response.ex` parses a thinking block to
   `%{type: :thinking, thinking: ...}` and discards the `signature` field. The API
   requires the signature to be present (and unmodified) when the assistant turn is
   replayed.
2. **`redacted_thinking` blocks are untyped/unpreserved.** They hit the
   `parse_content_block(block), do: block` fallthrough and come back as a raw map.
   Any pipeline that filters content blocks by type silently drops them — the
   single most common documented cause of the 400.
3. **Streaming silently drops `signature_delta` and `citations_delta`.**
   `stream.ex` `apply_delta/2` has a catch-all `apply_delta(block, _delta), do: block`,
   so any delta type beyond `text`/`input_json`/`thinking` is discarded. A streamed
   thinking block thus loses its signature (same 400 in the streaming path), and any
   streamed citation data is lost.

### Root cause

The parsed representation is lossy **and** is the thing used for round-tripping.
The fix preserves the load-bearing fields and provides a single, hard-to-misuse
helper for reconstructing the assistant turn, so callers don't hand-roll it and
re-introduce the loss.

## Goals / non-goals

**Goals**
- Preserve `signature` on parsed `thinking` blocks.
- Parse and preserve `redacted_thinking` as a typed block.
- Stop the streaming accumulator from silently dropping `signature_delta` and
  `citations_delta`.
- Provide `Response.to_assistant_content/1` that emits API-exact, string-keyed
  content blocks suitable for `Request.add_message(:assistant, content)`.

**Non-goals (deferred to S5 — `claudio-0vx`)**
- Typed `Citation` structs and parsing the `citations` array on text blocks (all
  location variants). S1 accumulates the raw `citations_delta` payload only.
- The request-side `citations: {enabled: true}` toggle.

Rationale for the seam: citations only exist when the caller opts in (default off),
so nothing in "don't 400 on replay" depends on typed citations. Typing them in S1
would be dead code until S5 adds the toggle. S1 takes the *non-lossy* obligation
("don't drop data"); S5 takes the *semantic* one ("give it meaning"). S5 depends on
S1 because both edit the same two seams (`response.ex` block parsing, `stream.ex`
delta accumulation); S1 establishes the patterns S5 builds citation typing on.

## Design

### 1. `lib/claudio/messages/response.ex` — non-streaming parse

**Types**
- Extend `thinking_block` with `signature: String.t() | nil`.
- Add `redacted_thinking_block :: %{type: :redacted_thinking, data: String.t()}`.
- Add `redacted_thinking_block()` to the `content_block` union.

**Parsing** (keep the existing dual atom-key / string-key clause pattern)
- `thinking` clauses gain `signature: block[:signature]` / `block["signature"]`
  (nil when absent — mirrors how `parse_usage/1` always includes cache fields).
- New `redacted_thinking` clauses (both key forms):
  `%{type: :redacted_thinking, data: block[:data] || block["data"]}`.

### 2. `lib/claudio/messages/stream.ex` — streaming accumulator

Add two `apply_delta/2` clauses **above** the catch-all (both atom- and string-key
forms, matching the existing style):

- `signature_delta` → `Map.put(block, "signature", signature)`.
  The signature arrives whole in a single delta (set, not append).
- `citations_delta` → append the `citation` object onto `block["citations"]`
  (`Map.update(block, "citations", [citation], &(&1 ++ [citation]))`). Raw
  accumulation only — no typed parsing (S5).

**No change needed elsewhere in streaming:** `build_final_message/1` already keeps
the raw, string-keyed blocks from `content_block_start` and applies deltas to them,
so its output is already API-shaped and round-trippable. `redacted_thinking` already
survives streaming (it rides entirely on `content_block_start` with no deltas). The
asymmetry is intentional: only the *non-streaming* parsed struct needs §1 + §3.

### 3. `lib/claudio/messages/response.ex` — round-trip helper

```elixir
@spec to_assistant_content(t()) :: [map()]
def to_assistant_content(%__MODULE__{content: content}), do: Enum.map(content, &block_to_api/1)
```

`block_to_api/1` emits string-keyed, API-exact blocks:

| parsed block         | emitted map |
|----------------------|-------------|
| `:text`              | `%{"type"=>"text","text"=>text}` |
| `:thinking`          | `%{"type"=>"thinking","thinking"=>thinking,"signature"=>signature}` (omit `"signature"` if nil) |
| `:redacted_thinking` | `%{"type"=>"redacted_thinking","data"=>data}` |
| `:tool_use`          | `%{"type"=>"tool_use","id"=>id,"name"=>name,"input"=>input}` |
| any other            | passed through unchanged (coverage grows in S5/S6) |

Usage (documented one-liner; **no** `Request.add_response/2` wrapper — dropped to
avoid a `Request`→`Response` dependency for trivial sugar, YAGNI, and it's free to
add later):

```elixir
next =
  request
  |> Request.add_message(:assistant, Response.to_assistant_content(resp))
  |> Request.add_message(:user, Tools.create_tool_result_message(results))
```

## Testing

Unit tests (default suite, no API key):

- **parse:** thinking-with-signature retains `signature`; `redacted_thinking` parses
  to `%{type: :redacted_thinking, data: ...}` (both key forms).
- **`to_assistant_content/1`:** returns string-keyed, API-exact blocks carrying
  `signature`, `data`, and `tool_use`; nil signature omitted.
- **stream:** `signature_delta` lands on the final thinking block via
  `build_final_message/1`; `citations_delta` accumulates onto `"citations"`;
  regression guard that `redacted_thinking` survives streaming unchanged.
- **"no 400" proof without a key:** build a Response with thinking + tool_use, run it
  through `add_message(:assistant, to_assistant_content(resp)) |> Request.to_map/1`,
  and assert the serialized payload contains the signature and redacted `data` in the
  correct shape.

Integration test (`@tag :integration`, excluded by default): a real
thinking + tool-use round trip that asserts no 400 on the second request.

## Files touched

- `lib/claudio/messages/response.ex` — types, thinking/redacted_thinking parsing, `to_assistant_content/1`.
- `lib/claudio/messages/stream.ex` — `signature_delta` + `citations_delta` clauses.
- `test/response_test.exs` — new parse + round-trip tests.
- `test/messages/stream_test.exs` — new streaming-delta tests.
- `test/messages_integration_test.exs` — one tagged round-trip test.

## Risks / second-order effects

- **Backward compatibility:** purely additive. No existing test asserts thinking
  block shape (verified — `response_test.exs` covers text/tool_use/stop-reasons
  only), so adding `signature` breaks nothing. New `redacted_thinking` blocks
  previously surfaced as raw maps, so typing them is strictly better.
- **Forward compatibility:** `to_assistant_content/1` passes unknown block types
  through unchanged, so S5/S6 server-tool blocks won't break it before they're
  explicitly supported.
