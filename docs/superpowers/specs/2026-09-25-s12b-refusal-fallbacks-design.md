# S12b — Refusal fallbacks (`fallbacks`, `fallback` blocks, `usage.iterations`)

- **Date:** 2026-09-25
- **Spec status:** **DRAFT — design not yet reviewed with Q.** Written at the S12 split so the
  verified facts are not lost. Before writing its plan: brainstorm the open questions below,
  re-probe, get Q's approval, then update this file's status.
- **Scope class:** request field + new response content block (non-streaming and streaming) +
  usage/stop_details typing. Ships in **0.7.0** (single bump after S15).
- **Split from:** roadmap S12 (Q, 2026-09-25). S12a (request surface) ships first:
  `2026-09-25-s12a-request-surface-design.md`. S12b builds on S12a's usage passthrough.
- **Provenance:** live docs fetched 2026-09-25 — `build-with-claude/refusals-and-fallback` (RF),
  `api/beta/messages/create` (REF), `release-notes/overview` (RN), all under
  `platform.claude.com/docs/en/` — plus one live probe (P7, `claude-opus-5-5`).

## Problem

The API can retry a refused request on another model server-side, but Claudio can't ask for it
(no `fallbacks` field), and the response surface it adds is untyped: a `fallback` content block,
the serving model, `usage.iterations`, and new `stop_details` fields.

## Verified facts

| # | Fact | Source |
|---|------|--------|
| F1 | Request: `"fallbacks": "default"` or `"fallbacks": [{"model": "claude-opus-4-8"}, …]` (up to three). Each entry can override `max_tokens`, `thinking`, `output_config`, `speed`. | RF |
| F2 | Beta header: `server-side-fallback-2026-07-01` (supports `"default"` and the list form) or `server-side-fallback-2026-06-01` (list form only). | RF; P7 → 200 with `2026-07-01` + `"default"` |
| F3 | Allowed targets per model: `allowed_fallback_models` on the model's entry in the Models API. | RF |
| F4 | Response: top-level `model` = the model that produced the message. New content block `{"type": "fallback", "from": {"model": …}, "to": {"model": …}}`; REF's `BetaFallbackBlock` also has an optional `trigger: {type: "refusal", category}` (RF's prose example omits it — parse it as optional). | RF, REF |
| F5 | `usage.iterations`: entries `"type": "message"` = declined attempts, `"type": "fallback_message"` = the serving attempt. Present whenever `fallbacks` is set (P7: present even with no refusal). | RF; P7 |
| F6 | `stop_details` adds `recommended_model` (RF); REF also lists `fallback_credit_token`, `fallback_has_prefill_claim`. | RF, REF |
| F7 | Echo rule for continuing the conversation: "`fallback`: Keep it exactly where it appeared." | RF |
| F8 | Streaming: decline before output → `message_start` names the fallback model and the `fallback` block is the first content block. Decline mid-output → the fallback block is a `content_block_start`/`content_block_stop` pair with **no deltas**; read the serving model from the block's `to.model`. | RF |
| F9 | Models: refusal classifiers on Fable 5.1, Fable 5, Opus 5.5, Opus 5. Not on Batches, Bedrock, Google Cloud, Foundry. (An older RN entry also lists Claude Platform on AWS; RF now says Claude API only.) | RF, RN |
| F10 | Claudio today already passes unknown content blocks through `Response` both ways (`parse_content_block(block) -> block`, `block_to_api(block) -> block`), so a `fallback` block is **already** echoed unchanged by `to_assistant_content/1` (satisfies F7). Streaming: `build_final_message/1` handles `content_block_start`/`_stop` generically. | repo `response.ex:378`, `:441` |

## Draft design (to be reviewed)

- `Request.set_fallbacks(req, :default | [model_or_entry])` → `"fallbacks"`; declares
  `server-side-fallback-2026-07-01`. List entries: a model string → `%{"model" => m}`; a map →
  passed through (per-entry overrides, F1). Local raises: empty list, more than three entries
  (API-universal per RF — **confirm by probe**), non-string/non-map entries.
- `Response` parses `fallback` blocks to `%{type: :fallback, from: map, to: map, trigger: map | nil}`
  and `to_assistant_content/1` re-emits the **exact original** string-keyed block (F7) — keep the
  raw block on the parsed map (e.g. `raw:`) rather than rebuilding it, so unknown sub-fields
  survive.
- Readers: `Response.fallback/1` (the fallback block or `nil`), `Response.served_by/1`
  (`to.model` when a fallback happened, else `model`).
- `usage.iterations` becomes a documented atom key (S12a keeps it as a string key until then).
- `stop_details` stays raw (S10 decision); document the new keys.
- `Stream`: verify the no-delta `fallback` block survives `build_final_message/1` and parses via
  `Response.from_map/1`; no new delta types.

## Open questions (resolve in brainstorming)

1. Typed `:fallback` block vs keeping it raw and only adding readers? (Typing changes what
   `resp.content` holds for callers that pattern-match on raw maps today.)
2. Should `set_fallbacks/2` validate the three-entry cap locally, or leave it to the API?
3. How to live-test: a refusal must be triggered deliberately to see a real `fallback` block —
   is there a documented test trigger, or do we rely on fixtures from REF/RF examples?
4. `Claudio.Batches`: fallbacks are not supported there (F9) — raise locally when a request
   with `fallbacks` goes into a batch, or leave it to the API?
