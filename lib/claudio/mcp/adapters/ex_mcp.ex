defmodule Claudio.MCP.Adapters.ExMCP do
  @moduledoc """
  Adapter for the ex_mcp library.

  Requires `{:ex_mcp, "~> 0.2"}` in your dependencies.

  ## Usage

      {:ok, client} = ExMCP.Client.start_link(transport: :stdio, command: "server")

      {:ok, tools} = Claudio.MCP.Adapters.ExMCP.list_tools(client)
  """

  @behaviour Claudio.MCP.Client

  alias Claudio.MCP.Client.{Tool, Resource, Prompt}

  @impl true
  def list_tools(client, opts \\ []) do
    with {:ok, response} <- do_call(:list_tools, [client, opts]) do
      tools =
        response
        |> extract_list("tools")
        |> Enum.map(&normalize_tool/1)

      {:ok, tools}
    end
  end

  @impl true
  def call_tool(client, name, args, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, 30_000)
    do_call(:call_tool, [client, name, args, timeout])
  end

  @impl true
  def list_resources(client, opts \\ []) do
    with {:ok, response} <- do_call(:list_resources, [client, opts]) do
      resources =
        response
        |> extract_list("resources")
        |> Enum.map(&normalize_resource/1)

      {:ok, resources}
    end
  end

  @impl true
  def read_resource(client, uri, opts \\ []) do
    do_call(:read_resource, [client, uri, opts])
  end

  @impl true
  def list_prompts(client, opts \\ []) do
    with {:ok, response} <- do_call(:list_prompts, [client, opts]) do
      prompts =
        response
        |> extract_list("prompts")
        |> Enum.map(&normalize_prompt/1)

      {:ok, prompts}
    end
  end

  @impl true
  def get_prompt(client, name, args \\ %{}, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, 30_000)
    do_call(:get_prompt, [client, name, args, timeout])
  end

  @impl true
  def ping(client, opts \\ []) do
    case do_call(:ping, [client, opts]) do
      {:ok, _} -> :ok
      error -> error
    end
  end

  defp do_call(function, args) do
    apply(ExMCP.Client, function, args)
  rescue
    UndefinedFunctionError ->
      {:error, :ex_mcp_not_available}
  end

  defp extract_list(response, key) when is_map(response) do
    response[key] || []
  end

  defp extract_list(list, _key) when is_list(list), do: list
  defp extract_list(_, _), do: []

  defp normalize_tool(tool) when is_map(tool) do
    %Tool{
      name: tool["name"],
      description: tool["description"],
      input_schema: tool["inputSchema"] || tool["input_schema"] || %{}
    }
  end

  defp normalize_resource(resource) when is_map(resource) do
    %Resource{
      uri: resource["uri"],
      name: resource["name"],
      description: resource["description"],
      mime_type: resource["mimeType"] || resource["mime_type"]
    }
  end

  defp normalize_prompt(prompt) when is_map(prompt) do
    %Prompt{
      name: prompt["name"],
      description: prompt["description"],
      arguments: prompt["arguments"] || []
    }
  end
end
