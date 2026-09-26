# S10 — API drift fixes (MCP connector v2, GA endpoints, correctness)

- **Date:** 2026-09-25
- **Spec status:** approved design; implementation plan to follow (writing-plans)
- **Scope class:** one bug fix (MCP), additive options, doc corrections. Target release **0.7.0**.
- **Roadmap:** `docs/superpowers/specs/2026-06-19-anthropic-api-coverage-roadmap.md` → "2026-09 refresh"
- **Provenance:** live docs fetched 2026-09-25 — `agents-and-tools/mcp-connector`,
  `build-with-claude/files`, `build-with-claude/skills-guide`,
  `agents-and-tools/tool-use/code-execution-tool`, `build-with-claude/streaming` —
  plus the bundled `claude-api` reference. Every code claim below was checked against
  this repo's source on the same date.

## Problem

Claudio v0.6.0 was built against the API as of June 2026. Since then:

1. **The MCP connector changed shape** (`mcp-client-2025-04-04` → `mcp-client-2025-11-20`,
   the old version deprecated). Tool configuration moved off the server entry into an
   `mcp_toolset` entry in `tools`, and the API rejects any `mcp_servers` entry that is
   not referenced by exactly one toolset. Claudio's `Request.add_mcp_server/2` emits only
   the `mcp_servers` entry (with the old `tool_configuration` field) and declares no beta
   at all — so every MCP-connector request Claudio builds today is invalid.
2. **Files and Skills APIs went GA.** Claudio's docs still tell callers to configure
   `files-api-2025-04-14`, and `Claudio.Skills` auto-attaches `skills-2025-10-02`.
3. **Smaller drift:** a newer code-execution tool version (`code_execution_20260521`),
   a `stop_details` response field Claudio drops, and doc examples that point at retired
   models (`claude-3-5-sonnet-20241022`) or at request shapes that 400 on current models
   (`budget_tokens`, forced `tool_choice`).

### Verified facts this spec rests on

| Fact | Source |
|---|---|
| New MCP beta is `mcp-client-2025-11-20`; `2025-04-04` deprecated | mcp-connector doc, header + migration guide |
| Every `mcp_servers` entry must be referenced by **exactly one** `mcp_toolset` (`mcp_server_name`); a server may have only one toolset | mcp-connector doc, "Validation rules" |
| Toolset fields: `type`, `mcp_server_name`, optional `default_config`, `configs` (keys are **exact tool names**), `cache_control`; per-tool options `enabled`, `defer_loading` | mcp-connector doc, "MCP toolset configuration" |
| Unknown tool names in `configs` → server-side warning only, **no error** | mcp-connector doc, "Validation rules" |
| Migration table: no config → bare toolset; `enabled: false` → `default_config.enabled: false`; `allowed_tools: [...]` → `default_config.enabled: false` + each name `enabled: true` in `configs` | mcp-connector doc, "Common migration patterns" |
| `mcp_tool_use` / `mcp_tool_result` block shapes unchanged | mcp-connector doc, "Response content types" vs `response.ex` parsers |
| Files: header optional; **with** it → beta shapes (`has_more/first_id/last_id`, `before_id/after_id`); **without** → `{data, next_page}`, `page`/`ids[]` cursors, `before_id/after_id` return **400**, `expires_at` always present | files doc, "Migrate from files-api-2025-04-14" |
| Claudio never sends the Files beta itself — callers put it on their client | `lib/claudio/files.ex` moduledoc |
| Skills guide has **no** mention of `skills-2025-10-02` or a migration table | skills-guide doc (verbatim search: none found) |
| `code_execution_20260521` = same runtime as `20260120`; only the tool description differs; no version needs a beta | code-execution doc, "Tool versions" |
| Unknown response blocks already round-trip: `parse_content_block/1` and `block_to_api/1` both pass unmatched maps through unchanged | `response.ex` fallthrough clauses |
| Streaming docs do **not** document where `stop_details` appears in SSE | streaming doc (no match) |

## Goals / non-goals

**Goals**
- MCP-connector requests built by Claudio are valid under `mcp-client-2025-11-20`.
- Files/Skills docs and defaults reflect GA without breaking any existing caller.
- `add_code_execution_tool` defaults to the newest version, with older versions selectable.
- `stop_details` is available on `Response` (non-streaming and accumulated streaming).
- No doc example uses a retired model or a shape that 400s on current models.

**Non-goals**
- Typed parsing of `bash_code_execution_tool_result` / `text_editor_code_execution_tool_result`
  (they already round-trip raw; typing lands in S14).
- MCP toolset `defer_loading` helpers beyond the raw `configs` map (tool search is S14).
- Pinned MCP tool lists (beta) — not requested.
- Any model-aware validation (decided: library stays model-agnostic).

## Design

### 1. MCP connector v2

**`Claudio.MCP.ServerConfig`**

- Struct: remove `:tool_configuration`; add `:default_config` (`map() | nil`) and
  `:configs` (`%{String.t() => map()} | nil`).
- `allow_tools/2` keeps its name and signature but now writes the new shape:
  `default_config: %{"enabled" => false}`, `configs: %{name => %{"enabled" => true}}`
  for each name. If any entry contains `*` or `?`, it raises
  `ArgumentError`: `"MCP allow_tools/2 takes exact tool names; got pattern \"search_*\". The mcp-client-2025-11-20 connector matches configs keys literally, so a pattern would silently enable no tools."`
  *(Why raise: the API accepts unknown names with only a server-side warning, so a
  translated pattern would produce a valid request with zero tools enabled — silent
  corruption. The old docs advertised globs; the API never documented them.)*
- New `set_default_config/2` (map) and `configure_tool/3` (name, map) — merge into the
  respective fields. These are the forward path for `defer_loading` and denylists.
- `to_map/1` emits only the server entry (`type`, `url`, `name`, `authorization_token`).
- New `to_toolset/1` emits `%{"type" => "mcp_toolset", "mcp_server_name" => name}` plus
  `default_config` / `configs` when set.

**`Claudio.Messages.Request.add_mcp_server/2`**

- Struct clause: append `ServerConfig.to_map/1` to `mcp_servers`, append
  `ServerConfig.to_toolset/1` to `tools`, `add_beta("mcp-client-2025-11-20")`.
- Raw-map clause:
  - If the map has `"tool_configuration"`, translate per the migration table (same
    exact-name rule and `ArgumentError` on patterns), strip it from the server entry,
    and emit `Logger.warning("... tool_configuration is deprecated (mcp-client-2025-04-04); translated to an mcp_toolset ...")`.
  - Append a toolset for the server's `"name"` **unless** `tools` already contains an
    `mcp_toolset` with that `mcp_server_name` (caller built it by hand — do not duplicate,
    since the API rejects two toolsets for one server).
  - Declare the beta.
- Atom-keyed raw maps: the existing clause accepts any map; the toolset lookup reads
  `"name"` then `:name`. If neither is present, raise `ArgumentError` naming the missing
  key (the API would reject it anyway; fail at build time with a clear message).

**Unchanged:** `Response` parsing of `mcp_tool_use` / `mcp_tool_result`; `Claudio.MCP.Client`
behaviour and adapters (client-side, unrelated to the connector wire shape).

### 2. GA endpoints

**Files** — no behaviour change for existing callers.
- `list/2` gains `:page` (cursor string from `next_page`) and `:ids` (list, ≤100,
  sent as repeated `ids[]`). `:before_id` / `:after_id` stay as pass-throughs.
- Moduledoc rewritten: no beta required; without the header, responses use
  `{data, next_page}` and `before_id`/`after_id` return 400; callers who still put
  `files-api-2025-04-14` on their client keep the old shapes. The return-shape doc on
  `list/2` lists both.
- Does **not** validate the `:ids` + `:page` combination (API owns validation — model-agnostic decision applies equally to endpoint rules).

**Skills** — header removal gated on a live check.
- Implementation step 1 (before any Skills code change): a tagged `:integration`
  test that calls `GET /v1/skills` twice — with and without `anthropic-beta: skills-2025-10-02` —
  and records the top-level response keys of each.
  - **Keys identical:** stop auto-attaching the header (`@beta` and `beta/1` removed;
    requests go through the plain client). Moduledoc: GA, no header.
  - **Keys differ:** stop auto-attaching by default, and document both shapes and how to
    opt back in (`Claudio.Client.with_betas(client, ["skills-2025-10-02"])`), mirroring Files.
    Update `list/2`'s documented options to the GA pagination.
  - Either branch: remove the stale "Beta." line and the `with_betas` note from the moduledoc.
- If no API key is available when this step runs, stop and report — do not guess the branch.

### 3. Smaller correctness items

**Code execution**
- `add_code_execution_tool/2` (new arity; `/1` delegates with `[]`): `version:` option
  `:"20260521"` (default) `| :"20260120" | :"20250825"`. Unknown atoms raise
  `ArgumentError` listing the valid ones. Doc: same runtime for 20260120/20260521; pick
  `20250825` only when programmatic tool calling / REPL persistence must be off.

**`stop_details`**
- `Response` struct gains `:stop_details` (`map() | nil`), populated from `stop_details`
  in the API body as-is (raw map, string keys — an open set of categories, so no atom
  conversion). `nil` whenever absent.
- `Stream.build_final_message/1`: in the `message_delta` clause add
  `maybe_update(delta, "stop_details")` alongside `stop_reason`. This location is
  **unverified** (streaming docs are silent); it is the sibling of `stop_reason`, and the
  clause is a no-op when the key is absent, so being wrong costs nothing but the field.
  The `stop_details` field doc says streamed population is unconfirmed; do not add a
  second lookup location speculatively.

**Docs**
- Replace every `claude-3-5-sonnet-20241022` and `claude-sonnet-4-5-20250929` in `lib/`
  moduledocs/doctests with `claude-opus-5` (grep-verified list in the plan).
- `enable_thinking/2` doc: replace the `budget_tokens` example with
  `%{"type" => "adaptive"}`; note that `budget_tokens` returns 400 on Opus 4.7+/5.x,
  Sonnet 5, and Fable models, and that dedicated helpers arrive in S11.
- `set_tool_choice/2` doc: `:any` and `{:tool, name}` return 400 on Claude Fable 5.1,
  Mythos 5.1 and Opus 5.5 — use `:auto` with a prompt instruction, `add_strict_tool/2`,
  or `set_output_format/2`.
- `CLAUDE.md`: MCP section (toolset + beta), Files/Skills GA, code-exec default version.
- `CHANGELOG.md`: 0.7.0 entry — MCP fix (with the `allow_tools` glob `ArgumentError`
  called out as a behaviour change), Files options, Skills header, code-exec default,
  `stop_details`.

## Testing

All unit tests use the existing Bypass / pure-map style; one file per module.

- `test/mcp/server_config_test.exs` — rewrite `allow_tools` cases to the new fields;
  glob raises with the pattern in the message; `to_map` never contains
  `tool_configuration`; `to_toolset` shapes (bare, allowlist, `configure_tool`).
- `test/mcp/request_mcp_test.exs` — struct path adds server + toolset + beta; raw map
  path adds toolset; raw map with existing toolset is not duplicated; raw
  `tool_configuration` translated (+ warning captured with `ExUnit.CaptureLog`) for the
  three migration-table rows; missing name raises; `required_betas/1` contains
  `mcp-client-2025-11-20` exactly once after two servers.
- `test/files_test.exs` — `:page` and `:ids` produce the right query string (Bypass
  asserts `ids[]` repetition).
- `test/skills_test.exs` — header assertions updated per the branch taken.
- `test/request_test.exs` — code-exec default + each version + invalid version raises.
- `test/response_test.exs` — `stop_details` present on refusal body, `nil` otherwise.
- `test/messages/stream_test.exs` — `message_delta` with `stop_details` lands on the
  final message; absent key leaves it `nil`.
- `test/integration/` — Skills header comparison (gates §2); an MCP-connector smoke
  request against a public MCP server is **not** added (needs a reachable https MCP URL;
  out of scope).

Done = `mix test` green, `mix format --check-formatted` clean, `mix compile --warnings-as-errors` clean.

## Risks

- **`allow_tools/2` glob callers now crash.** Intentional; called out in CHANGELOG.
  Their requests were already failing (no toolset, no beta), so no working code breaks.
- **Removing `:tool_configuration` from the struct** breaks code that pattern-matches
  or sets the field directly. Pre-1.0 minor bump; CHANGELOG entry.
- **Skills branch unknown until the live check runs** — the spec fixes both outcomes
  in advance so the plan does not stall on a design question.
