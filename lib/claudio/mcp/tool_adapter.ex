defmodule Claudio.MCP.ToolAdapter do
  @moduledoc """
  Bridges MCP tools into Claudio request format.

  Converts `Claudio.MCP.Client.Tool` structs (from any adapter) into the tool
  map format used by `Claudio.Messages.Request.add_tool/2`.

  ## Example

      {:ok, tools} = MyAdapter.list_tools(client)

      request = Request.new("claude-opus-5-5")
      |> Claudio.MCP.ToolAdapter.add_tools(tools)

      # With server prefix for disambiguation:
      |> Claudio.MCP.ToolAdapter.add_tools(tools, prefix: "my_server")
  """

  alias Claudio.MCP.Client.Tool
  alias Claudio.Messages.Request

  # Tool names the Messages API accepts (probed 2026-09-26).
  @tool_name ~r/^[a-zA-Z0-9_-]{1,128}$/

  @doc """
  Converts a list of MCP tools and adds them to a request.

  ## Options

    - `:prefix` - Prefix tool names with a server name (e.g., `"my_server"` → `"my_server__search"`)
  """
  @spec add_tools(Request.t(), [Tool.t()], keyword()) :: Request.t()
  def add_tools(%Request{} = request, tools, opts \\ []) when is_list(tools) do
    prefix = Keyword.get(opts, :prefix)

    Enum.reduce(tools, request, fn tool, req ->
      Request.add_tool(req, to_claudio_tool(tool, prefix))
    end)
  end

  @doc """
  Converts a single MCP tool to the Claudio tool map format.
  """
  @spec to_claudio_tool(Tool.t(), String.t() | nil) :: map()
  def to_claudio_tool(%Tool{} = tool, prefix \\ nil) do
    name =
      case prefix do
        nil -> tool.name
        p -> "#{p}__#{tool.name}"
      end

    # The API rejects other names; renaming would break mapping calls back to MCP.
    unless is_binary(name) and Regex.match?(@tool_name, name) do
      raise ArgumentError,
            "Claudio.MCP.ToolAdapter: tool name #{inspect(name)} must match " <>
              "^[a-zA-Z0-9_-]{1,128}$ (the Anthropic API rejects anything else)"
    end

    %{"name" => name, "input_schema" => with_object_type(tool.input_schema)}
    |> put_description(tool.description)
  end

  # MCP descriptions are optional, but the API rejects `"description": null`.
  defp put_description(map, description) when is_binary(description),
    do: Map.put(map, "description", description)

  defp put_description(map, _description), do: map

  # MCP schemas may omit "type"; the API requires it on input_schema.
  defp with_object_type(schema) when is_map(schema) do
    if Map.has_key?(schema, "type") or Map.has_key?(schema, :type),
      do: schema,
      else: Map.put(schema, "type", "object")
  end

  defp with_object_type(_schema), do: %{"type" => "object"}

  @doc "Alias for `to_claudio_tool/2`."
  @spec mcp_to_claudio(Tool.t(), String.t() | nil) :: map()
  def mcp_to_claudio(tool, prefix \\ nil), do: to_claudio_tool(tool, prefix)
end
