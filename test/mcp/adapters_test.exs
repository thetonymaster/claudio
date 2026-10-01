# Fakes shaped like the real libraries' return values (verified against hermes_mcp 0.14.1
# and ex_mcp 1.5.0 in the 2026-09-26 pre-release audit). They exist only in the test build.
defmodule Claudio.Test.FakeHermesResponse do
  defstruct [:result, :id, :method]
end

defmodule Claudio.Test.FakeHermesBase do
  alias Claudio.Test.FakeHermesResponse

  def list_tools(test_pid, opts) do
    send(test_pid, {:hermes_opts, opts})

    {:ok,
     %FakeHermesResponse{
       result: %{
         "tools" => [%{"name" => "echo", "inputSchema" => %{"type" => "object"}}],
         "nextCursor" => "page2"
       }
     }}
  end

  def list_resources(_pid, _opts),
    do:
      {:ok,
       %FakeHermesResponse{result: %{"resources" => [%{"uri" => "file:///a", "name" => "a"}]}}}

  def list_prompts(_pid, _opts),
    do: {:ok, %FakeHermesResponse{result: %{"prompts" => [%{"name" => "p"}]}}}

  def ping(_pid, _opts), do: :pong

  # A bug inside the client module: must surface, not be reported as "library missing".
  # Called via apply/3 so the undefined module is not a compile-time warning.
  # credo:disable-for-next-line Credo.Check.Refactor.Apply
  def call_tool(_pid, _name, _args, _opts), do: apply(Claudio.Test.NoSuchModule, :boom, [])
end

defmodule ExMCP.Client do
  @moduledoc false
  # ex_mcp 1.5 returns %ExMCP.Response{} structs by default; `format: :map` returns maps.
  defmodule Response do
    @moduledoc false
    defstruct [:tools, :nextCursor]
  end

  def list_tools(_client, opts) do
    if opts[:format] == :map,
      do: {:ok, %{"tools" => [%{"name" => "echo", "inputSchema" => %{"type" => "object"}}]}},
      else: {:ok, %Response{tools: [%{name: "echo"}], nextCursor: nil}}
  end
end

defmodule Claudio.MCP.AdaptersTest do
  use ExUnit.Case, async: true

  alias Claudio.MCP.Adapters.{ExMCP, HermesMCP, MCPEx}
  alias Claudio.MCP.Client.{Prompt, Resource, Tool}
  alias Claudio.Test.FakeHermesBase

  describe "HermesMCP" do
    test "list functions unwrap the response struct's result" do
      client = {FakeHermesBase, self()}

      assert {:ok, [%Tool{name: "echo", input_schema: %{"type" => "object"}}]} =
               HermesMCP.list_tools(client)

      assert {:ok, [%Resource{uri: "file:///a"}]} = HermesMCP.list_resources(client)
      assert {:ok, [%Prompt{name: "p"}]} = HermesMCP.list_prompts(client)
    end

    test "opts (e.g. cursor) are passed to the client" do
      assert {:ok, _} = HermesMCP.list_tools({FakeHermesBase, self()}, cursor: "page2")
      assert_received {:hermes_opts, [cursor: "page2"]}
    end

    test "ping maps :pong to :ok" do
      assert :ok = HermesMCP.ping({FakeHermesBase, self()})
    end

    test "a missing library or function is reported; a bug inside the client is not masked" do
      assert {:error, :hermes_mcp_not_available} =
               HermesMCP.list_tools({Claudio.Test.NotLoaded, self()})

      assert {:error, {:undefined_client_function, FakeHermesBase, :read_resource, 3}} =
               HermesMCP.read_resource({FakeHermesBase, self()}, "file:///a")

      assert_raise UndefinedFunctionError, fn ->
        HermesMCP.call_tool({FakeHermesBase, self()}, "t", %{})
      end
    end
  end

  describe "ExMCP" do
    test "list_tools asks for format: :map so the list isn't silently empty" do
      assert {:ok, [%Tool{name: "echo", input_schema: %{"type" => "object"}}]} =
               ExMCP.list_tools(:client)
    end
  end

  describe "MCPEx" do
    test "without the library, calls report :mcp_ex_not_available" do
      assert {:error, :mcp_ex_not_available} = MCPEx.list_tools(:client)
    end
  end
end
