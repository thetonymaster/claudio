defmodule Claudio.MCP.Client do
  @moduledoc """
  Behaviour for MCP client adapters.

  Defines a common interface that abstracts over different Elixir MCP client
  libraries (hermes_mcp, ex_mcp, mcp_ex, or custom implementations).

  ## Implementing an adapter

      defmodule MyApp.MCPAdapter do
        @behaviour Claudio.MCP.Client

        @impl true
        def list_tools(client, opts \\\\ []) do
          # Call your MCP library and normalize the response
          {:ok, [%Claudio.MCP.Client.Tool{name: "search", ...}]}
        end

        # ... implement other callbacks
      end

  ## Normalized types

  All adapters return the same normalized types regardless of the underlying
  library. This ensures that `Claudio.MCP.ToolAdapter` and
  `Claudio.MCP.ResultMapper` work consistently across implementations.
  """

  defmodule Tool do
    @moduledoc "Normalized MCP tool definition."

    @type t :: %__MODULE__{
            name: String.t(),
            description: String.t() | nil,
            input_schema: map()
          }

    defstruct [:name, :description, :input_schema]
  end

  defmodule Resource do
    @moduledoc "Normalized MCP resource definition."

    @type t :: %__MODULE__{
            uri: String.t(),
            name: String.t(),
            description: String.t() | nil,
            mime_type: String.t() | nil
          }

    defstruct [:uri, :name, :description, :mime_type]
  end

  defmodule Prompt do
    @moduledoc "Normalized MCP prompt definition."

    @type t :: %__MODULE__{
            name: String.t(),
            description: String.t() | nil,
            arguments: list(map())
          }

    defstruct [:name, :description, arguments: []]
  end

  @type tool :: Tool.t()
  @type resource :: Resource.t()
  @type prompt :: Prompt.t()

  @doc "List available tools from the MCP server."
  @callback list_tools(client :: term(), opts :: keyword()) ::
              {:ok, [tool()]} | {:error, term()}

  @doc "Execute a tool on the MCP server."
  @callback call_tool(client :: term(), name :: String.t(), args :: map(), opts :: keyword()) ::
              {:ok, term()} | {:error, term()}

  @doc "List available resources from the MCP server."
  @callback list_resources(client :: term(), opts :: keyword()) ::
              {:ok, [resource()]} | {:error, term()}

  @doc "Read a resource by URI from the MCP server."
  @callback read_resource(client :: term(), uri :: String.t(), opts :: keyword()) ::
              {:ok, term()} | {:error, term()}

  @doc "List available prompts from the MCP server."
  @callback list_prompts(client :: term(), opts :: keyword()) ::
              {:ok, [prompt()]} | {:error, term()}

  @doc "Get a prompt by name with optional arguments."
  @callback get_prompt(client :: term(), name :: String.t(), args :: map(), opts :: keyword()) ::
              {:ok, term()} | {:error, term()}

  @doc "Ping the MCP server to check connectivity."
  @callback ping(client :: term(), opts :: keyword()) ::
              :ok | {:error, term()}
end
