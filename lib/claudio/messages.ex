defmodule Claudio.Messages do

  def create_message(client, payload =  %{"stream" => true}) do
    url = "messages"

    case Tesla.post(client, url, payload, opts: [adapter: [body_as: :stream]]) do
      {:ok,  result} ->
        {:ok, result}

      {:error, %Tesla.Env{status: _, body: body}} ->
        {:error, body}
    end
  end

  @spec create_message(binary() | Tesla.Client.t(), any()) :: {:error, any()} | {:ok, any()}
  def create_message(client, payload) do
    url = "messages"

    case Tesla.post!(client, url, payload) do
      %Tesla.Env{status: 200, body: body} ->
        {:ok, body}

      %Tesla.Env{status: _, body: body} ->
        {:error, body}
    end
  end

  @spec count_tokens(binary() | Tesla.Client.t(), any()) :: {:error, any()} | {:ok, any()}
  def count_tokens(client, payload) do
    url = "messages/count_tokens"

    case Tesla.post!(client, url, payload) do
      %Tesla.Env{status: 200, body: body} ->
        {:ok, body}

      %Tesla.Env{status: _, body: body} ->
        {:error, body}
    end
  end
end
