defmodule Claudio.Messages.Response do
  @moduledoc """
  Structured response from the Messages API.
  """

  @type stop_reason ::
          :end_turn
          | :max_tokens
          | :stop_sequence
          | :tool_use
          | :pause_turn
          | :refusal
          | :model_context_window_exceeded

  @type content_block ::
          text_block()
          | thinking_block()
          | tool_use_block()
          | tool_result_block()

  @type text_block :: %{
          type: :text,
          text: String.t()
        }

  @type thinking_block :: %{
          type: :thinking,
          thinking: String.t()
        }

  @type tool_use_block :: %{
          type: :tool_use,
          id: String.t(),
          name: String.t(),
          input: map()
        }

  @type tool_result_block :: %{
          type: :tool_result,
          tool_use_id: String.t(),
          content: String.t() | list()
        }

  @type usage :: %{
          input_tokens: integer(),
          output_tokens: integer(),
          cache_creation_input_tokens: integer() | nil,
          cache_read_input_tokens: integer() | nil
        }

  @type t :: %__MODULE__{
          id: String.t(),
          type: String.t(),
          role: String.t(),
          model: String.t(),
          content: list(content_block()),
          stop_reason: stop_reason() | nil,
          stop_sequence: String.t() | nil,
          usage: usage()
        }

  defstruct [
    :id,
    :type,
    :role,
    :model,
    :content,
    :stop_reason,
    :stop_sequence,
    :usage
  ]

  @doc """
  Converts a raw API response map into a structured Response.
  """
  @spec from_map(map()) :: t()
  def from_map(data) when is_map(data) do
    %__MODULE__{
      id: data[:id] || data["id"],
      type: data[:type] || data["type"],
      role: data[:role] || data["role"],
      model: data[:model] || data["model"],
      content: parse_content(data[:content] || data["content"] || []),
      stop_reason: parse_stop_reason(data[:stop_reason] || data["stop_reason"]),
      stop_sequence: data[:stop_sequence] || data["stop_sequence"],
      usage: parse_usage(data[:usage] || data["usage"])
    }
  end

  @doc """
  Extracts all text content from the response.
  """
  @spec get_text(t()) :: String.t()
  def get_text(%__MODULE__{content: content}) do
    content
    |> Enum.filter(&(&1.type == :text))
    |> Enum.map(& &1.text)
    |> Enum.join("")
  end

  @doc """
  Extracts all tool use requests from the response.
  """
  @spec get_tool_uses(t()) :: list(tool_use_block())
  def get_tool_uses(%__MODULE__{content: content}) do
    Enum.filter(content, &(&1.type == :tool_use))
  end

  defp parse_content(content) when is_list(content) do
    Enum.map(content, &parse_content_block/1)
  end

  defp parse_content_block(%{type: "text"} = block) do
    %{type: :text, text: block[:text] || block["text"]}
  end

  defp parse_content_block(%{"type" => "text"} = block) do
    %{type: :text, text: block["text"]}
  end

  defp parse_content_block(%{type: "thinking"} = block) do
    %{type: :thinking, thinking: block[:thinking] || block["thinking"]}
  end

  defp parse_content_block(%{"type" => "thinking"} = block) do
    %{type: :thinking, thinking: block["thinking"]}
  end

  defp parse_content_block(%{type: "tool_use"} = block) do
    %{
      type: :tool_use,
      id: block[:id] || block["id"],
      name: block[:name] || block["name"],
      input: block[:input] || block["input"]
    }
  end

  defp parse_content_block(%{"type" => "tool_use"} = block) do
    %{
      type: :tool_use,
      id: block["id"],
      name: block["name"],
      input: block["input"]
    }
  end

  defp parse_content_block(%{type: "tool_result"} = block) do
    %{
      type: :tool_result,
      tool_use_id: block[:tool_use_id] || block["tool_use_id"],
      content: block[:content] || block["content"]
    }
  end

  defp parse_content_block(%{"type" => "tool_result"} = block) do
    %{
      type: :tool_result,
      tool_use_id: block["tool_use_id"],
      content: block["content"]
    }
  end

  defp parse_content_block(block), do: block

  defp parse_stop_reason("end_turn"), do: :end_turn
  defp parse_stop_reason("max_tokens"), do: :max_tokens
  defp parse_stop_reason("stop_sequence"), do: :stop_sequence
  defp parse_stop_reason("tool_use"), do: :tool_use
  defp parse_stop_reason("pause_turn"), do: :pause_turn
  defp parse_stop_reason("refusal"), do: :refusal
  defp parse_stop_reason("model_context_window_exceeded"), do: :model_context_window_exceeded
  defp parse_stop_reason(nil), do: nil
  defp parse_stop_reason(other), do: other

  defp parse_usage(%{input_tokens: input, output_tokens: output} = usage) do
    %{
      input_tokens: input,
      output_tokens: output,
      cache_creation_input_tokens: usage[:cache_creation_input_tokens],
      cache_read_input_tokens: usage[:cache_read_input_tokens]
    }
  end

  defp parse_usage(%{"input_tokens" => input, "output_tokens" => output} = usage) do
    %{
      input_tokens: input,
      output_tokens: output,
      cache_creation_input_tokens: usage["cache_creation_input_tokens"],
      cache_read_input_tokens: usage["cache_read_input_tokens"]
    }
  end

  defp parse_usage(nil) do
    %{
      input_tokens: 0,
      output_tokens: 0,
      cache_creation_input_tokens: nil,
      cache_read_input_tokens: nil
    }
  end

  defp parse_usage(other), do: other
end
