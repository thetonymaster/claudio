# MA1 — Managed Agents foundation (Agents, Environments, Sessions)

- **Date:** 2026-09-30
- **Spec status:** Design approved by Q in chat (2026-09-30, sections 1–3); written spec awaiting
  Q's review.
- **Scope class:** new namespace, one shared internal module, three resource modules, one
  pagination helper. Ships in **0.8.0** with MA2–MA4 (roadmap
  `2026-09-30-managed-agents-roadmap.md`).
- **Provenance:** live docs fetched 2026-09-30 under `platform.claude.com/docs/en/` —
  `managed-agents/overview` (OV), `managed-agents/agent-setup` (AS),
  `managed-agents/environments` (EN), `managed-agents/sessions` (SE),
  `managed-agents/session-operations` (SO), `api/beta/agents/list` (AL),
  `api/beta/sessions/list` (SL), `api/beta/sessions/events/list` (EL) — plus live probes P1–P7
  (2026-10-01 01:50 UTC, scratch agent/environment/session, all cleaned up).

## Problem

Claudio has no Managed Agents support. Every later MA spec needs the same base: a request
helper that attaches the beta header, query encoding for the API's bracketed filters
(`statuses[]`, `created_at[gte]`), cursor pagination, and the three core resources a session
needs — an agent, an environment, and the session itself.

## Verified facts

| # | Fact | Source |
|---|------|--------|
| F1 | Every MA1 endpoint needs `anthropic-beta: managed-agents-2026-04-01`. Without it `GET /v1/agents?limit=1` → 400 "Failed to parse request body: unknown field \"limit\"". The SDKs' `?beta=true` query param is neither needed with the header (P1a → 200) nor sufficient without it (P1c → same 400). | OV, P1 |
| F2 | Agent create: `name` and `model` required (`model` is a string or `{id, effort, speed, inference_geo}`); optional `system`, `tools`, `mcp_servers`, `skills`, `multiagent`, `description`, `metadata`. Response: `type: "agent"`, `id` (`agent_…`), `version: 1`, `model` normalised to a map (`{"effort":{"type":"high"},"id":…,"speed":"standard"}`), `archived_at`, timestamps. | AS, P2 |
| F3 | Agent update is `POST /v1/agents/{id}`; omitted fields preserved, arrays replaced, `metadata` merged per key. A real change bumps `version` (1 → 2). Optional `version` in the body is an optimistic-concurrency check: stale → **409** with `error.type: "invalid_request_error"`, "Concurrent modification detected. Please fetch the latest version and retry." | AS, P2, P4 |
| F4 | `GET /v1/agents/{id}?version=1` returns that version (`system: null` after v2 set it). `GET /v1/agents/{id}/versions/1` → 404. `GET /v1/agents/{id}/versions` lists versions newest first. Agents have archive (`POST …/archive`, sets `archived_at`), no delete. | P2, AS |
| F5 | Environment create: `name` required; `config` `{type: "cloud", networking, packages}` or `{type: "self_hosted"}`; optional `description`, `metadata`, `scope`. Response adds `state: "active"` and defaults `packages` to empty lists. `DELETE` works only while no session references it (→ `{"id", "type": "environment_deleted"}`); archive makes it read-only. Not versioned. | EN, P5 |
| F6 | Session create: `agent` (id string = latest version, `{type: "agent", id, version}`, or `{type: "agent_with_overrides", …}`) and `environment_id` required; optional `vault_ids`, `resources`, `title`, `metadata`, `budget`, `initial_events` (≤ 50; non-empty starts it `running`). Without `initial_events` the session is `idle`, with `stats.active_seconds: 0` — no model call. `agent` in the response is the resolved snapshot (version 2). | SE, P5 |
| F7 | Session `DELETE` → `{"id", "type": "session_deleted"}` (removes events, sandbox, produced files); archive keeps history and blocks new events. Neither works on a `running` session. Update (`POST /v1/sessions/{id}`) takes `agent.tools` / `agent.mcp_servers` (session must be `idle`) and `budget`. | SO, P5 |
| F8 | Lists are cursor-paged: `page` in, `next_page` out. When there is a further page the body has `next_page: "page_…"`; on the last page `next_page` is **absent** (single-page lists: keys `["data"]`) or `null` (the page fetched by cursor). Session lists may also return `prev_page`. No `has_more` / `first_id`. | AL, SL, P6 |
| F9 | Filters use bracketed names: `statuses[]` (repeatable), `created_at[gt\|gte\|lt\|lte]`, `created_by_ids[]`. Unbracketed `statuses=idle` → 400 listing the valid parameters (`agent_id, agent_version, created_at[gt], created_at[gte], created_at[lt], created_at[lte], created_by_ids[], deployment_id, include_archived, limit, memory_store_id, order, page, statuses[]`). Percent-encoded names (`statuses%5B%5D=idle`, what `URI.encode_query/1` emits) are accepted; an invalid value → 400 naming `statuses[0]`. | SL, P3, P7 |
| F10 | Events: `POST /v1/sessions/{id}/events` with `{"events": [...]}`; `GET /v1/sessions/{id}/events` takes `types[]`, `created_at[…]`, `order` (default `asc`), `limit`, `page`. A fresh idle session lists `{"data": []}`. | EL, P5 |
| F11 | Session resources: `POST/GET /v1/sessions/{id}/resources`, `GET/POST/DELETE …/resources/{rid}`; variants `file` (`file_id`, `mount_path?`), `github_repository` (`url`, `authorization_token?`, `checkout?`, `mount_path?`), `memory_store` (creation-time only). Not probed in P1–P7 — the integration test covers add/delete of a `file` resource. | SE |
| F12 | Claudio today: `Client.with_betas/2` unions + dedupes betas into one comma-joined header; `Skills`/`Admin` use private `get/post/delete` + `handle/1` returning `{:ok, body}` / `{:error, APIError.from_response(status, body)}`; `APIError` keeps unknown `error.type` strings as strings; Req's `put_params` keeps repeated `{name, value}` tuples in order. | code |

## Design

### 1. Modules

```
lib/claudio/managed_agents.ex              # overview moduledoc + stream/2
lib/claudio/managed_agents/http.ex         # @moduledoc false — transport + query encoding
lib/claudio/managed_agents/agents.ex
lib/claudio/managed_agents/environments.ex
lib/claudio/managed_agents/sessions.ex
```

`Claudio.Agent` is untouched in MA1 (its deprecation is MA2).

### 2. Transport (`Claudio.ManagedAgents.HTTP`, `@moduledoc false`)

- `get(client, path, opts)`, `post(client, path, body)`, `delete(client, path)`. Each runs
  `Claudio.Client.with_betas(client, ["managed-agents-2026-04-01"])` first (F1), so the beta is
  merged with — never replaces — the client's own betas. A `beta` argument is not added in
  MA1; MA3 decides the memory-store override.
- `post/3` with `body = nil` (archive endpoints) sends no body.
- `handle/1`: 2xx → `{:ok, body}`; other status → `{:error, APIError.from_response(status,
  body)}`; transport error → `{:error, reason}` (F12, unchanged contract).
- **Query encoding** `encode_query(opts)` → list of `{String.t(), String.t()}` handed to Req's
  `params:` (F9, F12):
  - scalar (string, integer, boolean, atom) → `{"key", to_string(v)}`
  - list of scalars → one `{"key[]", v}` per element, in order (`statuses: ["idle", "running"]`)
  - keyword list → one `{"key[sub]", v}` per pair (`created_at: [gte: "2026-09-01T00:00:00Z"]`)
  - anything else (map, nested list, list inside a keyword) → `ArgumentError` naming the key and
    `inspect/1` of the value. `nil` values → `ArgumentError` too (not silently dropped).
  - Option names are not checked; the API rejects unknown ones (F9).

### 3. Resource functions

All ids are guarded `when is_binary(id)`; bodies are maps (string or atom keys, encoded by
Jason) passed through; every function returns `{:ok, map()} | {:error, APIError.t() | term()}`.

**`Claudio.ManagedAgents.Agents`**

| Function | Request |
|---|---|
| `create(client, params)` | `POST agents` |
| `get(client, id, opts \\ [])` | `GET agents/{id}` — `version: n` → `?version=n` (F4) |
| `update(client, id, params)` | `POST agents/{id}` — `params` may carry `version` (F3) |
| `list(client, opts \\ [])` | `GET agents` — `limit`, `page`, `include_archived`, `created_at` |
| `archive(client, id)` | `POST agents/{id}/archive` |
| `list_versions(client, id, opts \\ [])` | `GET agents/{id}/versions` |

**`Claudio.ManagedAgents.Environments`** — `create/2`, `get/2`, `update/3` (`POST
environments/{id}`), `list/2`, `archive/2`, `delete/2`.

**`Claudio.ManagedAgents.Sessions`**

| Function | Request |
|---|---|
| `create(client, params)` | `POST sessions` |
| `get(client, id)` | `GET sessions/{id}` |
| `update(client, id, params)` | `POST sessions/{id}` |
| `list(client, opts \\ [])` | `GET sessions` — filters per F9 |
| `archive(client, id)` / `delete(client, id)` | `POST sessions/{id}/archive` / `DELETE sessions/{id}` |
| `send_events(client, id, events)` | `POST sessions/{id}/events`, body `%{"events" => events}`; `events` must be a list |
| `list_events(client, id, opts \\ [])` | `GET sessions/{id}/events` — `types`, `created_at`, `order`, `limit`, `page` |
| `add_resource(client, id, resource)` | `POST sessions/{id}/resources` |
| `list_resources(client, id, opts \\ [])` | `GET sessions/{id}/resources` |
| `get_resource(client, id, rid)` | `GET sessions/{id}/resources/{rid}` |
| `update_resource(client, id, rid, params)` | `POST sessions/{id}/resources/{rid}` |
| `delete_resource(client, id, rid)` | `DELETE sessions/{id}/resources/{rid}` |

Typed event builders/parsers and the event stream are MA2. Moduledocs show the raw-map form:

```elixir
Sessions.send_events(client, sid, [%{type: "user.message", content: [%{type: "text", text: "Hi"}]}])
```

### 4. Pagination — `Claudio.ManagedAgents.stream/2`

```elixir
@spec stream((keyword() -> {:ok, map()} | {:error, term()}), keyword()) :: Enumerable.t()
Claudio.ManagedAgents.stream(fn opts -> Agents.list(client, opts) end, limit: 100)
```

- Lazy (`Stream.resource/3`): first call with `opts`; each next call with
  `Keyword.put(opts, :page, cursor)`. Emits the items of `"data"` one by one.
- Stops when `"next_page"` is absent or `nil` (F8 — both observed).
- `{:error, exception}` (`APIError`, `Req.TransportError`, …) → `raise exception`;
  `{:error, other}` → `raise RuntimeError` with `inspect(other)`. Items already emitted stay
  emitted; nothing is truncated silently.
- A body without a `"data"` list → `ArgumentError` naming the function (catches passing a
  non-list function).
- Works for any MA list function now and in MA3/MA4.

### 5. Errors

- No new `APIError` types: the 409 from F3 is `invalid_request_error` (P4).
- `ArgumentError` cases: unencodable query value (§2), non-list `events` in `send_events/3`,
  non-list `"data"` in `stream/2`. Each message names the function and `inspect/1`s the value.
- Running-session archive/delete, environment delete while referenced, unknown fields, bad
  filter values: left to the API's 400s (F5, F7, F9).

## Testing

- **Unit (Bypass, `async: true`)** — `test/managed_agents/{http,agents,environments,sessions,
  managed_agents}_test.exs`: per function, method + path, `anthropic-beta` contains
  `managed-agents-2026-04-01`, merged and deduped with a client built with `beta:
  ["foo", "managed-agents-2026-04-01"]`, body passthrough, query string, non-2xx → `APIError`,
  non-JSON 5xx → `APIError`.
- **Encoder** — pure tests: scalars, booleans, integers, list → `k[]` repeated in order,
  keyword → `k[sub]`, mixed, and each `ArgumentError` case.
- **`stream/2`** — three pages (cursor threaded), last page without `next_page` key, last page
  with `next_page: null`, empty first page, error on page 2 raises after page 1's items are
  emitted, `Enum.take/2` fetches only the pages it needs (Bypass `expect` counts).
- **Integration** — `test/integration/managed_agents_integration_test.exs`, `:integration`,
  cleanup in `on_exit`: create agent → get → update (version 2) → `get(version: 1)` →
  `list_versions` → stale update → 409 `APIError`; create environment; create idle session; list
  events (`[]`); upload a small file via `Claudio.Files.upload/3`, `add_resource` /
  `list_resources` / `delete_resource`; `stream/2` over `Agents.list_versions` with `limit: 1`;
  delete session, archive agent, delete environment, delete file. No model call, no tokens.

## Docs

- `CHANGELOG.md` `[Unreleased]` → **Added:** Managed Agents foundation (beta
  `managed-agents-2026-04-01`): `Claudio.ManagedAgents.{Agents, Environments, Sessions}`,
  `Claudio.ManagedAgents.stream/2`.
- `CLAUDE.md`: a "Managed Agents (lib/claudio/managed_agents/)" architecture section; module
  tree entry.
- `README.md`: a short Managed Agents section (create agent + environment + session, send a
  message, list events) with a pointer that the run loop arrives in MA2.
- `mix.exs` `groups_for_modules`: "Managed Agents" group.

## Out of scope (MA1)

Event stream, typed events, runner, output files, `Claudio.Agent` deprecation (MA2);
deployments, vaults, memory stores, threads (MA3); dreams, work queue, webhooks (MA4); local
validation of any body field; retries specific to these endpoints (client `:retry` applies).
