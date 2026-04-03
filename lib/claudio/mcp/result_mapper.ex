defmodule Claudio.MCP.ResultMapper do
  @moduledoc """
  Maps tool use blocks from Claudio responses back to MCP call format.

  After Claude responds with tool_use or mcp_tool_use blocks, this module
  extracts them into a format suitable for calling back to MCP servers.

  ## Example

      response = Claudio.Messages.create(client, request)
      calls = Claudio.MCP.ResultMapper.extract_mcp_calls(response)

      results = Enum.map(calls, fn call ->
        {:ok, result} = MyAdapter.call_tool(mcp_client, call.name, call.arguments)
        Claudio.Tools.create_tool_result(call.id, result)
      end)
  """

  alias Claudio.Messages.Response

  @type mcp_call :: %{
          id: String.t(),
          name: String.t(),
          arguments: map(),
          server_name: String.t() | nil
        }

  @doc """
  Extracts MCP tool calls from a response.

  Handles both `mcp_tool_use` blocks (from server-side MCP connector) and
  regular `tool_use` blocks with prefixed names (from client-side MCP tools).

  **Note:** Regular `tool_use` blocks are identified as MCP calls when their name
  contains `__` (double underscore) as a separator — e.g., `server_name__tool_name`.
  If you define non-MCP tools with `__` in their names, they will be incorrectly
  captured. Use `mcp_tool_use` blocks (from the server-side MCP connector) or avoid
  `__` in regular tool names to prevent ambiguity.
  """
  @spec extract_mcp_calls(Response.t()) :: [mcp_call()]
  def extract_mcp_calls(%Response{content: content}) do
    content
    |> Enum.flat_map(&extract_call/1)
  end

  @doc """
  Extracts MCP tool calls for a specific server.
  """
  @spec extract_mcp_calls(Response.t(), String.t()) :: [mcp_call()]
  def extract_mcp_calls(%Response{} = response, server_name) when is_binary(server_name) do
    response
    |> extract_mcp_calls()
    |> Enum.filter(&(&1.server_name == server_name))
  end

  defp extract_call(%{type: :mcp_tool_use} = block) do
    [
      %{
        id: block.id,
        name: block.name,
        arguments: block.input,
        server_name: block.server_name
      }
    ]
  end

  defp extract_call(%{type: :tool_use, name: name} = block) do
    case parse_prefixed_name(name) do
      {server, tool_name} ->
        [
          %{
            id: block.id,
            name: tool_name,
            arguments: block.input,
            server_name: server
          }
        ]

      nil ->
        []
    end
  end

  defp extract_call(_), do: []

  defp parse_prefixed_name(name) when is_binary(name) do
    case String.split(name, "__", parts: 2) do
      [prefix, tool_name] when prefix != "" and tool_name != "" ->
        {prefix, tool_name}

      _ ->
        nil
    end
  end
end
