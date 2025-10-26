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
          service_tier: String.t() | nil
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
    :service_tier
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

  ## Example

      Request.new("claude-3-5-sonnet-20241022")
      |> Request.add_message_with_document(:user, "Summarize this document", "file_abc123")
  """
  @spec add_message_with_document(t(), role(), String.t(), String.t()) :: t()
  def add_message_with_document(%__MODULE__{} = request, role, text, file_id)
      when role in [:user, :assistant] do
    content = [
      %{
        "type" => "document",
        "source" => %{
          "type" => "file",
          "file_id" => file_id
        }
      },
      %{"type" => "text", "text" => text}
    ]

    add_message(request, role, content)
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
    ttl = Keyword.get(opts, :ttl)

    cache_control =
      case ttl do
        nil -> %{"type" => "ephemeral"}
        ttl -> %{"type" => "ephemeral", "ttl" => ttl}
      end

    system = [
      %{
        "type" => "text",
        "text" => text,
        "cache_control" => cache_control
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
    ttl = Keyword.get(opts, :ttl)

    cache_control =
      case ttl do
        nil -> %{"type" => "ephemeral"}
        ttl -> %{"type" => "ephemeral", "ttl" => ttl}
      end

    tool_with_cache = Map.put(tool, "cache_control", cache_control)
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

      Request.new("claude-3-5-sonnet-20241022")
      |> Request.add_mcp_server(%{
        "name" => "my_server",
        "url" => "http://localhost:8080"
      })
  """
  @spec add_mcp_server(t(), map()) :: t()
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
  def set_container(%__MODULE__{} = request, container) when is_binary(container) or is_map(container) do
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
  end

  defp normalize_content(content) when is_binary(content), do: content
  defp normalize_content(content) when is_list(content), do: content
  defp normalize_content(content), do: content

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
