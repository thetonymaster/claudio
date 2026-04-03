defmodule Claudio.MCP.ToolAdapter do
  @moduledoc """
  Bridges MCP tools into Claudio request format.

  Converts `Claudio.MCP.Client.Tool` structs (from any adapter) into the tool
  map format used by `Claudio.Messages.Request.add_tool/2`.

  ## Example

      {:ok, tools} = MyAdapter.list_tools(client)

      request = Request.new("claude-sonnet-4-5-20250929")
      |> Claudio.MCP.ToolAdapter.add_tools(tools)

      # With server prefix for disambiguation:
      |> Claudio.MCP.ToolAdapter.add_tools(tools, prefix: "my_server")
  """

  alias Claudio.MCP.Client.Tool
  alias Claudio.Messages.Request

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

    %{
      "name" => name,
      "description" => tool.description,
      "input_schema" => tool.input_schema
    }
  end
end
