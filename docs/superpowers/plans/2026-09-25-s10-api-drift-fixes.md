# S10 API Drift Fixes Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make Claudio's MCP-connector requests valid under `mcp-client-2025-11-20`, reflect Files/Skills GA, default code execution to `code_execution_20260521`, surface `stop_details`, and fix stale docs.

**Architecture:** All MCP wire-shape knowledge lives in `Claudio.MCP.ServerConfig` (server entry, toolset entry, legacy `tool_configuration` translation); `Request.add_mcp_server/2` only appends the two halves and declares the beta through the existing `add_beta/2`. Files/Skills changes are option/header plumbing in their own modules. `stop_details` is a raw pass-through field on `Response` and the stream accumulator.

**Tech Stack:** Elixir ≥ 1.15, Req, Jason, Bypass + ExUnit (`async: true`), `ExUnit.CaptureLog`.

**Spec:** `docs/superpowers/specs/2026-09-25-s10-api-drift-fixes-design.md`

## Global Constraints

- MCP beta string: `mcp-client-2025-11-20` (exactly; declared via `Request.add_beta/2`, never on the client).
- Toolset entry: `%{"type" => "mcp_toolset", "mcp_server_name" => name}` plus optional `"default_config"` / `"configs"`; `configs` keys are **exact tool names**.
- `allow_tools/2` raises `ArgumentError` on any name containing `*` or `?`, message: `MCP allow_tools/2 takes exact tool names; got pattern "search_*". The mcp-client-2025-11-20 connector matches configs keys literally, so a pattern would silently enable no tools.`
- Code execution versions: `:"20260521"` (default) `| :"20260120" | :"20250825"`; anything else raises `ArgumentError`.
- No model-aware validation anywhere (library stays model-agnostic; the API validates).
- No existing public function signature changes. Removing `ServerConfig`'s `:tool_configuration` struct field is the one intentional struct change.
- Commits: add files individually (never `git add .`); no AI attribution lines in commit messages.
- Done = `mix test` green, `mix format --check-formatted` clean, `mix compile --warnings-as-errors` clean. Baseline before this plan: 282 tests, 0 failures, 25 excluded.
- Work on branch `feat/s10-api-drift` created from `docs/s10-api-drift-spec`.

## Review Focus

1. **Two MCP servers on one request** — expect two toolsets (one per server) and `mcp-client-2025-11-20` in `required_betas/1` exactly once. → Task 2, test "two servers".
2. **`allow_tools([])`** — expect a toolset with `default_config: %{"enabled" => false}` and **no** `"configs"` key (zero tools enabled, same meaning as the old empty allowlist). → Task 1, test "empty allowlist".
3. **Atom-keyed raw server map** `%{name: "x", url: "https://..."}` — expect a toolset for `"x"`, not an `ArgumentError`. → Task 2, test "atom-keyed raw map".
4. **`Files.list(client, ids: [])`** — expect no `ids[]` parameter on the wire (empty query string), not `ids[]=`. → Task 3, test "empty ids".
5. **Atom-keyed response body with `stop_details:`** (`Response.from_map/1` accepts atom keys everywhere else) — expect it preserved. → Task 6, test "atom-keyed stop_details".

---

### Task 0: Branch

- [ ] **Step 1: Create the implementation branch**

```bash
git checkout docs/s10-api-drift-spec
git checkout -b feat/s10-api-drift
```

Expected: `Switched to a new branch 'feat/s10-api-drift'`.

---

### Task 1: `ServerConfig` — toolset shape

**Files:**
- Modify: `lib/claudio/mcp/server_config.ex` (whole module)
- Test: `test/mcp/server_config_test.exs` (whole file rewritten)

**Interfaces:**
- Produces:
  - `%ServerConfig{type, name, url, authorization_token, default_config :: map() | nil, configs :: %{String.t() => map()} | nil}` (no `:tool_configuration`)
  - `ServerConfig.allow_tools(t(), [String.t()]) :: t()` — raises `ArgumentError` on patterns / non-strings
  - `ServerConfig.set_default_config(t(), map()) :: t()` — merges
  - `ServerConfig.configure_tool(t(), String.t(), map()) :: t()` — merges into `configs[name]`
  - `ServerConfig.to_map(t()) :: map()` — server entry only
  - `ServerConfig.to_toolset(t()) :: map()` — `mcp_toolset` entry
  - `ServerConfig.split_raw(map()) :: {server_map :: map(), toolset :: map()}` — strips + translates legacy `tool_configuration` (logs a warning), raises `ArgumentError` when no `"name"`/`:name`

- [ ] **Step 1: Write the failing tests** — replace `test/mcp/server_config_test.exs` entirely:

```elixir
defmodule Claudio.MCP.ServerConfigTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias Claudio.MCP.ServerConfig

  describe "new/2" do
    test "creates a server config with type, name, and url" do
      config = ServerConfig.new("my_server", "https://mcp.example.com/sse")

      assert config.type == "url"
      assert config.name == "my_server"
      assert config.url == "https://mcp.example.com/sse"
      assert config.authorization_token == nil
      assert config.default_config == nil
      assert config.configs == nil
      refute Map.has_key?(config, :tool_configuration)
    end
  end

  describe "set_auth_token/2" do
    test "sets the authorization token" do
      config =
        ServerConfig.new("my_server", "https://mcp.example.com")
        |> ServerConfig.set_auth_token("my-token")

      assert config.authorization_token == "my-token"
    end
  end

  describe "allow_tools/2" do
    test "disables by default and enables each named tool" do
      config =
        ServerConfig.new("s", "https://mcp.example.com")
        |> ServerConfig.allow_tools(["search_events", "fetch_data"])

      assert config.default_config == %{"enabled" => false}

      assert config.configs == %{
               "search_events" => %{"enabled" => true},
               "fetch_data" => %{"enabled" => true}
             }
    end

    test "empty allowlist disables everything and emits no configs key" do
      toolset =
        ServerConfig.new("s", "https://mcp.example.com")
        |> ServerConfig.allow_tools([])
        |> ServerConfig.to_toolset()

      assert toolset == %{
               "type" => "mcp_toolset",
               "mcp_server_name" => "s",
               "default_config" => %{"enabled" => false}
             }
    end

    test "raises on a * pattern, naming the pattern" do
      error =
        assert_raise ArgumentError, fn ->
          ServerConfig.new("s", "https://x") |> ServerConfig.allow_tools(["search_*"])
        end

      assert error.message ==
               "MCP allow_tools/2 takes exact tool names; got pattern \"search_*\". " <>
                 "The mcp-client-2025-11-20 connector matches configs keys literally, " <>
                 "so a pattern would silently enable no tools."
    end

    test "raises on a ? pattern" do
      assert_raise ArgumentError, ~r/got pattern "tool_\?"/, fn ->
        ServerConfig.new("s", "https://x") |> ServerConfig.allow_tools(["tool_?"])
      end
    end

    test "raises on a non-string name" do
      assert_raise ArgumentError, ~r/takes tool name strings; got :search/, fn ->
        ServerConfig.new("s", "https://x") |> ServerConfig.allow_tools([:search])
      end
    end
  end

  describe "set_default_config/2 and configure_tool/3" do
    test "merge into existing config" do
      config =
        ServerConfig.new("s", "https://x")
        |> ServerConfig.allow_tools(["a"])
        |> ServerConfig.set_default_config(%{"defer_loading" => true})
        |> ServerConfig.configure_tool("a", %{"defer_loading" => false})
        |> ServerConfig.configure_tool("b", %{"enabled" => false})

      assert config.default_config == %{"enabled" => false, "defer_loading" => true}

      assert config.configs == %{
               "a" => %{"enabled" => true, "defer_loading" => false},
               "b" => %{"enabled" => false}
             }
    end
  end

  describe "to_map/1" do
    test "converts minimal config to the server entry" do
      map = ServerConfig.new("my_server", "https://mcp.example.com") |> ServerConfig.to_map()

      assert map == %{"type" => "url", "name" => "my_server", "url" => "https://mcp.example.com"}
    end

    test "includes authorization_token when set" do
      map =
        ServerConfig.new("my_server", "https://mcp.example.com")
        |> ServerConfig.set_auth_token("token-123")
        |> ServerConfig.to_map()

      assert map["authorization_token"] == "token-123"
    end

    test "never includes tool configuration (it lives on the toolset)" do
      map =
        ServerConfig.new("my_server", "https://mcp.example.com")
        |> ServerConfig.allow_tools(["search"])
        |> ServerConfig.to_map()

      refute Map.has_key?(map, "tool_configuration")
      refute Map.has_key?(map, "default_config")
      refute Map.has_key?(map, "configs")
    end
  end

  describe "to_toolset/1" do
    test "bare toolset when nothing is configured" do
      assert ServerConfig.new("s", "https://x") |> ServerConfig.to_toolset() ==
               %{"type" => "mcp_toolset", "mcp_server_name" => "s"}
    end

    test "allowlist toolset" do
      assert ServerConfig.new("s", "https://x")
             |> ServerConfig.allow_tools(["a"])
             |> ServerConfig.to_toolset() == %{
               "type" => "mcp_toolset",
               "mcp_server_name" => "s",
               "default_config" => %{"enabled" => false},
               "configs" => %{"a" => %{"enabled" => true}}
             }
    end
  end

  describe "split_raw/1" do
    test "plain raw map yields the map and a bare toolset" do
      assert ServerConfig.split_raw(%{"type" => "url", "name" => "raw", "url" => "https://x"}) ==
               {%{"type" => "url", "name" => "raw", "url" => "https://x"},
                %{"type" => "mcp_toolset", "mcp_server_name" => "raw"}}
    end

    test "atom-keyed raw map uses :name" do
      {server, toolset} = ServerConfig.split_raw(%{name: "atomy", url: "https://x"})
      assert server == %{name: "atomy", url: "https://x"}
      assert toolset == %{"type" => "mcp_toolset", "mcp_server_name" => "atomy"}
    end

    test "raises when the map has no name" do
      assert_raise ArgumentError, ~r/needs a "name" key/, fn ->
        ServerConfig.split_raw(%{"url" => "https://x"})
      end
    end

    test "legacy enabled: true with no allowlist -> bare toolset, field stripped, warning logged" do
      log =
        capture_log(fn ->
          {server, toolset} =
            ServerConfig.split_raw(%{
              "name" => "s",
              "url" => "https://x",
              "tool_configuration" => %{"enabled" => true}
            })

          assert server == %{"name" => "s", "url" => "https://x"}
          assert toolset == %{"type" => "mcp_toolset", "mcp_server_name" => "s"}
        end)

      assert log =~ "tool_configuration is deprecated"
    end

    test "legacy enabled: false -> default_config disabled (allowlist ignored)" do
      capture_log(fn ->
        {_server, toolset} =
          ServerConfig.split_raw(%{
            "name" => "s",
            "url" => "https://x",
            "tool_configuration" => %{"enabled" => false, "allowed_tools" => ["a"]}
          })

        assert toolset == %{
                 "type" => "mcp_toolset",
                 "mcp_server_name" => "s",
                 "default_config" => %{"enabled" => false}
               }
      end)
    end

    test "legacy allowed_tools -> allowlist toolset" do
      capture_log(fn ->
        {_server, toolset} =
          ServerConfig.split_raw(%{
            "name" => "s",
            "url" => "https://x",
            "tool_configuration" => %{"enabled" => true, "allowed_tools" => ["a", "b"]}
          })

        assert toolset == %{
                 "type" => "mcp_toolset",
                 "mcp_server_name" => "s",
                 "default_config" => %{"enabled" => false},
                 "configs" => %{"a" => %{"enabled" => true}, "b" => %{"enabled" => true}}
               }
      end)
    end

    test "legacy allowed_tools with a pattern raises" do
      capture_log(fn ->
        assert_raise ArgumentError, ~r/got pattern "search_\*"/, fn ->
          ServerConfig.split_raw(%{
            "name" => "s",
            "url" => "https://x",
            "tool_configuration" => %{"allowed_tools" => ["search_*"]}
          })
        end
      end)
    end
  end
end
```

- [ ] **Step 2: Run to verify failure**

Run: `mix test test/mcp/server_config_test.exs`
Expected: FAIL — compile/undefined errors for `to_toolset/1`, `split_raw/1`, `set_default_config/2`, `configure_tool/3`, and assertion failures on `allow_tools/2`.

- [ ] **Step 3: Implement** — replace `lib/claudio/mcp/server_config.ex` entirely:

```elixir
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

      Request.new("claude-opus-5")
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
  each named one.

  Raises `ArgumentError` on a name containing `*` or `?`. The connector matches
  `configs` keys literally and only logs a server-side warning for unknown
  names, so a pattern would produce a valid request with no tools enabled.

      ServerConfig.allow_tools(config, ["search_events", "fetch_data"])
  """
  @spec allow_tools(t(), [String.t()]) :: t()
  def allow_tools(%__MODULE__{} = config, names) when is_list(names) do
    Enum.each(names, &validate_exact_name!/1)

    config = set_default_config(config, %{"enabled" => false})
    Enum.reduce(names, config, &configure_tool(&2, &1, %{"enabled" => true}))
  end

  @doc """
  Merges `settings` into the toolset's `default_config` (applies to every tool
  unless overridden per tool). Supported keys include `"enabled"` and `"defer_loading"`.
  """
  @spec set_default_config(t(), map()) :: t()
  def set_default_config(%__MODULE__{} = config, settings) when is_map(settings) do
    %{config | default_config: Map.merge(config.default_config || %{}, settings)}
  end

  @doc """
  Merges `settings` into the per-tool override for `name` (an exact tool name).

      ServerConfig.configure_tool(config, "delete_all", %{"enabled" => false})
  """
  @spec configure_tool(t(), String.t(), map()) :: t()
  def configure_tool(%__MODULE__{} = config, name, settings)
      when is_binary(name) and is_map(settings) do
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
  def to_toolset(%__MODULE__{} = config) do
    %{"type" => "mcp_toolset", "mcp_server_name" => config.name}
    |> maybe_put("default_config", config.default_config)
    |> maybe_put("configs", empty_to_nil(config.configs))
  end

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
    toolset = %__MODULE__{name: name} |> apply_legacy(legacy) |> to_toolset()
    {server, toolset}
  end

  defp pop_legacy(server) do
    case Map.pop(server, "tool_configuration") do
      {nil, server} -> Map.pop(server, :tool_configuration)
      found -> found
    end
  end

  defp apply_legacy(config, nil), do: config

  defp apply_legacy(config, legacy) when is_map(legacy) do
    Logger.warning(
      "MCP server #{inspect(config.name)}: tool_configuration is deprecated " <>
        "(mcp-client-2025-04-04); translated to an mcp_toolset entry. " <>
        "Use Claudio.MCP.ServerConfig.allow_tools/2 or set_default_config/2 instead."
    )

    enabled = Map.get(legacy, "enabled", Map.get(legacy, :enabled))
    allowed = Map.get(legacy, "allowed_tools", Map.get(legacy, :allowed_tools))

    cond do
      enabled == false -> set_default_config(config, %{"enabled" => false})
      is_list(allowed) -> allow_tools(config, allowed)
      true -> config
    end
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

  defp empty_to_nil(map) when map == %{}, do: nil
  defp empty_to_nil(other), do: other

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
```

- [ ] **Step 4: Run to verify pass**

Run: `mix test test/mcp/server_config_test.exs`
Expected: PASS (all tests). `test/mcp/request_mcp_test.exs` will now fail on its `tool_configuration` assertion — fixed in Task 2; do not touch it here.

- [ ] **Step 5: Commit**

```bash
git add lib/claudio/mcp/server_config.ex test/mcp/server_config_test.exs
git commit -m "feat(mcp): ServerConfig emits mcp_toolset (mcp-client-2025-11-20); exact-name allowlist"
```

---

### Task 2: `Request.add_mcp_server/2` — both halves + beta

**Files:**
- Modify: `lib/claudio/messages/request.ex` (the `add_mcp_server` doc + both clauses, currently ~lines 486–507)
- Test: `test/mcp/request_mcp_test.exs` (whole file rewritten)

**Interfaces:**
- Consumes: `ServerConfig.to_map/1`, `ServerConfig.to_toolset/1`, `ServerConfig.split_raw/1` (Task 1); existing `Request.add_tool/2`, `Request.add_beta/2`, `Request.required_betas/1`.
- Produces: `Request.add_mcp_server(t(), ServerConfig.t() | map()) :: t()` — appends server to `mcp_servers`, appends toolset to `tools` unless one for that server name already exists, declares `mcp-client-2025-11-20`.

- [ ] **Step 1: Write the failing tests** — replace `test/mcp/request_mcp_test.exs` entirely:

```elixir
defmodule Claudio.Messages.Request.MCPTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias Claudio.Messages.Request
  alias Claudio.MCP.ServerConfig

  @beta "mcp-client-2025-11-20"

  describe "add_mcp_server/2 with ServerConfig" do
    test "adds the server entry, a matching toolset, and the beta" do
      server = ServerConfig.new("my_server", "https://mcp.example.com/sse")

      request = Request.new("claude-opus-5") |> Request.add_mcp_server(server)
      map = Request.to_map(request)

      assert map["mcp_servers"] == [
               %{"type" => "url", "name" => "my_server", "url" => "https://mcp.example.com/sse"}
             ]

      assert map["tools"] == [%{"type" => "mcp_toolset", "mcp_server_name" => "my_server"}]
      assert Request.required_betas(request) == [@beta]
    end

    test "auth token stays on the server; allowlist goes on the toolset" do
      server =
        ServerConfig.new("secure", "https://mcp.example.com")
        |> ServerConfig.set_auth_token("my-token")
        |> ServerConfig.allow_tools(["search_events"])

      map = Request.new("claude-opus-5") |> Request.add_mcp_server(server) |> Request.to_map()

      [server_map] = map["mcp_servers"]
      assert server_map["authorization_token"] == "my-token"
      refute Map.has_key?(server_map, "tool_configuration")

      assert [
               %{
                 "type" => "mcp_toolset",
                 "mcp_server_name" => "secure",
                 "default_config" => %{"enabled" => false},
                 "configs" => %{"search_events" => %{"enabled" => true}}
               }
             ] = map["tools"]
    end

    test "two servers -> two toolsets, beta declared once" do
      request =
        Request.new("claude-opus-5")
        |> Request.add_mcp_server(ServerConfig.new("a", "https://a.example.com"))
        |> Request.add_mcp_server(ServerConfig.new("b", "https://b.example.com"))

      map = Request.to_map(request)
      assert length(map["mcp_servers"]) == 2
      assert Enum.map(map["tools"], & &1["mcp_server_name"]) == ["a", "b"]
      assert Request.required_betas(request) == [@beta]
    end

    test "toolset is appended after tools already on the request" do
      map =
        Request.new("claude-opus-5")
        |> Request.add_tool(%{"name" => "local", "input_schema" => %{"type" => "object"}})
        |> Request.add_mcp_server(ServerConfig.new("s", "https://x.example.com"))
        |> Request.to_map()

      assert [%{"name" => "local"}, %{"type" => "mcp_toolset"}] = map["tools"]
    end
  end

  describe "add_mcp_server/2 with a raw map" do
    test "string-keyed map gets a toolset and the beta" do
      request =
        Request.new("claude-opus-5")
        |> Request.add_mcp_server(%{"type" => "url", "name" => "raw", "url" => "https://x"})

      map = Request.to_map(request)
      assert [%{"name" => "raw"}] = map["mcp_servers"]
      assert map["tools"] == [%{"type" => "mcp_toolset", "mcp_server_name" => "raw"}]
      assert Request.required_betas(request) == [@beta]
    end

    test "atom-keyed raw map gets a toolset for :name" do
      map =
        Request.new("claude-opus-5")
        |> Request.add_mcp_server(%{type: "url", name: "atomy", url: "https://x"})
        |> Request.to_map()

      assert map["tools"] == [%{"type" => "mcp_toolset", "mcp_server_name" => "atomy"}]
    end

    test "does not duplicate a hand-built toolset for the same server" do
      hand_built = %{
        "type" => "mcp_toolset",
        "mcp_server_name" => "raw",
        "default_config" => %{"defer_loading" => true}
      }

      map =
        Request.new("claude-opus-5")
        |> Request.add_tool(hand_built)
        |> Request.add_mcp_server(%{"type" => "url", "name" => "raw", "url" => "https://x"})
        |> Request.to_map()

      assert map["tools"] == [hand_built]
    end

    test "legacy tool_configuration is translated, stripped, and warned about" do
      log =
        capture_log(fn ->
          map =
            Request.new("claude-opus-5")
            |> Request.add_mcp_server(%{
              "type" => "url",
              "name" => "legacy",
              "url" => "https://x",
              "tool_configuration" => %{"enabled" => true, "allowed_tools" => ["a"]}
            })
            |> Request.to_map()

          [server_map] = map["mcp_servers"]
          refute Map.has_key?(server_map, "tool_configuration")

          assert map["tools"] == [
                   %{
                     "type" => "mcp_toolset",
                     "mcp_server_name" => "legacy",
                     "default_config" => %{"enabled" => false},
                     "configs" => %{"a" => %{"enabled" => true}}
                   }
                 ]
        end)

      assert log =~ "tool_configuration is deprecated"
    end

    test "raw map without a name raises" do
      assert_raise ArgumentError, ~r/needs a "name" key/, fn ->
        Request.new("claude-opus-5") |> Request.add_mcp_server(%{"url" => "https://x"})
      end
    end

    test "mixes ServerConfig and raw maps" do
      map =
        Request.new("claude-opus-5")
        |> Request.add_mcp_server(ServerConfig.new("typed", "https://mcp.example.com"))
        |> Request.add_mcp_server(%{"name" => "raw", "url" => "https://x"})
        |> Request.to_map()

      assert length(map["mcp_servers"]) == 2
      assert Enum.map(map["tools"], & &1["mcp_server_name"]) == ["typed", "raw"]
    end
  end
end
```

- [ ] **Step 2: Run to verify failure**

Run: `mix test test/mcp/request_mcp_test.exs`
Expected: FAIL — `map["tools"]` is `nil` and `required_betas` is `[]` in the new assertions.

- [ ] **Step 3: Implement** — in `lib/claudio/messages/request.ex`, replace the whole `@doc` for `add_mcp_server` and both clauses (from the `@doc """` above `@spec add_mcp_server` through the end of the raw-map clause) with:

```elixir
  @doc """
  Adds a server for the MCP connector (`mcp-client-2025-11-20`).

  Emits both halves the API requires: the server entry in `mcp_servers` and an
  `mcp_toolset` entry in `tools` referencing it by name. Declares the
  `mcp-client-2025-11-20` beta via `add_beta/2`.

  Accepts a `Claudio.MCP.ServerConfig` or a raw map. For a raw map, no toolset
  is added when `tools` already holds an `mcp_toolset` for that server name
  (the API rejects two toolsets for one server); a legacy `tool_configuration`
  key is translated onto the toolset with a deprecation warning. Add hand-built
  toolsets **before** calling this, or the request will carry two.

      Request.new("claude-opus-5")
      |> Request.add_mcp_server(
        Claudio.MCP.ServerConfig.new("my_server", "https://mcp.example.com/sse")
      )
  """
  @spec add_mcp_server(t(), Claudio.MCP.ServerConfig.t() | map()) :: t()
  def add_mcp_server(%__MODULE__{} = request, %Claudio.MCP.ServerConfig{} = server) do
    put_mcp_server(
      request,
      Claudio.MCP.ServerConfig.to_map(server),
      Claudio.MCP.ServerConfig.to_toolset(server)
    )
  end

  def add_mcp_server(%__MODULE__{} = request, server) when is_map(server) do
    {server_map, toolset} = Claudio.MCP.ServerConfig.split_raw(server)
    put_mcp_server(request, server_map, toolset)
  end

  defp put_mcp_server(%__MODULE__{mcp_servers: servers} = request, server_map, toolset) do
    request = %{request | mcp_servers: (servers || []) ++ [server_map]}

    request =
      if has_mcp_toolset?(request.tools, toolset["mcp_server_name"]),
        do: request,
        else: add_tool(request, toolset)

    add_beta(request, "mcp-client-2025-11-20")
  end

  defp has_mcp_toolset?(tools, server_name) do
    Enum.any?(tools || [], fn tool ->
      (tool["type"] || tool[:type]) == "mcp_toolset" and
        (tool["mcp_server_name"] || tool[:mcp_server_name]) == server_name
    end)
  end
```

- [ ] **Step 4: Run to verify pass**

Run: `mix test test/mcp/`
Expected: PASS (all files in `test/mcp/`).

- [ ] **Step 5: Run the whole suite** (other tests build requests)

Run: `mix test`
Expected: 0 failures.

- [ ] **Step 6: Commit**

```bash
git add lib/claudio/messages/request.ex test/mcp/request_mcp_test.exs
git commit -m "fix(mcp): add_mcp_server emits mcp_toolset + declares mcp-client-2025-11-20"
```

---

### Task 3: Files — GA pagination options + docs

**Files:**
- Modify: `lib/claudio/files.ex` (moduledoc "Beta gating" section ~lines 9–22; `list/2` doc ~lines 45–65; `upload/3` doc line mentioning the beta ~line 89–90; `build_query_params/1` ~lines 238–243)
- Test: `test/files_test.exs` (append to `describe "list/2 query params"`)

**Interfaces:**
- Produces: `Files.list(client, opts)` accepts `:limit`, `:page` (string), `:ids` (list of strings, sent as repeated `ids[]`), `:before_id`, `:after_id`.

- [ ] **Step 1: Write the failing tests** — add inside `describe "list/2 query params"` in `test/files_test.exs`:

```elixir
    test "passes :page and repeats ids[] in order", %{client: client, bypass: bypass} do
      Bypass.expect_once(bypass, "GET", "/files", fn conn ->
        # URI.decode_query collapses repeated keys, so read the raw pairs
        pairs = conn.query_string |> URI.query_decoder() |> Enum.to_list()
        assert pairs == [{"page", "pg_2"}, {"ids[]", "file_a"}, {"ids[]", "file_b"}]

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, Jason.encode!(%{"data" => [], "next_page" => nil}))
      end)

      assert {:ok, %{"data" => [], "next_page" => nil}} =
               Claudio.Files.list(client, page: "pg_2", ids: ["file_a", "file_b"])
    end

    test "empty ids sends no ids[] parameter", %{client: client, bypass: bypass} do
      Bypass.expect_once(bypass, "GET", "/files", fn conn ->
        assert conn.query_string == ""

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, Jason.encode!(%{"data" => [], "next_page" => nil}))
      end)

      assert {:ok, _} = Claudio.Files.list(client, ids: [])
    end
```

- [ ] **Step 2: Run to verify failure**

Run: `mix test test/files_test.exs`
Expected: FAIL — the first new test sees an empty query (options ignored). (The empty-ids test may already pass; that's fine.)

- [ ] **Step 3: Implement** — replace `build_query_params/1` and delete the now-unused `maybe_add_param/3` clauses:

```elixir
  defp build_query_params(opts) do
    scalars =
      for key <- [:limit, :page, :before_id, :after_id],
          Keyword.get(opts, key) != nil,
          do: {key, Keyword.get(opts, key)}

    scalars ++ Enum.map(Keyword.get(opts, :ids, []), &{"ids[]", &1})
  end
```

- [ ] **Step 4: Update docs** in `lib/claudio/files.ex`:

Replace the moduledoc `## Beta gating` section (heading through the `default_beta_features` config example) with:

```markdown
  ## GA — no beta header

  The Files API is generally available; no `anthropic-beta` header is needed.
  Responses without the header use the GA shapes: `list/2` returns
  `%{"data" => [...], "next_page" => cursor | nil}` and pages with `:page`
  (or fetches up to 100 known ids with `:ids`); `before_id`/`after_id` return 400.

  Callers that still put `files-api-2025-04-14` on their client keep the old
  beta shapes (`has_more`/`first_id`/`last_id`, `:before_id`/`:after_id`
  cursors, no `expires_at`) — Claudio passes whatever you choose through.
```

Replace the `list/2` doc's `## Beta gating` paragraph + `## Parameters` options + `## Returns` first bullet with:

```markdown
  ## Parameters

    * `client` — A `Req.Request` from `Claudio.Client.new/2`.
    * `opts` — Optional keyword list:
        * `:limit` — Files per page (server default 20, max 1000).
        * `:page` — Cursor from a previous response's `"next_page"`.
        * `:ids` — Up to 100 file ids, sent as repeated `ids[]`; returns a single page.
          Not combinable with `:page`/`:limit` (the API rejects it).
        * `:before_id` / `:after_id` — Legacy cursors; only valid when the client
          sends the `files-api-2025-04-14` beta header.

  ## Returns

    * `{:ok, %{"data" => [...], "next_page" => _}}` (GA) or
      `{:ok, %{"data" => [...], "first_id" => _, "last_id" => _, "has_more" => _}}`
      (with the legacy beta header).
```

In the `upload/3` doc, replace the sentence `Should have the \`files-api-2025-04-14\` beta feature configured (see moduledoc).` with nothing (delete it). In the moduledoc example, replace `"claude-sonnet-4-6"` with `"claude-opus-5"`.

- [ ] **Step 5: Run to verify pass**

Run: `mix test test/files_test.exs`
Expected: PASS (including the pre-existing `:before_id`/`:after_id` test).

- [ ] **Step 6: Commit**

```bash
git add lib/claudio/files.ex test/files_test.exs
git commit -m "feat(files): GA pagination (:page, :ids); document beta-header optionality"
```

---

### Task 4: Skills — stop auto-attaching the beta (gated on a live check)

**Files:**
- Modify: `lib/claudio/skills.ex` (moduledoc; remove `@beta`, `beta/1`; http helpers use `client` directly; alias)
- Modify: `test/skills_test.exs` (header assertions)
- Create: `test/integration/skills_integration_test.exs`

**Interfaces:**
- Consumes: `Claudio.Client.new/2`, `Claudio.Client.with_betas/2` (existing), `Claudio.IntegrationHelper` (existing).
- Produces: `Claudio.Skills.*` functions unchanged in signature; requests carry no `anthropic-beta` header unless the caller's client has one.

- [ ] **Step 1: Live probe (decides the moduledoc branch).** Requires `ANTHROPIC_API_KEY`.

```bash
[ -n "$ANTHROPIC_API_KEY" ] || { echo "NO KEY — STOP and report to Q"; exit 1; }
mix run -e '
client = Claudio.Client.new(%{token: System.fetch_env!("ANTHROPIC_API_KEY"), version: "2023-06-01"})
for {label, c} <- [with_beta: Claudio.Client.with_betas(client, ["skills-2025-10-02"]), without_beta: client] do
  {:ok, resp} = Req.get(c, url: "skills", params: [limit: 1])
  IO.puts("#{label}: status=#{resp.status} keys=#{inspect(resp.body |> Map.keys() |> Enum.sort())}")
end'
```

Expected: two lines, both `status=200`. **If the key is missing or either status is not 200: STOP. Report the exact output to Q; do not pick a branch.** Otherwise record both lines verbatim — they go in the Step 7 commit message.

- Keys identical → **Branch A** moduledoc (Step 4a).
- Keys differ → **Branch B** moduledoc (Step 4b).

The code change (Step 3) is the same in both branches.

- [ ] **Step 2: Update unit tests first** — in `test/skills_test.exs`:

Replace the `@beta "skills-2025-10-02"` attribute and `assert_beta/1` helper with:

```elixir
  defp assert_no_beta(conn) do
    assert Plug.Conn.get_req_header(conn, "anthropic-beta") == []
    conn
  end
```

Then replace every `assert_beta(conn)` call with `assert_no_beta(conn)`, and rename the two test titles:
- `"list passes limit/source and attaches the skills beta"` → `"list passes limit/source with no beta header"`
- `"create POSTs multipart/form-data with the beta header"` → `"create POSTs multipart/form-data with no beta header"`

Run: `mix test test/skills_test.exs`
Expected: FAIL — header is `["skills-2025-10-02"]`.

- [ ] **Step 3: Implement** — in `lib/claudio/skills.ex`:

Change `alias Claudio.{APIError, Client}` to `alias Claudio.APIError`; delete `@beta "skills-2025-10-02"` and `defp beta(client), do: Client.with_betas(client, [@beta])`; replace the three http helpers with:

```elixir
  defp http_get(client, url, params),
    do: handle(Req.get(client, url: url, params: params))

  defp http_delete(client, url), do: handle(Req.delete(client, url: url))

  defp http_multipart(client, url, form),
    do: handle(Req.post(client, url: url, form_multipart: form))
```

- [ ] **Step 4a (Branch A — keys identical):** replace the moduledoc paragraph starting `**Beta.** Every request carries` (through `the client with it.`) with:

```markdown
  **GA — no beta header.** Requests go out on the client as built.
```

- [ ] **Step 4b (Branch B — keys differ):** replace the same paragraph with (fill both key lists from the Step 1 output):

```markdown
  **GA — no beta header.** Without the header, `list/2` / `list_versions/3`
  return the GA shape (top-level keys: <without_beta keys from Step 1>). Callers
  that depend on the old beta shape (<with_beta keys from Step 1>) can opt back in:

      client = Claudio.Client.with_betas(client, ["skills-2025-10-02"])
```

- [ ] **Step 5: Add the live regression test** — create `test/integration/skills_integration_test.exs`:

```elixir
Code.require_file("../integration/integration_helper.exs", __DIR__)

defmodule Claudio.SkillsIntegrationTest do
  use ExUnit.Case, async: false
  import Claudio.IntegrationHelper

  @moduletag :integration
  @moduletag timeout: 120_000

  setup_all do
    case skip_if_no_api_key() do
      :ok -> {:ok, %{client: create_client()}}
      {:skip, reason} -> {:skip, reason}
    end
  end

  test "list works without the skills beta header", %{client: client} do
    assert {:ok, %{"data" => skills}} = Claudio.Skills.list(client, limit: 1)
    assert is_list(skills)
  end
end
```

- [ ] **Step 6: Run**

Run: `mix test test/skills_test.exs && mix test --only integration test/integration/skills_integration_test.exs`
Expected: unit PASS; integration PASS (1 test) with the key set.

- [ ] **Step 7: Commit** (paste the two Step 1 lines into the body)

```bash
git add lib/claudio/skills.ex test/skills_test.exs test/integration/skills_integration_test.exs
git commit -m "feat(skills): Skills API is GA — stop auto-attaching skills-2025-10-02

Live probe (GET /v1/skills?limit=1):
<with_beta line from Step 1>
<without_beta line from Step 1>"
```

---

### Task 5: Code execution tool version

**Files:**
- Modify: `lib/claudio/messages/request.ex` (`add_code_execution_tool` doc + function, ~lines 719–729)
- Test: `test/request_test.exs` (the `"add_code_execution_tool emits code_execution_20260120 with no beta"` test, ~line 654)

**Interfaces:**
- Produces: `Request.add_code_execution_tool(t(), keyword()) :: t()`; `/1` still works (default arg).

- [ ] **Step 1: Write the failing tests** — replace the existing `"add_code_execution_tool emits code_execution_20260120 with no beta"` test with:

```elixir
    test "add_code_execution_tool defaults to code_execution_20260521 with no beta" do
      request = Request.new("claude-opus-5") |> Request.add_code_execution_tool()

      assert Request.to_map(request)["tools"] == [
               %{"type" => "code_execution_20260521", "name" => "code_execution"}
             ]

      assert Request.required_betas(request) == []
    end

    test "add_code_execution_tool :version selects older versions" do
      for {version, type} <- [
            {:"20260120", "code_execution_20260120"},
            {:"20250825", "code_execution_20250825"}
          ] do
        [tool] =
          Request.new("claude-opus-5")
          |> Request.add_code_execution_tool(version: version)
          |> Request.to_map()
          |> Map.fetch!("tools")

        assert tool == %{"type" => type, "name" => "code_execution"}
      end
    end

    test "add_code_execution_tool rejects an unknown version" do
      assert_raise ArgumentError, ~r/:version must be one of/, fn ->
        Request.new("claude-opus-5") |> Request.add_code_execution_tool(version: :"20250522")
      end
    end
```

- [ ] **Step 2: Run to verify failure**

Run: `mix test test/request_test.exs`
Expected: FAIL — default emits `code_execution_20260120`; `/2` undefined.

- [ ] **Step 3: Implement** — replace the `add_code_execution_tool` doc + function:

```elixir
  @code_execution_versions [:"20260521", :"20260120", :"20250825"]

  @doc """
  Adds the server-side `code_execution` tool. GA — no beta header. Pairs with
  `set_container/2` for container reuse and the Files API (`container_upload`
  blocks). Results arrive as `bash_code_execution_tool_result` /
  `text_editor_code_execution_tool_result` blocks.

  ## Options

    * `:version` — `:"20260521"` (default), `:"20260120"`, or `:"20250825"`.
      `20260521` and `20260120` run the same runtime (REPL persistence and
      programmatic tool calling); `20260521` also tells Claude about the
      90-second per-cell limit. Use `:"20250825"` to turn those features off.
  """
  @spec add_code_execution_tool(t(), keyword()) :: t()
  def add_code_execution_tool(%__MODULE__{} = request, opts \\ []) do
    version = Keyword.get(opts, :version, :"20260521")

    unless version in @code_execution_versions do
      raise ArgumentError,
            "add_code_execution_tool/2 :version must be one of " <>
              "#{inspect(@code_execution_versions)}; got #{inspect(version)}"
    end

    add_tool(request, %{"type" => "code_execution_#{version}", "name" => "code_execution"})
  end
```

- [ ] **Step 4: Run to verify pass**

Run: `mix test test/request_test.exs`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/claudio/messages/request.ex test/request_test.exs
git commit -m "feat(tools): code_execution defaults to 20260521; :version option"
```

---

### Task 6: `stop_details` on `Response` and streamed messages

**Files:**
- Modify: `lib/claudio/messages/response.ex` (`@type t`, `defstruct`, `from_map/1`, ~lines 95–130)
- Modify: `lib/claudio/messages/stream.ex` (`message_delta` clause in `build_final_message/1`, ~line 216–225)
- Test: `test/response_test.exs`, `test/messages/stream_test.exs`

**Interfaces:**
- Produces: `%Response{stop_details: map() | nil}`; `Stream.build_final_message/1` result map may contain `"stop_details"`.

- [ ] **Step 1: Write the failing tests** — append to `test/response_test.exs` (before the final `end`):

```elixir
  describe "from_map/1 stop_details" do
    @details %{"type" => "refusal", "category" => "cyber", "explanation" => "declined"}

    test "keeps stop_details as a raw string-keyed map on refusal" do
      response =
        Response.from_map(%{
          "content" => [],
          "stop_reason" => "refusal",
          "stop_details" => @details
        })

      assert response.stop_reason == :refusal
      assert response.stop_details == @details
    end

    test "nil when absent" do
      assert Response.from_map(%{"content" => [], "stop_reason" => "end_turn"}).stop_details ==
               nil
    end

    test "atom-keyed stop_details" do
      response = Response.from_map(%{content: [], stop_reason: "refusal", stop_details: @details})
      assert response.stop_details == @details
    end
  end
```

Append to `test/messages/stream_test.exs` (before the final `end`; the helper is module-level, outside the `describe`):

```elixir
  defp final_message(delta_json) do
      sse = [
        ~s(event: message_start),
        ~s(data: {"type":"message_start","message":{"id":"msg_1","type":"message","role":"assistant","content":[],"model":"claude-opus-5","stop_reason":null,"usage":{"input_tokens":5,"output_tokens":0}}}),
        "",
        ~s(event: message_delta),
        ~s(data: {"type":"message_delta","delta":#{delta_json},"usage":{"output_tokens":3}}),
        "",
        ~s(event: message_stop),
        ~s(data: {"type":"message_stop"}),
        ""
      ]

      {:ok, message} =
        [Enum.join(sse, "\n") <> "\n"]
        |> ClaudioStream.parse_events()
        |> ClaudioStream.build_final_message()

      message
  end

  describe "build_final_message/1 stop_details" do
    test "copies stop_details from message_delta" do
      message =
        final_message(
          ~s({"stop_reason":"refusal","stop_sequence":null,"stop_details":{"type":"refusal","category":"cyber","explanation":"declined"}})
        )

      assert message["stop_reason"] == "refusal"

      assert message["stop_details"] == %{
               "type" => "refusal",
               "category" => "cyber",
               "explanation" => "declined"
             }
    end

    test "absent stop_details leaves the key off" do
      message = final_message(~s({"stop_reason":"end_turn","stop_sequence":null}))
      refute Map.has_key?(message, "stop_details")
    end
  end
```

- [ ] **Step 2: Run to verify failure**

Run: `mix test test/response_test.exs test/messages/stream_test.exs`
Expected: FAIL — `KeyError`/no `stop_details` field on the struct; streamed message lacks `"stop_details"`.

- [ ] **Step 3: Implement `Response`**

In the `@type t` map add after `stop_sequence: String.t() | nil,`:

```elixir
          stop_details: map() | nil,
```

In `defstruct` add `:stop_details` after `:stop_sequence`. In `from_map/1` add after the `stop_sequence:` line:

```elixir
      stop_details: data[:stop_details] || data["stop_details"],
```

Add to the moduledoc (or the struct field docs if present) one line:

```markdown
  `stop_details` is the raw API map (`"type"`, `"category"`, `"explanation"`), set only
  when `stop_reason` is `:refusal`. For streamed responses it is read from
  `message_delta.delta` next to `stop_reason`; that location is unconfirmed in
  Anthropic's streaming docs.
```

- [ ] **Step 4: Implement `Stream`** — in the `message_delta` clause of `build_final_message/1`, add one line after `|> maybe_update(delta, "stop_sequence")`:

```elixir
            |> maybe_update(delta, "stop_details")
```

- [ ] **Step 5: Run to verify pass**

Run: `mix test test/response_test.exs test/messages/stream_test.exs`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add lib/claudio/messages/response.ex lib/claudio/messages/stream.ex test/response_test.exs test/messages/stream_test.exs
git commit -m "feat(response): surface stop_details (non-streaming + accumulated stream)"
```

---

### Task 7: Docs, CHANGELOG, CLAUDE.md, final verification

**Files:**
- Modify: `lib/claudio.ex`, `lib/claudio/tools.ex`, `lib/claudio/batches.ex`, `lib/claudio/messages.ex`, `lib/claudio/messages/request.ex`, `lib/claudio/agent.ex`, `lib/claudio/mcp/tool_adapter.ex` (model ids in docs)
- Modify: `README.md` (model ids; Files section ~lines 314–326)
- Modify: `CLAUDE.md`, `CHANGELOG.md`

- [ ] **Step 1: Replace retired model ids in docs** (lib + README only — test fixtures keep their data strings)

```bash
sed -i '' 's/claude-3-5-sonnet-20241022/claude-opus-5/g; s/claude-sonnet-4-5-20250929/claude-opus-5/g' \
  lib/claudio.ex lib/claudio/tools.ex lib/claudio/batches.ex lib/claudio/messages.ex \
  lib/claudio/messages/request.ex lib/claudio/agent.ex lib/claudio/mcp/tool_adapter.ex README.md
grep -rn "claude-3-5-sonnet-20241022\|claude-sonnet-4-5-20250929" lib README.md
```

Expected: the grep prints nothing.

- [ ] **Step 2: `enable_thinking/2` doc** — in `lib/claudio/messages/request.ex`, replace the example line
`|> Request.enable_thinking(%{"type" => "enabled", "budget_tokens" => 1000})` with
`|> Request.enable_thinking(%{"type" => "adaptive"})` and add below the example block:

```markdown
  `%{"type" => "enabled", "budget_tokens" => n}` returns 400 on Claude Opus 4.7+,
  Opus 5.x, Sonnet 5 and Fable models; use `"adaptive"` there. Dedicated
  thinking/effort helpers are planned (roadmap S11).
```

- [ ] **Step 3: `set_tool_choice/2` doc** — add below its example block:

```markdown
  `:any` and `{:tool, name}` return 400 on Claude Fable 5.1, Mythos 5.1 and
  Opus 5.5. There, use `:auto` with a prompt instruction naming the tool,
  `add_strict_tool/2` for schema-valid arguments, or `set_output_format/2`
  when the forced call only existed to get JSON back.
```

- [ ] **Step 4: README Files section** — replace the sentence starting `The Files API is currently behind the \`files-api-2025-04-14\` Anthropic` and the client example carrying `beta: ["files-api-2025-04-14"]` with:

```markdown
The Files API is GA — no beta header needed. (Clients that still send
`files-api-2025-04-14` get the old list pagination; see `Claudio.Files.list/2`.)
```

and, in that client example, remove the `beta: ["files-api-2025-04-14"]` line.

- [ ] **Step 5: CLAUDE.md**
  - Architecture → MCP Support → server-side bullets: change `- \`Request.add_mcp_server/2\`: Accepts \`ServerConfig\` structs or raw maps` to `- \`Request.add_mcp_server/2\`: Accepts \`ServerConfig\` structs or raw maps; emits the \`mcp_servers\` entry **and** an \`mcp_toolset\` in \`tools\`, and declares \`mcp-client-2025-11-20\`. \`ServerConfig.allow_tools/2\` takes exact names (patterns raise); legacy \`tool_configuration\` in raw maps is translated with a warning.`
  - Request Builder: change `- \`add_code_execution_tool/1\` — \`code_execution_20260120\`; GA (pairs with \`set_container/2\`)` to `- \`add_code_execution_tool/2\` — \`code_execution_20260521\` (default; \`version:\` \`:"20260120"\` / \`:"20250825"\`); GA (pairs with \`set_container/2\`)`
  - Response Handling: add bullet `- **\`stop_details\`** — raw refusal details map (\`type\`/\`category\`/\`explanation\`), \`nil\` unless \`stop_reason: :refusal\``
  - Skills API section: change the heading suffix `— beta` to `— GA` and replace the sentence starting `Every request carries \`anthropic-beta: skills-2025-10-02\`` (through `(callers don't pre-configure the beta).`) with `GA — no beta header is attached.`

- [ ] **Step 6: CHANGELOG** — insert above `## [0.6.0] - 2026-06-19`:

```markdown
## [Unreleased] — targets 0.7.0

### Fixed

- **MCP connector** now emits a valid `mcp-client-2025-11-20` request:
  `Request.add_mcp_server/2` adds the `mcp_toolset` entry to `tools` and declares
  the beta. Previously the request had no toolset and no beta header and was rejected.

### Changed

- `Claudio.MCP.ServerConfig`: `:tool_configuration` struct field removed; tool
  selection lives on the toolset (`:default_config`, `:configs`).
  `allow_tools/2` now takes **exact tool names** and raises `ArgumentError` on
  `*`/`?` patterns (the connector matches names literally; a pattern would enable
  no tools). Raw maps with legacy `tool_configuration` are translated with a warning.
- `Claudio.Skills` no longer attaches `anthropic-beta: skills-2025-10-02` (Skills API is GA).
- `Request.add_code_execution_tool/2` defaults to `code_execution_20260521`
  (same runtime as `20260120`).

### Added

- `ServerConfig.to_toolset/1`, `set_default_config/2`, `configure_tool/3`, `split_raw/1`.
- `Files.list/2` GA pagination options `:page` and `:ids`.
- `add_code_execution_tool/2` `:version` option.
- `Response.stop_details` (also accumulated by `Stream.build_final_message/1`).

### Docs

- Examples use `claude-opus-5`; `enable_thinking/2` and `set_tool_choice/2`
  document the 400s on current models; Files documented as GA.
```

- [ ] **Step 7: Full verification**

```bash
mix format
mix format --check-formatted
mix compile --warnings-as-errors --force
mix test
```

Expected: format check exits 0; compile prints no warnings; `mix test` reports 0 failures and more than the 282-test baseline (25+ excluded).

- [ ] **Step 8: Commit**

```bash
git add lib/claudio.ex lib/claudio/tools.ex lib/claudio/batches.ex lib/claudio/messages.ex \
  lib/claudio/messages/request.ex lib/claudio/agent.ex lib/claudio/mcp/tool_adapter.ex \
  README.md CLAUDE.md CHANGELOG.md
git status --short   # any other file listed here was reformatted by mix format — inspect, then add it individually
git commit -m "docs: S10 — current model ids, GA Files/Skills, MCP toolset, thinking/tool_choice notes"
```
