defmodule Claudio.MCP.ClientTest do
  use ExUnit.Case, async: true

  alias Claudio.MCP.Client
  alias Claudio.MCP.Client.{Tool, Resource, Prompt}

  # A mock adapter that implements the behaviour for testing
  defmodule MockAdapter do
    @behaviour Client

    @impl true
    def list_tools(_client, _opts \\ []) do
      {:ok,
       [
         %Tool{name: "search", description: "Search docs", input_schema: %{"type" => "object"}},
         %Tool{name: "fetch", description: "Fetch URL", input_schema: %{}}
       ]}
    end

    @impl true
    def call_tool(_client, name, args, _opts \\ []) do
      {:ok, %{"result" => "called #{name} with #{inspect(args)}"}}
    end

    @impl true
    def list_resources(_client, _opts \\ []) do
      {:ok,
       [
         %Resource{
           uri: "file:///tmp/data.json",
           name: "data",
           description: "Data file",
           mime_type: "application/json"
         }
       ]}
    end

    @impl true
    def read_resource(_client, _uri, _opts \\ []) do
      {:ok, %{"contents" => [%{"text" => "hello"}]}}
    end

    @impl true
    def list_prompts(_client, _opts \\ []) do
      {:ok,
       [
         %Prompt{
           name: "summarize",
           description: "Summarize text",
           arguments: [%{"name" => "text", "required" => true}]
         }
       ]}
    end

    @impl true
    def get_prompt(_client, _name, _args \\ %{}, _opts \\ []) do
      {:ok, %{"messages" => [%{"role" => "user", "content" => "Summarize: hello"}]}}
    end

    @impl true
    def ping(_client, _opts \\ []) do
      :ok
    end
  end

  describe "behaviour contract via MockAdapter" do
    test "list_tools returns normalized Tool structs" do
      {:ok, tools} = MockAdapter.list_tools(:client)

      assert length(tools) == 2
      assert %Tool{name: "search"} = hd(tools)
      assert hd(tools).description == "Search docs"
      assert hd(tools).input_schema == %{"type" => "object"}
    end

    test "call_tool returns result" do
      {:ok, result} = MockAdapter.call_tool(:client, "search", %{query: "elixir"})

      assert result["result"] =~ "search"
    end

    test "list_resources returns normalized Resource structs" do
      {:ok, resources} = MockAdapter.list_resources(:client)

      assert [%Resource{uri: "file:///tmp/data.json", name: "data"}] = resources
    end

    test "read_resource returns contents" do
      {:ok, result} = MockAdapter.read_resource(:client, "file:///tmp/data.json")

      assert result["contents"]
    end

    test "list_prompts returns normalized Prompt structs" do
      {:ok, prompts} = MockAdapter.list_prompts(:client)

      assert [%Prompt{name: "summarize"}] = prompts
      assert hd(prompts).arguments == [%{"name" => "text", "required" => true}]
    end

    test "get_prompt returns prompt content" do
      {:ok, result} = MockAdapter.get_prompt(:client, "summarize", %{text: "hello"})

      assert result["messages"]
    end

    test "ping returns :ok" do
      assert :ok = MockAdapter.ping(:client)
    end
  end
end
