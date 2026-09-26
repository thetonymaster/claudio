defmodule Claudio.Options do
  @moduledoc false

  # Keyword.validate!/2 with an error that names the public function, so the message is
  # enough to find the bad call when it is logged without a stacktrace. `fun` is the
  # caller's name as users write it, e.g. "Request.add_web_search_tool/2".
  @spec validate!(term(), [atom()], String.t()) :: keyword()
  def validate!(opts, allowed, fun) do
    unless Keyword.keyword?(opts) do
      raise ArgumentError, "#{fun}: options must be a keyword list; got #{inspect(opts)}"
    end

    case opts |> Keyword.keys() |> Enum.uniq() |> Enum.reject(&(&1 in allowed)) do
      [] ->
        opts

      unknown ->
        noun = if match?([_], unknown), do: "option", else: "options"

        raise ArgumentError,
              "#{fun}: unknown #{noun} #{join(unknown)}; allowed: #{join(allowed)}"
    end
  end

  defp join(keys), do: Enum.map_join(keys, ", ", &inspect/1)
end
