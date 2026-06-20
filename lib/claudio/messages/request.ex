defmodule Claudio.Messages.Request do
  @moduledoc """
  Builder for constructing Messages API requests.

  ## Example

      alias Claudio.Messages.Request

      Request.new("claude-sonnet-4-5-20250929")
      |> Request.add_message(:user, "Hello!")
      |> Request.set_system("You are a helpful assistant")
      |> Request.set_max_tokens(1024)
      |> Request.set_temperature(0.7)
      |> Request.to_map()
  """

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
          cache_control: map() | nil
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
    cache_control: nil
  ]

  @doc """
  Creates a new request builder with the specified model.

  ## Example

      Request.new("claude-sonnet-4-5-20250929")
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

  ## Examples

      # Simple text message
      Request.new("claude-3-5-sonnet-20241022")
      |> Request.add_message(:user, "What is the weather?")

      # Multimodal message with image
      Request.new("claude-3-5-sonnet-20241022")
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

    %{request | messages: messages ++ [message]}
  end

  @doc """
  Adds a text message with an image from a base64-encoded string.

  ## Example

      Request.new("claude-3-5-sonnet-20241022")
      |> Request.add_message_with_image(:user, "What's in this image?", base64_data, "image/jpeg")
  """
  @spec add_message_with_image(t(), role(), String.t(), String.t(), String.t()) :: t()
  def add_message_with_image(
        %__MODULE__{} = request,
        role,
        text,
        base64_data,
        media_type \\ "image/jpeg"
      )
      when role in [:user, :assistant] do
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

      Request.new("claude-3-5-sonnet-20241022")
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

      Request.new("claude-3-5-sonnet-20241022")
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
      Request.new("claude-3-5-sonnet-20241022")
      |> Request.set_system("You are a helpful assistant")

      # With prompt caching
      Request.new("claude-3-5-sonnet-20241022")
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

      Request.new("claude-3-5-sonnet-20241022")
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

      Request.new("claude-3-5-sonnet-20241022")
      |> Request.set_max_tokens(1024)
  """
  @spec set_max_tokens(t(), integer()) :: t()
  def set_max_tokens(%__MODULE__{} = request, max_tokens) when is_integer(max_tokens) do
    %{request | max_tokens: max_tokens}
  end

  @doc """
  Sets the temperature (0.0-1.0).

  ## Example

      Request.new("claude-3-5-sonnet-20241022")
      |> Request.set_temperature(0.7)
  """
  @spec set_temperature(t(), float()) :: t()
  def set_temperature(%__MODULE__{} = request, temperature)
      when is_number(temperature) and temperature >= 0.0 and temperature <= 1.0 do
    %{request | temperature: temperature / 1}
  end

  @doc """
  Sets top_p for nucleus sampling (0.0-1.0).

  ## Example

      Request.new("claude-3-5-sonnet-20241022")
      |> Request.set_top_p(0.9)
  """
  @spec set_top_p(t(), float()) :: t()
  def set_top_p(%__MODULE__{} = request, top_p)
      when is_number(top_p) and top_p >= 0.0 and top_p <= 1.0 do
    %{request | top_p: top_p / 1}
  end

  @doc """
  Sets top_k for sampling from top K options.

  ## Example

      Request.new("claude-3-5-sonnet-20241022")
      |> Request.set_top_k(40)
  """
  @spec set_top_k(t(), integer()) :: t()
  def set_top_k(%__MODULE__{} = request, top_k) when is_integer(top_k) and top_k > 0 do
    %{request | top_k: top_k}
  end

  @doc """
  Sets custom stop sequences.

  ## Example

      Request.new("claude-3-5-sonnet-20241022")
      |> Request.set_stop_sequences(["END", "STOP"])
  """
  @spec set_stop_sequences(t(), list(String.t())) :: t()
  def set_stop_sequences(%__MODULE__{} = request, sequences) when is_list(sequences) do
    %{request | stop_sequences: sequences}
  end

  @doc """
  Enables streaming responses.

  ## Example

      Request.new("claude-3-5-sonnet-20241022")
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

      Request.new("claude-3-5-sonnet-20241022")
      |> Request.add_tool(tool)
  """
  @spec add_tool(t(), map()) :: t()
  def add_tool(%__MODULE__{tools: tools} = request, tool) when is_map(tool) do
    current_tools = tools || []
    %{request | tools: current_tools ++ [tool]}
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

      Request.new("claude-3-5-sonnet-20241022")
      |> Request.add_tool_with_cache(tool)
  """
  @spec add_tool_with_cache(t(), map(), keyword()) :: t()
  def add_tool_with_cache(%__MODULE__{} = request, tool, opts \\ []) when is_map(tool) do
    tool_with_cache = Map.put(tool, "cache_control", cache_control_map(Keyword.get(opts, :ttl)))
    add_tool(request, tool_with_cache)
  end

  @doc """
  Sets tool choice strategy.

  ## Example

      Request.new("claude-3-5-sonnet-20241022")
      |> Request.set_tool_choice(:auto)
      |> Request.set_tool_choice(:any)
      |> Request.set_tool_choice({:tool, "get_weather"})
      |> Request.set_tool_choice(:none)
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

      Request.new("claude-3-5-sonnet-20241022")
      |> Request.set_metadata(%{"user_id" => "123"})
  """
  @spec set_metadata(t(), map()) :: t()
  def set_metadata(%__MODULE__{} = request, metadata) when is_map(metadata) do
    %{request | metadata: metadata}
  end

  @doc """
  Enables extended thinking with optional budget.

  ## Example

      Request.new("claude-3-5-sonnet-20241022")
      |> Request.enable_thinking(%{"type" => "enabled", "budget_tokens" => 1000})
  """
  @spec enable_thinking(t(), map()) :: t()
  def enable_thinking(%__MODULE__{} = request, config) when is_map(config) do
    %{request | thinking: config}
  end

  @doc """
  Adds MCP (Model Context Protocol) server definitions.

  ## Example

      Request.new("claude-sonnet-4-5-20250929")
      |> Request.add_mcp_server(%{
        "name" => "my_server",
        "url" => "http://localhost:8080"
      })
  """
  @spec add_mcp_server(t(), Claudio.MCP.ServerConfig.t() | map()) :: t()
  def add_mcp_server(%__MODULE__{} = request, %Claudio.MCP.ServerConfig{} = server) do
    add_mcp_server(request, Claudio.MCP.ServerConfig.to_map(server))
  end

  def add_mcp_server(%__MODULE__{mcp_servers: servers} = request, server) when is_map(server) do
    current_servers = servers || []
    %{request | mcp_servers: current_servers ++ [server]}
  end

  @doc """
  Sets context management configuration.

  Controls how context is managed across requests.

  ## Example

      Request.new("claude-3-5-sonnet-20241022")
      |> Request.set_context_management(%{
        "strategy" => "auto",
        "max_context_tokens" => 100000
      })
  """
  @spec set_context_management(t(), map()) :: t()
  def set_context_management(%__MODULE__{} = request, config) when is_map(config) do
    %{request | context_management: config}
    |> add_beta("context-management-2025-06-27")
  end

  @doc """
  Sets container identifier for tool reuse.

  Allows tools to maintain state across requests.

  ## Example

      # String container ID
      Request.new("claude-3-5-sonnet-20241022")
      |> Request.set_container("my-container-123")

      # Container config object
      Request.new("claude-3-5-sonnet-20241022")
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

      Request.new("claude-3-5-sonnet-20241022")
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
  supported models `effort` / `task_budget`). This replaces the whole map; for
  structured JSON output prefer `set_output_format/2`, which merges.

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
  def set_output_format(%__MODULE__{output_config: existing} = request, schema)
      when is_map(schema) do
    format = %{"type" => "json_schema", "schema" => schema}
    %{request | output_config: Map.put(existing || %{}, "format", format)}
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
    add_tool(request, Map.put(tool, "strict", true))
  end

  @doc """
  Adds a tool with fine-grained ("eager") input streaming enabled.

  Sets `eager_input_streaming: true` so the tool's `input_json_delta` chunks
  stream as they are generated. GA — not a beta feature; use the regular
  streaming path (`enable_streaming/1`).
  """
  @spec add_tool_with_eager_streaming(t(), map()) :: t()
  def add_tool_with_eager_streaming(%__MODULE__{} = request, tool) when is_map(tool) do
    add_tool(request, Map.put(tool, "eager_input_streaming", true))
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
    tool =
      %{"type" => web_fetch_type(Keyword.get(opts, :version)), "name" => "web_fetch"}
      |> maybe_put("max_uses", Keyword.get(opts, :max_uses))
      |> maybe_put("allowed_domains", Keyword.get(opts, :allowed_domains))
      |> maybe_put("blocked_domains", Keyword.get(opts, :blocked_domains))
      |> maybe_put("max_content_tokens", Keyword.get(opts, :max_content_tokens))
      |> maybe_put_citations(Keyword.get(opts, :citations))

    add_tool(request, tool)
  end

  @doc """
  Adds the server-side `code_execution` tool (`code_execution_20260120`). GA —
  no beta header. Pairs with `set_container/2` for container reuse and the Files
  API (`container_upload` blocks). Results are typed as
  `bash_code_execution_tool_result` / `text_editor_code_execution_tool_result`.
  """
  @spec add_code_execution_tool(t()) :: t()
  def add_code_execution_tool(%__MODULE__{} = request) do
    add_tool(request, %{"type" => "code_execution_20260120", "name" => "code_execution"})
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
    tool =
      %{"type" => "text_editor_20250728", "name" => "str_replace_based_edit_tool"}
      |> maybe_put("max_characters", Keyword.get(opts, :max_characters))

    add_tool(request, tool)
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
  end

  defp cache_control_map(nil), do: %{"type" => "ephemeral"}
  defp cache_control_map(ttl), do: %{"type" => "ephemeral", "ttl" => ttl}

  defp normalize_content(content) when is_binary(content), do: content
  defp normalize_content(content) when is_list(content), do: content
  defp normalize_content(content), do: content

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp maybe_put_citations(map, true), do: Map.put(map, "citations", %{"enabled" => true})
  defp maybe_put_citations(map, _), do: map

  defp web_search_type(:basic), do: "web_search_20250305"
  defp web_search_type(nil), do: "web_search_20260209"
  defp web_search_type(version) when is_binary(version), do: version

  defp web_fetch_type(:basic), do: "web_fetch_20250910"
  defp web_fetch_type(nil), do: "web_fetch_20260209"
  defp web_fetch_type(version) when is_binary(version), do: version

  defp normalize_search_result_content(text) when is_binary(text),
    do: %{"type" => "text", "text" => text}

  defp normalize_search_result_content(%{} = block), do: block

  defp search_result_cache(nil), do: nil
  defp search_result_cache(false), do: nil
  defp search_result_cache(true), do: cache_control_map(nil)
  defp search_result_cache(ttl) when is_binary(ttl), do: cache_control_map(ttl)
end
