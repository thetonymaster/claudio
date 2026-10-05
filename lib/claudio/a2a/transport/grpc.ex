defmodule Claudio.A2A.Transport.GRPC do
  @moduledoc """
  gRPC transport for the A2A protocol (v0.3+).

  > **Not implemented.** Every callback returns `{:error, :grpc_not_implemented}`.
  > The module exists so the `Claudio.A2A.Transport` behaviour has a placeholder
  > for the gRPC binding; use `Claudio.A2A.Transport.HTTP` (the default).
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
