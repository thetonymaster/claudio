defmodule Claudio.A2A.Transport.GRPC do
  @moduledoc """
  gRPC transport for the A2A protocol (v0.3+).

  Requires optional dependencies:

      {:protox, "~> 1.7"}
      {:grpc, "~> 0.11"}

  > **Note:** This transport is not yet implemented. It will use protox for
  > protobuf encoding and the grpc package for transport. See `a2a.proto`
  > for the service definition.
  """

  @behaviour Claudio.A2A.Transport

  @impl true
  def discover(_endpoint, _opts) do
    {:error, :grpc_not_implemented}
  end

  @impl true
  def send_message(_endpoint, _message, _opts) do
    {:error, :grpc_not_implemented}
  end

  @impl true
  def get_task(_endpoint, _task_id, _opts) do
    {:error, :grpc_not_implemented}
  end

  @impl true
  def list_tasks(_endpoint, _opts) do
    {:error, :grpc_not_implemented}
  end

  @impl true
  def cancel_task(_endpoint, _task_id, _opts) do
    {:error, :grpc_not_implemented}
  end
end
