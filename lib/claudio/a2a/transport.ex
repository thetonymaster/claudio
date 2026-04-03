defmodule Claudio.A2A.Transport do
  @moduledoc """
  Behaviour for A2A transport implementations.

  Claudio supports multiple transport bindings for the A2A protocol:

  - `Claudio.A2A.Transport.HTTP` — JSON-RPC 2.0 over HTTP (default)
  - `Claudio.A2A.Transport.GRPC` — gRPC (requires optional `protox` + `grpc` deps)

  ## Usage

      # Default HTTP transport
      Client.send_message("https://agent.example.com/a2a", message)

      # Explicit gRPC transport
      Client.send_message("agent.example.com:443", message,
        transport: Claudio.A2A.Transport.GRPC)
  """

  alias Claudio.A2A.{AgentCard, Task, Message}

  @type endpoint :: String.t()
  @type opts :: keyword()
  @type send_response :: Task.t() | Message.t()
  @type list_response :: %{tasks: [Task.t()], next_page_token: String.t()}

  @doc """
  Discover an agent's capabilities.

  ## Common options

    - `:auth_token` — Bearer token for authentication
    - `:receive_timeout` — HTTP receive timeout in ms
    - `:connect_options` — Connection options (e.g., transport opts)
  """
  @callback discover(endpoint(), opts()) :: {:ok, AgentCard.t()} | {:error, term()}

  @doc """
  Send a message to an agent.

  ## Common options

    - `:auth_token` — Bearer token for authentication
    - `:configuration` — SendMessageConfiguration map
    - `:metadata` — Additional metadata
    - `:receive_timeout` — HTTP receive timeout in ms
    - `:connect_options` — Connection options
  """
  @callback send_message(endpoint(), Message.t(), opts()) ::
              {:ok, send_response()} | {:error, term()}

  @doc """
  Get a task by ID.

  ## Common options

    - `:history_length` — Number of history messages to include
    - `:auth_token` — Bearer token for authentication
  """
  @callback get_task(endpoint(), task_id :: String.t(), opts()) ::
              {:ok, Task.t()} | {:error, term()}

  @doc """
  List tasks with optional filters.

  ## Common options

    - `:context_id` — Filter by context ID
    - `:status` — Filter by task state atom (e.g., `:working`, `:completed`)
    - `:page_size` — Results per page
    - `:page_token` — Pagination token
    - `:history_length` — Number of history messages to include
    - `:auth_token` — Bearer token for authentication
  """
  @callback list_tasks(endpoint(), opts()) :: {:ok, list_response()} | {:error, term()}

  @doc """
  Cancel a task.

  ## Common options

    - `:auth_token` — Bearer token for authentication
  """
  @callback cancel_task(endpoint(), task_id :: String.t(), opts()) ::
              {:ok, Task.t()} | {:error, term()}
end
