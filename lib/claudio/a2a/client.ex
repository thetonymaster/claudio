defmodule Claudio.A2A.Client do
  @moduledoc """
  A2A client for discovering and interacting with remote agents.

  Delegates to a transport implementation. Defaults to JSON-RPC 2.0 over HTTP.

  ## Examples

      # Discover an agent (default HTTP transport)
      {:ok, card} = Claudio.A2A.Client.discover("https://agent.example.com")

      # Send a message
      alias Claudio.A2A.{Message, Part}
      message = Message.new(:user, [Part.text("Search for Elixir libraries")])
      {:ok, task} = Claudio.A2A.Client.send_message("https://agent.example.com/a2a", message)

      # Check task status
      {:ok, task} = Claudio.A2A.Client.get_task("https://agent.example.com/a2a", task.id)

      # Use a different transport
      {:ok, task} = Claudio.A2A.Client.send_message("agent:443", message,
        transport: Claudio.A2A.Transport.GRPC)
  """

  alias Claudio.A2A.{Task, Message}

  @default_transport Claudio.A2A.Transport.HTTP

  @doc """
  Discover an agent's capabilities from its base URL.

  Fetches the agent card from `{base_url}/.well-known/agent-card.json`.

  ## Options

    - `:transport` — Transport module (default: `Claudio.A2A.Transport.HTTP`)
  """
  @spec discover(String.t(), keyword()) :: {:ok, Claudio.A2A.AgentCard.t()} | {:error, term()}
  def discover(base_url, opts \\ []) do
    transport(opts).discover(base_url, transport_opts(opts))
  end

  @doc """
  Send a message to an agent, creating or continuing a task.

  ## Options

    - `:task_id` — Continue an existing task
    - `:configuration` — SendMessageConfiguration map
    - `:metadata` — Additional metadata
    - `:auth_token` — Bearer token for authentication
    - `:transport` — Transport module (default: `Claudio.A2A.Transport.HTTP`)
  """
  @spec send_message(String.t(), Message.t(), keyword()) ::
          {:ok, Task.t() | Message.t()} | {:error, term()}
  def send_message(endpoint, %Message{} = message, opts \\ []) do
    transport(opts).send_message(endpoint, message, transport_opts(opts))
  end

  @doc """
  Get a task by ID.

  ## Options

    - `:history_length` — Number of history messages to include
    - `:transport` — Transport module
  """
  @spec get_task(String.t(), String.t(), keyword()) :: {:ok, Task.t()} | {:error, term()}
  def get_task(endpoint, task_id, opts \\ []) do
    transport(opts).get_task(endpoint, task_id, transport_opts(opts))
  end

  @doc """
  List tasks, optionally filtered.

  ## Options

    - `:context_id` — Filter by context
    - `:status` — Filter by state (atom, e.g. `:working`)
    - `:page_size` — Results per page
    - `:page_token` — Pagination token
    - `:history_length` — Number of history messages to include
    - `:transport` — Transport module
  """
  @spec list_tasks(String.t(), keyword()) ::
          {:ok, %{tasks: [Task.t()], next_page_token: String.t()}} | {:error, term()}
  def list_tasks(endpoint, opts \\ []) do
    transport(opts).list_tasks(endpoint, transport_opts(opts))
  end

  @doc """
  Cancel a task.

  ## Options

    - `:transport` — Transport module
  """
  @spec cancel_task(String.t(), String.t(), keyword()) :: {:ok, Task.t()} | {:error, term()}
  def cancel_task(endpoint, task_id, opts \\ []) do
    transport(opts).cancel_task(endpoint, task_id, transport_opts(opts))
  end

  defp transport(opts), do: Keyword.get(opts, :transport, @default_transport)
  defp transport_opts(opts), do: Keyword.delete(opts, :transport)
end
