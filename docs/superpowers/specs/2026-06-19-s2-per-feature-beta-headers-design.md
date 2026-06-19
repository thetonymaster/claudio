# S2 — Per-feature beta-header management

- **Date:** 2026-06-19
- **Beads:** `claudio-7mj` (epic `claudio-8rv`)
- **Spec status:** approved design; implementation plan to follow (writing-plans)
- **Scope class:** additive plumbing + one feature wired (no breaking changes)
- **Roadmap:** `docs/superpowers/specs/2026-06-19-anthropic-api-coverage-roadmap.md` (gap T3.14)

## Problem

Anthropic gates some Messages-API features behind an `anthropic-beta` header
(comma-separated, multi-valued). In Claudio, that header is built **once** at
`Client.new/2` from the user-supplied `:beta` list and never changes thereafter
(`client.ex` `get_headers/1`). `Request.to_map/1` carries no beta information,
and the send path (`Messages.create/2` → `Req.post`) uses the client's pre-built
headers verbatim.

The consequence: a feature toggle that *requires* a beta header silently `400`s
unless the caller already knew the magic dated string and passed it to
`Client.new`. The concrete case in the current codebase is
`Request.set_context_management/2` — it sets the `context_management` body field
but the API rejects that field with `400 invalid_request_error` unless
`anthropic-beta: context-management-2025-06-27` is present. The same trap will
hit every future beta-gated feature (computer use, memory, skills, …).

### Root cause

The knowledge of "this feature needs this beta" lives nowhere. The setter that
introduces a beta-gated body field does not record the header that field
depends on, and the send path has no way to recover it. Betas and the features
that need them are decoupled.

## Goals / non-goals

**Goals**
- Let a feature setter **declare** the beta string it requires, co-located with
  the setter (so the string lives next to the code that needs it).
- Merge declared betas into the `anthropic-beta` header at send time, unioned
  with whatever the client was built with — for `Messages.create/2`,
  `Messages.count_tokens/2`, and `Batches.create/2`.
- Provide a public escape hatch, `Request.add_beta/2`, so callers can opt into
  betas the library does not yet model (e.g. `mcp-client-2025-11-20`).
- Wire the one beta-gated feature that exists today: `set_context_management/2`.

**Non-goals (deferred)**
- **Auto-wiring the MCP connector.** The current connector beta is
  `mcp-client-2025-11-20` (the older `mcp-client-2025-04-04` is deprecated), and
  the modern connector shape also adds an `mcp_toolset` tools entry alongside
  `mcp_servers`. Wiring it correctly is a connector change, not header plumbing —
  it belongs in its own spec (relates to S6). `add_beta/2` covers callers who
  need it now.
- **Auto-merging betas for the raw-map path.** `create/count_tokens/batches`
  also accept raw maps (no `Request` struct, so no declared betas). These keep
  today's behaviour: the caller manages betas via `Client.new`. Documented, not
  changed.

## Design (betas on the `Request` struct, merged at send)

### 1. `lib/claudio/messages/request.ex`

**Struct + types**
- Add `betas: []` to `defstruct` and to `@type t` as `betas: [String.t()]`.

**Public API**
- `add_beta/2` — append a beta string to `request.betas` if not already present
  (dedup, preserving insertion order). The user-facing escape hatch.
- `required_betas/1` — return `request.betas`.

**Private**
- `put_beta/2` — same append-if-absent logic, used by feature setters. (May be
  implemented as `add_beta/2` itself; keep one code path.)

**Wiring**
- `set_context_management/2` additionally calls
  `put_beta(request, "context-management-2025-06-27")`.

**Unchanged**
- `to_map/1` does **not** serialize `betas`. Betas are an HTTP header, never a
  body field; including them in the JSON body would be ignored at best and
  rejected at worst.

### 2. `lib/claudio/client.ex`

- `with_betas/2` (public): the single merge point reused by all call sites.
  - `with_betas(client, [])` → returns `client` unchanged.
  - Otherwise: read the existing header via
    `Req.Request.get_header(client, "anthropic-beta")` (returns a list of header
    values such as `["a,b"]` or `[]`), split each value on `,`, trim, drop
    empties, union with the new betas (dedup, stable order), and write the joined
    result back via `Req.Request.put_header/3`.
  - A client built with no `:beta` (header absent) gets the new betas alone.

### 3. `lib/claudio/messages.ex`

- `create(client, %Request{} = req)`:
  `create(Client.with_betas(client, Request.required_betas(req)), Request.to_map(req))`.
- `count_tokens(client, %Request{} = req)`: same merge before delegating to the
  map clause.
- Raw-map clauses (`create/count_tokens` with a plain map) are unchanged.

### 4. `lib/claudio/batches.ex`

- `create/2` learns to accept items whose `:params`/`"params"` is a `%Request{}`
  (additive — today they are raw maps). For each item:
  - `%Request{}` params → collect `Request.required_betas/1`, replace params with
    `Request.to_map/1`.
  - Raw-map params → pass through untouched, contribute no betas.
- Union all collected betas across items, then
  `client = Client.with_betas(client, all_betas)` before the batch `Req.post`.
- A batch with only raw-map params behaves exactly as today.

## Beta strings (pinned 2026-06-19)

| Feature wired in S2 | beta string |
|---|---|
| `set_context_management/2` | `context-management-2025-06-27` |

Verified current against the live Anthropic API reference this session. The
integration test (below) re-pins it against the real API at build time.

## Testing

**Unit / Bypass (default suite, no key)**
- **request:** `add_beta/2` dedups; `set_context_management/2` populates `betas`
  with `"context-management-2025-06-27"`; `required_betas/1` returns the list;
  `to_map/1` output does **not** contain a `betas`/`anthropic-beta` key.
- **client:** `with_betas(client, [])` is a no-op; `with_betas` on a client built
  with `beta: ["a"]` produces the unioned, deduped header `"a,context-..."`;
  `with_betas` on a client with no beta sets the header to just the new values.
- **messages (Bypass):** a `%Request{}` with `set_context_management` sent via
  `Messages.create/2` against a Bypass server arrives with the merged
  `anthropic-beta` header (assert on the captured request); same for
  `count_tokens/2`.
- **batches (Bypass):** `Batches.create/2` with one item whose `params` is a
  `%Request{}` carrying `set_context_management` POSTs with the merged header and
  a serialized (struct-free) `params` body; a raw-map-only batch POSTs with the
  header unchanged.

**Integration (`@tag :integration`, excluded by default, run with
`--include integration`)** — one test on the `Messages.create` path that pins the
dated string against the live API and proves the beta is load-bearing:
- **Positive:** `IntegrationHelper.create_client/0` (no `:beta` list) + a
  `%Request{}` built with `set_context_management(%{edits: [%{type:
  "clear_tool_uses_20250919"}]})` on `IntegrationHelper.test_model/0` → assert
  `{:ok, %Response{}}` (HTTP 200). S2's auto-merge supplied the beta.
- **Negative control:** the same context-management payload sent as a **raw map**
  (no beta anywhere) → assert a `400` error. Proves the beta is required, so the
  positive 200 means S2 attached it — not that the API ignores the field.

The positive test must run on a model that **supports context editing**, so a
missing-beta `400` is the only way it can fail on the beta dimension. Start with
`IntegrationHelper.test_model/0`; if that model rejects `context_management` for
a model-gating reason rather than a missing beta, pin the test to a
context-editing-capable model instead (verify during execution).

Batches and `count_tokens` are covered by Bypass only: both reuse the same
`Client.with_betas/2` helper the live test exercises, and live batches are
asynchronous (up to 24h), so a live batch test would not finish in a test run.

Integration tests follow the repo convention in `test/integration/`
(`Claudio.IntegrationHelper`); fail-loud, not silent-skip, when a key is absent,
matching the S1 convention.

## Files touched

- `lib/claudio/messages/request.ex` — `betas` field, `add_beta/2`,
  `required_betas/1`, `put_beta/2`, `set_context_management/2` wiring.
- `lib/claudio/client.ex` — `with_betas/2`.
- `lib/claudio/messages.ex` — merge betas in the `%Request{}` clauses of
  `create/2` and `count_tokens/2`.
- `lib/claudio/batches.ex` — accept `%Request{}` params, collect + merge betas.
- `test/request_test.exs` — `betas`, `add_beta/2`, `set_context_management`
  wiring, `to_map` exclusion.
- `test/client_test.exs` — `with_betas/2` merge cases.
- `test/messages_test.exs` — Bypass header-merge assertions (create + count_tokens).
- `test/batches_test.exs` — Bypass header-merge + `%Request{}` params serialization.
- `test/integration/messages_integration_test.exs` — live context-management test
  (positive + negative control).

## Risks / second-order effects

- **Backward compatibility:** purely additive. The `betas` field defaults to `[]`,
  so existing `%Request{}` construction is unaffected; `with_betas(client, [])`
  is a no-op, so any code path that produces no declared betas is byte-identical
  to today.
- **Batches accepting `%Request{}` params:** today callers pass raw maps; nothing
  regresses because raw-map params still flow through untouched. Passing a
  `%Request{}` previously would have serialized the struct's internals as JSON
  (broken) — so this is strictly a new, correct capability.
- **`to_map/1` must never emit `betas`:** a unit test guards this. If a beta
  leaked into the body it would be an unknown field; the guard keeps body and
  header concerns separate.
- **Dated string drift:** `context-management-2025-06-27` is verified now; the
  integration test re-pins it on every build that runs `--include integration`,
  so a future API change surfaces as a failing test rather than a silent
  production `400`.
- **Header dedup correctness:** `with_betas/2` splits existing comma-joined header
  values before unioning, so re-merging an already-present beta cannot produce a
  duplicated or malformed header value.
