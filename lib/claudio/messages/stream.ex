defmodule Claudio.Messages.Stream do
  @moduledoc """
  Utilities for parsing and consuming Server-Sent Events (SSE) from streaming Messages API responses.

  `parse_events/1` emits `[:claudio, :messages, :stream, :start | :stop]` around each consumption
  (and the older `[:claudio, :messages, :stream, :usage]`); see the [telemetry guide](telemetry.html).

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

  The simplest way to stream is `to_response/2`: print text as it arrives and still get
  `usage`, `stop_reason` and tool calls at the end.

      {:ok, stream_response} =
        Claudio.Messages.create(client, Claudio.Messages.Request.enable_streaming(request))

      {:ok, response} =
        Claudio.Messages.Stream.to_response(stream_response, on_text: &IO.write/1)

  For lower-level control, enumerate the parsed events:

      stream_response
      |> Claudio.Messages.Stream.parse_events()
      |> Stream.filter(&match?({:ok, %{event: "content_block_delta"}}, &1))
      |> Enum.each(fn {:ok, event} ->
        IO.puts(event.data["delta"]["text"])
      end)

  ## Consume once

  A streaming body can be read **once**, and only by the process that called
  `Claudio.Messages.create/2`: a second read waits forever, and a read from another
  process raises. Use the `:on_text` / `:on_event` options of `to_response/2` instead of
  enumerating the response twice.
  """

  alias Claudio.Messages.Response

  @type event :: %{
          event: String.t(),
          data: map() | nil
        }

  @type parsed_event :: {:ok, event()} | {:error, term()}

  @doc """
  Consumes a streaming response in one pass and returns the final `Claudio.Messages.Response`.

  The simplest way to stream: print text as it arrives and still get `usage`,
  `stop_reason` and tool calls at the end.

      {:ok, response} =
        Claudio.Messages.Stream.to_response(stream_response, on_text: &IO.write/1)

      response.usage.output_tokens

  ## Options

  - `:on_text` — called with each text delta, in order.
  - `:on_event` — called with each parsed event (`{:ok, event} | {:error, reason}`).

  A streaming body can be read **once**, and only by the process that called
  `Claudio.Messages.create/2`: a second read waits forever, and a read from another
  process raises. Use `:on_text` / `:on_event` instead of enumerating the response twice.

  An SSE `error` event is returned as `{:error, %Claudio.APIError{}}`; other failures are
  as for `build_final_message/1`. That error's `status_code` is `200` (the stream's HTTP
  status), so match on its `type`.
  """
  @spec to_response(Req.Response.t() | Enumerable.t(), keyword()) ::
          {:ok, Response.t()} | {:error, term()}
  def to_response(source, opts \\ []) do
    opts = Claudio.Options.validate!(opts, [:on_text, :on_event], "Stream.to_response/2")
    on_text = Keyword.get(opts, :on_text)
    on_event = Keyword.get(opts, :on_event)

    source
    |> parse_events()
    |> Elixir.Stream.each(fn event ->
      if on_event, do: on_event.(event)
      if on_text, do: maybe_text(event, on_text)
    end)
    |> build_final_message()
    |> case do
      {:ok, message} -> {:ok, Response.from_map(message)}
      {:error, %{"type" => "error"} = data} -> {:error, Claudio.APIError.from_response(200, data)}
      {:error, _} = error -> error
    end
  end

  defp maybe_text(
         {:ok,
          %{
            event: "content_block_delta",
            data: %{"delta" => %{"type" => "text_delta", "text" => text}}
          }},
         fun
       )
       when is_binary(text),
       do: fun.(text)

  defp maybe_text(_event, _fun), do: :ok

  @doc """
  Parses Server-Sent Events from a streaming response body.

  Returns a Stream of `{:ok, event}` or `{:error, reason}` tuples.

  Pass the whole `%Req.Response{}` from `Claudio.Messages.create/2` to link the stream span
  to the `create` span; passing `response.body` still works, unlinked.

  Emits `[:claudio, :messages, :stream, :start | :stop]` around each consumption of the
  returned stream; see the [telemetry guide](telemetry.html).

  ## Example

      response
      |> Stream.parse_events()
      |> Enum.to_list()
  """
  @spec parse_events(Req.Response.t() | Enumerable.t()) :: Enumerable.t()
  def parse_events(%Req.Response{body: body} = response) do
    # A non-async body (e.g. a Req.Test plug) is the whole SSE payload as one binary.
    body = if is_binary(body), do: [body], else: body
    do_parse_events(body, Req.Response.get_private(response, :claudio))
  end

  def parse_events(stream), do: do_parse_events(stream, nil)

  defp do_parse_events(stream, link) do
    stream
    |> Stream.transform(fn -> "" end, &parse_chunk/2, &flush_buffer/1, fn _ -> :ok end)
    |> Stream.map(&parse_event/1)
    |> emit_usage_telemetry()
    |> halt_after_message_stop()
    |> stream_span(link)
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

  # [:claudio, :messages, :stream] :start/:stop around one consumption. Exactly one :stop per
  # :start: on message_stop, an SSE error, a parse error, the upstream ending without
  # message_stop (last fun), or the consumer halting (after fun).
  defp stream_span(events, link) do
    Stream.transform(
      events,
      fn -> new_span(link) end,
      &span_event/2,
      fn span -> {[], finish_span(span, :error, :incomplete_stream)} end,
      fn span -> finish_span(span, :halted, nil) end
    )
  end

  defp new_span(link) do
    %{
      link: link,
      started?: false,
      stopped?: false,
      # The span covers the whole consumption: its clock starts here, not at message_start.
      start_time: System.monotonic_time(),
      start_system_time: System.system_time(),
      metadata: %{},
      usage: nil,
      stop_reason: nil,
      fallback_model: nil
    }
  end

  defp span_event({:ok, %{event: "message_start", data: %{} = data} = parsed} = event, span) do
    span =
      case {span.started?, map_field(data, :message)} do
        {false, %{} = message} -> start_span(span, field(message, :model), field(message, :id))
        _ -> span
      end

    {[event], %{span | usage: track_usage(span.usage, parsed)}}
  end

  defp span_event({:ok, %{event: "message_delta", data: %{} = data} = parsed} = event, span) do
    stop_reason =
      case data do
        %{"delta" => %{"stop_reason" => reason}} when is_binary(reason) -> reason
        _ -> span.stop_reason
      end

    {[event], %{span | usage: track_usage(span.usage, parsed), stop_reason: stop_reason}}
  end

  defp span_event(
         {:ok,
          %{
            event: "content_block_start",
            data: %{"content_block" => %{"type" => "fallback", "to" => %{"model" => model}}}
          }} = event,
         span
       )
       when is_binary(model),
       do: {[event], %{span | fallback_model: model}}

  defp span_event({:ok, %{event: "message_stop"}} = event, span),
    do: {[event], finish_span(span, :completed, nil)}

  defp span_event({:ok, %{event: "error", data: data}} = event, span) do
    error_type =
      case data do
        %{"error" => %{"type" => type}} when is_binary(type) ->
          sse_error_type(type)

        _ ->
          :stream_error
      end

    {[event], finish_span(span, :error, error_type)}
  end

  defp span_event({:error, _reason} = event, span),
    do: {[event], finish_span(span, :error, :parse_error)}

  defp span_event(event, span), do: {[event], span}

  # Known API types become the same atoms `create` reports; an unknown identifier stays a
  # bounded string; anything else (empty, free text) is :unknown.
  defp sse_error_type(type) do
    case Claudio.APIError.parse_type(type) do
      nil -> :unknown
      atom when is_atom(atom) -> atom
      string -> Claudio.Telemetry.bounded_type(string) || :unknown
    end
  end

  defp start_span(span, model, response_id) do
    link_model = if span.link, do: span.link[:model]

    metadata =
      %{telemetry_span_context: make_ref()}
      |> Claudio.Telemetry.put_present(:model, model || link_model)
      |> Claudio.Telemetry.put_present(:response_id, response_id)
      |> put_link(span.link)

    :telemetry.execute(
      [:claudio, :messages, :stream, :start],
      %{monotonic_time: span.start_time, system_time: span.start_system_time},
      metadata
    )

    %{span | started?: true, metadata: metadata}
  end

  defp put_link(metadata, %{span_context: ctx} = link) do
    metadata
    |> Map.put(:parent_span_context, ctx)
    |> Claudio.Telemetry.put_present(:request_id, link[:request_id])
    |> Claudio.Telemetry.put_present(:request_model, link[:model])
    |> Map.merge(link[:request_metadata] || %{})
  end

  defp put_link(metadata, _link), do: metadata

  defp finish_span(%{stopped?: true} = span, _reason, _error_type), do: span

  defp finish_span(%{started?: false} = span, reason, error_type),
    do: span |> start_span(nil, nil) |> finish_span(reason, error_type)

  defp finish_span(span, reason, error_type) do
    now = System.monotonic_time()
    tokens = Claudio.Telemetry.usage(span.usage)

    metadata =
      span.metadata
      |> Map.merge(tokens)
      |> Map.put(:reason, reason)
      |> Claudio.Telemetry.put_present(:stop_reason, Response.parse_stop_reason(span.stop_reason))
      |> Claudio.Telemetry.put_present(
        :response_model,
        span.fallback_model || span.metadata[:model]
      )
      |> Claudio.Telemetry.put_present(:error_type, error_type)

    :telemetry.execute(
      [:claudio, :messages, :stream, :stop],
      Map.merge(tokens, %{duration: now - span.start_time, monotonic_time: now}),
      metadata
    )

    %{span | stopped?: true}
  end

  defp emit_usage_telemetry(event_stream) do
    # message_delta usage is cumulative but may omit fields message_start carried (e.g.
    # input_tokens, cache counters): merge, delta wins — as build_final_message/1 does.
    Stream.transform(event_stream, nil, fn
      {:ok, %{event: "message_stop"}} = event, latest_usage ->
        maybe_emit_stream_usage_telemetry(latest_usage)
        {[event], latest_usage}

      {:ok, %{} = parsed} = event, usage ->
        {[event], track_usage(usage, parsed)}

      event, latest_usage ->
        {[event], latest_usage}
    end)
  end

  # The running usage after `event`, shared by the :usage and span stages so they cannot drift:
  # message_start resets it to the message's usage, message_delta merges over it (delta wins).
  defp track_usage(_usage, %{event: "message_start", data: %{}} = event),
    do: merge_usage(nil, event_usage(event))

  defp track_usage(usage, %{event: "message_delta", data: %{}} = event),
    do: merge_usage(usage, event_usage(event))

  defp track_usage(usage, _event), do: usage

  # The usage map an event carries (message_start: data.message.usage; message_delta:
  # data.usage), string or atom keys; nil when absent or not a map.
  defp event_usage(%{event: "message_start", data: data}),
    do: data |> map_field(:message) |> map_field(:usage)

  defp event_usage(%{event: "message_delta", data: data}), do: map_field(data, :usage)

  # A field under its string key, else its atom key.
  # A stored `false` is a value, not an absent key.
  defp field(map, key) do
    case Map.fetch(map, Atom.to_string(key)) do
      {:ok, value} -> value
      :error -> Map.get(map, key)
    end
  end

  # A map-valued field; nil when absent or not a map.
  defp map_field(%{} = map, key) do
    case field(map, key) do
      %{} = value -> value
      _ -> nil
    end
  end

  defp map_field(_not_a_map, _key), do: nil

  defp merge_usage(current, nil), do: current
  defp merge_usage(nil, %{} = usage), do: stringify_keys(usage)
  defp merge_usage(%{} = current, %{} = usage), do: Map.merge(current, stringify_keys(usage))

  defp maybe_emit_stream_usage_telemetry(usage) when is_map(usage) do
    metadata = Claudio.Telemetry.usage(usage)

    if map_size(metadata) > 0 do
      :telemetry.execute([:claudio, :messages, :stream, :usage], %{}, metadata)
    end
  end

  defp maybe_emit_stream_usage_telemetry(_), do: :ok

  @doc """
  Emits the text of each `text_delta` event as a stream of text *chunks*.

  Enumerate them, or `Enum.join/1` them for the full text.

  ## Example

      response
      |> Stream.parse_events()
      |> Stream.accumulate_text()
      |> Enum.each(&IO.write/1)
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
  # credo:disable-for-next-line Credo.Check.Refactor.CyclomaticComplexity
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
