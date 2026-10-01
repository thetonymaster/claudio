defmodule Claudio.Messages.Request do
  @moduledoc """
  Builder for constructing Messages API requests.

  ## Example

      alias Claudio.Messages.Request

      Request.new("claude-opus-5-5")
      |> Request.add_message(:user, "Hello!")
      |> Request.set_system("You are a helpful assistant")
      |> Request.set_max_tokens(1024)
      |> Request.to_map()
  """

  alias Claudio.MCP.ServerConfig
  alias Claudio.Messages.Response

  @type role :: :user | :assistant
  @type content :: String.t() | list(map())

  @type tool_choice :: :auto | :any | {:tool, String.t()} | :none

  @type t :: %__MODULE__{
          model: String.t(),
          messages: list(map()),
          max_tokens: integer() | nil,
          system: String.t() | list() | nil,
          temperature: float() | nil,
          top_p: float() | nil,
          top_k: integer() | nil,
          stop_sequences: list(String.t()) | nil,
          stream: boolean() | nil,
          tools: list(map()) | nil,
          tool_choice: map() | nil,
          metadata: map() | nil,
          thinking: map() | nil,
          mcp_servers: list(map()) | nil,
          context_management: map() | nil,
          container: String.t() | map() | nil,
          service_tier: String.t() | nil,
          betas: [String.t()],
          output_config: map() | nil,
          cache_control: map() | nil,
          speed: String.t() | nil,
          inference_geo: String.t() | nil,
          diagnostics: map() | nil,
          fallbacks: String.t() | [map()] | nil,
          compaction: map() | nil
        }

  defstruct [
    :model,
    :messages,
    :max_tokens,
    :system,
    :temperature,
    :top_p,
    :top_k,
    :stop_sequences,
    :stream,
    :tools,
    :tool_choice,
    :metadata,
    :thinking,
    :mcp_servers,
    :context_management,
    :container,
    :service_tier,
    betas: [],
    output_config: nil,
    cache_control: nil,
    speed: nil,
    inference_geo: nil,
    diagnostics: nil,
    fallbacks: nil,
    compaction: nil
  ]

  # Server-side refusal fallbacks; also needed to replay a `fallback` block (probed 2026-09-25).
  @fallback_beta "server-side-fallback-2026-07-01"

  # Context editing (clear_* edits) and threshold compaction (compact_20260112; also needed
  # to replay an unsigned compaction block). Probed 2026-09-26.
  @context_management_beta "context-management-2025-06-27"
  @compaction_beta "compact-2026-01-12"

  # On-demand compaction (top-level `compaction`); also needed on every later request that
  # replays a signed compaction block (probed 2026-09-26).
  @on_demand_compaction_beta "compact-2026-09-04"

  # Advisor tool; also needed to replay advisor blocks (probed 2026-09-26).
  @advisor_beta "advisor-tool-2026-03-01"

  @doc """
  Creates a new request builder with the specified model.

  ## Example

      Request.new("claude-opus-5-5")
  """
  @spec new(String.t()) :: t()
  def new(model) when is_binary(model) do
    %__MODULE__{
      model: model,
      messages: []
    }
  end

  @doc """
  Adds a message to the conversation.

  Content can be:
  - A string for simple text messages
  - A list of content blocks for multimodal messages (text, images, documents)

  A list `content` holding a `fallback` block (from `Response.to_assistant_content/1`)
  declares `server-side-fallback-2026-07-01`, which the API requires to accept it.

  A `compaction` block declares its replay beta: `compact-2026-09-04` when it carries a
  `signature` (on-demand), else `compact-2026-01-12` (threshold — which also needs the
  `compact_20260112` edit on the request; see `add_compaction/2`).

  Advisor blocks (`advisor_tool_result`, or a `server_tool_use` named `"advisor"`) declare
  `advisor-tool-2026-03-01`.

  ## Examples

      # Simple text message
      Request.new("claude-opus-5-5")
      |> Request.add_message(:user, "What is the weather?")

      # Multimodal message with image
      Request.new("claude-opus-5-5")
      |> Request.add_message(:user, [
        %{"type" => "image", "source" => %{
          "type" => "base64",
          "media_type" => "image/jpeg",
          "data" => base64_image
        }},
        %{"type" => "text", "text" => "What's in this image?"}
      ])
  """
  @spec add_message(t(), role(), content()) :: t()
  def add_message(%__MODULE__{messages: messages} = request, role, content)
      when role in [:user, :assistant] do
    message = %{
      "role" => to_string(role),
      "content" => normalize_content(content)
    }

    request = %{request | messages: messages ++ [message]}

    # Replaying a `fallback` block (Response.to_assistant_content/1) needs the beta even
    # on a turn that does not set fallbacks (400 without it, probed 2026-09-25).
    request =
      if has_fallback_block?(content), do: add_beta(request, @fallback_beta), else: request

    # A replayed compaction block needs its beta: signed (on-demand) blocks need
    # compact-2026-09-04, unsigned (threshold) blocks compact-2026-01-12 (probed 2026-09-26).
    request = add_compaction_replay_betas(request, content)

    # Replaying advisor blocks needs the advisor beta even without the tool (probed 2026-09-26).
    if has_advisor_block?(content), do: add_beta(request, @advisor_beta), else: request
  end

  defp has_fallback_block?(content) when is_list(content) do
    Enum.any?(content, fn
      %{"type" => type} -> type in ["fallback", :fallback]
      %{type: type} -> type in ["fallback", :fallback]
      _ -> false
    end)
  end

  defp has_fallback_block?(_content), do: false

  defp add_compaction_replay_betas(request, content) when is_list(content) do
    Enum.reduce(content, request, fn block, acc ->
      cond do
        not compaction_block?(block) -> acc
        compaction_signature(block) -> add_beta(acc, @on_demand_compaction_beta)
        true -> add_beta(acc, @compaction_beta)
      end
    end)
  end

  defp add_compaction_replay_betas(request, _content), do: request

  defp compaction_block?(%{"type" => type}), do: type in ["compaction", :compaction]
  defp compaction_block?(%{type: type}), do: type in ["compaction", :compaction]
  defp compaction_block?(_block), do: false

  # A typed block (Response) keeps the original under :raw.
  defp compaction_signature(%{raw: raw}) when is_map(raw), do: compaction_signature(raw)
  defp compaction_signature(block), do: Map.get(block, "signature") || Map.get(block, :signature)

  defp has_advisor_block?(content) when is_list(content),
    do: Enum.any?(content, &advisor_block?/1)

  defp has_advisor_block?(_content), do: false

  defp advisor_block?(block) when is_map(block) do
    type = Map.get(block, "type") || Map.get(block, :type)
    name = Map.get(block, "name") || Map.get(block, :name)

    type in ["advisor_tool_result", :advisor_tool_result] or
      (type in ["server_tool_use", :server_tool_use] and name == "advisor")
  end

  defp advisor_block?(_block), do: false

  defp edit_type(%{"type" => type}), do: to_string(type)
  defp edit_type(%{type: type}), do: to_string(type)
  defp edit_type(_edit), do: nil

  defp has_compact_edit?(config) do
    case Map.get(config, "edits") || Map.get(config, :edits) do
      edits when is_list(edits) ->
        Enum.any?(edits, fn
          %{"type" => type} -> type in ["compact_20260112", :compact_20260112]
          %{type: type} -> type in ["compact_20260112", :compact_20260112]
          _ -> false
        end)

      _ ->
        false
    end
  end

  @doc """
  Adds a text message with an image from a base64-encoded string.

  Without `media_type`, PNG, GIF, WebP and JPEG are detected from the data's leading
  bytes (a mismatched type is a 400); anything unrecognized is sent as `"image/jpeg"`.

  ## Example

      Request.new("claude-opus-5-5")
      |> Request.add_message_with_image(:user, "What's in this image?", base64_data, "image/jpeg")
  """
  @spec add_message_with_image(t(), role(), String.t(), String.t(), String.t() | nil) :: t()
  def add_message_with_image(
        %__MODULE__{} = request,
        role,
        text,
        base64_data,
        media_type \\ nil
      )
      when role in [:user, :assistant] do
    media_type = media_type || detect_image_type(base64_data)

    content = [
      %{
        "type" => "image",
        "source" => %{
          "type" => "base64",
          "media_type" => media_type,
          "data" => base64_data
        }
      },
      %{"type" => "text", "text" => text}
    ]

    add_message(request, role, content)
  end

  @doc """
  Adds a text message with an image from a URL.

  ## Example

      Request.new("claude-opus-5-5")
      |> Request.add_message_with_image_url(:user, "What's in this image?", "https://example.com/image.jpg")
  """
  @spec add_message_with_image_url(t(), role(), String.t(), String.t()) :: t()
  def add_message_with_image_url(%__MODULE__{} = request, role, text, image_url)
      when role in [:user, :assistant] do
    content = [
      %{
        "type" => "image",
        "source" => %{
          "type" => "url",
          "url" => image_url
        }
      },
      %{"type" => "text", "text" => text}
    ]

    add_message(request, role, content)
  end

  @doc """
  Adds a text message with a document from the Files API.

  ## Options

  - `:citations` - When `true`, enables citations on the document
    (`"citations" => %{"enabled" => true}`). The API requires citations to be
    enabled on all-or-none of the documents in a request. **Incompatible with
    structured outputs** (`set_output_config/2`) — the API returns 400.
  - `:title` - Optional document title (length-limited; not cited from).
  - `:context` - Optional document metadata passed to the model but not cited from.

  ## Examples

      Request.new("claude-opus-5-5")
      |> Request.add_message_with_document(:user, "Summarize this document", "file_abc123")

      Request.new("claude-opus-4-8")
      |> Request.add_message_with_document(:user, "Summarize", "file_abc123",
        citations: true,
        title: "Q4 Report"
      )
  """
  @spec add_message_with_document(t(), role(), String.t(), String.t(), keyword()) :: t()
  def add_message_with_document(%__MODULE__{} = request, role, text, file_id, opts \\ [])
      when role in [:user, :assistant] do
    document =
      %{
        "type" => "document",
        "source" => %{
          "type" => "file",
          "file_id" => file_id
        }
      }
      |> maybe_put_citations(Keyword.get(opts, :citations))
      |> maybe_put("title", Keyword.get(opts, :title))
      |> maybe_put("context", Keyword.get(opts, :context))

    content = [document, %{"type" => "text", "text" => text}]

    add_message(request, role, content)
  end

  @doc """
  Builds a `search_result` content block for RAG / grounded citations.

  `contents` may be a list of strings (each wrapped as a `text` block) or a list
  of pre-built text-block maps. Compose into a turn with `add_message/3`:

      result =
        Request.search_result_block("https://docs/api", "API Reference", ["…"],
          citations: true
        )

      request
      |> Request.add_message(:user, [
        result,
        %{"type" => "text", "text" => "How do I authenticate?"}
      ])

  ## Options

  - `:citations` - When `true`, enables citations on this result
    (surfaces as `search_result_location` citations on response text blocks).
  - `:cache_control` - `true` for default ephemeral caching, or a ttl string
    (`"5m"` / `"1h"`).
  """
  @spec search_result_block(String.t(), String.t(), [String.t() | map()], keyword()) :: map()
  def search_result_block(source, title, contents, opts \\ [])
      when is_binary(source) and is_binary(title) and is_list(contents) do
    %{
      "type" => "search_result",
      "source" => source,
      "title" => title,
      "content" => Enum.map(contents, &normalize_search_result_content/1)
    }
    |> maybe_put_citations(Keyword.get(opts, :citations))
    |> maybe_put("cache_control", search_result_cache(Keyword.get(opts, :cache_control)))
  end

  @doc """
  Sets the system prompt.

  Can be a string or a list of content blocks with optional cache_control.

  ## Examples

      # Simple string
      Request.new("claude-opus-5-5")
      |> Request.set_system("You are a helpful assistant")

      # With prompt caching
      Request.new("claude-opus-5-5")
      |> Request.set_system([
        %{
          "type" => "text",
          "text" => "Long system prompt here...",
          "cache_control" => %{"type" => "ephemeral"}
        }
      ])
  """
  @spec set_system(t(), String.t() | list()) :: t()
  def set_system(%__MODULE__{} = request, system) do
    %{request | system: system}
  end

  @doc """
  Sets the system prompt with prompt caching enabled.

  ## Options

  - `:ttl` - Cache duration, either `"5m"` (default) or `"1h"`

  ## Example

      Request.new("claude-opus-5-5")
      |> Request.set_system_with_cache("Long system prompt...", ttl: "1h")
  """
  @spec set_system_with_cache(t(), String.t(), keyword()) :: t()
  def set_system_with_cache(%__MODULE__{} = request, text, opts \\ []) do
    system = [
      %{
        "type" => "text",
        "text" => text,
        "cache_control" => cache_control_map(Keyword.get(opts, :ttl))
      }
    ]

    %{request | system: system}
  end

  @doc """
  Sets the maximum number of tokens to generate.

  ## Example

      Request.new("claude-opus-5-5")
      |> Request.set_max_tokens(1024)
  """
  @spec set_max_tokens(t(), integer()) :: t()
  def set_max_tokens(%__MODULE__{} = request, max_tokens) when is_integer(max_tokens) do
    %{request | max_tokens: max_tokens}
  end

  @doc """
  Sets the temperature (0.0-1.0).

  ## Example

      Request.new("claude-haiku-4-5")
      |> Request.set_temperature(0.7)

  Sampling parameters return 400 on Claude Opus 4.7+, Opus 5.x, Sonnet 5 and
  Fable models; use them only with models that accept them (e.g. Claude Haiku 4.5).
  """
  @spec set_temperature(t(), float()) :: t()
  def set_temperature(%__MODULE__{} = request, temperature)
      when is_number(temperature) and temperature >= 0.0 and temperature <= 1.0 do
    %{request | temperature: temperature / 1}
  end

  @doc """
  Sets top_p for nucleus sampling (0.0-1.0).

  ## Example

      Request.new("claude-haiku-4-5")
      |> Request.set_top_p(0.9)

  Sampling parameters return 400 on Claude Opus 4.7+, Opus 5.x, Sonnet 5 and
  Fable models; use them only with models that accept them (e.g. Claude Haiku 4.5).
  """
  @spec set_top_p(t(), float()) :: t()
  def set_top_p(%__MODULE__{} = request, top_p)
      when is_number(top_p) and top_p >= 0.0 and top_p <= 1.0 do
    %{request | top_p: top_p / 1}
  end

  @doc """
  Sets top_k for sampling from top K options.

  ## Example

      Request.new("claude-haiku-4-5")
      |> Request.set_top_k(40)

  Sampling parameters return 400 on Claude Opus 4.7+, Opus 5.x, Sonnet 5 and
  Fable models; use them only with models that accept them (e.g. Claude Haiku 4.5).
  """
  @spec set_top_k(t(), integer()) :: t()
  def set_top_k(%__MODULE__{} = request, top_k) when is_integer(top_k) and top_k > 0 do
    %{request | top_k: top_k}
  end

  @doc """
  Sets custom stop sequences.

  ## Example

      Request.new("claude-opus-5-5")
      |> Request.set_stop_sequences(["END", "STOP"])
  """
  @spec set_stop_sequences(t(), list(String.t())) :: t()
  def set_stop_sequences(%__MODULE__{} = request, sequences) when is_list(sequences) do
    %{request | stop_sequences: sequences}
  end

  @doc """
  Enables streaming responses.

  ## Example

      Request.new("claude-opus-5-5")
      |> Request.enable_streaming()
  """
  @spec enable_streaming(t()) :: t()
  def enable_streaming(%__MODULE__{} = request) do
    %{request | stream: true}
  end

  @doc """
  Adds a tool definition.

  ## Example

      tool = %{
        "name" => "get_weather",
        "description" => "Get weather for a location",
        "input_schema" => %{
          "type" => "object",
          "properties" => %{
            "location" => %{"type" => "string"}
          },
          "required" => ["location"]
        }
      }

      Request.new("claude-opus-5-5")
      |> Request.add_tool(tool)

  ## Options

  - `:defer_loading` — `true` keeps the tool out of the initial prompt until a tool search
    tool (`add_tool_search_tool/2`) returns a reference to it. At least one tool must stay
    non-deferred.
  - `:allowed_callers` — who may call the tool: `:direct` (the model; the default when
    omitted), `:code_execution` (code inside a `code_execution_20260120`+ sandbox —
    programmatic tool calling), or a raw string.
  """
  @spec add_tool(t(), map(), keyword()) :: t()
  def add_tool(%__MODULE__{tools: tools} = request, tool, opts \\ [])
      when is_map(tool) do
    opts =
      Claudio.Options.validate!(opts, [:defer_loading, :allowed_callers], "Request.add_tool/3")

    tool =
      tool
      |> put_tool_key("defer_loading", defer_loading!(Keyword.get(opts, :defer_loading)))
      |> put_tool_key("allowed_callers", allowed_callers!(Keyword.get(opts, :allowed_callers)))

    %{request | tools: (tools || []) ++ [tool]}
  end

  defp defer_loading!(value) when is_boolean(value) or is_nil(value), do: value

  defp defer_loading!(other) do
    raise ArgumentError,
          "Request.add_tool/3 :defer_loading must be a boolean; got #{inspect(other)}"
  end

  defp allowed_callers!(nil), do: nil
  defp allowed_callers!(callers) when is_list(callers), do: Enum.map(callers, &allowed_caller!/1)

  defp allowed_callers!(other) do
    raise ArgumentError,
          "Request.add_tool/3 :allowed_callers must be a list; got #{inspect(other)}"
  end

  defp allowed_caller!(:direct), do: "direct"
  # Responses always tag programmatic calls as code_execution_20260120 (tool-reference).
  defp allowed_caller!(:code_execution), do: "code_execution_20260120"
  defp allowed_caller!(caller) when is_binary(caller), do: caller

  defp allowed_caller!(other) do
    raise ArgumentError,
          "Request.add_tool/3 :allowed_callers entries must be :direct, :code_execution " <>
            "or a string; got #{inspect(other)}"
  end

  @doc """
  Adds a tool definition with prompt caching enabled.

  Useful when you have many tool definitions and want to cache them.

  ## Example

      tool = %{
        "name" => "get_weather",
        "description" => "Get weather for a location",
        "input_schema" => %{"type" => "object", "properties" => %{}}
      }

      Request.new("claude-opus-5-5")
      |> Request.add_tool_with_cache(tool)
  """
  @spec add_tool_with_cache(t(), map(), keyword()) :: t()
  def add_tool_with_cache(%__MODULE__{} = request, tool, opts \\ []) when is_map(tool) do
    # defer_loading is left out on purpose: the API rejects it together with cache_control.
    opts =
      Claudio.Options.validate!(opts, [:ttl, :allowed_callers], "Request.add_tool_with_cache/3")

    tool = put_tool_key(tool, "cache_control", cache_control_map(Keyword.get(opts, :ttl)))
    add_tool(request, tool, Keyword.take(opts, [:allowed_callers]))
  end

  @doc """
  Sets tool choice strategy.

  ## Example

      Request.new("claude-opus-5-5")
      |> Request.set_tool_choice(:auto)
      |> Request.set_tool_choice(:any)
      |> Request.set_tool_choice({:tool, "get_weather"})
      |> Request.set_tool_choice(:none)

  `:any` and `{:tool, name}` return 400 on Claude Fable 5.1, Mythos 5.1 and
  Opus 5.5. There, use `:auto` with a prompt instruction naming the tool,
  `add_strict_tool/2` for schema-valid arguments, or `set_output_format/2`
  when the forced call only existed to get JSON back.
  """
  @spec set_tool_choice(t(), tool_choice()) :: t()
  def set_tool_choice(%__MODULE__{} = request, :auto) do
    %{request | tool_choice: %{"type" => "auto"}}
  end

  def set_tool_choice(%__MODULE__{} = request, :any) do
    %{request | tool_choice: %{"type" => "any"}}
  end

  def set_tool_choice(%__MODULE__{} = request, {:tool, name}) when is_binary(name) do
    %{request | tool_choice: %{"type" => "tool", "name" => name}}
  end

  def set_tool_choice(%__MODULE__{} = request, :none) do
    %{request | tool_choice: %{"type" => "none"}}
  end

  @doc """
  Sets request metadata.

  ## Example

      Request.new("claude-opus-5-5")
      |> Request.set_metadata(%{"user_id" => "123"})
  """
  @spec set_metadata(t(), map()) :: t()
  def set_metadata(%__MODULE__{} = request, metadata) when is_map(metadata) do
    %{request | metadata: metadata}
  end

  @doc """
  Enables extended thinking with optional budget.

  ## Example

      Request.new("claude-opus-5-5")
      |> Request.enable_thinking(%{"type" => "adaptive"})

  `%{"type" => "enabled", "budget_tokens" => n}` returns 400 on Claude Opus 4.7+,
  Opus 5.x, Sonnet 5 and Fable models; use `"adaptive"` there. This is the raw
  setter (replaces `thinking`); prefer `enable_adaptive_thinking/2` /
  `disable_thinking/1`, and `set_effort/2` to steer how much the model thinks.
  """
  @spec enable_thinking(t(), map()) :: t()
  def enable_thinking(%__MODULE__{} = request, config) when is_map(config) do
    %{request | thinking: config}
  end

  @thinking_displays [:summarized, :omitted, :updates]
  @thinking_display_updates_beta "thinking-display-updates-2026-08-18"
  @block_binding_behaviors [:error, :drop_block]
  @block_binding_beta "thinking-binding-controls-2026-08-01"

  @doc """
  Enables adaptive thinking (`thinking: %{"type" => "adaptive"}`), replacing any
  previous `thinking` config. The model decides how much to think; steer it with
  `set_effort/2`.

  ## Options

  - `:display` — `:summarized`, `:omitted` or `:updates`. Omit it (or pass `nil`)
    to use the model's default. `:updates` (progress notes as separate `thinking` blocks)
    also declares the `thinking-display-updates-2026-08-18` beta. A beta declared
    here stays declared if `thinking` is later replaced.
  - `:block_binding` — `:error` or `:drop_block`: what the API does with a `thinking` block
    whose conversation prefix changed since it was produced (an edited earlier message, a
    block removed from the middle). `:error` rejects the request (400); `:drop_block` drops
    that block and every later thinking block and reports it in
    `Response.input_transformations`. Declares `thinking-binding-controls-2026-08-01`.
    Unset: accounts created on/after 2026-08-31 behave as `:error`; older accounts are not
    enforced. See `set_thinking_block_binding/2`.

  ## Example

      Request.new("claude-opus-5-5")
      |> Request.enable_adaptive_thinking(display: :summarized)
      |> Request.set_effort(:high)
  """
  @spec enable_adaptive_thinking(t(), keyword()) :: t()
  def enable_adaptive_thinking(%__MODULE__{} = request, opts \\ []) do
    opts =
      Claudio.Options.validate!(
        opts,
        [:display, :block_binding],
        "Request.enable_adaptive_thinking/2"
      )

    display =
      case Keyword.get(opts, :display) do
        nil ->
          nil

        display when display in @thinking_displays ->
          display

        other ->
          raise ArgumentError,
                "Request.enable_adaptive_thinking/2 :display must be one of " <>
                  ":summarized, :omitted, :updates; got #{inspect(other)}"
      end

    binding = block_binding!("enable_adaptive_thinking/2", Keyword.get(opts, :block_binding))

    thinking =
      %{"type" => "adaptive"}
      |> maybe_put("display", display && Atom.to_string(display))
      |> maybe_put("block_binding", binding)

    request = %{request | thinking: thinking}

    request =
      if display == :updates, do: add_beta(request, @thinking_display_updates_beta), else: request

    if binding, do: add_beta(request, @block_binding_beta), else: request
  end

  @doc """
  Sets `thinking.block_binding.prefix_mismatch_behavior` (`:error` or `:drop_block`) on the
  thinking config already set — adaptive or a raw `enable_thinking/2` `"enabled"` map —
  and declares `thinking-binding-controls-2026-08-01`. Raises if no thinking config is set.
  A later thinking setter replaces the whole map (the beta stays declared). The API rejects
  `block_binding` on `"disabled"` thinking.

  `:error` rejects a request whose `thinking` block no longer matches the conversation
  prefix it was produced under (400); `:drop_block` drops that block and every later
  thinking block and reports it in `Response.input_transformations`. Unset, accounts
  created on/after 2026-08-31 behave as `:error` and older accounts are not enforced — set
  it explicitly to get the same behavior everywhere.

  ## Example

      Request.new("claude-sonnet-4-6")
      |> Request.enable_thinking(%{"type" => "enabled", "budget_tokens" => 2048})
      |> Request.set_thinking_block_binding(:drop_block)
  """
  @spec set_thinking_block_binding(t(), :error | :drop_block) :: t()
  def set_thinking_block_binding(%__MODULE__{} = request, behavior)
      when behavior in @block_binding_behaviors do
    case request.thinking do
      nil ->
        raise ArgumentError,
              "Request.set_thinking_block_binding/2 needs thinking set first " <>
                "(enable_adaptive_thinking/2 or enable_thinking/2)"

      thinking ->
        binding = %{"prefix_mismatch_behavior" => Atom.to_string(behavior)}
        # Drop an atom :block_binding so an atom-keyed raw map can't emit the key twice.
        thinking = thinking |> Map.delete(:block_binding) |> Map.put("block_binding", binding)
        add_beta(%{request | thinking: thinking}, @block_binding_beta)
    end
  end

  def set_thinking_block_binding(%__MODULE__{}, other) do
    raise ArgumentError,
          "Request.set_thinking_block_binding/2 behavior must be :error or :drop_block; " <>
            "got #{inspect(other)}"
  end

  defp block_binding!(_fun, nil), do: nil

  defp block_binding!(_fun, behavior) when behavior in @block_binding_behaviors,
    do: %{"prefix_mismatch_behavior" => Atom.to_string(behavior)}

  defp block_binding!(fun, other) do
    raise ArgumentError,
          "Request.#{fun} :block_binding must be :error or :drop_block; got #{inspect(other)}"
  end

  @doc """
  Turns thinking off (`thinking: %{"type" => "disabled"}`), replacing any previous
  `thinking` config. Models that always think reject this with a 400.
  """
  @spec disable_thinking(t()) :: t()
  def disable_thinking(%__MODULE__{} = request) do
    %{request | thinking: %{"type" => "disabled"}}
  end

  @doc """
  Adds a server for the MCP connector (`mcp-client-2025-11-20`).

  Emits both halves the API requires: the server entry in `mcp_servers` and an
  `mcp_toolset` entry in `tools` referencing it by name. Declares the
  `mcp-client-2025-11-20` beta via `add_beta/2`.

  Accepts a `Claudio.MCP.ServerConfig` or a raw map; a legacy
  `tool_configuration` key in a raw map is translated onto the toolset with a
  deprecation warning. If `tools` already holds an `mcp_toolset` for that
  server name (the API allows one per server), no second toolset is added —
  unless the new one carries `default_config`/`configs`, which would be lost,
  so that raises `ArgumentError`. Add hand-built toolsets **before** calling
  this, or the request will carry two. Server names must be unique; adding a
  second server with an existing name raises `ArgumentError`.

      Request.new("claude-opus-5-5")
      |> Request.add_mcp_server(
        Claudio.MCP.ServerConfig.new("my_server", "https://mcp.example.com/sse")
      )
  """
  @spec add_mcp_server(t(), Claudio.MCP.ServerConfig.t() | map()) :: t()
  def add_mcp_server(%__MODULE__{} = request, %Claudio.MCP.ServerConfig{} = server) do
    put_mcp_server(
      request,
      ServerConfig.to_map(server),
      ServerConfig.to_toolset(server)
    )
  end

  def add_mcp_server(%__MODULE__{} = request, server) when is_map(server) do
    {server_map, toolset} = ServerConfig.split_raw(server)
    put_mcp_server(request, server_map, toolset)
  end

  defp put_mcp_server(%__MODULE__{mcp_servers: servers} = request, server_map, toolset) do
    name = toolset["mcp_server_name"]

    if Enum.any?(servers || [], &((&1["name"] || &1[:name]) == name)) do
      raise ArgumentError,
            "request already has an MCP server named #{inspect(name)}; the connector " <>
              "requires unique server names (each is referenced by exactly one mcp_toolset)"
    end

    request = %{request | mcp_servers: (servers || []) ++ [server_map]}

    request =
      cond do
        not has_mcp_toolset?(request.tools, name) ->
          add_tool(request, toolset)

        Map.has_key?(toolset, "default_config") or Map.has_key?(toolset, "configs") ->
          raise ArgumentError,
                "request already has an mcp_toolset for #{inspect(name)}; the new server's " <>
                  "tool config (#{inspect(Map.take(toolset, ["default_config", "configs"]))}) " <>
                  "would be dropped. Put the config on one toolset only."

        true ->
          request
      end

    add_beta(request, "mcp-client-2025-11-20")
  end

  defp has_mcp_toolset?(tools, server_name) do
    Enum.any?(tools || [], fn tool ->
      (tool["type"] || tool[:type]) == "mcp_toolset" and
        (tool["mcp_server_name"] || tool[:mcp_server_name]) == server_name
    end)
  end

  @doc """
  Sets the raw `context_management` map, replacing any previous one (including edits added
  by `add_clear_tool_uses/2`, `add_clear_thinking/2`, `add_compaction/2`; betas they
  declared stay). Always declares `context-management-2025-06-27`; also declares
  `compact-2026-01-12` when `edits` holds a `compact_20260112` edit (the API rejects it
  otherwise). Prefer the builders.

  ## Example

      Request.new("claude-opus-5-5")
      |> Request.set_context_management(%{
        "edits" => [
          %{"type" => "clear_thinking_20251015", "keep" => "all"},
          %{"type" => "clear_tool_uses_20250919", "keep" => %{"type" => "tool_uses", "value" => 3}},
          %{"type" => "compact_20260112", "trigger" => %{"type" => "input_tokens", "value" => 150_000}}
        ]
      })
  """
  @spec set_context_management(t(), map()) :: t()
  def set_context_management(%__MODULE__{} = request, config) when is_map(config) do
    request = add_beta(%{request | context_management: config}, @context_management_beta)
    if has_compact_edit?(config), do: add_beta(request, @compaction_beta), else: request
  end

  @doc """
  Adds a `clear_tool_uses_20250919` context edit (declares `context-management-2025-06-27`):
  once the trigger is reached, the API clears older tool results from the prompt it sends
  to the model. Your stored history is unchanged.

  ## Options (each omitted option is left to the API default)

  - `:trigger` — `{:input_tokens, n}` or `{:tool_uses, n}`
  - `:keep` — number of most recent tool uses to keep
  - `:clear_at_least` — minimum input tokens to clear (makes the cache invalidation worth it)
  - `:exclude_tools` — tool names never cleared
  - `:clear_tool_inputs` — `true`, `false`, or a list of tool names whose inputs are cleared too

  ## Example

      Request.new("claude-opus-5-5")
      |> Request.add_clear_tool_uses(trigger: {:input_tokens, 100_000}, keep: 3)
  """
  @spec add_clear_tool_uses(t(), keyword()) :: t()
  def add_clear_tool_uses(%__MODULE__{} = request, opts \\ []) do
    opts =
      Claudio.Options.validate!(
        opts,
        [
          :trigger,
          :keep,
          :clear_at_least,
          :exclude_tools,
          :clear_tool_inputs
        ],
        "Request.add_clear_tool_uses/2"
      )

    fun = "add_clear_tool_uses/2"

    edit =
      %{"type" => "clear_tool_uses_20250919"}
      |> maybe_put("trigger", map_opt(opts, :trigger, &clear_trigger!/1))
      |> maybe_put("keep", map_opt(opts, :keep, &count_map!(fun, :keep, "tool_uses", &1)))
      |> maybe_put(
        "clear_at_least",
        map_opt(opts, :clear_at_least, &count_map!(fun, :clear_at_least, "input_tokens", &1))
      )
      |> maybe_put(
        "exclude_tools",
        map_opt(opts, :exclude_tools, &string_list!(fun, :exclude_tools, &1))
      )
      |> maybe_put(
        "clear_tool_inputs",
        clear_tool_inputs!(fun, Keyword.get(opts, :clear_tool_inputs))
      )

    request |> put_edit(edit, :last) |> add_beta(@context_management_beta)
  end

  @doc """
  Adds a `clear_thinking_20251015` context edit (declares `context-management-2025-06-27`).
  It is always placed **first** in `edits` — the API rejects it anywhere else.

  ## Options

  - `:keep` — `:all`, or a positive number of recent assistant turns whose thinking is kept.
    Omitted: the model's default.
  """
  @spec add_clear_thinking(t(), keyword()) :: t()
  def add_clear_thinking(%__MODULE__{} = request, opts \\ []) do
    opts = Claudio.Options.validate!(opts, [:keep], "Request.add_clear_thinking/2")

    keep =
      case Keyword.get(opts, :keep) do
        nil ->
          nil

        :all ->
          "all"

        n when is_integer(n) and n > 0 ->
          %{"type" => "thinking_turns", "value" => n}

        other ->
          raise ArgumentError,
                "Request.add_clear_thinking/2 :keep must be :all or a positive integer; " <>
                  "got #{inspect(other)}"
      end

    edit = maybe_put(%{"type" => "clear_thinking_20251015"}, "keep", keep)
    request |> put_edit(edit, :first) |> add_beta(@context_management_beta)
  end

  @doc """
  Adds a `compact_20260112` edit — **threshold compaction** (declares `compact-2026-01-12`).
  When the input passes the trigger, the API summarizes the conversation into a
  `compaction` block at the start of the reply; everything before that block is ignored
  on later turns. Keep this edit on every later request that replays the block (the API
  rejects a replayed threshold block without it); see `apply_compaction/2`.

  ## Options (each omitted option is left to the API default)

  - `:trigger` — input tokens that trigger compaction (API default 150000, minimum 50000)
  - `:pause_after_compaction` — `true` returns right after the summary
    (`stop_reason: :compaction`)
  - `:instructions` — summarization instructions
  """
  @spec add_compaction(t(), keyword()) :: t()
  def add_compaction(%__MODULE__{} = request, opts \\ []) do
    opts =
      Claudio.Options.validate!(
        opts,
        [:trigger, :pause_after_compaction, :instructions],
        "Request.add_compaction/2"
      )

    edit =
      %{"type" => "compact_20260112"}
      |> maybe_put(
        "trigger",
        map_opt(opts, :trigger, &count_map!("add_compaction/2", :trigger, "input_tokens", &1))
      )
      |> maybe_put("pause_after_compaction", pause_after_compaction!(opts))
      |> maybe_put("instructions", opts[:instructions])

    request |> put_edit(edit, :last) |> add_beta(@compaction_beta)
  end

  @doc """
  Asks for an **on-demand** summary of the conversation so far (top-level
  `compaction: %{"type" => "summarize"}`; declares `compact-2026-09-04`). The reply is only
  a signed `compaction` block with `stop_reason: :compaction`; continue with
  `apply_compaction/2`. The API rejects this combined with `context_management`,
  `stop_sequences`, `output_config.format`, a forced `tool_choice`, or a last assistant
  turn ending in an unanswered `tool_use` — those are left to its 400. To drop
  context-management edits set earlier, use `%{request | context_management: nil}`
  (`set_context_management/2` takes a map, and `%{}` would still be sent).

  ## Options

  - `:instructions` — replaces the default summarization prompt (≤ 16384 characters)

  ## Example

      {:ok, summary} = Messages.create(client, Request.request_compaction(request))

      request =
        request
        |> Request.apply_compaction(summary)
        |> Request.add_message(:user, "Continue")
  """
  @spec request_compaction(t(), keyword()) :: t()
  def request_compaction(%__MODULE__{} = request, opts \\ []) do
    opts = Claudio.Options.validate!(opts, [:instructions], "Request.request_compaction/2")
    compaction = maybe_put(%{"type" => "summarize"}, "instructions", opts[:instructions])
    add_beta(%{request | compaction: compaction}, @on_demand_compaction_beta)
  end

  @doc """
  Continues a conversation from a compaction summary, for either kind of compaction.

  Replaces `messages` with a single assistant message holding the response content from
  its **last** `compaction` block onward (the block first, byte-exact, as the API
  requires), and clears `compaction` so the next call is a normal turn. Everything else
  — `system`, `tools`, `thinking`, `context_management` (a threshold replay needs its
  `compact_20260112` edit), betas — is kept. The replay beta is declared by
  `add_message/3`. Add the next user turn after it — also after a
  `pause_after_compaction: true` reply, whose content is only the block (a
  `[assistant: [block], user: …]` history is accepted, probe P8). A paused threshold
  compaction summarized the user turn that triggered it too: re-add that turn after the
  block if the next reply should still answer it.

  Raises `ArgumentError` for a failed compaction (`content: nil`) — the current history
  is still the only record of the conversation.

  Editing the history yourself (rather than through this function) can invalidate the
  signatures of kept `thinking` blocks; `set_thinking_block_binding(:drop_block)` makes the
  API drop such blocks instead of rejecting the request.

  Raises `ArgumentError` when the response has no `compaction` block.
  """
  @spec apply_compaction(t(), Claudio.Messages.Response.t()) :: t()
  def apply_compaction(%__MODULE__{} = request, %Claudio.Messages.Response{} = response) do
    content = Response.to_assistant_content(response)

    case last_compaction_index(content) do
      nil ->
        raise ArgumentError,
              "Request.apply_compaction/2 response has no compaction block; " <>
                "got stop_reason #{inspect(response.stop_reason)}"

      index ->
        block = Enum.at(content, index)

        # A failed compaction returns a block with content: nil — nothing was summarized,
        # so replacing the history with it would silently lose the conversation.
        if is_nil(Map.get(block, "content") || Map.get(block, :content)) do
          raise ArgumentError,
                "Request.apply_compaction/2 compaction failed (content: nil); nothing was " <>
                  "summarized — keep the current history"
        end

        %{request | messages: [], compaction: nil}
        |> add_message(:assistant, Enum.drop(content, index))
    end
  end

  defp last_compaction_index(content) do
    content
    |> Enum.with_index()
    |> Enum.reduce(nil, fn {block, index}, last ->
      if compaction_block?(block), do: index, else: last
    end)
  end

  defp pause_after_compaction!(opts) do
    case Keyword.get(opts, :pause_after_compaction) do
      value when is_boolean(value) or is_nil(value) ->
        value

      other ->
        raise ArgumentError,
              "Request.add_compaction/2 :pause_after_compaction must be a boolean; " <>
                "got #{inspect(other)}"
    end
  end

  # nil means "not given"; any other value (including false) is validated by `fun`.
  defp map_opt(opts, key, fun) do
    case Keyword.get(opts, key) do
      nil -> nil
      value -> fun.(value)
    end
  end

  defp string_list!(fun, opt, list) when is_list(list) do
    if Enum.all?(list, &is_binary/1), do: list, else: string_list_error!(fun, opt, list)
  end

  defp string_list!(fun, opt, other), do: string_list_error!(fun, opt, other)

  defp string_list_error!(fun, opt, value) do
    raise ArgumentError,
          "Request.#{fun} #{inspect(opt)} must be a list of tool names; got #{inspect(value)}"
  end

  defp clear_tool_inputs!(_fun, value) when is_boolean(value) or is_nil(value), do: value

  defp clear_tool_inputs!(fun, value) when is_list(value),
    do: string_list!(fun, :clear_tool_inputs, value)

  defp clear_tool_inputs!(fun, other) do
    raise ArgumentError,
          "Request.#{fun} :clear_tool_inputs must be a boolean or a list of tool names; " <>
            "got #{inspect(other)}"
  end

  defp clear_trigger!({kind, n}) when kind in [:input_tokens, :tool_uses] and is_integer(n),
    do: %{"type" => Atom.to_string(kind), "value" => n}

  defp clear_trigger!(other) do
    raise ArgumentError,
          "Request.add_clear_tool_uses/2 :trigger must be {:input_tokens, n} or " <>
            "{:tool_uses, n}; got #{inspect(other)}"
  end

  defp count_map!(_fun, _opt, type, n) when is_integer(n), do: %{"type" => type, "value" => n}

  defp count_map!(fun, opt, _type, other) do
    raise ArgumentError,
          "Request.#{fun} #{inspect(opt)} must be an integer; got #{inspect(other)}"
  end

  # Appends (or, for clear_thinking, prepends) an edit, keeping whichever key style
  # (`"edits"` / `:edits`) a raw set_context_management/2 used and any other keys.
  defp put_edit(%__MODULE__{context_management: cm} = request, edit, position) do
    cm = cm || %{}
    key = if Map.has_key?(cm, :edits) and not Map.has_key?(cm, "edits"), do: :edits, else: "edits"
    current = Map.get(cm, key) || []

    edits =
      if position == :first,
        # Only one clear_thinking edit is meaningful: a new one replaces the old.
        do: [edit | Enum.reject(current, &(edit_type(&1) == edit["type"]))],
        else: current ++ [edit]

    %{request | context_management: Map.put(cm, key, edits)}
  end

  @doc """
  Sets container identifier for tool reuse.

  Allows tools to maintain state across requests.

  ## Example

      # String container ID
      Request.new("claude-opus-5-5")
      |> Request.set_container("my-container-123")

      # Container config object
      Request.new("claude-opus-5-5")
      |> Request.set_container(%{
        "id" => "my-container",
        "ttl" => 3600
      })
  """
  @spec set_container(t(), String.t() | map()) :: t()
  def set_container(%__MODULE__{} = request, container)
      when is_binary(container) or is_map(container) do
    %{request | container: container}
  end

  @doc """
  Sets service tier for capacity selection.

  Options:
  - `"auto"` - Automatically select based on availability
  - `"standard_only"` - Only use standard tier capacity

  ## Example

      Request.new("claude-opus-5-5")
      |> Request.set_service_tier("auto")
  """
  @spec set_service_tier(t(), String.t()) :: t()
  def set_service_tier(%__MODULE__{} = request, tier) when tier in ["auto", "standard_only"] do
    %{request | service_tier: tier}
  end

  @doc """
  Adds a beta feature flag the request requires.

  Beta flags are merged into the `anthropic-beta` request header at send time
  (see `Claudio.Client.with_betas/2`). Use this to opt into beta-gated features
  the library does not model with a dedicated setter.

  Duplicates are ignored; insertion order is preserved.

  ## Example

      Request.new("claude-opus-4-8")
      |> Request.add_beta("context-management-2025-06-27")
  """
  @spec add_beta(t(), String.t()) :: t()
  def add_beta(%__MODULE__{betas: betas} = request, beta) when is_binary(beta) do
    if beta in betas do
      request
    else
      %{request | betas: betas ++ [beta]}
    end
  end

  @doc """
  Returns the list of beta feature flags this request requires.
  """
  @spec required_betas(t()) :: [String.t()]
  def required_betas(%__MODULE__{betas: betas}), do: betas

  @doc """
  Sets the raw `output_config` map.

  `output_config` is the API container for output controls (`format`, and on
  supported models `effort` / `task_budget`). This **replaces the whole map** —
  calling it after `set_effort/2`, `set_task_budget/3` or `set_output_format/2`
  discards what they set. Prefer those helpers; they merge.

  ## Example

      Request.new("claude-opus-4-8")
      |> Request.set_output_config(%{"effort" => "high"})
  """
  @spec set_output_config(t(), map()) :: t()
  def set_output_config(%__MODULE__{} = request, config) when is_map(config) do
    %{request | output_config: config}
  end

  @doc """
  Requests structured JSON output matching `schema` (a JSON Schema map).

  Sets `output_config.format` to `{type: "json_schema", schema: schema}`, merging
  into any existing `output_config` (so a prior `set_output_config/2` survives).
  GA — no beta header. The schema must use `"additionalProperties" => false` and
  list its `"required"` keys. Not compatible with document citations.

  ## Example

      Request.new("claude-opus-4-8")
      |> Request.set_output_format(%{
        "type" => "object",
        "properties" => %{"name" => %{"type" => "string"}},
        "required" => ["name"],
        "additionalProperties" => false
      })
  """
  @spec set_output_format(t(), map()) :: t()
  def set_output_format(%__MODULE__{} = request, schema)
      when is_map(schema) do
    put_output_config(request, "format", %{"type" => "json_schema", "schema" => schema})
  end

  @effort_levels [:low, :medium, :high, :xhigh, :max]
  @task_budgets_beta "task-budgets-2026-03-13"

  @doc """
  Sets `output_config.effort` — how much the model thinks and spends overall.
  GA, no beta header. Merges into `output_config`.

  `level` is `:low`, `:medium`, `:high`, `:xhigh` or `:max`. Which levels a model
  accepts (and its default) varies; the API rejects unsupported ones.

  ## Example

      Request.new("claude-opus-5-5")
      |> Request.enable_adaptive_thinking()
      |> Request.set_effort(:xhigh)
  """
  @spec set_effort(t(), :low | :medium | :high | :xhigh | :max) :: t()
  def set_effort(%__MODULE__{} = request, level) when level in @effort_levels do
    put_output_config(request, "effort", Atom.to_string(level))
  end

  def set_effort(%__MODULE__{}, level) do
    raise ArgumentError,
          "Request.set_effort/2 level must be one of :low, :medium, :high, :xhigh, :max; " <>
            "got #{inspect(level)}"
  end

  @doc """
  Sets an advisory token budget for the whole task
  (`output_config.task_budget = %{"type" => "tokens", "total" => total}`) and
  declares the `task-budgets-2026-03-13` beta. Merges into `output_config`;
  calling it again replaces the budget. `max_tokens` stays the hard cap.

  `total` must be a positive integer (the API enforces its own minimum, 20,000 as
  of 2026-09). Options:

  - `:remaining` — tokens left when carrying a budget across requests
    (non-negative integer; the API defaults it to `total`).

  ## Example

      Request.new("claude-opus-5-5")
      |> Request.set_task_budget(64_000, remaining: 40_000)
  """
  @spec set_task_budget(t(), pos_integer(), keyword()) :: t()
  def set_task_budget(%__MODULE__{} = request, total, opts \\ []) do
    opts = Claudio.Options.validate!(opts, [:remaining], "Request.set_task_budget/3")

    unless is_integer(total) and total > 0 do
      raise ArgumentError,
            "Request.set_task_budget/3 total must be a positive integer; got #{inspect(total)}"
    end

    budget =
      case Keyword.fetch(opts, :remaining) do
        :error ->
          %{"type" => "tokens", "total" => total}

        {:ok, remaining} when is_integer(remaining) and remaining >= 0 ->
          %{"type" => "tokens", "total" => total, "remaining" => remaining}

        {:ok, other} ->
          raise ArgumentError,
                "Request.set_task_budget/3 :remaining must be a non-negative integer; " <>
                  "got #{inspect(other)}"
      end

    request
    |> put_output_config("task_budget", budget)
    |> add_beta(@task_budgets_beta)
  end

  # Stringifies top-level keys first: a raw `set_output_config(%{effort: ...})`
  # plus a helper would otherwise encode both `effort` keys into one JSON object.
  defp put_output_config(%__MODULE__{output_config: existing} = request, key, value) do
    base = Map.new(existing || %{}, fn {k, v} -> {to_string(k), v} end)
    %{request | output_config: Map.put(base, key, value)}
  end

  @clear_at_values [:next_user_message, :never]
  @clear_at_beta "mid-conversation-system-clear-at-2026-08-21"
  @message_effort_beta "mid-conversation-output-config-2026-07-01"

  @doc """
  Appends a mid-conversation `role: "system"` message (GA — no beta header).

  `content` is a string or a list of content blocks, passed through unchanged. Where
  the message may sit (after a `user` turn, not first when it carries content, …) is
  checked by the API, not here.

  ## Options

  - `:clear_at` — `:next_user_message` (the message stops rendering once a later
    `user` message exists) or `:never`. Declares the
    `mid-conversation-system-clear-at-2026-08-21` beta.
  - `:effort` — `:low` … `:max`: per-message effort from the next `user` turn on
    (`"output_config" => %{"effort" => ...}`). Declares the
    `mid-conversation-output-config-2026-07-01` beta. With `content: []` this is an
    effort-only message, which the API accepts anywhere, including first.

  Raises `ArgumentError` for combinations the API always rejects:
  `clear_at: :next_user_message` with `:effort`, and `[]` content without `:effort`.

  ## Example

      Request.new("claude-opus-5-5")
      |> Request.add_system_message([], effort: :low)
      |> Request.add_message(:user, "Name a primary color.")
      |> Request.add_system_message("Answer in one word.", clear_at: :next_user_message)
  """
  @spec add_system_message(t(), String.t() | [map()], keyword()) :: t()
  # credo:disable-for-next-line Credo.Check.Refactor.CyclomaticComplexity
  def add_system_message(%__MODULE__{messages: messages} = request, content, opts \\ [])
      when is_binary(content) or is_list(content) do
    opts = Claudio.Options.validate!(opts, [:clear_at, :effort], "Request.add_system_message/3")
    clear_at = Keyword.get(opts, :clear_at)
    effort = Keyword.get(opts, :effort)

    unless is_nil(clear_at) or clear_at in @clear_at_values do
      raise ArgumentError,
            "Request.add_system_message/3 :clear_at must be one of :next_user_message, :never; " <>
              "got #{inspect(clear_at)}"
    end

    unless is_nil(effort) or effort in @effort_levels do
      raise ArgumentError,
            "Request.add_system_message/3 :effort must be one of :low, :medium, :high, :xhigh, :max; " <>
              "got #{inspect(effort)}"
    end

    if clear_at == :next_user_message and effort do
      raise ArgumentError,
            "Request.add_system_message/3 clear_at: :next_user_message cannot be combined with " <>
              ":effort (a turn-scoped system message cannot carry output_config)"
    end

    if content == [] and is_nil(effort) do
      raise ArgumentError,
            "Request.add_system_message/3 empty content [] requires :effort " <>
              "(a system message needs content or output_config)"
    end

    message =
      %{"role" => "system", "content" => content}
      |> maybe_put("clear_at", clear_at && Atom.to_string(clear_at))
      |> maybe_put("output_config", effort && %{"effort" => Atom.to_string(effort)})

    request = %{request | messages: messages ++ [message]}
    request = if clear_at, do: add_beta(request, @clear_at_beta), else: request
    if effort, do: add_beta(request, @message_effort_beta), else: request
  end

  @speeds [:fast, :standard]
  @fast_mode_beta "fast-mode-2026-02-01"

  @doc """
  Sets `speed` (`:fast` or `:standard`). Fast mode is an access-gated research
  preview. Always declares the `fast-mode-2026-02-01` beta — the API rejects the
  `speed` field without it, even for `:standard`. The response's `usage.speed`
  reports the speed used.
  """
  @spec set_speed(t(), :fast | :standard) :: t()
  def set_speed(%__MODULE__{} = request, speed) when speed in @speeds do
    add_beta(%{request | speed: Atom.to_string(speed)}, @fast_mode_beta)
  end

  def set_speed(%__MODULE__{}, speed) do
    raise ArgumentError,
          "Request.set_speed/2 speed must be one of :fast, :standard; got #{inspect(speed)}"
  end

  @inference_geos [:global, :us]

  @doc """
  Sets `inference_geo` — where the request is processed (`:global` or `:us`; GA, no
  beta). Without it the workspace default applies. `:us` is billed at 1.1× standard
  pricing. Not sent by `Claudio.Messages.count_tokens/2` when given a `Request`
  (that endpoint rejects it).
  The response's `usage.inference_geo` reports where it ran.
  """
  @spec set_inference_geo(t(), :global | :us) :: t()
  def set_inference_geo(%__MODULE__{} = request, geo) when geo in @inference_geos do
    %{request | inference_geo: Atom.to_string(geo)}
  end

  def set_inference_geo(%__MODULE__{}, geo) do
    raise ArgumentError,
          "Request.set_inference_geo/2 geo must be one of :global, :us; got #{inspect(geo)}"
  end

  @doc """
  Asks for cache diagnostics (GA, no beta): the response's `diagnostics` explains a
  prompt-cache miss against `previous_message_id` (the `id` of an earlier response in
  the same conversation). It is `nil` when there is nothing to compare or no divergence
  was found, and `%{"cache_miss_reason" => nil}` when the comparison was still pending.
  Not sent by `Claudio.Messages.count_tokens/2` when given a `Request` (that endpoint
  rejects it).
  """
  @spec enable_cache_diagnostics(t(), String.t() | nil) :: t()
  def enable_cache_diagnostics(%__MODULE__{} = request, previous_message_id \\ nil) do
    unless is_nil(previous_message_id) or is_binary(previous_message_id) do
      raise ArgumentError,
            "Request.enable_cache_diagnostics/2 previous_message_id must be a string or nil; " <>
              "got #{inspect(previous_message_id)}"
    end

    %{request | diagnostics: %{"previous_message_id" => previous_message_id}}
  end

  @doc """
  Sets `fallbacks` — server-side retry of a refused request on another model (beta;
  declares `server-side-fallback-2026-07-01`).

    * `:default` — the API picks the recommended fallback for the refusal category.
    * a non-empty list — tried in order; a model string becomes `%{"model" => model}`,
      a map is sent unchanged (it may override `max_tokens`, `thinking`,
      `output_config` and `speed` for that attempt).

  The API allows up to three entries, each distinct and listed in the requested
  model's `allowed_fallback_models`; those rules are left to it. Not supported by the
  Message Batches API (the item errors). Not sent by `Claudio.Messages.count_tokens/2`
  when given a `Request` (that endpoint rejects it). See `Claudio.Messages.Response`
  for the `fallback` block, `Response.served_by/1` and `usage.iterations`.
  """
  @spec set_fallbacks(t(), :default | [String.t() | map(), ...]) :: t()
  def set_fallbacks(%__MODULE__{} = request, :default) do
    add_beta(%{request | fallbacks: "default"}, @fallback_beta)
  end

  def set_fallbacks(%__MODULE__{} = request, [_ | _] = entries) do
    add_beta(%{request | fallbacks: Enum.map(entries, &fallback_entry/1)}, @fallback_beta)
  end

  def set_fallbacks(%__MODULE__{}, other) do
    raise ArgumentError,
          "Request.set_fallbacks/2 fallbacks must be :default or a non-empty list of " <>
            "model strings or maps; got #{inspect(other)}"
  end

  defp fallback_entry(model) when is_binary(model), do: %{"model" => model}
  defp fallback_entry(entry) when is_map(entry), do: entry

  defp fallback_entry(entry) do
    raise ArgumentError,
          "Request.set_fallbacks/2 each entry must be a model string or a map; " <>
            "got #{inspect(entry)}"
  end

  @doc """
  Adds a tool with strict schema validation enabled (`strict: true`).

  Guarantees the model's `tool_use.input` validates exactly against the schema.
  The schema must use `"additionalProperties" => false` and list `"required"`.
  GA — no beta header. (`strict` is a plain tool field; `add_tool/2` also passes
  it through if you set it yourself.)
  """
  @spec add_strict_tool(t(), map()) :: t()
  def add_strict_tool(%__MODULE__{} = request, tool) when is_map(tool) do
    add_tool(request, put_tool_key(tool, "strict", true))
  end

  @doc """
  Adds a tool with fine-grained ("eager") input streaming enabled.

  Sets `eager_input_streaming: true` so the tool's `input_json_delta` chunks
  stream as they are generated. GA — not a beta feature; use the regular
  streaming path (`enable_streaming/1`).
  """
  @spec add_tool_with_eager_streaming(t(), map()) :: t()
  def add_tool_with_eager_streaming(%__MODULE__{} = request, tool) when is_map(tool) do
    add_tool(request, put_tool_key(tool, "eager_input_streaming", true))
  end

  @doc """
  Adds a tool search tool (GA, no beta) so tools added with `defer_loading: true` are
  found on demand: `:regex` (`tool_search_tool_regex_20251119`) or `:bm25`
  (`tool_search_tool_bm25_20251119`).
  """
  @spec add_tool_search_tool(t(), :regex | :bm25) :: t()
  def add_tool_search_tool(%__MODULE__{} = request, variant) when variant in [:regex, :bm25] do
    name = "tool_search_tool_#{variant}"
    add_tool(request, %{"type" => "#{name}_20251119", "name" => name})
  end

  def add_tool_search_tool(%__MODULE__{}, other) do
    raise ArgumentError,
          "Request.add_tool_search_tool/2 variant must be :regex or :bm25; got #{inspect(other)}"
  end

  @advisor_cache_ttls ["5m", "1h"]

  @doc """
  Adds the advisor tool (`advisor_20260301`; declares `advisor-tool-2026-03-01`): the model
  can consult `model` mid-task. Replaying advisor blocks later also needs the beta —
  `add_message/3` declares it.

  ## Options

  - `:max_uses` — advisor calls per request
  - `:max_tokens` — advisor output cap (API minimum 1024)
  - `:caching` — `"5m"` or `"1h"`: caches the advisor's context
  """
  @spec add_advisor_tool(t(), String.t(), keyword()) :: t()
  def add_advisor_tool(%__MODULE__{} = request, model, opts \\ [])
      when is_binary(model) do
    opts =
      Claudio.Options.validate!(
        opts,
        [:max_uses, :max_tokens, :caching],
        "Request.add_advisor_tool/3"
      )

    caching =
      case Keyword.get(opts, :caching) do
        nil ->
          nil

        ttl when ttl in @advisor_cache_ttls ->
          %{"type" => "ephemeral", "ttl" => ttl}

        other ->
          raise ArgumentError,
                "Request.add_advisor_tool/3 :caching must be \"5m\" or \"1h\"; got #{inspect(other)}"
      end

    tool =
      %{"type" => "advisor_20260301", "name" => "advisor", "model" => model}
      |> maybe_put("max_uses", Keyword.get(opts, :max_uses))
      |> maybe_put("max_tokens", Keyword.get(opts, :max_tokens))
      |> maybe_put("caching", caching)

    request |> add_tool(tool) |> add_beta(@advisor_beta)
  end

  @doc """
  Adds the computer use client toolset (`computer_toolset_20260801`, GA, no beta) — the
  computer tool Claude Opus 5.5 accepts. Each action arrives as its own `tool_use` whose
  `name` is the member (`"screenshot"`, `"left_click"`, …) and whose `toolset_name` is
  `"computer"`; every `tool_result` must echo `toolset_name`
  (`Claudio.Tools.create_tool_result/4`). See `Claudio.Agent` for a loop that does this.

  ## Options

  - `:configs` — `%{member => %{enabled: boolean, defer_loading: boolean}}`
  - `:cache_control` — cache breakpoint on the entry
  """
  @spec add_computer_toolset(t(), keyword()) :: t()
  def add_computer_toolset(%__MODULE__{} = request, opts \\ []),
    do: add_toolset(request, "computer_toolset_20260801", opts, "Request.add_computer_toolset/2")

  @doc """
  Adds the browser use client toolset (`browser_toolset_20260801`, GA, no beta). Same
  mechanics and options as `add_computer_toolset/2`, with `toolset_name` `"browser"`.
  """
  @spec add_browser_toolset(t(), keyword()) :: t()
  def add_browser_toolset(%__MODULE__{} = request, opts \\ []),
    do: add_toolset(request, "browser_toolset_20260801", opts, "Request.add_browser_toolset/2")

  defp add_toolset(request, type, opts, fun) do
    opts = Claudio.Options.validate!(opts, [:configs, :cache_control], fun)

    configs =
      case Keyword.get(opts, :configs) do
        nil ->
          nil

        configs when not is_map(configs) ->
          bad_member_config!(type, configs)

        configs ->
          Map.new(configs, fn {member, conf} ->
            {to_string(member), member_config!(type, conf)}
          end)
      end

    tool =
      %{"type" => type}
      |> maybe_put("configs", configs)
      |> maybe_put("cache_control", Keyword.get(opts, :cache_control))

    add_tool(request, tool)
  end

  @doc """
  Adds the server-side `web_search` tool. GA — no beta header.

  ## Options

  - `:version` — `:basic` for `web_search_20250305`, otherwise the default
    `web_search_20260209` (dynamic filtering on 4.6+). A full type string is
    also accepted.
  - `:max_uses` — cap the number of searches per request.
  - `:allowed_domains` / `:blocked_domains` — domain filtering (lists).
  - `:user_location` — approximate-location map for localized results.

  Server-tool output is typed as `server_tool_use` / `web_search_tool_result`
  blocks (see `Claudio.Messages.Response.get_server_tool_uses/1`).
  """
  @spec add_web_search_tool(t(), keyword()) :: t()
  def add_web_search_tool(%__MODULE__{} = request, opts \\ []) do
    opts =
      Claudio.Options.validate!(
        opts,
        [
          :version,
          :max_uses,
          :allowed_domains,
          :blocked_domains,
          :user_location
        ],
        "Request.add_web_search_tool/2"
      )

    tool =
      %{"type" => web_search_type(Keyword.get(opts, :version)), "name" => "web_search"}
      |> maybe_put("max_uses", Keyword.get(opts, :max_uses))
      |> maybe_put("allowed_domains", Keyword.get(opts, :allowed_domains))
      |> maybe_put("blocked_domains", Keyword.get(opts, :blocked_domains))
      |> maybe_put("user_location", Keyword.get(opts, :user_location))

    add_tool(request, tool)
  end

  @doc """
  Adds the server-side `web_fetch` tool. GA — no beta header.

  ## Options

  - `:version` — `:basic` for `web_fetch_20250910`, otherwise the default
    `web_fetch_20260209` (dynamic filtering). A full type string is also accepted.
  - `:max_uses` — cap the number of fetches per request.
  - `:allowed_domains` / `:blocked_domains` — domain filtering (lists).
  - `:citations` — `true` enables citations on fetched content.
  - `:max_content_tokens` — approximate cap on fetched content size.

  Unlike web search (URLs Claude finds), web fetch can only retrieve URLs that
  already appeared in the conversation.
  """
  @spec add_web_fetch_tool(t(), keyword()) :: t()
  def add_web_fetch_tool(%__MODULE__{} = request, opts \\ []) do
    opts =
      Claudio.Options.validate!(
        opts,
        [
          :version,
          :max_uses,
          :allowed_domains,
          :blocked_domains,
          :max_content_tokens,
          :citations
        ],
        "Request.add_web_fetch_tool/2"
      )

    tool =
      %{"type" => web_fetch_type(Keyword.get(opts, :version)), "name" => "web_fetch"}
      |> maybe_put("max_uses", Keyword.get(opts, :max_uses))
      |> maybe_put("allowed_domains", Keyword.get(opts, :allowed_domains))
      |> maybe_put("blocked_domains", Keyword.get(opts, :blocked_domains))
      |> maybe_put("max_content_tokens", Keyword.get(opts, :max_content_tokens))
      |> maybe_put_citations(Keyword.get(opts, :citations))

    add_tool(request, tool)
  end

  @code_execution_versions [:"20260521", :"20260120", :"20250825"]

  @doc """
  Adds the server-side `code_execution` tool. GA — no beta header. Pairs with
  `set_container/2` for container reuse and the Files API (`container_upload`
  blocks). Results arrive as `bash_code_execution_tool_result` /
  `text_editor_code_execution_tool_result` blocks.

  ## Options

    * `:version` — `:"20260521"` (default), `:"20260120"`, or `:"20250825"`.
      `20260521` and `20260120` run the same runtime (REPL persistence and
      programmatic tool calling); `20260521` also tells Claude about the
      90-second per-cell limit. Use `:"20250825"` to turn those features off.
  """
  @spec add_code_execution_tool(t(), keyword()) :: t()
  def add_code_execution_tool(%__MODULE__{} = request, opts \\ []) do
    version = Keyword.get(opts, :version, :"20260521")

    unless version in @code_execution_versions do
      raise ArgumentError,
            "add_code_execution_tool/2 :version must be one of " <>
              "#{inspect(@code_execution_versions)}; got #{inspect(version)}"
    end

    add_tool(request, %{"type" => "code_execution_#{version}", "name" => "code_execution"})
  end

  @doc """
  Adds the client-side, schema-less `bash` tool (`bash_20250124`). You execute
  the returned `tool_use` locally and send back a `tool_result`. Do **not** add
  an `input_schema` — the schema is built into the model.
  """
  @spec add_bash_tool(t()) :: t()
  def add_bash_tool(%__MODULE__{} = request) do
    add_tool(request, %{"type" => "bash_20250124", "name" => "bash"})
  end

  @doc """
  Adds the client-side, schema-less text editor tool (`text_editor_20250728`,
  name `str_replace_based_edit_tool`). Client-executed like `bash`.

  ## Options

  - `:max_characters` — cap `view`-command output length.
  """
  @spec add_text_editor_tool(t(), keyword()) :: t()
  def add_text_editor_tool(%__MODULE__{} = request, opts \\ []) do
    opts = Claudio.Options.validate!(opts, [:max_characters], "Request.add_text_editor_tool/2")

    tool =
      %{"type" => "text_editor_20250728", "name" => "str_replace_based_edit_tool"}
      |> maybe_put("max_characters", Keyword.get(opts, :max_characters))

    add_tool(request, tool)
  end

  @doc """
  Adds the client-side `memory` tool (`memory_20250818`). GA — no beta header.

  Claude issues `view` / `create` / `str_replace` / `insert` / `delete` /
  `rename` commands scoped to a `/memories` directory; you execute them locally.
  **Confine every operation to `/memories`** and reject path traversal. Pairs
  with `set_context_management/2` for long-running agents.
  """
  @spec add_memory_tool(t()) :: t()
  def add_memory_tool(%__MODULE__{} = request) do
    add_tool(request, %{"type" => "memory_20250818", "name" => "memory"})
  end

  @doc """
  Adds the `computer` tool (`computer_20250124`) for desktop control, and
  declares the required `computer-use-2025-01-24` beta header (via `add_beta/2`,
  so the send path attaches it automatically).

  Client-side: Claude requests screenshots / mouse / keyboard actions that your
  application executes. Typically paired with `add_bash_tool/1` and
  `add_text_editor_tool/2`.

  ## Options

  - `:display_number` — X11 display number for the environment.
  - `:version` — `:"20251124"` for `computer_20251124` (declares `computer-use-2025-11-24`).
    Claude Opus 5.5 accepts only the toolset: use `add_computer_toolset/2`.
  """
  @spec add_computer_tool(t(), pos_integer(), pos_integer(), keyword()) :: t()
  def add_computer_tool(%__MODULE__{} = request, display_width_px, display_height_px, opts \\ [])
      when is_integer(display_width_px) and is_integer(display_height_px) do
    opts =
      Claudio.Options.validate!(opts, [:display_number, :version], "Request.add_computer_tool/4")

    {type, beta} =
      case Keyword.get(opts, :version) do
        v when v in [nil, :"20250124"] ->
          {"computer_20250124", "computer-use-2025-01-24"}

        :"20251124" ->
          {"computer_20251124", "computer-use-2025-11-24"}

        other ->
          raise ArgumentError,
                ~s(Request.add_computer_tool/4 :version must be :"20250124" or :"20251124"; ) <>
                  "got #{inspect(other)} (use add_computer_toolset/2 for computer_toolset_20260801)"
      end

    tool =
      %{
        "type" => type,
        "name" => "computer",
        "display_width_px" => display_width_px,
        "display_height_px" => display_height_px
      }
      |> maybe_put("display_number", Keyword.get(opts, :display_number))

    request
    |> add_beta(beta)
    |> add_tool(tool)
  end

  @doc """
  Adds a text message whose content block carries a `cache_control` breakpoint.

  Use for the "growing conversation prefix" caching pattern — mark the last
  stable turn so the prefix up to it is cached. GA — no beta header. Up to 4
  `cache_control` breakpoints are allowed per request (not enforced here).

  ## Options

  - `:ttl` — cache duration, `"5m"` (default) or `"1h"`

  ## Example

      Request.new("claude-opus-4-8")
      |> Request.add_message_with_cache(:user, "Large shared context...", ttl: "1h")
      |> Request.add_message(:user, "The actual question")
  """
  @spec add_message_with_cache(t(), role(), String.t(), keyword()) :: t()
  def add_message_with_cache(%__MODULE__{} = request, role, text, opts \\ [])
      when role in [:user, :assistant] and is_binary(text) do
    content = [
      %{
        "type" => "text",
        "text" => text,
        "cache_control" => cache_control_map(Keyword.get(opts, :ttl))
      }
    ]

    add_message(request, role, content)
  end

  @doc """
  Sets a top-level `cache_control` breakpoint, auto-placed on the last cacheable
  block of the request (server-side). The simplest way to cache the request
  prefix when you don't need per-block placement. GA — no beta header.

  ## Options

  - `:ttl` — cache duration, `"5m"` (default) or `"1h"`

  ## Example

      Request.new("claude-opus-4-8")
      |> Request.set_system("Large shared context...")
      |> Request.set_cache_control(ttl: "1h")
  """
  @spec set_cache_control(t(), keyword()) :: t()
  def set_cache_control(%__MODULE__{} = request, opts \\ []) do
    %{request | cache_control: cache_control_map(Keyword.get(opts, :ttl))}
  end

  @doc """
  Converts the request to a map suitable for the API.
  """
  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = request) do
    %{
      "model" => request.model,
      "messages" => request.messages
    }
    |> maybe_put("max_tokens", request.max_tokens)
    |> maybe_put("system", request.system)
    |> maybe_put("temperature", request.temperature)
    |> maybe_put("top_p", request.top_p)
    |> maybe_put("top_k", request.top_k)
    |> maybe_put("stop_sequences", request.stop_sequences)
    |> maybe_put("stream", request.stream)
    |> maybe_put("tools", request.tools)
    |> maybe_put("tool_choice", request.tool_choice)
    |> maybe_put("metadata", request.metadata)
    |> maybe_put("thinking", request.thinking)
    |> maybe_put("mcp_servers", request.mcp_servers)
    |> maybe_put("context_management", request.context_management)
    |> maybe_put("container", request.container)
    |> maybe_put("service_tier", request.service_tier)
    |> maybe_put("output_config", request.output_config)
    |> maybe_put("cache_control", request.cache_control)
    |> maybe_put("speed", request.speed)
    |> maybe_put("inference_geo", request.inference_geo)
    |> maybe_put("diagnostics", request.diagnostics)
    |> maybe_put("fallbacks", request.fallbacks)
    |> maybe_put("compaction", request.compaction)
  end

  defp cache_control_map(nil), do: %{"type" => "ephemeral"}
  defp cache_control_map(ttl), do: %{"type" => "ephemeral", "ttl" => ttl}

  # Magic bytes of the image formats the API accepts; decodes only the first 16 bytes.
  defp detect_image_type(base64_data) do
    case Base.decode64(binary_part(base64_data, 0, min(byte_size(base64_data), 16)),
           padding: false
         ) do
      {:ok, <<0x89, "PNG", _::binary>>} -> "image/png"
      {:ok, <<"GIF8", _::binary>>} -> "image/gif"
      {:ok, <<"RIFF", _::binary-size(4), "WEBP", _::binary>>} -> "image/webp"
      _ -> "image/jpeg"
    end
  end

  defp normalize_content(content) when is_binary(content), do: content
  defp normalize_content(content) when is_list(content), do: Enum.map(content, &unwrap_typed/1)
  defp normalize_content(content), do: content

  # Any atom-typed block came from Response parsing: send its API shape (the original map
  # when kept under :raw), never the typed map with nil fields the API rejects.
  # A cache_control the caller added to a typed block is kept (it is not a Response field).
  defp unwrap_typed(%{type: type} = block) when is_atom(type) and not is_nil(type) do
    api_block = Response.to_api_block(block)

    case Map.get(block, :cache_control) || Map.get(block, "cache_control") do
      nil -> api_block
      cache_control -> Map.put(api_block, "cache_control", cache_control)
    end
  end

  defp unwrap_typed(block), do: block

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  # Sets a string key on a caller's tool map, dropping an atom twin so the JSON never
  # carries the key twice (atom-keyed tool maps are accepted everywhere).
  defp put_tool_key(tool, _key, nil), do: tool

  defp put_tool_key(tool, key, value),
    do: tool |> Map.delete(String.to_atom(key)) |> Map.put(key, value)

  defp stringify_keys(map) when is_map(map), do: Map.new(map, fn {k, v} -> {to_string(k), v} end)

  defp member_config!(_type, conf) when is_map(conf), do: stringify_keys(conf)

  defp member_config!(type, conf) when is_list(conf) do
    if Keyword.keyword?(conf),
      do: stringify_keys(Map.new(conf)),
      else: bad_member_config!(type, conf)
  end

  defp member_config!(type, conf), do: bad_member_config!(type, conf)

  defp bad_member_config!(type, conf) do
    fun =
      if type == "browser_toolset_20260801",
        do: "add_browser_toolset/2",
        else: "add_computer_toolset/2"

    raise ArgumentError,
          "Request.#{fun} :configs member values must be maps or keyword lists " <>
            "(enabled:, defer_loading:); got #{inspect(conf)}"
  end

  defp maybe_put_citations(map, true), do: Map.put(map, "citations", %{"enabled" => true})
  defp maybe_put_citations(map, _), do: map

  defp web_search_type(:basic), do: "web_search_20250305"
  defp web_search_type(nil), do: "web_search_20260209"
  defp web_search_type(version) when is_binary(version), do: version
  defp web_search_type(version) when is_atom(version), do: "web_search_#{version}"

  defp web_fetch_type(:basic), do: "web_fetch_20250910"
  defp web_fetch_type(nil), do: "web_fetch_20260209"
  defp web_fetch_type(version) when is_binary(version), do: version
  defp web_fetch_type(version) when is_atom(version), do: "web_fetch_#{version}"

  defp normalize_search_result_content(text) when is_binary(text),
    do: %{"type" => "text", "text" => text}

  defp normalize_search_result_content(%{} = block), do: block

  defp search_result_cache(nil), do: nil
  defp search_result_cache(false), do: nil
  defp search_result_cache(true), do: cache_control_map(nil)
  defp search_result_cache(ttl) when is_binary(ttl), do: cache_control_map(ttl)

  defp search_result_cache(other) do
    raise ArgumentError,
          "Request.search_result_block/4 :cache_control must be true, false or a ttl " <>
            "string (\"5m\" / \"1h\"); got #{inspect(other)}"
  end
end
