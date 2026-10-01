# Managed Agents roadmap (MA1–MA4, release 0.8.0)

- **Date:** 2026-09-30
- **Status:** Decomposition approved by Q in chat (2026-09-30); MA1 spec written alongside.
- **Baseline:** `main` at 94fd0d6 (0.7.0 + `[Unreleased]`: per-client options, req ≥ 0.6.1).
- **Provenance:** live docs under `platform.claude.com/docs/en/` — `managed-agents/*`
  (overview, agent-setup, environments, sessions, session-operations, events-and-streaming,
  permission-policies, tools, mcp-connector, skills, vaults, memory, dreams, files,
  scheduled-deployments, webhooks, reference), `api/beta/*`, `release-notes/overview` —
  plus the anthropic-sdk-python / -typescript `api.md` endpoint lists, fetched 2026-09-30.
  Live probes are recorded per spec (MA1: P1–P7).

## Goal

Full Managed Agents API support in Claudio, typed where it pays off: the session run loop
(events, custom tools, confirmations) gets structs and a runner; every other resource is a thin
raw-map module. `Claudio.Agent` (client-side Messages tool loop) is deprecated in favour of the
session runner.

## Cross-cutting decisions

- **Namespace:** `Claudio.ManagedAgents.*`. `Claudio.ManagedAgents` itself holds the overview
  moduledoc and `stream/2` (lazy pagination).
- **Raw maps by default.** Resource functions return `{:ok, map()}` (decoded body, string keys)
  or `{:error, %Claudio.APIError{}}` — the `Skills` / `Admin` / `Models` contract. Bodies are
  passed through. The API owns validation; Claudio doesn't re-check fields locally. Reason:
  the beta has shipped 11 changes since 2026-04-08; structs per resource would go stale.
- **Typed only on the run path (MA2):** `Claudio.ManagedAgents.Event` (parse + builders) and
  the session runner.
- **Beta header per request.** Each module adds its beta via `Claudio.Client.with_betas/2`;
  callers use their ordinary client. Memory stores need `agent-memory-2026-07-22` *instead of*
  `managed-agents-2026-04-01` (both → 400) — the conflict rule is an MA3 decision.
- **Specs just in time.** One spec per MA, written immediately before its implementation, each
  with its own probes; dated strings and fields are re-pinned then.
- **Release:** MA1–MA4 accumulate under CHANGELOG `[Unreleased]`; one bump to **0.8.0** after
  MA4. No MA bumps `@version` on its own.

## `Claudio.Agent` deprecation (Q, 2026-09-30: option 1)

Managed sessions hand custom tool calls back to the client (`agent.custom_tool_use` → session
idles with `stop_reason: requires_action` → client sends `user.custom_tool_result`). The
handler-map contract of `Claudio.Agent.run/3` (`%{"name" => fn input -> {:ok, _} | {:error, _}
end}`) carries over to the MA2 runner. In MA2: `Claudio.Agent` gets `@moduledoc` and
`@deprecated` notes pointing at the runner, keeps working through 0.x, and is removed at 1.0.
The exact handler contract is fixed in the MA2 spec.

## Decomposition

| Spec | Scope | Status |
|------|-------|--------|
| **MA1** | Foundation: shared HTTP helper (beta, bracketed query encoding), `ManagedAgents.stream/2`; Agents, Environments, Sessions (CRUD, archive/delete, events send + list, session resources) | spec `2026-09-30-ma1-foundation-design.md` |
| MA2 | Running sessions: SSE event stream, `Event` structs + builders, session runner (custom tool handlers, confirmation callback, reconnect + dedupe by event id), session output files (`/v1/files?scope_id=`), `Claudio.Agent` deprecation | not started |
| MA3 | Deployments + deployment runs (pause/unpause/run), Vaults + credentials (archive, `mcp_oauth_validate`), Memory stores + memories + memory versions (separate beta), session threads | not started |
| MA4 | Dreams (research preview, access-gated; labelled preview), self-hosted environment work queue, webhook signature verification (pure function) | not started |

**Order:** MA1 → MA2 → MA3 → MA4 → 0.8.0 release prep.

## Resource inventory (research, 2026-09-30)

Every path is under `/v1`; every list is cursor-paged (`page` in, `next_page` out). "SDK" marks
a path seen only in the SDK `api.md`; MA specs verify their slice by probe.

| Resource | Endpoints | Spec |
|---|---|---|
| Agents | `POST /agents`, `GET /agents/{id}` (`?version=N`), `POST /agents/{id}`, `GET /agents`, `POST /agents/{id}/archive`, `GET /agents/{id}/versions` — no delete | MA1 |
| Environments | `POST /environments`, `GET/POST/DELETE /environments/{id}`, `GET /environments`, `POST /environments/{id}/archive` | MA1 |
| Sessions | `POST /sessions`, `GET/POST/DELETE /sessions/{id}`, `GET /sessions`, `POST /sessions/{id}/archive` | MA1 |
| Session events | `GET/POST /sessions/{id}/events` (MA1), `GET /sessions/{id}/events/stream` (MA2) | MA1/MA2 |
| Session resources | `POST/GET /sessions/{id}/resources`, `GET/POST/DELETE /sessions/{id}/resources/{rid}` | MA1 |
| Session threads | `GET /sessions/{id}/threads`, `GET /sessions/{id}/threads/{tid}`, `POST …/{tid}/archive`, `GET …/{tid}/events`, `GET …/{tid}/stream` | MA3 |
| Deployments | `POST /deployments`, `GET/POST /deployments/{id}`, `GET /deployments`, `POST …/archive`, `…/pause`, `…/unpause`, `…/run` | MA3 |
| Deployment runs | `GET /deployment_runs` (`deployment_id`, `has_error`), `GET /deployment_runs/{id}` | MA3 |
| Vaults | `POST /vaults`, `GET/POST/DELETE /vaults/{id}`, `GET /vaults`, `POST …/archive` | MA3 |
| Vault credentials | `POST/GET /vaults/{id}/credentials`, `GET/POST/DELETE …/{cid}`, `POST …/{cid}/archive`, `POST …/{cid}/mcp_oauth_validate` | MA3 |
| Memory stores | `POST /memory_stores`, `GET/POST/DELETE /memory_stores/{id}`, `GET /memory_stores`, `POST …/archive`; memories CRUD under `…/memories`; `GET …/memory_versions`, `GET …/memory_versions/{vid}`, `POST …/{vid}/redact` (beta `agent-memory-2026-07-22`) | MA3 |
| Dreams | `POST /dreams`, `GET /dreams/{id}`, `GET /dreams`, `POST …/cancel`, `POST …/archive` (betas `managed-agents-2026-04-01,dreaming-2026-04-21`) | MA4 |
| Env work queue (SDK) | `GET /environments/{id}/work`, `GET/POST …/work/{wid}`, `POST …/ack`, `…/heartbeat`, `…/stop`, `GET …/work/poll`, `GET …/work/stats` | MA4 |
| Webhooks | Console-registered; `webhook-id` / `webhook-timestamp` / `webhook-signature` headers, `whsec_` secret | MA4 |

## Open questions (resolved in the owning spec)

- MA3: memory-store beta conflict — raise locally, strip, or let the API's 400 through.
- MA4: does Q's key have Dreams preview access? If not, Dreams ship with Bypass tests only and
  a doc note that they are unverified live.
