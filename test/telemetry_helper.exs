defmodule Claudio.TelemetryTestSupport do
  @moduledoc false
  import ExUnit.Callbacks, only: [on_exit: 1]

  # Forwards the given events to the test process as {:telemetry, event, measurements, metadata}.
  # Handlers run in the emitting process and test modules are async, so by default only events
  # emitted by the test process itself are forwarded; pass `filter:` (metadata -> boolean) for
  # events emitted elsewhere (e.g. a stream consumed in a Task).
  def attach(events, opts \\ []) do
    id = "claudio-telemetry-test-#{System.unique_integer([:positive])}"
    :ok = :telemetry.attach_many(id, events, &__MODULE__.forward/4, {self(), opts[:filter]})
    on_exit(fn -> :telemetry.detach(id) end)
  end

  def forward(event, measurements, metadata, {pid, nil}) do
    if self() == pid, do: send(pid, {:telemetry, event, measurements, metadata})
  end

  def forward(event, measurements, metadata, {pid, filter}) do
    if filter.(metadata), do: send(pid, {:telemetry, event, measurements, metadata})
  end
end
