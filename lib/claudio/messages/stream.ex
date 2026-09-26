defmodule Claudio.Messages.Stream do
  @moduledoc """
  Utilities for parsing and consuming Server-Sent Events (SSE) from streaming Messages API responses.

  Streaming usage telemetry is emitted via `[:claudio, :messages, :stream, :usage]`
  when `parse_events/1` reaches the terminal `message_stop` event; the usage is
  `message_start`'s merged with the `message_delta` frames (delta wins). Metadata carries `:input_tokens`,
  `:output_tokens`, the cache counters and `:thinking_tokens` when present.

  ## Event Types

  The Messages API streaming responses include the following event types:
  - `message_start` - Initial message with empty content
  - `content_block_start` - Beginning of a content block
  - `content_block_delta` - Incremental content updates (text, JSON, thinking);
    read them with `accumulate_text/1` / `accumulate_thinking/1`
  - `content_block_stop` - End of a content block
  - `message_delta` - Top-level message changes (usage updates)
  - `message_stop` - Stream completion
  - `ping` - Keep-alive events
  - `error` - Error events

  ## Example

      {:ok, response} =
        Claudio.Messages.create(client, Claudio.Messages.Request.enable_streaming(request))

      response.body
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
    |> Stream.transform(fn -> "" end, &parse_chunk/2, &flush_buffer/1, fn _ -> :ok end)
    |> Stream.map(&parse_event/1)
    |> emit_usage_telemetry()
    |> halt_after_message_stop()
  end

  # Helper to stop consuming stream after message_stop event
  defp halt_after_message_stop(event_stream) do
    Stream.transform(event_stream, false, fn
      _event, true ->
        # Already saw message_stop, halt immediately
        {:halt, true}

      {:ok, %{event: "message_stop"}} = event, false ->
        # Emit message_stop and signal to halt next iteration
        {[event], true}

      {:ok, %{event: "error"}} = event, false ->
        # Emit error and signal to halt next iteration
        {[event], true}

      event, false ->
        # Continue normally
        {[event], false}
    end)
  end

  defp emit_usage_telemetry(event_stream) do
    # message_delta usage is cumulative but may omit fields message_start carried (e.g.
    # input_tokens, cache counters): merge, delta wins — as build_final_message/1 does.
    Stream.transform(event_stream, nil, fn
      {:ok, %{event: "message_start", data: %{} = data}} = event, _usage ->
        message = data["message"] || data[:message] || %{}
        {[event], merge_usage(nil, message["usage"] || message[:usage])}

      {:ok, %{event: "message_delta", data: %{} = data}} = event, usage ->
        {[event], merge_usage(usage, data["usage"] || data[:usage])}

      {:ok, %{event: "message_stop"}} = event, latest_usage ->
        maybe_emit_stream_usage_telemetry(latest_usage)
        {[event], latest_usage}

      event, latest_usage ->
        {[event], latest_usage}
    end)
  end

  defp merge_usage(current, nil), do: current
  defp merge_usage(nil, %{} = usage), do: stringify_keys(usage)
  defp merge_usage(%{} = current, %{} = usage), do: Map.merge(current, stringify_keys(usage))

  defp maybe_emit_stream_usage_telemetry(usage) when is_map(usage) do
    metadata = usage_to_metadata(usage)

    if map_size(metadata) > 0 do
      :telemetry.execute([:claudio, :messages, :stream, :usage], %{}, metadata)
    end
  end

  defp maybe_emit_stream_usage_telemetry(_), do: :ok

  defp usage_to_metadata(usage) when is_map(usage) do
    %{}
    |> maybe_put_usage_key(:input_tokens, usage)
    |> maybe_put_usage_key(:output_tokens, usage)
    |> maybe_put_usage_key(:cache_creation_input_tokens, usage)
    |> maybe_put_usage_key(:cache_read_input_tokens, usage)
    |> maybe_put_thinking_tokens(usage)
  end

  # The final message_delta carries usage.output_tokens_details.thinking_tokens.
  defp maybe_put_thinking_tokens(metadata, usage) do
    case usage["output_tokens_details"] || usage[:output_tokens_details] do
      %{} = details ->
        case details["thinking_tokens"] || details[:thinking_tokens] do
          nil -> metadata
          tokens -> Map.put(metadata, :thinking_tokens, tokens)
        end

      _ ->
        metadata
    end
  end

  defp maybe_put_usage_key(metadata, key, usage) do
    case Map.get(usage, key) || Map.get(usage, Atom.to_string(key)) do
      nil -> metadata
      value -> Map.put(metadata, key, value)
    end
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

  @doc ~S"""
  Emits `{block_index, text}` for every `thinking_delta` with non-empty text.

  The index tells one `thinking` block from the next: with `display: :updates` each
  block is a separate progress note, and a block's first emission is the point the
  API docs say to treat it as an update. Empty deltas (`display: :omitted`),
  other deltas, other events and `{:error, _}` items emit nothing.

  The index is `nil` only for a malformed frame with no `"index"` (the API always
  sends one); its text is still emitted rather than dropped.

  ## Example

      response
      |> Stream.parse_events()
      |> Stream.accumulate_thinking()
      |> Enum.each(fn {index, text} -> IO.puts("[#{index}] #{text}") end)
  """
  @spec accumulate_thinking(Enumerable.t()) :: Enumerable.t()
  def accumulate_thinking(event_stream) do
    Stream.flat_map(event_stream, fn
      {:ok, %{event: "content_block_delta", data: data}} when is_map(data) ->
        delta = data["delta"] || data[:delta] || %{}
        type = delta["type"] || delta[:type]
        text = delta["thinking"] || delta[:thinking]

        if type == "thinking_delta" and is_binary(text) and text != "" do
          [{data["index"] || data[:index], text}]
        else
          []
        end

      _ ->
        []
    end)
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

  Streamed tool input (`input_json_delta` chunks on `tool_use`, `server_tool_use` and
  `mcp_tool_use` blocks) is decoded into the block's `"input"`. If a block's accumulated
  JSON is invalid — typically output cut off by `max_tokens` mid-call — the result is
  `{:error, {:invalid_tool_input_json, index, partial_json}}`.

  ## Example

      {:ok, final_message} =
        response
        |> Stream.parse_events()
        |> Stream.build_final_message()
  """
  @spec build_final_message(Enumerable.t()) :: {:ok, map()} | {:error, term()}
  def build_final_message(event_stream) do
    # Open blocks are keyed by index (a delta or stop names its block), and closed blocks
    # are ordered by index, so interleaved blocks can't overwrite each other.
    initial_state = %{
      message: %{},
      content_blocks: [],
      open_blocks: %{},
      last_index: nil,
      saw_stop: false,
      error: nil
    }

    final_state =
      Enum.reduce(event_stream, initial_state, fn
        {:ok, %{event: "message_start", data: data}}, state when is_map(data) ->
          message = data["message"] || data[:message] || %{}
          # Convert atom keys to string keys for consistency
          message_with_string_keys = atomize_to_stringify(message)
          %{state | message: message_with_string_keys}

        {:ok, %{event: "content_block_start", data: data}}, state when is_map(data) ->
          block = data["content_block"] || data[:content_block]
          index = data["index"] || data[:index]
          %{state | open_blocks: Map.put(state.open_blocks, index, block), last_index: index}

        {:ok, %{event: "content_block_delta", data: data}}, state when is_map(data) ->
          update_open_block(state, data)

        {:ok, %{event: "content_block_stop", data: data}}, state ->
          close_block(state, event_index(data, state))

        {:ok, %{event: "message_delta", data: data}}, state when is_map(data) ->
          delta = data["delta"] || data[:delta] || %{}
          usage = data["usage"] || data[:usage]

          message =
            state.message
            |> maybe_update(delta, "stop_reason")
            |> maybe_update(delta, "stop_sequence")
            |> maybe_update(delta, "stop_details")
            # Programmatic tool calling: the container may be refreshed here (S14).
            |> maybe_update(delta, "container")
            |> maybe_put_usage(usage)
            # context_management sits at the event's top level, beside delta and usage.
            |> maybe_update(data, "context_management")
            # After a mid-stream fallback the final message_delta repeats input_transformations
            # at the event's top level (SDK BetaRawMessageDeltaEvent) with the serving
            # model's entries, replacing the message_start value.
            |> maybe_update(data, "input_transformations")

          %{state | message: message}

        {:ok, %{event: "message_stop"}}, state ->
          %{state | saw_stop: true}

        {:ok, %{event: "ping"}}, state ->
          state

        {:ok, %{event: "error", data: data}}, state ->
          %{state | error: data}

        {:error, reason}, state ->
          %{state | error: reason}

        _, state ->
          state
      end)

    cond do
      final_state.error ->
        {:error, final_state.error}

      # A block that started but never stopped means the stream was cut off: report it
      # instead of returning a message silently missing that content.
      map_size(final_state.open_blocks) > 0 ->
        {:error, {:incomplete_stream, final_state.open_blocks |> Map.keys() |> Enum.sort()}}

      # Cut off between blocks (or never started): no stop_reason, possibly missing content.
      not final_state.saw_stop ->
        {:error, {:incomplete_stream, :no_message_stop}}

      true ->
        content =
          final_state.content_blocks
          |> Enum.with_index()
          |> Enum.sort_by(fn {{index, _block}, position} -> {index || position, position} end)
          |> Enum.map(fn {{_index, block}, _position} -> block end)

        {:ok, Map.put(final_state.message, "content", content)}
    end
  end

  defp event_index(data, state) when is_map(data),
    do: data["index"] || data[:index] || state.last_index

  defp event_index(_data, state), do: state.last_index

  defp close_block(state, index) do
    case Map.pop(state.open_blocks, index) do
      {nil, _open} ->
        state

      {block, open} ->
        case finalize_block(block) do
          {:ok, block} ->
            %{state | content_blocks: state.content_blocks ++ [{index, block}], open_blocks: open}

          {:error, partial_json} ->
            %{state | error: {:invalid_tool_input_json, index, partial_json}, open_blocks: open}
        end
    end
  end

  # Private functions

  # SSE framing: an event is every line up to a blank line. A network chunk can end
  # anywhere — mid-line, mid-event, mid-UTF-8 sequence — so the buffer keeps everything
  # after the last complete event, not just the last line. CRLF is normalized to LF.
  defp parse_chunk(chunk, buffer) do
    data = String.replace(buffer <> chunk, "\r\n", "\n")
    parts = String.split(data, "\n\n")
    {complete, [rest]} = Enum.split(parts, -1)
    {Enum.flat_map(complete, &event_from_block/1), rest}
  end

  # A stream that ends without a trailing blank line still carries its last event.
  defp flush_buffer(buffer) do
    {event_from_block(String.replace(buffer, "\r\n", "\n")), buffer}
  end

  # Per the SSE spec, an event with no data line is not dispatched.
  defp event_from_block(block) do
    case parse_sse_lines(String.split(block, "\n")) do
      %{data: nil} -> []
      event -> [event]
    end
  end

  defp parse_sse_lines(lines) do
    event =
      Enum.reduce(lines, %{event: nil, data: nil}, fn line, acc ->
        cond do
          String.starts_with?(line, "event:") ->
            event_type = line |> String.slice(6..-1//1) |> String.trim()
            %{acc | event: event_type}

          String.starts_with?(line, "data:") ->
            data = line |> String.slice(5..-1//1) |> String.trim()
            # Multiple data lines in one event are joined with a newline (SSE spec).
            %{acc | data: if(acc.data, do: acc.data <> "\n" <> data, else: data)}

          true ->
            acc
        end
      end)

    event
  end

  defp parse_event(%{event: event_type, data: data_str}) when is_binary(data_str) do
    # Decode with string keys (Jason's default). Earlier versions used
    # `keys: :atoms`, which produced atom-keyed data maps — inconsistent with
    # the raw Anthropic JSON convention and a footgun for downstream consumers
    # that pattern-match on string keys (e.g. Normandy's adapter). The
    # accumulator helpers in this module already read `data["x"] || data[:x]`
    # defensively, so switching to strings is a no-op internally.
    case Jason.decode(data_str) do
      {:ok, data} -> {:ok, %{event: event_type, data: data}}
      {:error, reason} -> {:error, {:invalid_event_data_json, event_type, reason}}
    end
  end

  defp parse_event(other) do
    {:error, {:invalid_event, other}}
  end

  defp update_open_block(state, data) do
    index = event_index(data, state)

    case Map.fetch(state.open_blocks, index) do
      {:ok, block} ->
        delta = data["delta"] || data[:delta] || %{}
        %{state | open_blocks: Map.put(state.open_blocks, index, apply_delta(block, delta))}

      :error ->
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

  defp apply_delta(block, %{"type" => "signature_delta", "signature" => signature}) do
    Map.put(block, "signature", signature)
  end

  defp apply_delta(block, %{type: "signature_delta", signature: signature}) do
    Map.put(block, :signature, signature)
  end

  defp apply_delta(block, %{"type" => "citations_delta", "citation" => citation}) do
    current = block["citations"] || block[:citations] || []
    Map.put(block, "citations", current ++ [citation])
  end

  defp apply_delta(block, %{type: "citations_delta", citation: citation}) do
    current = block[:citations] || block["citations"] || []
    Map.put(block, :citations, current ++ [citation])
  end

  # Threshold compaction streams the whole summary in one compaction_delta after a
  # content_block_start with "content": null (probed 2026-09-26). Every delta field but
  # "type" is written into the block, so encrypted_content/signature survive if sent.
  defp apply_delta(block, %{"type" => "compaction_delta"} = delta) do
    Map.merge(block, Map.delete(delta, "type"))
  end

  defp apply_delta(block, %{type: "compaction_delta"} = delta) do
    Map.merge(block, Map.delete(delta, :type))
  end

  defp apply_delta(block, _delta), do: block

  # Streamed tool input (tool_use, server_tool_use, mcp_tool_use) arrives as
  # input_json_delta string chunks; decode them into "input" once the block is complete.
  # Invalid JSON (output cut off by max_tokens, or eager input streaming) is an error
  # rather than a block with half its input.
  defp finalize_block(%{"partial_json" => json} = block) do
    with {:ok, input} <- decode_tool_input(json),
         do: {:ok, block |> Map.delete("partial_json") |> Map.put("input", input)}
  end

  defp finalize_block(%{partial_json: json} = block) do
    with {:ok, input} <- decode_tool_input(json),
         do: {:ok, block |> Map.delete(:partial_json) |> Map.put(:input, input)}
  end

  defp finalize_block(block), do: {:ok, block}

  defp decode_tool_input(""), do: {:ok, %{}}

  defp decode_tool_input(json) do
    case Jason.decode(json) do
      {:ok, %{} = input} -> {:ok, input}
      _ -> {:error, json}
    end
  end

  defp maybe_update(map, delta, key) do
    case Map.get(delta, key) || Map.get(delta, String.to_atom(key)) do
      nil -> map
      value -> Map.put(map, key, value)
    end
  end

  defp maybe_put_usage(map, nil), do: map

  # message_delta usage is cumulative but may omit fields message_start carried
  # (e.g. input_tokens): merge, delta wins. Top-level keys are stringified first so
  # an atom-keyed start and a string-keyed delta cannot keep both copies of a field.
  defp maybe_put_usage(map, usage) do
    case Map.get(map, "usage") do
      %{} = current ->
        Map.put(map, "usage", Map.merge(stringify_keys(current), stringify_keys(usage)))

      _ ->
        Map.put(map, "usage", usage)
    end
  end

  defp stringify_keys(%{} = map), do: Map.new(map, fn {k, v} -> {to_string(k), v} end)

  # Convert a map with atom keys to string keys (shallow conversion for top level only)
  defp atomize_to_stringify(map) when is_map(map) do
    Map.new(map, fn
      {key, value} when is_atom(key) -> {Atom.to_string(key), value}
      {key, value} -> {key, value}
    end)
  end

  defp atomize_to_stringify(other), do: other
end
