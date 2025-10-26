defmodule Claudio.Messages.Stream do
  @moduledoc """
  Utilities for parsing and consuming Server-Sent Events (SSE) from streaming Messages API responses.

  ## Event Types

  The Messages API streaming responses include the following event types:
  - `message_start` - Initial message with empty content
  - `content_block_start` - Beginning of a content block
  - `content_block_delta` - Incremental content updates (text, JSON, thinking)
  - `content_block_stop` - End of a content block
  - `message_delta` - Top-level message changes (usage updates)
  - `message_stop` - Stream completion
  - `ping` - Keep-alive events
  - `error` - Error events

  ## Example

      response = Claudio.Messages.create_message(client, request)

      response
      |> Claudio.Messages.Stream.parse_events()
      |> Stream.filter(&match?({:ok, %{event: "content_block_delta"}}, &1))
      |> Enum.each(fn {:ok, event} ->
        IO.puts(event.data["delta"]["text"])
      end)
  """

  @type event :: %{
          event: String.t(),
          data: map() | nil
        }

  @type parsed_event :: {:ok, event()} | {:error, term()}

  @doc """
  Parses Server-Sent Events from a streaming response body.

  Returns a Stream of `{:ok, event}` or `{:error, reason}` tuples.

  ## Example

      response
      |> Stream.parse_events()
      |> Enum.to_list()
  """
  @spec parse_events(Enumerable.t()) :: Enumerable.t()
  def parse_events(stream) do
    stream
    |> Stream.transform("", &parse_chunk/2)
    |> Stream.map(&parse_event/1)
  end

  @doc """
  Accumulates text deltas from streaming events into complete text chunks.

  ## Example

      response
      |> Stream.parse_events()
      |> Stream.accumulate_text()
      |> Enum.each(&IO.puts/1)
  """
  @spec accumulate_text(Enumerable.t()) :: Enumerable.t()
  def accumulate_text(event_stream) do
    event_stream
    |> Stream.filter(fn
      {:ok, %{event: "content_block_delta", data: %{"delta" => %{"type" => "text_delta"}}}} ->
        true

      {:ok, %{event: "content_block_delta", data: %{delta: %{type: "text_delta"}}}} ->
        true

      _ ->
        false
    end)
    |> Stream.map(fn {:ok, %{data: data}} ->
      data["delta"]["text"] || data["delta"][:text] || data[:delta]["text"] ||
        data[:delta][:text]
    end)
    |> Stream.reject(&is_nil/1)
  end

  @doc """
  Filters stream to only specific event types.

  ## Example

      response
      |> Stream.parse_events()
      |> Stream.filter_events(["content_block_delta", "message_stop"])
  """
  @spec filter_events(Enumerable.t(), list(String.t())) :: Enumerable.t()
  def filter_events(event_stream, event_types) when is_list(event_types) do
    Stream.filter(event_stream, fn
      {:ok, %{event: event_type}} -> event_type in event_types
      _ -> false
    end)
  end

  @doc """
  Accumulates all events and returns the final complete message.

  ## Example

      {:ok, final_message} =
        response
        |> Stream.parse_events()
        |> Stream.build_final_message()
  """
  @spec build_final_message(Enumerable.t()) :: {:ok, map()} | {:error, term()}
  def build_final_message(event_stream) do
    initial_state = %{
      message: %{},
      content_blocks: [],
      current_block: nil,
      error: nil
    }

    final_state =
      Enum.reduce(event_stream, initial_state, fn
        {:ok, %{event: "message_start", data: data}}, state ->
          message = data["message"] || data[:message] || %{}
          # Convert atom keys to string keys for consistency
          message_with_string_keys = atomize_to_stringify(message)
          %{state | message: message_with_string_keys}

        {:ok, %{event: "content_block_start", data: data}}, state ->
          block = data["content_block"] || data[:content_block]
          index = data["index"] || data[:index]
          %{state | current_block: {index, block}}

        {:ok, %{event: "content_block_delta", data: data}}, state ->
          update_current_block(state, data)

        {:ok, %{event: "content_block_stop"}}, state ->
          case state.current_block do
            {_index, block} ->
              %{
                state
                | content_blocks: state.content_blocks ++ [block],
                  current_block: nil
              }

            nil ->
              state
          end

        {:ok, %{event: "message_delta", data: data}}, state ->
          delta = data["delta"] || data[:delta] || %{}
          usage = data["usage"] || data[:usage]

          message =
            state.message
            |> maybe_update(delta, "stop_reason")
            |> maybe_update(delta, "stop_sequence")
            |> maybe_put_usage(usage)

          %{state | message: message}

        {:ok, %{event: "message_stop"}}, state ->
          state

        {:ok, %{event: "ping"}}, state ->
          state

        {:ok, %{event: "error", data: data}}, state ->
          %{state | error: data}

        {:error, reason}, state ->
          %{state | error: reason}

        _, state ->
          state
      end)

    case final_state.error do
      nil ->
        message = Map.put(final_state.message, "content", final_state.content_blocks)
        {:ok, message}

      error ->
        {:error, error}
    end
  end

  # Private functions

  defp parse_chunk(chunk, buffer) do
    data = buffer <> chunk
    lines = String.split(data, "\n")

    case List.last(lines) do
      "" ->
        # Complete message, process all events
        events = extract_events(Enum.drop(lines, -1), [])
        {events, ""}

      _ ->
        # Incomplete message, keep last line in buffer
        events = extract_events(Enum.drop(lines, -1), [])
        {events, List.last(lines)}
    end
  end

  defp extract_events([], acc), do: Enum.reverse(acc)

  defp extract_events(lines, acc) do
    case parse_sse_block(lines) do
      {nil, rest} -> extract_events(rest, acc)
      {event, rest} -> extract_events(rest, [event | acc])
    end
  end

  defp parse_sse_block([]), do: {nil, []}

  defp parse_sse_block(lines) do
    {event_lines, rest} = Enum.split_while(lines, &(&1 != ""))
    rest = Enum.drop_while(rest, &(&1 == ""))

    if event_lines == [] do
      {nil, rest}
    else
      event = parse_sse_lines(event_lines)
      {event, rest}
    end
  end

  defp parse_sse_lines(lines) do
    Enum.reduce(lines, %{event: nil, data: nil}, fn line, acc ->
      cond do
        String.starts_with?(line, "event:") ->
          event_type = line |> String.slice(6..-1//1) |> String.trim()
          %{acc | event: event_type}

        String.starts_with?(line, "data:") ->
          data = line |> String.slice(5..-1//1) |> String.trim()
          %{acc | data: data}

        true ->
          acc
      end
    end)
  end

  defp parse_event(%{event: event_type, data: data_str}) when is_binary(data_str) do
    case Poison.decode(data_str, keys: :atoms) do
      {:ok, data} -> {:ok, %{event: event_type, data: data}}
      {:error, _} -> {:ok, %{event: event_type, data: nil}}
    end
  end

  defp parse_event(%{event: event_type, data: nil}) do
    {:ok, %{event: event_type, data: nil}}
  end

  defp parse_event(other) do
    {:error, {:invalid_event, other}}
  end

  defp update_current_block(state, data) do
    case state.current_block do
      {index, block} ->
        delta = data["delta"] || data[:delta] || %{}
        updated_block = apply_delta(block, delta)
        %{state | current_block: {index, updated_block}}

      nil ->
        state
    end
  end

  defp apply_delta(block, %{"type" => "text_delta", "text" => text}) do
    current_text = block["text"] || block[:text] || ""
    Map.put(block, "text", current_text <> text)
  end

  defp apply_delta(block, %{type: "text_delta", text: text}) do
    current_text = block["text"] || block[:text] || ""
    Map.put(block, :text, current_text <> text)
  end

  defp apply_delta(block, %{"type" => "input_json_delta", "partial_json" => json}) do
    current_json = block["partial_json"] || block[:partial_json] || ""
    Map.put(block, "partial_json", current_json <> json)
  end

  defp apply_delta(block, %{type: "input_json_delta", partial_json: json}) do
    current_json = block["partial_json"] || block[:partial_json] || ""
    Map.put(block, :partial_json, current_json <> json)
  end

  defp apply_delta(block, %{"type" => "thinking_delta", "thinking" => thinking}) do
    current_thinking = block["thinking"] || block[:thinking] || ""
    Map.put(block, "thinking", current_thinking <> thinking)
  end

  defp apply_delta(block, %{type: "thinking_delta", thinking: thinking}) do
    current_thinking = block["thinking"] || block[:thinking] || ""
    Map.put(block, :thinking, current_thinking <> thinking)
  end

  defp apply_delta(block, _delta), do: block

  defp maybe_update(map, delta, key) do
    case Map.get(delta, key) || Map.get(delta, String.to_atom(key)) do
      nil -> map
      value -> Map.put(map, key, value)
    end
  end

  defp maybe_put_usage(map, nil), do: map

  defp maybe_put_usage(map, usage) do
    Map.put(map, "usage", usage)
  end

  # Convert a map with atom keys to string keys (shallow conversion for top level only)
  defp atomize_to_stringify(map) when is_map(map) do
    Map.new(map, fn
      {key, value} when is_atom(key) -> {Atom.to_string(key), value}
      {key, value} -> {key, value}
    end)
  end

  defp atomize_to_stringify(other), do: other
end
