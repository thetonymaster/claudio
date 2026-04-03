defmodule Claudio.A2A.Part do
  @moduledoc """
  A2A Part — the smallest unit of content within a Message or Artifact.

  Parts can contain text, file references, raw bytes, or structured data.

  ## Examples

      Part.text("Hello, world!")
      Part.file("https://example.com/doc.pdf", "application/pdf")
      Part.data(%{"key" => "value"})
  """

  import Claudio.A2A.Util, only: [maybe_put: 3]

  @type t :: %__MODULE__{
          text: String.t() | nil,
          raw: binary() | nil,
          url: String.t() | nil,
          data: term() | nil,
          filename: String.t() | nil,
          media_type: String.t() | nil,
          metadata: map() | nil
        }

  defstruct [:text, :raw, :url, :data, :filename, :media_type, :metadata]

  @doc "Create a text part."
  @spec text(String.t()) :: t()
  def text(content) when is_binary(content) do
    %__MODULE__{text: content}
  end

  @doc "Create a file reference part."
  @spec file(String.t(), String.t()) :: t()
  def file(url, media_type) when is_binary(url) and is_binary(media_type) do
    %__MODULE__{url: url, media_type: media_type}
  end

  @doc "Create a structured data part."
  @spec data(term()) :: t()
  def data(value) do
    %__MODULE__{data: value}
  end

  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = part) do
    %{}
    |> maybe_put("text", part.text)
    |> maybe_put("raw", part.raw)
    |> maybe_put("url", part.url)
    |> maybe_put("data", part.data)
    |> maybe_put("filename", part.filename)
    |> maybe_put("mediaType", part.media_type)
    |> maybe_put("metadata", part.metadata)
  end

  @spec from_map(map()) :: t()
  def from_map(map) when is_map(map) do
    %__MODULE__{
      text: map["text"],
      raw: map["raw"],
      url: map["url"],
      data: map["data"],
      filename: map["filename"],
      media_type: map["mediaType"] || map["media_type"],
      metadata: map["metadata"]
    }
  end
end
