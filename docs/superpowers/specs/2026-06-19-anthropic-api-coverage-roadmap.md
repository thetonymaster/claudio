# Anthropic API Coverage — Gap Analysis & Roadmap

- **Date:** 2026-06-19
- **Beads epic:** `claudio-8rv` (children `claudio-hms`, `-7mj`, `-9lj`, `-5h7`, `-0vx`, `-euz`, `-nwf`, `-c7t`, `-zrq`)
- **Provenance:** deep-research sweep of the current Anthropic API surface (official docs at `platform.claude.com` / `docs.claude.com` + the `anthropic-sdk-python`/`-typescript` repos), diffed against Claudio v0.5.0, with every code-level claim verified against this repo's source.
- **Baseline audited:** Claudio v0.5.0 — Messages (create/stream/count_tokens), Batches (full lifecycle), Files (full lifecycle), MCP connector + client adapters, A2A; auth via `x-api-key` only.

Legend: ✅ verified in Claudio's source · 📖 per official Anthropic docs (re-confirm exact dated strings at implementation time).

---

## Status summary

| Spec | Title | Beads | Priority | Status |
|------|-------|-------|----------|--------|
| **S1** | Extended-thinking round-trip correctness | `claudio-hms` | P1 | **DONE** (this branch) |
| S2 | Per-feature beta-header management | `claudio-7mj` | P2 | open |
| S3 | Request-builder additions (structured outputs, eager streaming, msg-level caching) | `claudio-9lj` | P2 | open |
| S4 | Models API module | `claudio-5h7` | P2 | open |
| S5 | Citations + content-block parsing (search_result, server-tool results) | `claudio-0vx` | P2 | open (blocked by S1 ✓) |
| S6 | Server-side tool helpers (web_search, web_fetch, code_execution, text_editor, computer_use, memory) | `claudio-euz` | P2 | open (blocked by S2, S5) |
| S7 | Admin API module | `claudio-nwf` | P3 | open (blocked by S2) |
| S8 | Auth (Bearer/OAuth) + alt deployments (Bedrock/Vertex) | `claudio-c7t` | P3 | open |
| S9 | Niche beta endpoints (Agent Skills API, prompt-tools) | `claudio-zrq` | P4 | open (blocked by S2) |

**Recommended build order:** S1 → S2 → S4 → S3 → S5 → S6 → S7 → S8 → S9.
Rationale: bugs first (S1); beta-header plumbing (S2) is foundational for S6/S7/S9; Models (S4) is a ~1-file freebie; S6 is heaviest and sits after its dependencies (may split into web-tools / code-exec / computer+memory).

---

## Decomposition (S1–S9)

| # | Spec | Gap items (see inventory) | Touches | Depends on |
|---|------|---------------------------|---------|-----------|
| **S1** | Extended-thinking round-trip correctness | T0.1 signature, T0.2 redacted_thinking, T0.3 signature_delta/citations_delta | `response.ex`, `stream.ex`, `agent.ex` | — |
| **S2** | Per-feature beta-header management | T3.14 | `client.ex`, `request.ex` | — |
| **S3** | Request-builder additions | T1.4 structured outputs, T2.11 eager_input_streaming, T2.7 message-level `cache_control` | `request.ex` | — |
| **S4** | Models API | T1.5 | new `Claudio.Models` | — |
| **S5** | Citations + content-block parsing | T2.8 citations, T2.9 search_result, server-tool result typing | `response.ex`, `request.ex`, `stream.ex` | S1 |
| **S6** | Server-side tool helpers | T1.6 web_search, T2.10 web_fetch/code_exec/text_editor, T3.15 computer_use, T3.16 memory | new `Claudio.Tools.*`, `request.ex` | S2, S5 |
| **S7** | Admin API | T2.12 | new `Claudio.Admin.*` (admin key) | S2 |
| **S8** | Auth + alt deployments | T2.13 Bearer/OAuth, T3.18 Bedrock/Vertex | `client.ex`, new transports | — |
| **S9** | Niche beta endpoints | T3.17 Skills API, T3.19 prompt-tools | new modules | S2 |

---

## Gap inventory

### Tier 0 — correctness bugs (latent 400s) — **DONE in S1**

These were features Claudio *partially* implemented in a way that breaks real multi-turn extended-thinking + tool-use loops.

1. **`thinking` blocks dropped `signature`** ✅ — `response.ex` parsed a thinking block without `signature`. The API requires it (unmodified) on replay or returns `400 invalid_request_error`. **Fixed.**
2. **`redacted_thinking` untyped/unpreserved** ✅ — hit the `parse_content_block` fallthrough → raw map; docs name "code that filters content blocks by type and drops `redacted_thinking`" as the #1 cause of the 400. **Fixed (typed block).**
3. **Streaming dropped `signature_delta` / `citations_delta`** ✅ — `stream.ex` `apply_delta` catch-all swallowed them, so streamed thinking lost its signature and citation data was lost. **Fixed.**
- **Root cause (discovered during S1's final review):** the parsed `Response` was lossy AND multiple places re-serialized it back to API shape — `Response` (new `to_assistant_content/1`) and `Agent` (`serialize_block/1`), so fixing one missed the other. **S1 also unified them onto `Response.to_assistant_content/1`** (deleted `Agent`'s divergent serializer) so `Agent.run/4` no longer 400s and future block types are handled in one place.

### Tier 1 — high value, GA, broadly useful

4. **Structured outputs** 📖 — **GA**, no beta header. `output_config.format` (`{type: "json_schema", schema: …}`) + per-tool `"strict": true`. Claudio has no `output_config` field at all. *(S3)*
5. **Models API** 📖 — **GA**, no beta header. `GET /v1/models` (list, paginated) + `GET /v1/models/{id}`. No module exists. ~1-file freebie. *(S4)*
6. **Web search tool** 📖 — `web_search_20250305`, **GA**. Needs a request helper + response parsing for `server_tool_use` / `web_search_tool_result` / citations (currently untyped raw maps). `pause_turn` stop_reason already mapped ✅. *(S6)*

### Tier 2 — medium value

7. **`cache_control` on message content blocks** ✅ gap — Claudio caches only system (`set_system_with_cache`) + tools (`add_tool_with_cache`), both with correct `ttl`. 📖 `cache_control` (up to 4 breakpoints, `ttl` "5m"/"1h") is also valid on user/assistant/tool_result content blocks (the "growing conversation prefix" pattern). No helper. *(S3)*
8. **Citations** 📖 — GA. Request: `citations:{enabled:true}` on documents (`add_message_with_document/3` doesn't thread it). Response: `text` blocks gain a `citations` array (not parsed). Location types: `char_location`, `page_location`, `content_block_location`, `search_result_location`, `web_search_result_location`. *(S5)*
9. **`search_result` content blocks** 📖 — GA, good fit for Elixir RAG. No builder + `search_result_location` citations unparsed. *(S5)*
10. **Code execution + text editor + web fetch tools** 📖 — server/client tools needing helpers. `set_container/2` ✅ is exactly the container-reuse field these need. Code execution wants `code-execution-2025-08-25`. *(S6)*
11. **`eager_input_streaming: true`** 📖 (fine-grained tool streaming) — GA, now a tool field (old beta header legacy). Request-builder gap only; `input_json_delta` accumulation already works ✅. *(S3)*
12. **Admin API** 📖 — `/v1/organizations/*` (members, workspaces, keys, invites, **usage & cost reports**). GA but uses an **admin key** (`sk-ant-admin…`) → separate `Claudio.Admin` namespace. *(S7)*
13. **Bearer / OAuth auth** ✅ Claudio is `x-api-key` only (`client.ex` hardcodes it). 📖 API also accepts `Authorization: Bearer` (Workload Identity Federation via `POST /v1/oauth/token`; Claude-Code-style tokens need `anthropic-beta: oauth-2025-04-20`). Minimal win: configurable Bearer header. *(S8)*

### Tier 3 — low / niche / optional

14. **Per-feature beta-header management** ✅ cross-cutting — `to_map` attaches no betas; client headers come only from the user-supplied `beta` list set at `Client.new`. So `set_context_management/2` (needs `context-management-2025-06-27`), computer use, etc. **silently 400** unless the user knows the magic string. *(S2)*
15. **Computer use tool** 📖 (`computer_20250124`, beta header `computer-use-2025-01-24` required) — niche for an Elixir lib. *(S6)*
16. **Memory tool** 📖 (`memory_20250818`, beta) — ties into the `context_management` field Claudio already has. *(S6)*
17. **Agent Skills API** 📖 (`/v1/skills`, beta `skills-2025-10-02`, multipart) — Claudio's Files plumbing partly applies. *(S9)*
18. **Bedrock / Vertex adapters** 📖 — large effort (SigV4 / GCP ADC, model-id prefixing, feature masking). Defer until demand. *(S8)*
19. **Prompt tools API** 📖 (`/v1/experimental/*`) — experimental, access-gated. Lowest priority; exact beta header UNVERIFIED. *(S9)*

---

## Explicitly NOT building (deprecated / non-goals)

- **Text Completions** (`POST /v1/complete`) — 📖 legacy; modern models are Messages-only.
- **Token-efficient tool use** (`token-efficient-tools-2025-02-19`) — 📖 Claude-3.7-only, deprecated; no-op on current models.
- **`model_context_window_exceeded` stop_reason** — already mapped ✅ (`response.ex`). Not a gap.
- **1M context header helper** — 📖 GA (no header) on current models; the dated header is on a retirement path. Doc note at most.

---

## Confidence / caveats

- Tier 0 bugs and the Tier 1/2 *structural* gaps (Models API, structured outputs, web search, citations, message-level caching) are high-confidence — verified in code and on official docs.
- Exact **dated tool-type strings and beta-header values** (e.g. `web_search_20260209`, `skills-2025-10-02`) came from research-agent doc fetches; **pin each against the live reference page before shipping**.

## Sources

- Anthropic docs: `platform.claude.com/docs` (structured outputs, models-list, citations, search-results, prompt-caching, streaming, extended-thinking, administration-api, tool pages for web-search/web-fetch/code-execution/text-editor/computer-use/memory, agent-skills, beta-headers, authentication, Bedrock/Vertex).
- Official SDKs: `github.com/anthropics/anthropic-sdk-python`, `…/anthropic-sdk-typescript`.
