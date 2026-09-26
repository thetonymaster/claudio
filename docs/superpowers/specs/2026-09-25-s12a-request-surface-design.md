# S12a — 5.x request surface (system messages, per-message effort, speed, inference_geo, cache diagnostics)

- **Date:** 2026-09-25
- **Spec status:** approved design; implementation plan to follow (writing-plans)
- **Scope class:** additive request helpers + usage/response parsing that stops dropping fields.
  Ships in **0.7.0** (single bump after S15; no `@version` change here).
- **Split:** roadmap S12 was split (decided by Q, 2026-09-25) into **S12a** (this spec, request
  surface) and **S12b** (refusal fallbacks — `2026-09-25-s12b-refusal-fallbacks-design.md`).
- **Roadmap:** `docs/superpowers/specs/2026-06-19-anthropic-api-coverage-roadmap.md` → "2026-09 refresh"
- **Provenance:** live docs fetched 2026-09-25, all under `platform.claude.com/docs/en/` —
  `build-with-claude/mid-conversation-system-messages` (MCS), `build-with-claude/effort` (EFF),
  `build-with-claude/fast-mode` (FM), `manage-claude/data-residency` (DR),
  `build-with-claude/cache-diagnostics` (CD), `api/beta/messages/create` (REF),
  `release-notes/overview` (RN) — plus **live probes** against `claude-opus-5-5` on the same date
  (P1–P11 below). Code claims checked against main @ 92da159.

## Problem

Claudio can't build several request shapes that the current (5.x) Messages API accepts, and it
drops response data those requests return:

1. No way to add a mid-conversation `role: "system"` message: `Request.add_message/3` and
   friends guard `role in [:user, :assistant]` (`request.ex:107-108`).
2. No helper for `clear_at`, per-message effort, `speed` or `inference_geo`, and no way to set
   the top-level `diagnostics` request field. Nothing declares the betas that `clear_at`,
   per-message effort and `speed` require.
3. `Response.parse_usage/1` keeps a fixed set of keys (`response.ex:428-458`), so
   `usage.inference_geo`, `usage.service_tier` and `usage.cache_creation` (present on **every**
   response, P1), `usage.speed` (P8) and any future field are dropped.
4. `Response` has no `diagnostics` field, although every response carries a top-level
   `diagnostics` (RN, P1).

### Verified facts this spec rests on

| # | Fact | Source |
|---|------|--------|
| F1 | A `{"role": "system", "content": ...}` entry inside `messages` needs **no beta header**; `content` is a string or content blocks. Supported on Fable 5.1, Mythos 5.1, Fable 5, Mythos 5, Opus 5.5, Opus 4.8, Opus 5 — not Sonnet 5. | MCS; P1 → 200 |
| F2 | Placement rules (after a `user` turn, last or followed by `assistant`, not first when it carries content; consecutive system messages merge) are enforced by the API with a 400. | MCS |
| F3 | `clear_at` sits on the system message: `"never"` (default) or `"next_user_message"`; requires beta `mid-conversation-system-clear-at-2026-08-21`. Without it: 400 `messages.1.clear_at: Extra inputs are not permitted`. A turn-scoped (`clear_at: "next_user_message"`) message carries only text content and **no `output_config`** and no `cache_control`. | MCS; P2 → 400, P3 → 200 |
| F4 | Per-message effort: `{"role": "system", "content": [], "output_config": {"effort": "low"}}`; beta `mid-conversation-output-config-2026-07-01`; applies from the next `user` turn until changed; values `low`…`max`. Only `effort` is allowed per message (`format` stays top-level). A message with neither content nor `output_config` fields is rejected. An effort-only message is accepted anywhere, including first. | EFF, REF, MCS; P4 → 200 |
| F5 | `output_config` on a **user** message → 400 `output_config is only permitted on role 'system' messages`. `task_budget` in a per-message `output_config` → 400 `Extra inputs are not permitted`. | P5, P6 |
| F6 | `speed: "fast" \| "standard"` requires beta `fast-mode-2026-02-01` — **even `"standard"`** (400 `speed: Extra inputs are not permitted` without it). Research preview (access-gated); models Opus 5.5 / Opus 5 / Opus 4.8. Response `usage.speed` echoes it (present only when requested). | FM, REF; P8 → 200 `usage.speed: "fast"`, P9 → 400 |
| F7 | `inference_geo: "global" \| "us"` — GA, no beta; 4.6-and-later models; response `usage.inference_geo` (present on every response, `"global"` by default). | DR, REF; P10 → 200 `usage.inference_geo: "us"`, P1 → `"global"` |
| F8 | Cache diagnostics is **GA** ("The `cache-diagnosis-2026-04-07` beta header is no longer required"). Request `diagnostics: {"previous_message_id": null \| "<id>"}`; response top-level `diagnostics` is `null`, `{"cache_miss_reason": null}` or `{"cache_miss_reason": {"type": ..., "cache_missed_input_tokens": n}}`; streaming: on `message_start`. Responses always include `diagnostics`. | CD, RN; P11 → 200 |
| F9 | Every probed response's `usage` held `cache_creation`, `cache_creation_input_tokens`, `cache_read_input_tokens`, `inference_geo`, `input_tokens`, `output_tokens`, `output_tokens_details`, `service_tier` (+ `speed` when set, `iterations` when `fallbacks` set). Top-level keys: `container`, `diagnostics`, `model`, `stop_details`, `stop_reason`, `stop_sequence`, `usage`. | P1–P11 |
| F10 | `Stream.build_final_message/1` stores the whole `message_start` message map, so a `diagnostics` key there survives into the final message. | repo (probe, 2026-09-25) |
| F11 | Unknown content blocks pass through `Response` untouched in both directions (`parse_content_block(block) -> block`, `block_to_api(block) -> block`). | repo `response.ex:378`, `:441` |

## Goals / non-goals

**Goals**

- `Request.add_system_message/3` (with `clear_at:` / `effort:`), `Request.set_speed/2`,
  `Request.set_inference_geo/2`, `Request.enable_cache_diagnostics/2` — each declaring its
  beta when one is needed.
- `Response.usage` stops dropping fields (option (a), decided by Q): documented fields become
  atom keys; every other field is kept under the key it arrived with.
- `Response.diagnostics`.

**Non-goals**

- No per-model validation (Claudio stays model-agnostic); **no local placement validation** for
  system messages (F2 is context-dependent; the API's 400 is authoritative).
- `add_message/3` and its variants keep accepting only `:user` / `:assistant`.
- `tool_addition` / `tool_removal` system blocks (`inline-tools-2026-09-15`) — not in scope; a
  caller can pass them as raw content blocks, but no beta is declared for them.
- Telemetry unchanged (no `speed` / `inference_geo` metadata).
- `container` is not added to `Response` (a top-level response field, not usage; out of scope).
- Refusal fallbacks and `usage.iterations` typing → **S12b**.

## Design

Same conventions as S11: enumerated values are **atoms only**; invalid values raise
`ArgumentError` naming the function, the allowed values and `inspect/1` of what was received;
option keys go through `Keyword.validate!/2`; a `nil` option means "not given". Local raises
only for inputs the API rejects on **every** model (F3, F4); everything model- or
context-dependent is left to the API.

### 1. `Request.add_system_message/3`

```elixir
@spec add_system_message(t(), String.t() | [map()], keyword()) :: t()
Request.add_system_message(req, "Reply in French.")
# appends %{"role" => "system", "content" => "Reply in French."}

Request.add_system_message(req, "Only for this turn.", clear_at: :next_user_message)
# + "clear_at" => "next_user_message"; add_beta("mid-conversation-system-clear-at-2026-08-21")

Request.add_system_message(req, [], effort: :low)
# %{"role" => "system", "content" => [], "output_config" => %{"effort" => "low"}}
# add_beta("mid-conversation-output-config-2026-07-01")
```

- `content`: a string or a list of content blocks, passed through unchanged (guard
  `is_binary/1 or is_list/1`; anything else is a `FunctionClauseError`, as in S11).
- `:clear_at` ∈ `:next_user_message | :never`. Any given `:clear_at` (including `:never`)
  emits the field and declares the clear-at beta (F3: the field is rejected without it).
- `:effort` ∈ `:low | :medium | :high | :xhigh | :max` → `"output_config" => %{"effort" => …}`
  and the per-message-output-config beta.
- Raises (`ArgumentError`, all API-universal, F3/F4):
  - `clear_at: :next_user_message` together with `:effort` — a turn-scoped message cannot
    carry `output_config`.
  - `content == []` without `:effort` — a message with neither content nor output_config is
    rejected.
- Appends to `messages` (same list `add_message/3` uses). No placement checks (non-goal).

### 2. Top-level request fields

New struct fields `:speed`, `:inference_geo`, `:diagnostics` (default `nil`), emitted by
`to_map/1` via the existing `maybe_put/3` chain as `"speed"`, `"inference_geo"`,
`"diagnostics"`. Batches pick them up through `to_map/1` and `required_betas/1` unchanged.

```elixir
@spec set_speed(t(), :fast | :standard) :: t()
Request.set_speed(req, :fast)          # "speed" => "fast"; add_beta("fast-mode-2026-02-01") (always, F6)

@spec set_inference_geo(t(), :global | :us) :: t()
Request.set_inference_geo(req, :us)    # "inference_geo" => "us"; GA, no beta (F7)

@spec enable_cache_diagnostics(t(), String.t() | nil) :: t()
Request.enable_cache_diagnostics(req)            # "diagnostics" => %{"previous_message_id" => nil}
Request.enable_cache_diagnostics(req, "msg_01")  # %{"previous_message_id" => "msg_01"}; GA (F8)
```

- `set_speed/2` / `set_inference_geo/2` raise on unknown values. `enable_cache_diagnostics/2`
  raises when the id is neither a string nor `nil`.
- Docs note: fast mode is an access-gated research preview; `inference_geo: "us"` is billed
  at 1.1× (DR).

### 3. `Response.usage` keeps every field (option (a))

`parse_usage/1`'s atom-key and string-key clauses produce:

- **Atom keys for documented fields** (value from the atom or string key, `nil` if absent):
  `input_tokens`, `output_tokens`, `cache_creation_input_tokens`, `cache_read_input_tokens`,
  `output_tokens_details` (existing) plus **`cache_creation`, `service_tier`, `inference_geo`,
  `speed`** (new, all carried raw).
- **Every other field** kept under the key it arrived with (e.g. `"iterations"` stays a string
  key until S12b types it).

The `nil` clause gains the four new keys as `nil`. The fallthrough `parse_usage(other)` (a map
without both token counts) is unchanged. The `usage` type gains the four fields plus
`optional(atom() | String.t()) => term()`. One module attribute lists the documented keys so
the two clauses and the `nil` clause cannot drift.

### 4. `Response.diagnostics`

New struct field, `data[:diagnostics] || data["diagnostics"]`, carried raw (like
`stop_details`). The stream needs no change (F10).

### 5. Docs

- CHANGELOG `[Unreleased]`: **Added** — the four request helpers, `Response.diagnostics`, new
  usage keys; **Changed** — `Response.usage` now also carries fields Claudio does not know
  (under their original keys).
- CLAUDE.md: Request-builder bullets; Response bullets (`diagnostics`, usage passthrough).
- Roadmap: S11 → merged #19 (92da159); S12 row replaced by **S12a** (this spec) and **S12b**
  (fallbacks, draft spec).

## Testing

TDD, unit tests first:

- `test/request_test.exs`
  - `add_system_message/3`: string and block content; `clear_at` both values (emitted, beta
    declared once); `effort` each level (output_config + beta); effort-only `[]`;
    raises for unknown `clear_at` / effort, `clear_at: :next_user_message` + `effort`,
    `[]` without effort, unknown option key; `nil` options = not given; appends after existing
    messages without touching them.
  - `set_speed/2` both values + beta; unknown raises. `set_inference_geo/2` both values, no
    beta; unknown raises. `enable_cache_diagnostics/2` nil/id; non-string raises.
  - `to_map/1` omits the three new fields when unset.
- `test/response_test.exs`
  - usage: new atom keys from string- and atom-keyed input; an unknown field (`"iterations"`,
    `:future_field`) survives under its original key; `nil` usage has the new keys as `nil`;
    the existing exact-match assertion (`response_test.exs:26`) updated for the new keys.
  - `diagnostics`: string/atom keys, absent → `nil`.
- `test/messages/stream_test.exs`: `diagnostics` on `message_start` survives
  `build_final_message/1` → `Response.from_map/1`.
- Integration (`:integration`, opt-in, `claude-opus-5-5`): effort-only system message first,
  a user turn, then a `clear_at: :next_user_message` system message; `set_inference_geo(:us)`;
  `enable_cache_diagnostics()` → 200, `usage.inference_geo == "us"`, `usage.service_tier`
  is a string. Fast mode is not live-tested (access-gated; P8 verified it for this key).

## Risks

| Risk | Effect if it bites | Mitigation |
|------|--------------------|------------|
| Beta strings change | 400 | Pinned from docs **and** live probes P2–P4, P8 (2026-09-25); one attribute each. |
| New `inference_geo` regions / `speed` values | Local `ArgumentError` blocks a valid value | Patch the atom list; raw `to_map` escape hatch is not available for these fields — accepted cost (atoms-only convention). |
| Mixed atom/string keys in `usage` | Callers must know unknown fields keep their original keys | Documented in the `usage` type and moduledoc; documented fields are always atom keys. |
| Combined effort-only + turn-scoped system messages in one conversation untested live | 400 in the integration test | The integration test is the probe; a failure there is reported, not loosened. |
