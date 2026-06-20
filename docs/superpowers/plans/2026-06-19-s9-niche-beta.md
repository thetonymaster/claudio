# S9 — Niche beta endpoints (Agent Skills API)

- **Date:** 2026-06-19
- **Bead:** `claudio-zrq` (epic `claudio-8rv`)
- **Branch:** `s9-niche-beta` (off `s8-auth`; stacks).
- **Roadmap row:** S9 — niche beta endpoints. Depends on S2 ✓. Lowest priority.
- **Touches:** new `lib/claudio/skills.ex`, `mix.exs` (ex_doc group), `CLAUDE.md`.

## Scope decision

Roadmap S9 = T3.17 Agent Skills API **and** T3.19 prompt-tools.

- **Agent Skills API — SHIP.** Endpoints + beta verified against the live API reference (2026-06-19).
- **Prompt tools (`/v1/experimental/*`) — DEFER (documented).** The roadmap already flags its beta header as **UNVERIFIED**; the live doc page is inaccessible (returns an empty page). Per "don't confabulate," I will **not** guess endpoints/beta strings. Documented as not-implemented (experimental, access-gated).

## Verified (Skills API, live reference 2026-06-19)

- Beta header: **`skills-2025-10-02`** (the module attaches it itself via `Claudio.Client.with_betas/2` — callers don't pre-configure).
- `GET /v1/skills` — list; query params `limit` (≤100, default 20), `page` (token), `source` (`custom`/`anthropic`). Returns `{data, has_more, next_page}`.
- `POST /v1/skills` — create (multipart/form-data; returns the skill object: `id, created_at, display_title, latest_version, source, type, updated_at`).
- Skill object `type` is `"skill"`.

### Standard-REST sub-resources (conventional; not each individually shown, noted honestly)
- `GET /v1/skills/{id}`, `DELETE /v1/skills/{id}`
- `GET /v1/skills/{id}/versions`, `GET /v1/skills/{id}/versions/{version}`, `DELETE /v1/skills/{id}/versions/{version}`
- `POST /v1/skills/{id}/versions` — create version (multipart)

### Multipart create — field names NOT verified
The verified create curl didn't show the form-data fields. Rather than guess (a wrong field 400s), `create/2` and `create_version/3` accept a **caller-supplied `form_multipart` list** (same shape `Claudio.Files.upload/3` uses: `[field: {bytes, filename: …, content_type: …}]`). The module supplies the endpoint + beta + multipart transport; the caller supplies the exact fields. Documented.

## Design

`Claudio.Skills`, thin wrappers over a shared private helper (mirrors `Claudio.Admin`/`Claudio.Models`: raw body `{:ok, map()}`, non-2xx → `APIError`). The `skills-2025-10-02` beta is merged onto the client per call via `Client.with_betas/2` (S2), so it works even if the client wasn't built with it.

```elixir
defp beta(client), do: Client.with_betas(client, ["skills-2025-10-02"])
defp http_get(client, url, params), do: handle(Req.get(beta(client), url: url, params: params))
defp http_delete(client, url),      do: handle(Req.delete(beta(client), url: url))
defp http_multipart(client, url, f), do: handle(Req.post(beta(client), url: url, form_multipart: f))
```

## Tasks (TDD — Bypass)

1. **Reads/manage** — `list/2` (+ params + asserts `anthropic-beta: skills-2025-10-02`), `get/2`, `delete/2`, `list_versions/2`, `get_version/3`, `delete_version/3`.
2. **Create (multipart)** — `create/2`, `create_version/3` POST multipart to the right path with the beta header (assert `content-type` starts with `multipart/form-data`).
3. **Errors** — non-2xx → `APIError`.
4. **Docs** — `mix.exs` "Skills API (beta)" ex_doc group; CLAUDE.md section incl. the prompt-tools deferral.

Then `mix format`, `mix test`, push, PR (base `s8-auth`).
