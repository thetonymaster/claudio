defmodule Claudio.MCP.ServerConfig do
  @moduledoc """
  Structured configuration for the Anthropic MCP connector (`mcp-client-2025-11-20`).

  The connector needs two halves in a Messages request: a server entry in
  `mcp_servers` (`to_map/1`) and an `mcp_toolset` entry in `tools` that
  references the server by name (`to_toolset/1`). `Claudio.Messages.Request.add_mcp_server/2`
  emits both and declares the beta header.

  Tool selection lives on the toolset: `allow_tools/2` (allowlist of **exact**
  tool names), `set_default_config/2`, and `configure_tool/3`.

  ## Example

      alias Claudio.MCP.ServerConfig

      server =
        ServerConfig.new("my_server", "https://mcp.example.com/sse")
        |> ServerConfig.set_auth_token("bearer-token-here")
        |> ServerConfig.allow_tools(["search_events", "fetch_data"])

      Request.new("claude-opus-5-5")
      |> Request.add_mcp_server(server)
  """

  require Logger

  @type t :: %__MODULE__{
          type: String.t(),
          name: String.t(),
          url: String.t(),
          authorization_token: String.t() | nil,
          default_config: map() | nil,
          configs: %{String.t() => map()} | nil
        }

  defstruct [
    :type,
    :name,
    :url,
    :authorization_token,
    :default_config,
    :configs
  ]

  @doc """
  Creates a new MCP server configuration.

      ServerConfig.new("my_server", "https://mcp.example.com/sse")
  """
  @spec new(String.t(), String.t()) :: t()
  def new(name, url) when is_binary(name) and is_binary(url) do
    %__MODULE__{type: "url", name: name, url: url}
  end

  @doc """
  Sets the OAuth bearer token the connector sends to the MCP server.
  """
  @spec set_auth_token(t(), String.t()) :: t()
  def set_auth_token(%__MODULE__{} = config, token) when is_binary(token) do
    %{config | authorization_token: token}
  end

  @doc """
  Allowlists tools by **exact name**: disables all tools by default and enables
  each named one. A later call replaces the allowlist (tools only an earlier call
  enabled are no longer enabled); other per-tool settings are kept.

  Raises `ArgumentError` on a name containing `*` or `?`. The connector matches
  `configs` keys literally and only logs a server-side warning for unknown
  names, so a pattern would produce a valid request with no tools enabled.

      ServerConfig.allow_tools(config, ["search_events", "fetch_data"])
  """
  @spec allow_tools(t(), [String.t()]) :: t()
  def allow_tools(%__MODULE__{} = config, names) when is_list(names) do
    Enum.each(names, &validate_exact_name!/1)

    config =
      config
      |> set_default_config(%{"enabled" => false})
      |> drop_previous_enables(names)

    Enum.reduce(names, config, &configure_tool(&2, &1, %{"enabled" => true}))
  end

  # A new allowlist replaces the old one: tools enabled by an earlier call but
  # absent from `names` lose their `"enabled" => true` (per-tool settings take
  # precedence over default_config, so leaving it would keep them on). Other
  # per-tool settings survive; an override left empty is removed.
  defp drop_previous_enables(%__MODULE__{configs: nil} = config, _names), do: config

  defp drop_previous_enables(%__MODULE__{configs: configs} = config, names) do
    configs =
      for {name, settings} <- configs, reduce: %{} do
        acc ->
          settings =
            if name not in names and settings["enabled"] == true,
              do: Map.delete(settings, "enabled"),
              else: settings

          if settings == %{}, do: acc, else: Map.put(acc, name, settings)
      end

    %{config | configs: configs}
  end

  @doc """
  Merges `settings` into the toolset's `default_config` (applies to every tool
  unless overridden per tool). Supported keys include `"enabled"` and `"defer_loading"`.
  """
  @spec set_default_config(t(), map()) :: t()
  def set_default_config(%__MODULE__{} = config, settings) when is_map(settings) do
    settings = stringify_keys(settings)
    %{config | default_config: Map.merge(config.default_config || %{}, settings)}
  end

  @doc """
  Merges `settings` into the per-tool override for `name` (an exact tool name).

      ServerConfig.configure_tool(config, "delete_all", %{"enabled" => false})
  """
  @spec configure_tool(t(), String.t(), map()) :: t()
  def configure_tool(%__MODULE__{} = config, name, settings)
      when is_binary(name) and is_map(settings) do
    settings = stringify_keys(settings)
    configs = Map.update(config.configs || %{}, name, settings, &Map.merge(&1, settings))
    %{config | configs: configs}
  end

  @doc """
  The `mcp_servers` entry for this server.
  """
  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = config) do
    %{"type" => config.type, "name" => config.name, "url" => config.url}
    |> maybe_put("authorization_token", config.authorization_token)
  end

  @doc """
  The `mcp_toolset` entry (for `tools`) that references this server.
  """
  @spec to_toolset(t()) :: map()
  def to_toolset(%__MODULE__{} = config),
    do: build_toolset(config.name, config.default_config, config.configs)

  @doc """
  Splits a raw server map into `{server_entry, toolset}`.

  A legacy `tool_configuration` key (connector `mcp-client-2025-04-04`) is
  removed from the server entry and translated onto the toolset with a
  deprecation warning. Raises `ArgumentError` when the map has neither
  `"name"` nor `:name`.
  """
  @spec split_raw(map()) :: {map(), map()}
  def split_raw(server) when is_map(server) do
    name =
      Map.get(server, "name") || Map.get(server, :name) ||
        raise ArgumentError,
              "MCP server map needs a \"name\" key (the mcp_toolset references the server " <>
                "by name); got keys #{inspect(Map.keys(server))}"

    {legacy, server} = pop_legacy(server)
    toolset = legacy_toolset(name, legacy)
    {server, toolset}
  end

  # Strips both key forms so neither leaks into the server entry; the string
  # key wins when both are present.
  defp pop_legacy(server) do
    {string_value, server} = Map.pop(server, "tool_configuration")
    {atom_value, server} = Map.pop(server, :tool_configuration)
    {string_value || atom_value, server}
  end

  defp legacy_toolset(name, nil), do: build_toolset(name, nil, nil)

  defp legacy_toolset(name, legacy) when is_map(legacy) do
    Logger.warning(
      "MCP server #{inspect(name)}: tool_configuration is deprecated " <>
        "(mcp-client-2025-04-04); translated to an mcp_toolset entry. " <>
        "Use Claudio.MCP.ServerConfig.allow_tools/2 or set_default_config/2 instead."
    )

    enabled = Map.get(legacy, "enabled", Map.get(legacy, :enabled))
    allowed = Map.get(legacy, "allowed_tools", Map.get(legacy, :allowed_tools))

    cond do
      enabled == false ->
        build_toolset(name, %{"enabled" => false}, nil)

      is_list(allowed) ->
        Enum.each(allowed, &validate_exact_name!/1)
        configs = Map.new(allowed, &{&1, %{"enabled" => true}})
        build_toolset(name, %{"enabled" => false}, configs)

      true ->
        build_toolset(name, nil, nil)
    end
  end

  defp build_toolset(name, default_config, configs) do
    %{"type" => "mcp_toolset", "mcp_server_name" => name}
    |> maybe_put("default_config", default_config)
    |> maybe_put("configs", empty_to_nil(configs))
  end

  defp validate_exact_name!(name) when is_binary(name) do
    if String.contains?(name, ["*", "?"]) do
      raise ArgumentError,
            "MCP allow_tools/2 takes exact tool names; got pattern #{inspect(name)}. " <>
              "The mcp-client-2025-11-20 connector matches configs keys literally, " <>
              "so a pattern would silently enable no tools."
    end
  end

  defp validate_exact_name!(other) do
    raise ArgumentError, "MCP allow_tools/2 takes tool name strings; got #{inspect(other)}"
  end

  # Settings are stored with string keys so atom and string forms of the same
  # setting merge (and allow_tools/2 can find a prior "enabled").
  defp stringify_keys(settings), do: Map.new(settings, fn {k, v} -> {to_string(k), v} end)

  defp empty_to_nil(map) when map == %{}, do: nil
  defp empty_to_nil(other), do: other

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
