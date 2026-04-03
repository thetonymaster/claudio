defmodule Claudio.A2A.Task do
  @moduledoc """
  A2A Task — the fundamental unit of work in the A2A protocol.

  Tasks have a lifecycle: submitted → working → input_required → completed/failed/canceled.
  """

  alias Claudio.A2A.{Message, Artifact}
  import Claudio.A2A.Util, only: [maybe_put: 3]

  @type state ::
          :submitted
          | :working
          | :input_required
          | :completed
          | :failed
          | :canceled
          | :rejected
          | :auth_required

  @type task_status :: %{
          state: state(),
          message: Message.t() | nil,
          timestamp: String.t() | nil
        }

  @type t :: %__MODULE__{
          id: String.t(),
          context_id: String.t() | nil,
          status: task_status(),
          artifacts: [Artifact.t()],
          history: [Message.t()],
          metadata: map() | nil
        }

  defstruct [:id, :context_id, :status, artifacts: [], history: [], metadata: nil]

  @doc "Check if a task is in a terminal state."
  @spec terminal?(t()) :: boolean()
  def terminal?(%__MODULE__{status: %{state: state}}) do
    state in [:completed, :failed, :canceled, :rejected]
  end

  @spec from_map(map()) :: t()
  def from_map(map) when is_map(map) do
    %__MODULE__{
      id: map["id"],
      context_id: map["contextId"] || map["context_id"],
      status: parse_status(map["status"]),
      artifacts: parse_artifacts(map["artifacts"]),
      history: parse_history(map["history"]),
      metadata: map["metadata"]
    }
  end

  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = task) do
    %{
      "id" => task.id,
      "status" => status_to_map(task.status)
    }
    |> maybe_put("contextId", task.context_id)
    |> maybe_put("artifacts", unless_empty(task.artifacts, &Artifact.to_map/1))
    |> maybe_put("history", unless_empty(task.history, &Message.to_map/1))
    |> maybe_put("metadata", task.metadata)
  end

  defp parse_status(nil), do: %{state: :submitted, message: nil, timestamp: nil}

  defp parse_status(map) when is_map(map) do
    %{
      state: parse_state(map["state"]),
      message: if(map["message"], do: Message.from_map(map["message"])),
      timestamp: map["timestamp"]
    }
  end

  defp status_to_map(%{state: state} = status) do
    %{"state" => state_to_string(state)}
    |> maybe_put("message", if(status[:message], do: Message.to_map(status.message)))
    |> maybe_put("timestamp", status[:timestamp])
  end

  @state_map %{
    "TASK_STATE_SUBMITTED" => :submitted,
    "TASK_STATE_WORKING" => :working,
    "TASK_STATE_INPUT_REQUIRED" => :input_required,
    "TASK_STATE_COMPLETED" => :completed,
    "TASK_STATE_FAILED" => :failed,
    "TASK_STATE_CANCELED" => :canceled,
    "TASK_STATE_REJECTED" => :rejected,
    "TASK_STATE_AUTH_REQUIRED" => :auth_required,
    "submitted" => :submitted,
    "working" => :working,
    "input-required" => :input_required,
    "completed" => :completed,
    "failed" => :failed,
    "canceled" => :canceled,
    "rejected" => :rejected,
    "auth-required" => :auth_required
  }

  defp parse_state(state) when is_binary(state), do: Map.get(@state_map, state, :submitted)
  defp parse_state(_), do: :submitted

  defp state_to_string(:submitted), do: "TASK_STATE_SUBMITTED"
  defp state_to_string(:working), do: "TASK_STATE_WORKING"
  defp state_to_string(:input_required), do: "TASK_STATE_INPUT_REQUIRED"
  defp state_to_string(:completed), do: "TASK_STATE_COMPLETED"
  defp state_to_string(:failed), do: "TASK_STATE_FAILED"
  defp state_to_string(:canceled), do: "TASK_STATE_CANCELED"
  defp state_to_string(:rejected), do: "TASK_STATE_REJECTED"
  defp state_to_string(:auth_required), do: "TASK_STATE_AUTH_REQUIRED"

  defp parse_artifacts(nil), do: []
  defp parse_artifacts(list) when is_list(list), do: Enum.map(list, &Artifact.from_map/1)

  defp parse_history(nil), do: []
  defp parse_history(list) when is_list(list), do: Enum.map(list, &Message.from_map/1)

  defp unless_empty([], _fun), do: nil
  defp unless_empty(list, fun), do: Enum.map(list, fun)
end
