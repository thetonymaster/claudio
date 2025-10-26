defmodule Claudio.APIError do
  @moduledoc """
  Exception raised when the Anthropic API returns an error response.
  """

  defexception [:type, :message, :status_code, :raw_body]

  @type error_type ::
          :invalid_request_error
          | :authentication_error
          | :permission_error
          | :not_found_error
          | :rate_limit_error
          | :api_error
          | :overloaded_error

  @type t :: %__MODULE__{
          type: error_type() | String.t(),
          message: String.t(),
          status_code: integer(),
          raw_body: map() | nil
        }

  @doc """
  Creates a new APIError from an HTTP error response.
  """
  @spec from_response(integer(), map()) :: t()
  def from_response(status_code, body) when is_map(body) do
    error_info = body[:error] || body["error"] || %{}

    type =
      case error_info[:type] || error_info["type"] do
        "invalid_request_error" -> :invalid_request_error
        "authentication_error" -> :authentication_error
        "permission_error" -> :permission_error
        "not_found_error" -> :not_found_error
        "rate_limit_error" -> :rate_limit_error
        "api_error" -> :api_error
        "overloaded_error" -> :overloaded_error
        other when is_binary(other) -> other
        nil -> :api_error
      end

    message = error_info[:message] || error_info["message"] || "Unknown error"

    %__MODULE__{
      type: type,
      message: message,
      status_code: status_code,
      raw_body: body
    }
  end

  @impl true
  def message(%__MODULE__{type: type, message: msg, status_code: status}) do
    "[#{status}] #{type}: #{msg}"
  end
end
