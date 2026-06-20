# S5 — Citations + content-block parsing

- **Date:** 2026-06-19
- **Bead:** `claudio-0vx` (epic `claudio-8rv`)
- **Branch:** `s5-citations` (off `origin/main` @ b8aa090; S1–S4 merged)
- **Roadmap row:** S5 — "Citations + content-block parsing (search_result, server-tool results)". Depends on S1 ✓.
- **Touches:** `lib/claudio/messages/request.ex`, `lib/claudio/messages/response.ex`, `lib/claudio/messages/stream.ex` (verify only), `CLAUDE.md`.

## Verified API shapes (pinned against live docs 2026-06-19)

Sources: `platform.claude.com/docs/en/build-with-claude/citations.md` and `…/search-results.md`.

### Document block (request) — `citations.md`
```json
{
  "type": "document",
  "source": { "type": "file", "file_id": "file_…" },
  "title": "My Document",                 // optional
  "context": "Trustworthy doc metadata",  // optional, NOT cited from
  "citations": { "enabled": true }        // optional
}
```
Citations must be enabled on **all or none** of the documents in a request.
`cache_control` is valid on the document block (cache the source; citation blocks themselves are not cacheable).

### search_result content block (request / tool-result) — `search-results.md`
```json
{
  "type": "search_result",
  "source": "https://example.com/article",        // REQUIRED
  "title": "Article Title",                         // REQUIRED
  "content": [ { "type": "text", "text": "…" } ],  // REQUIRED (array of text blocks)
  "citations": { "enabled": true }                  // optional
}
```
Also accepts `cache_control`. Used as top-level user content or inside a tool_result.

### Response: text-block citations — `citations.md`
A response `text` block gains a `citations` array. Location variants (preserved verbatim):
- `char_location`  — `cited_text, document_index, document_title, start_char_index, end_char_index`
- `page_location`  — `… start_page_number, end_page_number`
- `content_block_location` — `… start_block_index, end_block_index`
- `search_result_location` — `type, source, title, cited_text, search_result_index, start_block_index, end_block_index`
- `web_search_result_location` — web-search variant

### Response: server-tool blocks (typed, content preserved)
- `server_tool_use` → `{ "type", "id", "name", "input" }`
- `web_search_tool_result` → `{ "type", "tool_use_id", "content": [ … | error ] }`

### Streaming
`citations_delta` (`delta.citation` appended to the block's `citations` list) is **already handled** by `stream.ex` (S1, lines ~384–392). Task 5 locks it with a characterization test; no code change expected.

### ⚠️ Incompatibility (doc note)
Citations + Structured Outputs (`output_config.format`) → **400**. Note in CLAUDE.md / docstrings.

## Design decisions

- **`add_message_with_document/5`** — add `opts \\ []` (`:citations` bool, `:title`, `:context`). Backward compatible: existing `/4` callers unaffected, default opts emit the current block byte-for-byte.
- **`search_result_block/4`** — `search_result_block(source, title, contents, opts \\ [])` returns a string-keyed content-block map. `contents`: list of strings (wrapped as text blocks) or list of pre-built text maps. `opts`: `:citations` (bool → `{"enabled"=>true}`), `:cache_control` (reuses private `cache_control_map/1`). Compose via `add_message/3`. Chosen over a bespoke `add_message_with_search_results` for composability (matches how `add_message` already accepts raw content lists).
- **Response citations** — preserve the `citations` array on `:text` blocks for **reading** only. `block_to_api/1` (replay) keeps emitting plain `{type,text}` — citations are response metadata, not required on replay; not replaying them avoids 400 risk. Add `get_citations/1` to aggregate across text blocks.
- **server-tool typing** — parse `server_tool_use` + `web_search_tool_result` into typed maps (content preserved verbatim), add `block_to_api/1` round-trip clauses + typespec entries, add `get_server_tool_uses/1`. The request-side web_search/web_fetch tool helpers are **S6**, not here.
- **search_result is request-only** — not parsed from responses (never appears there); its citations surface as `search_result_location` entries in text-block `citations`, already covered by the generic preservation.

## Tasks (TDD — one failing test → implement → pass → commit each)

1. **Request: document citations** — `add_message_with_document/5` opts `:citations`/`:title`/`:context`. Tests: opts emit `citations`/`title`/`context`; no opts ⇒ unchanged block.
2. **Request: search_result builder** — `search_result_block/4`. Tests: required fields; string vs map contents; `:citations`; `:cache_control` (5m default + 1h).
3. **Response: text-block citations + `get_citations/1`** — preserve `citations`; aggregate. Tests: char_location preserved; absent ⇒ nil; `get_citations/1` across blocks; `get_text/1` still works.
4. **Response: server-tool typing + round-trip + `get_server_tool_uses/1`** — parse `server_tool_use` + `web_search_tool_result` (string & atom keys), `to_assistant_content/1` round-trip, helper. Tests for each.
5. **Stream: citations_delta characterization** — feed content_block_delta citations_delta, assert accumulation onto `citations`. Locks existing behavior.
6. **Integration (live, `--include integration`)** — search_result citations end-to-end: two `search_result_block`s + a question → assert a response text block carries a `search_result_location` citation. (server-tool live test deferred to S6, which adds the web_search request helper.)

Then: `CLAUDE.md` docs, `mix format --check-formatted`, `mix test`, push, PR (base `s5-citations` → merge after S4; do not auto-merge).
