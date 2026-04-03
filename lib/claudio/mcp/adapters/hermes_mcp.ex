defmodule Claudio.MCP.Adapters.HermesMCP do
  @moduledoc """
  Adapter for the hermes_mcp (anubis-mcp) library.

  Requires `{:hermes_mcp, "~> 0.14"}` in your dependencies.

  The client argument is a `{module, client}` tuple where `module` is the
  Hermes client module and `client` is the client reference (PID or struct).

  > **Note:** This adapter is untested without hermes_mcp installed.
  > It will return `{:error, :hermes_mcp_not_available}` if the library
  > is not available.

  ## Usage

      # Start a Hermes client (see hermes_mcp docs)
      {:ok, pid} = MyHermesClient.start_link(transport: {:stdio, command: "server"})

      # Use via the adapter with {module, client} tuple
      client = {MyHermesClient, pid}
      {:ok, tools} = Claudio.MCP.Adapters.HermesMCP.list_tools(client)
  """

  @behaviour Claudio.MCP.Client

  alias Claudio.MCP.Client.{Tool, Resource, Prompt}

  @impl true
  def list_tools({module, client}, opts \\ []) do
    with {:ok, response} <- call_client(module, client, :list_tools, [], opts) do
      tools =
        response
        |> extract_list("tools")
        |> Enum.map(&normalize_tool/1)

      {:ok, tools}
    end
  end

  @impl true
  def call_tool({module, client}, name, args, opts \\ []) do
    call_client(module, client, :call_tool, [name, args], opts)
  end

  @impl true
  def list_resources({module, client}, opts \\ []) do
    with {:ok, response} <- call_client(module, client, :list_resources, [], opts) do
      resources =
        response
        |> extract_list("resources")
        |> Enum.map(&normalize_resource/1)

      {:ok, resources}
    end
  end

  @impl true
  def read_resource({module, client}, uri, opts \\ []) do
    call_client(module, client, :read_resource, [uri], opts)
  end

  @impl true
  def list_prompts({module, client}, opts \\ []) do
    with {:ok, response} <- call_client(module, client, :list_prompts, [], opts) do
      prompts =
        response
        |> extract_list("prompts")
        |> Enum.map(&normalize_prompt/1)

      {:ok, prompts}
    end
  end

  @impl true
  def get_prompt({module, client}, name, args \\ %{}, opts \\ []) do
    call_client(module, client, :get_prompt, [name, args], opts)
  end

  @impl true
  def ping({module, client}, opts \\ []) do
    case call_client(module, client, :ping, [], opts) do
      {:ok, _} -> :ok
      :pong -> :ok
      error -> error
    end
  end

  defp call_client(module, client, function, args, _opts) do
    apply(module, function, [client | args])
  rescue
    UndefinedFunctionError ->
      {:error, :hermes_mcp_not_available}
  end

  defp extract_list(response, key) when is_map(response) do
    case Map.get(response, key) do
      nil -> Map.get(response, String.to_atom(key), [])
      value -> value
    end
  end

  defp extract_list(list, _key) when is_list(list), do: list
  defp extract_list(_, _), do: []

  defp normalize_tool(tool) when is_map(tool) do
    %Tool{
      name: get_field(tool, "name"),
      description: get_field(tool, "description"),
      input_schema: get_field(tool, "inputSchema") || get_field(tool, "input_schema") || %{}
    }
  end

  defp normalize_resource(resource) when is_map(resource) do
    %Resource{
      uri: get_field(resource, "uri"),
      name: get_field(resource, "name"),
      description: get_field(resource, "description"),
      mime_type: get_field(resource, "mimeType") || get_field(resource, "mime_type")
    }
  end

  defp normalize_prompt(prompt) when is_map(prompt) do
    %Prompt{
      name: get_field(prompt, "name"),
      description: get_field(prompt, "description"),
      arguments: get_field(prompt, "arguments") || []
    }
  end

  defp get_field(map, string_key) do
    case Map.get(map, string_key) do
      nil -> Map.get(map, String.to_atom(string_key))
      value -> value
    end
  end
end
