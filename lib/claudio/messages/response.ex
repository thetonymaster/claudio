defmodule Claudio.Messages.Response do
  @moduledoc """
  Structured response from the Messages API.

  `stop_details` is the raw API map (`"type"`, `"category"`, `"explanation"`), set only
  when `stop_reason` is `:refusal`. With `Request.set_fallbacks/2` it can also carry
  `"recommended_model"` (a model to retry directly when the fallback attempt was
  skipped), `"fallback_credit_token"` and `"fallback_has_prefill_claim"`. For streamed
  responses it is read from `message_delta.delta` next to `stop_reason`; that location
  is unconfirmed in Anthropic's streaming docs.

  `diagnostics` is carried raw (see `Request.enable_cache_diagnostics/2`):
  `nil` when diagnostics were not requested, there was nothing to compare, or the
  comparison found no divergence; `%{"cache_miss_reason" => nil}` when the comparison
  was still pending (inconclusive — check the next turn); otherwise a reason map such
  as `%{"cache_miss_reason" => %{"type" => "system_changed", "cache_missed_input_tokens" => n}}`.

  With `Request.set_fallbacks/2`, a refused request may be retried on another model.
  Each handoff is a `:fallback` content block (`fallbacks/1`); `served_by/1` names the
  model that produced the message, and `usage.iterations` records every attempt.

  Context management: `context_management` is the raw response map
  (`%{"applied_edits" => [...]}`, `nil` when the request configured no edits). A
  `:compaction` content block holds a compaction summary; `stop_reason` is `:compaction`
  when the reply is only that block (on-demand compaction, or `pause_after_compaction`).
  Continue with `Request.apply_compaction/2`.

  `input_transformations` (only with the `thinking-binding-controls-2026-08-01` beta, see
  `Request.set_thinking_block_binding/2`) is the raw list of what the API changed in the
  input: entries `%{"type" => "thinking_dropped" | "thinking_mismatch_allowed", "path" =>
  "messages.N.content.M", "reason" => "prefix_binding_mismatch" | "model_binding_mismatch"}`.
  `[]` when nothing changed; `nil` without the beta. Ignore unknown `type`/`reason` values.

  `usage` keeps every field the API returns: documented fields are atom keys (`nil`
  when absent); any other field keeps the key it arrived with (so it may be a string
  key). This applies when both `input_tokens` and `output_tokens` are present (either
  key style); a usage map missing one of them is returned as received.
  """

  @type stop_reason ::
          :end_turn
          | :max_tokens
          | :stop_sequence
          | :tool_use
          | :pause_turn
          | :refusal
          | :model_context_window_exceeded
          | :compaction

  @type content_block ::
          text_block()
          | thinking_block()
          | redacted_thinking_block()
          | tool_use_block()
          | tool_result_block()
          | mcp_tool_use_block()
          | mcp_tool_result_block()
          | server_tool_use_block()
          | web_search_tool_result_block()
          | fallback_block()
          | compaction_block()
          | server_tool_result_block()
          | container_upload_block()

  @type text_block :: %{
          :type => :text,
          :text => String.t(),
          optional(:citations) => list()
        }

  @type thinking_block :: %{
          type: :thinking,
          thinking: String.t(),
          signature: String.t() | nil
        }

  @type redacted_thinking_block :: %{
          type: :redacted_thinking,
          data: String.t()
        }

  @type tool_use_block :: %{
          type: :tool_use,
          id: String.t(),
          name: String.t(),
          input: map(),
          caller: map() | nil,
          toolset_name: String.t() | nil
        }

  @type tool_result_block :: %{
          type: :tool_result,
          tool_use_id: String.t(),
          content: String.t() | list()
        }

  @type mcp_tool_use_block :: %{
          type: :mcp_tool_use,
          id: String.t(),
          name: String.t(),
          server_name: String.t(),
          input: map()
        }

  @type mcp_tool_result_block :: %{
          type: :mcp_tool_result,
          tool_use_id: String.t(),
          server_name: String.t(),
          content: term(),
          is_error: boolean()
        }

  @type server_tool_use_block :: %{
          type: :server_tool_use,
          id: String.t(),
          name: String.t(),
          input: map(),
          caller: map() | nil
        }

  @type web_search_tool_result_block :: %{
          type: :web_search_tool_result,
          tool_use_id: String.t(),
          content: term(),
          caller: map() | nil,
          raw: map()
        }

  @typedoc """
  A server-tool result other than web search (`web_fetch_tool_result`,
  `code_execution_tool_result`, `bash_code_execution_tool_result`,
  `text_editor_code_execution_tool_result`, `tool_search_tool_result`,
  `advisor_tool_result`). `content` is the raw nested value (its variants and error codes
  change over time); `raw` is the block as received and is what
  `to_assistant_content/1` replays.
  """
  @type server_tool_result_block :: %{
          type: atom(),
          tool_use_id: String.t(),
          content: term(),
          caller: map() | nil,
          raw: map()
        }

  @type container_upload_block :: %{type: :container_upload, file_id: String.t(), raw: map()}

  @typedoc """
  A server-side fallback handoff (`Request.set_fallbacks/2`). `raw` is the block as
  received; `Response.to_assistant_content/1` re-emits it unchanged.
  """
  @type fallback_block :: %{
          type: :fallback,
          from: map() | nil,
          to: map() | nil,
          trigger: map() | nil,
          raw: map()
        }

  @typedoc """
  A compaction summary (`Request.add_compaction/2` threshold compaction, or
  `Request.request_compaction/2` on demand). `content` is the summary text (`nil` when
  compaction failed). `raw` is the block as received — including `signature` for on-demand
  blocks — and is what `to_assistant_content/1` replays.
  """
  @type compaction_block :: %{
          type: :compaction,
          content: String.t() | nil,
          raw: map()
        }

  @typedoc """
  Token usage. Documented fields are atom keys (`nil` when the API did not send
  them); any other field the API returns is kept under the key it arrived with.
  A usage map missing `input_tokens` or `output_tokens` is returned as received.
  `iterations` (present when `fallbacks` was set) lists each attempt as the raw
  API map: `"type" => "message"` for a model that declined, `"fallback_message"`
  for the one that served; the top-level counts cover only the returned attempt.
  With compaction, iterations also holds `"type" => "compaction"` entries; the top-level
  counts exclude them (the billed total is the sum over iterations).
  """
  @type usage :: %{
          optional(atom() | String.t()) => term(),
          input_tokens: integer(),
          output_tokens: integer(),
          cache_creation_input_tokens: integer() | nil,
          cache_read_input_tokens: integer() | nil,
          output_tokens_details: map() | nil,
          cache_creation: map() | nil,
          service_tier: String.t() | nil,
          inference_geo: String.t() | nil,
          speed: String.t() | nil,
          iterations: [map()] | nil
        }

  @type t :: %__MODULE__{
          id: String.t(),
          type: String.t(),
          role: String.t(),
          model: String.t(),
          content: list(content_block()),
          stop_reason: stop_reason() | nil,
          stop_sequence: String.t() | nil,
          stop_details: map() | nil,
          diagnostics: map() | nil,
          context_management: map() | nil,
          container: map() | nil,
          input_transformations: [map()] | nil,
          usage: usage()
        }

  defstruct [
    :id,
    :type,
    :role,
    :model,
    :content,
    :stop_reason,
    :stop_sequence,
    :stop_details,
    :diagnostics,
    :context_management,
    :container,
    :input_transformations,
    :usage
  ]

  @doc """
  Converts a raw API response map into a structured Response.
  """
  @spec from_map(map()) :: t()
  def from_map(data) when is_map(data) do
    %__MODULE__{
      id: data[:id] || data["id"],
      type: data[:type] || data["type"],
      role: data[:role] || data["role"],
      model: data[:model] || data["model"],
      content: parse_content(data[:content] || data["content"] || []),
      stop_reason: parse_stop_reason(data[:stop_reason] || data["stop_reason"]),
      stop_sequence: data[:stop_sequence] || data["stop_sequence"],
      stop_details: data[:stop_details] || data["stop_details"],
      diagnostics: data[:diagnostics] || data["diagnostics"],
      context_management: data[:context_management] || data["context_management"],
      container: data[:container] || data["container"],
      input_transformations: data[:input_transformations] || data["input_transformations"],
      usage: parse_usage(data[:usage] || data["usage"])
    }
  end

  @doc """
  Extracts all text content from the response.
  """
  @spec get_text(t()) :: String.t()
  def get_text(%__MODULE__{content: content}) do
    content
    |> Enum.filter(&(&1[:type] == :text))
    |> Enum.map(& &1.text)
    |> Enum.join("")
  end

  # Exact text of an interrupted `display: "updates"` thinking block
  # (platform.claude.com/docs/en/build-with-claude/thinking, fetched 2026-09-25).
  @interrupted_thinking "This part of the response was interrupted before it finished."

  @doc """
  Returns the non-empty `thinking` texts, in content order.

  A list, not a joined string: with `display: :updates` each `thinking` block is a
  separate progress note. Empty texts (`display: :omitted`) and `redacted_thinking`
  blocks are skipped. An interrupted update's placeholder text is kept — filter it
  with `thinking_interrupted?/1`.
  """
  @spec get_thinking(t()) :: [String.t()]
  def get_thinking(%__MODULE__{content: content}) do
    for %{type: :thinking, thinking: text} <- content, is_binary(text), text != "", do: text
  end

  @doc """
  True when `block` is a `thinking` block holding the API's placeholder for an
  update that was cut off: `"#{@interrupted_thinking}"`.
  """
  @spec thinking_interrupted?(content_block()) :: boolean()
  def thinking_interrupted?(%{type: :thinking, thinking: @interrupted_thinking}), do: true
  def thinking_interrupted?(_block), do: false

  @doc """
  Extracts the tool use requests to execute. After a server-side fallback, `tool_use`
  blocks before the last `fallback` block came from the model that declined; they are
  skipped here, as `to_assistant_content/1` drops them from the replay.
  """
  @spec get_tool_uses(t()) :: list(tool_use_block())
  def get_tool_uses(%__MODULE__{content: content}) do
    content
    |> since_last_fallback()
    |> Enum.filter(&(&1[:type] == :tool_use))
  end

  @doc """
  Aggregates every citation across all `text` blocks, in document order.

  Each entry is the raw citation map as returned by the API (e.g.
  `char_location`, `page_location`, `content_block_location`,
  `search_result_location`, `web_search_result_location`). Returns `[]` when no
  citations are present.
  """
  @spec get_citations(t()) :: list()
  def get_citations(%__MODULE__{content: content}) do
    content
    |> Enum.filter(&(&1[:type] == :text))
    |> Enum.flat_map(&Map.get(&1, :citations, []))
  end

  # Server-tool result blocks typed shallowly (S14): content stays raw, raw is replayed.
  @server_result_types %{
    "web_fetch_tool_result" => :web_fetch_tool_result,
    "code_execution_tool_result" => :code_execution_tool_result,
    "bash_code_execution_tool_result" => :bash_code_execution_tool_result,
    "text_editor_code_execution_tool_result" => :text_editor_code_execution_tool_result,
    "tool_search_tool_result" => :tool_search_tool_result,
    "advisor_tool_result" => :advisor_tool_result
  }
  @server_result_atoms Map.values(@server_result_types)

  @doc """
  Extracts all server-side tool use requests (`server_tool_use`) from the
  response — e.g. `web_search` / `web_fetch` invocations Claude ran on the
  server. The matching results are `web_search_tool_result` blocks.
  """
  @spec get_server_tool_uses(t()) :: list(server_tool_use_block())
  def get_server_tool_uses(%__MODULE__{content: content}) do
    Enum.filter(content, &(&1[:type] == :server_tool_use))
  end

  @doc """
  Returns server-tool result blocks in content order: `web_search_tool_result`,
  `web_fetch_tool_result`, `code_execution_tool_result`, `bash_code_execution_tool_result`,
  `text_editor_code_execution_tool_result`, `tool_search_tool_result`, `advisor_tool_result`
  and `container_upload`. `content` is the raw nested value.
  """
  @spec get_server_tool_results(t()) :: [map()]
  def get_server_tool_results(%__MODULE__{content: content}) do
    types = [:web_search_tool_result, :container_upload | @server_result_atoms]
    Enum.filter(content, &(is_map(&1) and &1[:type] in types))
  end

  @doc "Returns the server-tool result blocks of one type (e.g. `:code_execution_tool_result`)."
  @spec get_server_tool_results(t(), atom()) :: [map()]
  def get_server_tool_results(%__MODULE__{content: content}, type) when is_atom(type) do
    Enum.filter(content, &(is_map(&1) and &1[:type] == type))
  end

  @doc """
  Extracts all MCP tool use requests from the response.
  """
  @spec get_mcp_tool_uses(t()) :: list(mcp_tool_use_block())
  def get_mcp_tool_uses(%__MODULE__{content: content}) do
    Enum.filter(content, &(&1[:type] == :mcp_tool_use))
  end

  @doc """
  Extracts MCP tool use requests from the response for a specific server.
  """
  @spec get_mcp_tool_uses(t(), String.t()) :: list(mcp_tool_use_block())
  def get_mcp_tool_uses(%__MODULE__{content: content}, server_name) when is_binary(server_name) do
    Enum.filter(content, &(&1[:type] == :mcp_tool_use && &1[:server_name] == server_name))
  end

  @doc """
  Returns every `fallback` block, in content order (`[]` when the request was not
  retried on a fallback model). One block marks each handoff between models.
  """
  @spec fallbacks(t()) :: [fallback_block()]
  def fallbacks(%__MODULE__{content: content}) do
    for %{type: :fallback} = block <- content, do: block
  end

  @doc """
  Returns the model that produced the returned message: the last `fallback` block's
  `to.model`, else `model`.

  Not simply `model`: a streamed response that fell back mid-output keeps the
  requested (declining) model from `message_start` in `model`. When every model in
  the chain declined (`stop_reason: :refusal`), it names the model whose refusal was
  returned.
  """
  @spec served_by(t()) :: String.t() | nil
  def served_by(%__MODULE__{model: model} = response) do
    case List.last(fallbacks(response)) do
      %{to: to} when is_map(to) -> Map.get(to, "model") || Map.get(to, :model) || model
      _ -> model
    end
  end

  @doc """
  Returns the last `compaction` block, or `nil`. See `Request.apply_compaction/2` to
  continue from it.
  """
  @spec compaction_block(t()) :: compaction_block() | nil
  def compaction_block(%__MODULE__{content: content}) do
    content |> Enum.filter(&match?(%{type: :compaction}, &1)) |> List.last()
  end

  # Blocks from the last `fallback` block on — every block when there is none. Earlier
  # blocks belong to a model that declined (see to_assistant_content/1). Reads parsed
  # and raw (string- or atom-keyed) content alike; shared with Claudio.Tools.
  @doc false
  @spec since_last_fallback(list()) :: list()
  def since_last_fallback(blocks) when is_list(blocks) do
    case last_fallback_index(blocks) do
      nil -> blocks
      index -> Enum.drop(blocks, index)
    end
  end

  @doc """
  Converts the response content into API-shaped assistant content blocks for
  replaying as the assistant turn in a follow-up request:

      request
      |> Request.add_message(:assistant, Response.to_assistant_content(response))

  Emits string-keyed blocks that preserve `signature` (thinking) and `data`
  (redacted_thinking) — both required by the API when continuing an
  extended-thinking + tool-use conversation. Unknown block types are passed
  through unchanged (coverage grows in later specs).

  After a server-side fallback (`Request.set_fallbacks/2`) it applies the API's
  continuation rules: before the last `fallback` block it drops `thinking`,
  `redacted_thinking`, `connector_text` and `tool_use` blocks, and keeps a
  `server_tool_use` or `mcp_tool_use` only when its result block is present.
  `fallback` blocks stay where they are. In practice this only changes a streamed
  response that fell back mid-output; a non-streaming response normally puts the
  `fallback` block first. `response.content` still holds every block.

  If you edit earlier messages before replaying, a `thinking` block's signature may no longer
  match; see `Request.set_thinking_block_binding/2`.
  """
  @spec to_assistant_content(t()) :: [map()]
  def to_assistant_content(%__MODULE__{content: content}) do
    content
    |> Enum.map(&block_to_api/1)
    |> apply_fallback_continuation_rules()
  end

  defp parse_content(content) when is_list(content) do
    Enum.map(content, &parse_content_block/1)
  end

  defp parse_content_block(%{type: "text"} = block) do
    text_block(block[:text], block[:citations])
  end

  defp parse_content_block(%{"type" => "text"} = block) do
    text_block(block["text"], block["citations"])
  end

  defp parse_content_block(%{type: "thinking"} = block) do
    %{type: :thinking, thinking: block[:thinking], signature: block[:signature]}
  end

  defp parse_content_block(%{"type" => "thinking"} = block) do
    %{type: :thinking, thinking: block["thinking"], signature: block["signature"]}
  end

  defp parse_content_block(%{type: "redacted_thinking"} = block) do
    %{type: :redacted_thinking, data: block[:data]}
  end

  defp parse_content_block(%{"type" => "redacted_thinking"} = block) do
    %{type: :redacted_thinking, data: block["data"]}
  end

  defp parse_content_block(%{type: "tool_use"} = block) do
    %{
      type: :tool_use,
      id: block[:id],
      name: block[:name],
      input: block[:input],
      caller: block[:caller],
      toolset_name: block[:toolset_name]
    }
  end

  defp parse_content_block(%{"type" => "tool_use"} = block) do
    %{
      type: :tool_use,
      id: block["id"],
      name: block["name"],
      input: block["input"],
      caller: block["caller"],
      toolset_name: block["toolset_name"]
    }
  end

  defp parse_content_block(%{type: "tool_result"} = block) do
    %{
      type: :tool_result,
      tool_use_id: block[:tool_use_id],
      content: block[:content]
    }
  end

  defp parse_content_block(%{"type" => "tool_result"} = block) do
    %{
      type: :tool_result,
      tool_use_id: block["tool_use_id"],
      content: block["content"]
    }
  end

  defp parse_content_block(%{type: "mcp_tool_use"} = block) do
    %{
      type: :mcp_tool_use,
      id: block[:id],
      name: block[:name],
      server_name: block[:server_name],
      input: block[:input]
    }
  end

  defp parse_content_block(%{"type" => "mcp_tool_use"} = block) do
    %{
      type: :mcp_tool_use,
      id: block["id"],
      name: block["name"],
      server_name: block["server_name"],
      input: block["input"]
    }
  end

  defp parse_content_block(%{type: "mcp_tool_result"} = block) do
    %{
      type: :mcp_tool_result,
      tool_use_id: block[:tool_use_id],
      server_name: block[:server_name],
      content: block[:content],
      is_error: Map.get(block, :is_error, false)
    }
  end

  defp parse_content_block(%{"type" => "mcp_tool_result"} = block) do
    %{
      type: :mcp_tool_result,
      tool_use_id: block["tool_use_id"],
      server_name: block["server_name"],
      content: block["content"],
      is_error: Map.get(block, "is_error", false)
    }
  end

  defp parse_content_block(%{type: "server_tool_use"} = block) do
    %{
      type: :server_tool_use,
      id: block[:id],
      name: block[:name],
      input: block[:input],
      caller: block[:caller]
    }
  end

  defp parse_content_block(%{"type" => "server_tool_use"} = block) do
    %{
      type: :server_tool_use,
      id: block["id"],
      name: block["name"],
      input: block["input"],
      caller: block["caller"]
    }
  end

  defp parse_content_block(%{type: "web_search_tool_result"} = block) do
    %{
      type: :web_search_tool_result,
      tool_use_id: block[:tool_use_id],
      content: block[:content],
      caller: block[:caller],
      raw: block
    }
  end

  defp parse_content_block(%{"type" => "web_search_tool_result"} = block) do
    %{
      type: :web_search_tool_result,
      tool_use_id: block["tool_use_id"],
      content: block["content"],
      caller: block["caller"],
      raw: block
    }
  end

  defp parse_content_block(%{type: "fallback"} = block) do
    fallback_block(block, block[:from], block[:to], block[:trigger])
  end

  defp parse_content_block(%{"type" => "fallback"} = block) do
    fallback_block(block, block["from"], block["to"], block["trigger"])
  end

  defp parse_content_block(%{type: "compaction"} = block),
    do: %{type: :compaction, content: block[:content], raw: block}

  defp parse_content_block(%{"type" => "compaction"} = block),
    do: %{type: :compaction, content: block["content"], raw: block}

  defp parse_content_block(%{"type" => type} = block)
       when is_map_key(@server_result_types, type) do
    %{
      type: Map.fetch!(@server_result_types, type),
      tool_use_id: block["tool_use_id"],
      content: block["content"],
      caller: block["caller"],
      raw: block
    }
  end

  defp parse_content_block(%{type: type} = block) when is_map_key(@server_result_types, type) do
    %{
      type: Map.fetch!(@server_result_types, type),
      tool_use_id: block[:tool_use_id],
      content: block[:content],
      caller: block[:caller],
      raw: block
    }
  end

  defp parse_content_block(%{"type" => "container_upload"} = block),
    do: %{type: :container_upload, file_id: block["file_id"], raw: block}

  defp parse_content_block(%{type: "container_upload"} = block),
    do: %{type: :container_upload, file_id: block[:file_id], raw: block}

  defp parse_content_block(block), do: block

  defp text_block(text, nil), do: %{type: :text, text: text}
  defp text_block(text, citations), do: %{type: :text, text: text, citations: citations}

  defp fallback_block(raw, from, to, trigger) do
    %{type: :fallback, from: from, to: to, trigger: trigger, raw: raw}
  end

  defp block_to_api(%{type: :text, text: text}) do
    %{"type" => "text", "text" => text}
  end

  defp block_to_api(%{type: :thinking, thinking: thinking} = block) do
    base = %{"type" => "thinking", "thinking" => thinking}

    case block[:signature] do
      nil -> base
      signature -> Map.put(base, "signature", signature)
    end
  end

  defp block_to_api(%{type: :redacted_thinking, data: data}) do
    %{"type" => "redacted_thinking", "data" => data}
  end

  defp block_to_api(%{type: :tool_use, id: id, name: name, input: input} = block) do
    %{"type" => "tool_use", "id" => id, "name" => name, "input" => input}
    |> put_present("caller", block[:caller])
    |> put_present("toolset_name", block[:toolset_name])
  end

  defp block_to_api(%{type: :mcp_tool_use} = block) do
    %{
      "type" => "mcp_tool_use",
      "id" => block.id,
      "name" => block.name,
      "server_name" => block.server_name,
      "input" => block.input
    }
  end

  defp block_to_api(%{type: :mcp_tool_result} = block) do
    %{
      "type" => "mcp_tool_result",
      "tool_use_id" => block.tool_use_id,
      "server_name" => block.server_name,
      "content" => block.content,
      "is_error" => block.is_error
    }
  end

  defp block_to_api(%{type: :server_tool_use} = block) do
    %{
      "type" => "server_tool_use",
      "id" => block.id,
      "name" => block.name,
      "input" => block.input
    }
    |> put_present("caller", block[:caller])
  end

  defp block_to_api(%{type: :web_search_tool_result, raw: raw}) when is_map(raw), do: raw

  defp block_to_api(%{type: :web_search_tool_result} = block) do
    %{
      "type" => "web_search_tool_result",
      "tool_use_id" => block.tool_use_id,
      "content" => block.content
    }
  end

  defp block_to_api(%{type: :fallback, raw: raw}), do: raw

  defp block_to_api(%{type: :compaction, raw: raw}), do: raw
  defp block_to_api(%{type: :container_upload, raw: raw}) when is_map(raw), do: raw

  defp block_to_api(%{type: :container_upload} = block),
    do: %{"type" => "container_upload", "file_id" => block[:file_id]}

  defp block_to_api(%{type: type, raw: raw}) when type in @server_result_atoms and is_map(raw),
    do: raw

  # Hand-built typed result without its original map: rebuild the API shape.
  defp block_to_api(%{type: type} = block) when type in @server_result_atoms do
    %{
      "type" => Atom.to_string(type),
      "tool_use_id" => block[:tool_use_id],
      "content" => block[:content]
    }
    |> put_present("caller", block[:caller])
  end

  defp block_to_api(block), do: block

  # Continuation rules after a server-side fallback (platform.claude.com/docs/en/
  # build-with-claude/refusals-and-fallback, "Continuing the conversation", fetched
  # 2026-09-25). mcp_tool_use is not in that table; it follows the server_tool_use
  # pairing rule because an unpaired one is rejected (probed 2026-09-25).
  @dropped_before_fallback ~w(thinking redacted_thinking connector_text tool_use)
  @paired_before_fallback ~w(server_tool_use mcp_tool_use)

  defp apply_fallback_continuation_rules(blocks) do
    case last_fallback_index(blocks) do
      index when is_integer(index) and index > 0 ->
        {before, rest} = Enum.split(blocks, index)

        result_ids =
          for block <- blocks, id = field(block, "tool_use_id"), into: MapSet.new(), do: id

        Enum.filter(before, &keep_before_fallback?(&1, result_ids)) ++ rest

      _none_or_first ->
        blocks
    end
  end

  defp last_fallback_index(blocks) do
    blocks
    |> Enum.with_index()
    |> Enum.reduce(nil, fn {block, index}, last ->
      if block_type(block) == "fallback", do: index, else: last
    end)
  end

  defp keep_before_fallback?(block, result_ids) do
    type = block_type(block)

    cond do
      type in @dropped_before_fallback -> false
      type in @paired_before_fallback -> MapSet.member?(result_ids, field(block, "id"))
      true -> true
    end
  end

  # Replayed blocks are string-keyed, but unknown blocks pass through with whatever
  # keys they arrived with, and a typed block Claudio does not re-emit (e.g.
  # :tool_result) keeps an atom type.
  defp block_type(block) do
    case field(block, "type") do
      type when is_atom(type) and not is_nil(type) -> Atom.to_string(type)
      type -> type
    end
  end

  defp field(block, key) when is_map(block) do
    case Map.fetch(block, key) do
      {:ok, value} -> value
      :error -> Map.get(block, String.to_existing_atom(key))
    end
  end

  defp field(_not_a_map, _key), do: nil

  defp put_present(map, _key, nil), do: map
  defp put_present(map, key, value), do: Map.put(map, key, value)

  defp parse_stop_reason("end_turn"), do: :end_turn
  defp parse_stop_reason("max_tokens"), do: :max_tokens
  defp parse_stop_reason("stop_sequence"), do: :stop_sequence
  defp parse_stop_reason("tool_use"), do: :tool_use
  defp parse_stop_reason("pause_turn"), do: :pause_turn
  defp parse_stop_reason("refusal"), do: :refusal
  defp parse_stop_reason("model_context_window_exceeded"), do: :model_context_window_exceeded
  defp parse_stop_reason("compaction"), do: :compaction
  defp parse_stop_reason(nil), do: nil
  defp parse_stop_reason(other), do: other

  # Documented usage fields become atom keys; every other field keeps the key it
  # arrived with, so fields Claudio does not know about yet are not dropped.
  @usage_keys [
    :input_tokens,
    :output_tokens,
    :cache_creation_input_tokens,
    :cache_read_input_tokens,
    :output_tokens_details,
    :cache_creation,
    :service_tier,
    :inference_geo,
    :speed,
    :iterations
  ]
  @usage_string_keys Enum.map(@usage_keys, &Atom.to_string/1)

  # Both token counts must be present, each under either key style.
  defp parse_usage(usage)
       when is_map(usage) and
              (is_map_key(usage, :input_tokens) or is_map_key(usage, "input_tokens")) and
              (is_map_key(usage, :output_tokens) or is_map_key(usage, "output_tokens")),
       do: normalize_usage(usage)

  defp parse_usage(nil) do
    @usage_keys
    |> Map.new(&{&1, nil})
    |> Map.merge(%{input_tokens: 0, output_tokens: 0})
  end

  defp parse_usage(other), do: other

  defp normalize_usage(usage) do
    known = Map.new(@usage_keys, &{&1, usage_value(usage, &1)})

    usage
    |> Map.drop(@usage_keys ++ @usage_string_keys)
    |> Map.merge(known)
  end

  # Atom key wins when a field is present under both key styles.
  defp usage_value(usage, key) do
    case Map.fetch(usage, key) do
      {:ok, value} -> value
      :error -> Map.get(usage, Atom.to_string(key))
    end
  end
end
