defmodule Claudio.MCP.ServerConfig do
  @moduledoc """
  Structured configuration for MCP servers passed to the Anthropic Messages API.

  The Anthropic API supports a server-side MCP connector where Claude connects
  to MCP servers on your behalf. This module provides a typed builder for those
  server configurations.

  ## Example

      alias Claudio.MCP.ServerConfig

      server = ServerConfig.new("my_server", "https://mcp.example.com/sse")
      |> ServerConfig.set_auth_token("bearer-token-here")
      |> ServerConfig.allow_tools(["search_*", "fetch_data"])

      request = Request.new("claude-sonnet-4-5-20250929")
      |> Request.add_mcp_server(server)
  """

  @type t :: %__MODULE__{
          type: String.t(),
          name: String.t(),
          url: String.t(),
          authorization_token: String.t() | nil,
          tool_configuration: map() | nil
        }

  defstruct [
    :type,
    :name,
    :url,
    :authorization_token,
    :tool_configuration
  ]

  @doc """
  Creates a new MCP server configuration.

  ## Parameters

    - `name` - Human-readable server name
    - `url` - The server's HTTP URL

  ## Example

      ServerConfig.new("my_server", "https://mcp.example.com/sse")
  """
  @spec new(String.t(), String.t()) :: t()
  def new(name, url) when is_binary(name) and is_binary(url) do
    %__MODULE__{
      type: "url",
      name: name,
      url: url
    }
  end

  @doc """
  Sets the authorization token for authenticating with the MCP server.

  ## Example

      ServerConfig.new("my_server", "https://mcp.example.com")
      |> ServerConfig.set_auth_token("my-bearer-token")
  """
  @spec set_auth_token(t(), String.t()) :: t()
  def set_auth_token(%__MODULE__{} = config, token) when is_binary(token) do
    %{config | authorization_token: token}
  end

  @doc """
  Sets which tools are allowed from this MCP server.

  Accepts a list of tool name patterns (supports glob-style matching).

  ## Example

      ServerConfig.new("my_server", "https://mcp.example.com")
      |> ServerConfig.allow_tools(["search_*", "fetch_data"])
  """
  @spec allow_tools(t(), list(String.t())) :: t()
  def allow_tools(%__MODULE__{} = config, patterns) when is_list(patterns) do
    tool_config = %{
      "allowed_tools" => patterns,
      "enabled" => true
    }

    %{config | tool_configuration: tool_config}
  end

  @doc """
  Converts the server configuration to a map suitable for the API payload.
  """
  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = config) do
    %{
      "type" => config.type,
      "name" => config.name,
      "url" => config.url
    }
    |> maybe_put("authorization_token", config.authorization_token)
    |> maybe_put("tool_configuration", config.tool_configuration)
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
