defmodule Claudio.A2A.Message do
  @moduledoc """
  A2A Message — a communication turn between a client and remote agent.

  ## Examples

      alias Claudio.A2A.{Message, Part}

      message = Message.new(:user, [Part.text("Search for Elixir libraries")])

      # With task context
      message = Message.new(:user, [Part.text("Continue searching")])
      |> Message.set_task_id("task-123")
  """

  alias Claudio.A2A.Part
  import Claudio.A2A.Util, only: [maybe_put: 3]

  @type role :: :user | :agent
  @type t :: %__MODULE__{
          message_id: String.t() | nil,
          role: role(),
          parts: [Part.t()],
          context_id: String.t() | nil,
          task_id: String.t() | nil,
          reference_task_ids: [String.t()] | nil,
          extensions: [String.t()] | nil,
          metadata: map() | nil
        }

  defstruct [
    :message_id,
    :role,
    :parts,
    :context_id,
    :task_id,
    :reference_task_ids,
    :extensions,
    :metadata
  ]

  @doc "Create a new message with a role and parts."
  @spec new(role(), [Part.t()]) :: t()
  def new(role, parts) when role in [:user, :agent] and is_list(parts) do
    %__MODULE__{
      message_id: generate_id(),
      role: role,
      parts: parts
    }
  end

  @doc "Set the task ID for multi-turn conversations."
  @spec set_task_id(t(), String.t()) :: t()
  def set_task_id(%__MODULE__{} = message, task_id) when is_binary(task_id) do
    %{message | task_id: task_id}
  end

  @doc "Set the context ID for grouping related tasks."
  @spec set_context_id(t(), String.t()) :: t()
  def set_context_id(%__MODULE__{} = message, context_id) when is_binary(context_id) do
    %{message | context_id: context_id}
  end

  @doc "Set metadata on the message."
  @spec set_metadata(t(), map()) :: t()
  def set_metadata(%__MODULE__{} = message, metadata) when is_map(metadata) do
    %{message | metadata: metadata}
  end

  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = msg) do
    %{
      "messageId" => msg.message_id,
      "role" => role_to_string(msg.role),
      "parts" => Enum.map(msg.parts, &Part.to_map/1)
    }
    |> maybe_put("contextId", msg.context_id)
    |> maybe_put("taskId", msg.task_id)
    |> maybe_put("referenceTaskIds", msg.reference_task_ids)
    |> maybe_put("extensions", msg.extensions)
    |> maybe_put("metadata", msg.metadata)
  end

  @spec from_map(map()) :: t()
  def from_map(map) when is_map(map) do
    %__MODULE__{
      message_id: map["messageId"] || map["message_id"],
      role: parse_role(map["role"]),
      parts: parse_parts(map["parts"] || []),
      context_id: map["contextId"] || map["context_id"],
      task_id: map["taskId"] || map["task_id"],
      reference_task_ids: map["referenceTaskIds"] || map["reference_task_ids"],
      extensions: map["extensions"],
      metadata: map["metadata"]
    }
  end

  defp role_to_string(:user), do: "user"
  defp role_to_string(:agent), do: "agent"

  defp parse_role("user"), do: :user
  defp parse_role("agent"), do: :agent
  defp parse_role(_), do: :user

  defp parse_parts(parts) when is_list(parts), do: Enum.map(parts, &Part.from_map/1)
  defp parse_parts(_), do: []

  defp generate_id, do: "msg-" <> Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)
end
