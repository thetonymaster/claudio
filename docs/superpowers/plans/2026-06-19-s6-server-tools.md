# S6 — Server-side tool helpers

- **Date:** 2026-06-19
- **Bead:** `claudio-euz` (epic `claudio-8rv`)
- **Branch:** `s6-server-tools` (off `s5-citations`; stacks — S5 must merge first)
- **Roadmap row:** S6 — server/client tool request-builder helpers. Depends on S2 ✓ (beta headers) + S5 (response typing of `server_tool_use` / `web_search_tool_result`).
- **Touches:** `lib/claudio/messages/request.ex`, `CLAUDE.md`.

## Verified tool strings (pinned against live docs 2026-06-19)

| Helper | `type` | `name` | Beta header | Source |
|---|---|---|---|---|
| web search | `web_search_20260209` (default) / `web_search_20250305` (basic) | `web_search` | — (GA) | tool-use-concepts.md |
| web fetch | `web_fetch_20260209` (default) / `web_fetch_20250910` (basic) | `web_fetch` | — (GA) | web-fetch-tool.md |
| code execution | `code_execution_20260120` | `code_execution` | — (GA) | tool-use.md |
| bash | `bash_20250124` | `bash` | — | tool-use-concepts.md |
| text editor | `text_editor_20250728` | `str_replace_based_edit_tool` | — | tool-use-concepts.md |
| memory | `memory_20250818` | `memory` | — (GA; cURL uses plain `messages.create`) | memory-tool.md |
| computer use | `computer_20250124` | `computer` | **`computer-use-2025-01-24`** | roadmap T3.15 |

**Only computer-use needs a beta header** — declared via S2's `add_beta/2` (the send path merges it). The roadmap's "memory = beta" / `web_search_20250305`-only notes were stale; corrected above.

### Optional fields (verified)
- **web search**: `max_uses`, `allowed_domains`, `blocked_domains`, `user_location`.
- **web fetch**: `max_uses`, `allowed_domains`, `blocked_domains`, `citations: {enabled}`, `max_content_tokens`.
- **text editor**: `max_characters`.
- **computer use**: required `display_width_px`, `display_height_px`; optional `display_number`.

bash / text_editor are **schema-less** Anthropic-defined tools — declare by `type` + `name` only, never add `input_schema`.

## Design

Add `add_*_tool` helpers directly on `Claudio.Messages.Request` — consistent with the existing `add_strict_tool/2` / `add_tool_with_eager_streaming/2`, and lets the **beta declaration happen automatically** (computer-use calls `add_beta/2` before `add_tool/2`). Each helper builds the string-keyed tool map (dropping `nil` opts via `maybe_put/3`) and appends through `add_tool/2` (which already handles a `nil` tools list). No new module — keeps the surface cohesive with S3.

Responses from these tools (`server_tool_use`, `web_search_tool_result`) are already typed by **S5**; `get_server_tool_uses/1` reads them.

## Tasks (TDD — failing test → implement → pass → commit each)

1. **web search** — `add_web_search_tool/2` (`:version`, `:max_uses`, `:allowed_domains`, `:blocked_domains`, `:user_location`). Default `web_search_20260209`. Tests: default shape; basic-version opt; opts threaded; appends to tools; no beta declared.
2. **web fetch** — `add_web_fetch_tool/2` (`:version`, `:max_uses`, `:allowed_domains`, `:blocked_domains`, `:citations`, `:max_content_tokens`). Tests: default shape; `citations: true`; opts; no beta.
3. **code execution + bash + text editor** — `add_code_execution_tool/1`, `add_bash_tool/1`, `add_text_editor_tool/2` (`:max_characters`). Tests: exact schema-less shapes; text-editor name `str_replace_based_edit_tool`; no betas.
4. **memory** — `add_memory_tool/1` → `{type: memory_20250818, name: memory}`, no beta. Test shape.
5. **computer use** — `add_computer_tool/4(request, width, height, opts)` → `{type: computer_20250124, name: computer, display_width_px, display_height_px}` + optional `display_number`; **declares `computer-use-2025-01-24`** via `add_beta`. Tests: shape + `required_betas/1` includes the flag.
6. **Integration (live)** — `add_web_search_tool` → ask a question that needs current info → assert `get_server_tool_uses/1` returns a `web_search` `server_tool_use` and the response contains a `web_search_tool_result` (ties S5 parsing + S6 builder end-to-end).

Then: `CLAUDE.md` docs, `mix format`, `mix test`, push, PR (base `s5-citations`; merge after S5).
