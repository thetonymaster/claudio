defmodule Claudio.APIError do
  @moduledoc """
  Exception raised when the Anthropic API returns an error response.
  """

  defexception [:type, :message, :status_code, :raw_body]

  @type error_type ::
          :invalid_request_error
          | :authentication_error
          | :billing_error
          | :permission_error
          | :not_found_error
          | :request_too_large
          | :rate_limit_error
          | :api_error
          | :timeout_error
          | :overloaded_error

  @known_types ~w(invalid_request_error authentication_error billing_error permission_error
                  not_found_error request_too_large rate_limit_error api_error timeout_error
                  overloaded_error)
  @type_atoms Map.new(@known_types, &{&1, String.to_atom(&1)})

  @type t :: %__MODULE__{
          type: error_type() | String.t(),
          message: String.t(),
          status_code: integer(),
          raw_body: map() | String.t() | nil
        }

  @doc """
  Creates a new APIError from an HTTP error response.

  Handles both plain maps (non-streaming responses) and structs like
  `Req.Response.Async` (streaming error responses).
  """
  @spec from_response(integer(), map() | struct() | String.t() | nil) :: t()
  def from_response(status_code, %_{}) do
    # Handle streaming error responses (e.g., Req.Response.Async)
    # These don't have a decoded error body, so we provide a generic error
    %__MODULE__{
      type: :api_error,
      message: "Streaming request failed with status #{status_code}",
      status_code: status_code,
      raw_body: nil
    }
  end

  # credo:disable-for-next-line Credo.Check.Refactor.CyclomaticComplexity
  def from_response(status_code, body) when is_map(body) do
    error_info =
      case body[:error] || body["error"] do
        %{} = info -> info
        _ -> %{}
      end

    type = parse_type(error_info[:type] || error_info["type"]) || type_for_status(status_code)

    message =
      error_info[:message] || error_info["message"] || body[:message] || body["message"] ||
        "Unknown error"

    %__MODULE__{
      type: type,
      message: message,
      status_code: status_code,
      raw_body: body
    }
  end

  # A body that isn't a JSON object — an empty 5xx, a proxy's HTML page, plain text — still
  # becomes an APIError, typed from the HTTP status.
  def from_response(status_code, body) do
    detail =
      case body do
        text when is_binary(text) and text != "" ->
          "a non-JSON body: " <> printable(text)

        text when is_binary(text) or is_nil(text) ->
          "an empty body"

        other ->
          "an unexpected body: " <> String.slice(inspect(other), 0, 200)
      end

    %__MODULE__{
      type: type_for_status(status_code),
      message: "HTTP #{status_code} with #{detail}",
      status_code: status_code,
      raw_body: body
    }
  end

  @doc false
  @spec parse_type(term()) :: error_type() | String.t() | nil
  def parse_type(""), do: nil
  def parse_type(type) when is_binary(type), do: Map.get(@type_atoms, type, type)
  def parse_type(_type), do: nil

  defp printable(text) do
    if String.valid?(text) do
      String.slice(text, 0, 200)
    else
      inspect(binary_part(text, 0, min(byte_size(text), 200)), binaries: :as_binaries)
    end
  end

  defp type_for_status(400), do: :invalid_request_error
  defp type_for_status(401), do: :authentication_error
  defp type_for_status(402), do: :billing_error
  defp type_for_status(403), do: :permission_error
  defp type_for_status(404), do: :not_found_error
  defp type_for_status(413), do: :request_too_large
  defp type_for_status(429), do: :rate_limit_error
  defp type_for_status(504), do: :timeout_error
  defp type_for_status(529), do: :overloaded_error
  defp type_for_status(_status), do: :api_error

  @impl true
  def message(%__MODULE__{type: type, message: msg, status_code: status}) do
    "[#{status}] #{type}: #{msg}"
  end
end
