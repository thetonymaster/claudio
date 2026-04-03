defmodule Claudio.MCP.Adapters.MCPEx do
  @moduledoc """
  Adapter for the mcp_ex library.

  Requires `{:mcp_ex, "~> 0.3"}` in your dependencies.

  ## Usage

      {:ok, client} = MCPEx.Client.start_link(transport: :stdio, command: "server")

      {:ok, tools} = Claudio.MCP.Adapters.MCPEx.list_tools(client)
  """

  @behaviour Claudio.MCP.Client

  alias Claudio.MCP.Client.{Tool, Resource, Prompt}

  @impl true
  def list_tools(client, opts \\ []) do
    cursor = Keyword.get(opts, :cursor)

    with {:ok, response} <- do_call(:list_tools, [client, cursor]) do
      tools =
        (response[:tools] || response["tools"] || [])
        |> Enum.map(&normalize_tool/1)

      {:ok, tools}
    end
  end

  @impl true
  def call_tool(client, name, args, _opts \\ []) do
    do_call(:call_tool, [client, name, args])
  end

  @impl true
  def list_resources(client, opts \\ []) do
    cursor = Keyword.get(opts, :cursor)

    with {:ok, response} <- do_call(:list_resources, [client, cursor]) do
      resources =
        (response[:resources] || response["resources"] || [])
        |> Enum.map(&normalize_resource/1)

      {:ok, resources}
    end
  end

  @impl true
  def read_resource(client, uri, _opts \\ []) do
    do_call(:read_resource, [client, uri])
  end

  @impl true
  def list_prompts(client, opts \\ []) do
    cursor = Keyword.get(opts, :cursor)

    with {:ok, response} <- do_call(:list_prompts, [client, cursor]) do
      prompts =
        (response[:prompts] || response["prompts"] || [])
        |> Enum.map(&normalize_prompt/1)

      {:ok, prompts}
    end
  end

  @impl true
  def get_prompt(client, name, args \\ %{}, _opts \\ []) do
    do_call(:get_prompt, [client, name, args])
  end

  @impl true
  def ping(client, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, 5_000)

    case do_call(:ping, [client, timeout]) do
      {:ok, _} -> :ok
      error -> error
    end
  end

  defp do_call(function, args) do
    apply(MCPEx.Client, function, args)
  rescue
    UndefinedFunctionError ->
      {:error, :mcp_ex_not_available}
  end

  defp normalize_tool(tool) when is_map(tool) do
    %Tool{
      name: get_field(tool, :name, "name"),
      description: get_field(tool, :description, "description"),
      input_schema:
        get_field(tool, :inputSchema, "inputSchema") ||
          get_field(tool, :input_schema, "input_schema") || %{}
    }
  end

  defp normalize_resource(resource) when is_map(resource) do
    %Resource{
      uri: get_field(resource, :uri, "uri"),
      name: get_field(resource, :name, "name"),
      description: get_field(resource, :description, "description"),
      mime_type:
        get_field(resource, :mimeType, "mimeType") ||
          get_field(resource, :mime_type, "mime_type")
    }
  end

  defp normalize_prompt(prompt) when is_map(prompt) do
    %Prompt{
      name: get_field(prompt, :name, "name"),
      description: get_field(prompt, :description, "description"),
      arguments: get_field(prompt, :arguments, "arguments") || []
    }
  end

  defp get_field(map, atom_key, string_key) do
    map[atom_key] || map[string_key]
  end
end
