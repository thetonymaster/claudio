defmodule Claudio.A2A.Util do
  @moduledoc false

  @doc "Put a key-value pair into a map only if the value is not nil."
  def maybe_put(map, _key, nil), do: map
  def maybe_put(map, key, value), do: Map.put(map, key, value)
end
