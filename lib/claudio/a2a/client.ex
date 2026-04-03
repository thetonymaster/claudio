defmodule Claudio.A2A.Client do
  @moduledoc """
  A2A client for discovering and interacting with remote agents.

  Uses JSON-RPC 2.0 over HTTP as the default transport.

  ## Examples

      # Discover an agent
      {:ok, card} = Claudio.A2A.Client.discover("https://agent.example.com")

      # Send a message
      alias Claudio.A2A.{Message, Part}
      message = Message.new(:user, [Part.text("Search for Elixir libraries")])
      {:ok, task} = Claudio.A2A.Client.send_message("https://agent.example.com/a2a", message)

      # Check task status
      {:ok, task} = Claudio.A2A.Client.get_task("https://agent.example.com/a2a", task.id)
  """

  alias Claudio.A2A.{AgentCard, Task, Message}
  import Claudio.A2A.Util, only: [maybe_put: 3]

  @agent_card_path "/.well-known/agent-card.json"

  @doc """
  Discover an agent's capabilities from its base URL.

  Fetches the agent card from `{base_url}/.well-known/agent-card.json`.
  """
  @spec discover(String.t(), keyword()) :: {:ok, AgentCard.t()} | {:error, term()}
  def discover(base_url, opts \\ []) do
    url = String.trim_trailing(base_url, "/") <> @agent_card_path

    case http_get(url, opts) do
      {:ok, body} -> {:ok, AgentCard.from_map(body)}
      error -> error
    end
  end

  @doc """
  Send a message to an agent, creating or continuing a task.

  ## Options

    - `:task_id` — Continue an existing task
    - `:configuration` — SendMessageConfiguration map
    - `:metadata` — Additional metadata
    - `:auth_token` — Bearer token for authentication
  """
  @spec send_message(String.t(), Message.t(), keyword()) ::
          {:ok, Task.t() | Message.t()} | {:error, term()}
  def send_message(endpoint, %Message{} = message, opts \\ []) do
    params = build_send_params(message, opts)

    case json_rpc(endpoint, "message/send", params, opts) do
      {:ok, %{"id" => _} = result} -> {:ok, Task.from_map(result)}
      {:ok, %{"messageId" => _} = result} -> {:ok, Message.from_map(result)}
      error -> error
    end
  end

  @doc """
  Get a task by ID.

  ## Options

    - `:history_length` — Number of history messages to include
  """
  @spec get_task(String.t(), String.t(), keyword()) :: {:ok, Task.t()} | {:error, term()}
  def get_task(endpoint, task_id, opts \\ []) do
    params =
      %{"id" => task_id}
      |> maybe_put("historyLength", Keyword.get(opts, :history_length))

    case json_rpc(endpoint, "tasks/get", params, opts) do
      {:ok, result} -> {:ok, Task.from_map(result)}
      error -> error
    end
  end

  @doc """
  List tasks, optionally filtered.

  ## Options

    - `:context_id` — Filter by context
    - `:status` — Filter by state (atom, e.g. `:working`)
    - `:page_size` — Results per page
    - `:page_token` — Pagination token
    - `:history_length` — Number of history messages to include
  """
  @spec list_tasks(String.t(), keyword()) ::
          {:ok, %{tasks: [Task.t()], next_page_token: String.t()}} | {:error, term()}
  def list_tasks(endpoint, opts \\ []) do
    params =
      %{}
      |> maybe_put("contextId", Keyword.get(opts, :context_id))
      |> maybe_put("status", state_to_string(Keyword.get(opts, :status)))
      |> maybe_put("pageSize", Keyword.get(opts, :page_size))
      |> maybe_put("pageToken", Keyword.get(opts, :page_token))
      |> maybe_put("historyLength", Keyword.get(opts, :history_length))

    case json_rpc(endpoint, "tasks/list", params, opts) do
      {:ok, result} ->
        tasks = Enum.map(result["tasks"] || [], &Task.from_map/1)

        {:ok,
         %{
           tasks: tasks,
           next_page_token: result["nextPageToken"] || ""
         }}

      error ->
        error
    end
  end

  @doc """
  Cancel a task.
  """
  @spec cancel_task(String.t(), String.t(), keyword()) :: {:ok, Task.t()} | {:error, term()}
  def cancel_task(endpoint, task_id, opts \\ []) do
    params = %{"id" => task_id}

    case json_rpc(endpoint, "tasks/cancel", params, opts) do
      {:ok, result} -> {:ok, Task.from_map(result)}
      error -> error
    end
  end

  # JSON-RPC helpers

  defp json_rpc(endpoint, method, params, opts) do
    request_id = generate_request_id()

    body = %{
      "jsonrpc" => "2.0",
      "method" => method,
      "id" => request_id,
      "params" => params
    }

    case http_post(endpoint, body, opts) do
      {:ok, %{"result" => result}} -> {:ok, result}
      {:ok, %{"error" => error}} -> {:error, parse_rpc_error(error)}
      {:ok, other} -> {:ok, other}
      error -> error
    end
  end

  defp http_get(url, opts) do
    headers = build_headers(opts)
    req_opts = [headers: headers, decode_body: false] ++ timeout_opts(opts)

    case Req.get(url, req_opts) do
      {:ok, %{status: 200, body: body}} -> decode_json(body)
      {:ok, %{status: status}} -> {:error, {:http_error, status}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp http_post(endpoint, body, opts) do
    headers =
      [{"content-type", "application/json"}]
      |> Kernel.++(build_headers(opts))

    encoded = Poison.encode!(body)
    req_opts = [body: encoded, headers: headers, decode_body: false] ++ timeout_opts(opts)

    case Req.post(endpoint, req_opts) do
      {:ok, %{status: 200, body: body}} -> decode_json(body)
      {:ok, %{status: status}} -> {:error, {:http_error, status}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp timeout_opts(opts) do
    Enum.reduce([:receive_timeout, :connect_options], [], fn key, acc ->
      case Keyword.get(opts, key) do
        nil -> acc
        value -> [{key, value} | acc]
      end
    end)
  end

  defp build_headers(opts) do
    case Keyword.get(opts, :auth_token) do
      nil -> []
      token -> [{"authorization", "Bearer #{token}"}]
    end
  end

  defp build_send_params(message, opts) do
    %{"message" => Message.to_map(message)}
    |> maybe_put("configuration", Keyword.get(opts, :configuration))
    |> maybe_put("metadata", Keyword.get(opts, :metadata))
  end

  defp parse_rpc_error(%{"code" => code, "message" => message}) do
    %{code: code, message: message}
  end

  defp parse_rpc_error(error), do: error

  defp decode_json(body) do
    case Poison.decode(body) do
      {:ok, decoded} -> {:ok, decoded}
      {:error, _} -> {:error, :invalid_json}
    end
  end

  defp generate_request_id do
    "req-" <> Base.encode16(:crypto.strong_rand_bytes(4), case: :lower)
  end

  defp state_to_string(nil), do: nil
  defp state_to_string(:submitted), do: "TASK_STATE_SUBMITTED"
  defp state_to_string(:working), do: "TASK_STATE_WORKING"
  defp state_to_string(:completed), do: "TASK_STATE_COMPLETED"
  defp state_to_string(:failed), do: "TASK_STATE_FAILED"
  defp state_to_string(:canceled), do: "TASK_STATE_CANCELED"
  defp state_to_string(:input_required), do: "TASK_STATE_INPUT_REQUIRED"
  defp state_to_string(:rejected), do: "TASK_STATE_REJECTED"
  defp state_to_string(:auth_required), do: "TASK_STATE_AUTH_REQUIRED"
  defp state_to_string(other) when is_binary(other), do: other
end
