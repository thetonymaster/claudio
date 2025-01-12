defmodule Claudio.Client do
  @user_agent "claudio"

  @spec new(%{:token => any(), :version => any(), optional(any()) => any()}) :: Tesla.Client.t()
  def new(config, endpoint \\ "https://api.anthropic.com/v1/") do
    client(config, endpoint)
  end

  defp client(auth, endpoint) do
    Tesla.client(middleware(auth, endpoint), adapter())
  end

  defp middleware(auth, endpoint) do
    [
      Tesla.Middleware.KeepRequest,
      Tesla.Middleware.PathParams,
      {Tesla.Middleware.BaseUrl, endpoint},
      {Tesla.Middleware.Headers, get_headers(auth)},
      {Tesla.Middleware.JSON, engine: Poison, engine_opts: [keys: :atoms]},
      Tesla.Middleware.Logger
    ]
  end

  defp get_headers(auth) do
    %{token: token, version: version} = auth
    headers = [{"user-agent", @user_agent}, {"anthropic-version", version}, {"x-api-key", token}]

    case auth do
      %{beta: beta} ->
        [{"anthropic-beta", Enum.join(beta, ",")} | headers]

      _ ->
        headers
    end
  end

  defp adapter do
    Keyword.get(config(), :adapter)
  end

  defp config do
    Application.get_env(:claudio, __MODULE__, [])
  end
end
