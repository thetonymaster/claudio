defmodule Claudio.Batches do
  @moduledoc """
  Client for the Message Batches API.

  The Batches API allows you to process multiple Messages API requests asynchronously
  in a single batch operation. This is ideal for large-scale, non-urgent processing.

  ## Features

  - Process up to 100,000 requests per batch
  - Maximum batch size of 256 MB
  - Asynchronous processing (up to 24 hours)
  - All Messages API features supported (including beta features)
  - Results provided as downloadable `.jsonl` file

  ## Example

      alias Claudio.Batches

      # Create a batch
      requests = [
        %{
          "custom_id" => "req-1",
          "params" => %{
            "model" => "claude-3-5-sonnet-20241022",
            "max_tokens" => 1024,
            "messages" => [%{"role" => "user", "content" => "Hello"}]
          }
        },
        %{
          "custom_id" => "req-2",
          "params" => %{
            "model" => "claude-3-5-sonnet-20241022",
            "max_tokens" => 1024,
            "messages" => [%{"role" => "user", "content" => "Hi there"}]
          }
        }
      ]

      {:ok, batch} = Batches.create(client, requests)

      # Check batch status
      {:ok, status} = Batches.get(client, batch.id)

      # Get results when complete
      if status.processing_status == "ended" do
        {:ok, results} = Batches.get_results(client, batch.id)
      end

      # List all batches
      {:ok, batches} = Batches.list(client)

      # Cancel a batch
      {:ok, _} = Batches.cancel(client, batch.id)
  """

  alias Claudio.APIError

  @type batch_request :: %{
          required(:custom_id) => String.t(),
          required(:params) => map()
        }

  @type batch_status ::
          :in_progress
          | :canceling
          | :ended

  @type batch :: %{
          id: String.t(),
          type: String.t(),
          processing_status: batch_status(),
          request_counts: map(),
          ended_at: String.t() | nil,
          created_at: String.t(),
          expires_at: String.t(),
          results_url: String.t() | nil
        }

  @doc """
  Creates a new message batch.

  ## Parameters

  - `client` - Tesla client configured with authentication
  - `requests` - List of batch requests, each with a `custom_id` and `params`

  ## Example

      requests = [
        %{
          "custom_id" => "my-request-1",
          "params" => %{
            "model" => "claude-3-5-sonnet-20241022",
            "max_tokens" => 1024,
            "messages" => [%{"role" => "user", "content" => "Hello"}]
          }
        }
      ]

      {:ok, batch} = Claudio.Batches.create(client, requests)
  """
  @spec create(Tesla.Client.t(), list(batch_request())) :: {:ok, map()} | {:error, APIError.t()}
  def create(client, requests) when is_list(requests) do
    url = "messages/batches"
    payload = %{"requests" => requests}

    case Tesla.post(client, url, payload) do
      {:ok, %Tesla.Env{status: 200, body: body}} ->
        {:ok, body}

      {:ok, %Tesla.Env{status: status, body: body}} ->
        {:error, APIError.from_response(status, body)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Retrieves information about a specific batch.

  ## Example

      {:ok, batch} = Claudio.Batches.get(client, "batch_123")
      IO.inspect(batch.processing_status)
      IO.inspect(batch.request_counts)
  """
  @spec get(Tesla.Client.t(), String.t()) :: {:ok, map()} | {:error, APIError.t()}
  def get(client, batch_id) when is_binary(batch_id) do
    url = "messages/batches/#{batch_id}"

    case Tesla.get(client, url) do
      {:ok, %Tesla.Env{status: 200, body: body}} ->
        {:ok, body}

      {:ok, %Tesla.Env{status: status, body: body}} ->
        {:error, APIError.from_response(status, body)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Retrieves the results of a completed batch.

  Returns a list of result objects, each containing the `custom_id` and either
  a successful `result` or an `error`.

  ## Example

      {:ok, results} = Claudio.Batches.get_results(client, "batch_123")

      Enum.each(results, fn result ->
        case result do
          %{"custom_id" => id, "result" => result} ->
            IO.puts("Success for \#{id}")
            IO.inspect(result)

          %{"custom_id" => id, "error" => error} ->
            IO.puts("Error for \#{id}")
            IO.inspect(error)
        end
      end)
  """
  @spec get_results(Tesla.Client.t(), String.t()) :: {:ok, list(map())} | {:error, APIError.t()}
  def get_results(client, batch_id) when is_binary(batch_id) do
    url = "messages/batches/#{batch_id}/results"

    case Tesla.get(client, url) do
      {:ok, %Tesla.Env{status: 200, body: body}} when is_binary(body) ->
        # Results are returned as JSONL (one JSON object per line)
        results =
          body
          |> String.split("\n", trim: true)
          |> Enum.map(&parse_jsonl_line/1)
          |> Enum.reject(&is_nil/1)

        {:ok, results}

      {:ok, %Tesla.Env{status: 200, body: body}} when is_list(body) ->
        {:ok, body}

      {:ok, %Tesla.Env{status: status, body: body}} ->
        {:error, APIError.from_response(status, body)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Lists all batches for the account.

  ## Options

  - `:limit` - Number of batches to return (default: 20, max: 100)
  - `:before_id` - Get batches before this ID (for pagination)
  - `:after_id` - Get batches after this ID (for pagination)

  ## Example

      # List first 50 batches
      {:ok, response} = Claudio.Batches.list(client, limit: 50)

      # Paginate through results
      {:ok, next_page} = Claudio.Batches.list(client, after_id: response.last_id)
  """
  @spec list(Tesla.Client.t(), keyword()) :: {:ok, map()} | {:error, APIError.t()}
  def list(client, opts \\ []) do
    url = "messages/batches"
    query_params = build_query_params(opts)

    case Tesla.get(client, url, query: query_params) do
      {:ok, %Tesla.Env{status: 200, body: body}} ->
        {:ok, body}

      {:ok, %Tesla.Env{status: status, body: body}} ->
        {:error, APIError.from_response(status, body)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Cancels a batch that is currently in progress.

  Note: Requests that have already started processing will complete,
  but no new requests from the batch will be started.

  ## Example

      {:ok, batch} = Claudio.Batches.cancel(client, "batch_123")
      # batch.processing_status will be "canceling" or "ended"
  """
  @spec cancel(Tesla.Client.t(), String.t()) :: {:ok, map()} | {:error, APIError.t()}
  def cancel(client, batch_id) when is_binary(batch_id) do
    url = "messages/batches/#{batch_id}/cancel"

    case Tesla.post(client, url, %{}) do
      {:ok, %Tesla.Env{status: 200, body: body}} ->
        {:ok, body}

      {:ok, %Tesla.Env{status: status, body: body}} ->
        {:error, APIError.from_response(status, body)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Deletes a batch and its results.

  Note: This will delete both the batch metadata and any result files.
  This action cannot be undone.

  ## Example

      {:ok, _} = Claudio.Batches.delete(client, "batch_123")
  """
  @spec delete(Tesla.Client.t(), String.t()) :: {:ok, map()} | {:error, APIError.t()}
  def delete(client, batch_id) when is_binary(batch_id) do
    url = "messages/batches/#{batch_id}"

    case Tesla.delete(client, url) do
      {:ok, %Tesla.Env{status: 200, body: body}} ->
        {:ok, body}

      {:ok, %Tesla.Env{status: status, body: body}} ->
        {:error, APIError.from_response(status, body)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Waits for a batch to complete, polling at regular intervals.

  ## Options

  - `:poll_interval` - Seconds between status checks (default: 30)
  - `:timeout` - Maximum seconds to wait (default: 86400 = 24 hours)
  - `:callback` - Function called with batch status on each poll

  ## Example

      {:ok, final_batch} = Claudio.Batches.wait_for_completion(
        client,
        batch_id,
        poll_interval: 60,
        timeout: 3600,
        callback: fn status ->
          IO.puts("Status: \#{status.processing_status}")
          IO.inspect(status.request_counts)
        end
      )

      {:ok, results} = Claudio.Batches.get_results(client, final_batch.id)
  """
  @spec wait_for_completion(Tesla.Client.t(), String.t(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def wait_for_completion(client, batch_id, opts \\ []) do
    poll_interval = Keyword.get(opts, :poll_interval, 30) * 1000
    timeout = Keyword.get(opts, :timeout, 86_400) * 1000
    callback = Keyword.get(opts, :callback)
    start_time = System.monotonic_time(:millisecond)

    do_wait_for_completion(client, batch_id, poll_interval, timeout, start_time, callback)
  end

  # Private functions

  defp do_wait_for_completion(client, batch_id, poll_interval, timeout, start_time, callback) do
    elapsed = System.monotonic_time(:millisecond) - start_time

    if elapsed > timeout do
      {:error, :timeout}
    else
      case get(client, batch_id) do
        {:ok, batch} ->
          if callback, do: callback.(batch)

          status = batch[:processing_status] || batch["processing_status"]

          if status == "ended" or status == :ended do
            {:ok, batch}
          else
            Process.sleep(poll_interval)
            do_wait_for_completion(client, batch_id, poll_interval, timeout, start_time, callback)
          end

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp build_query_params(opts) do
    []
    |> maybe_add_param(:limit, Keyword.get(opts, :limit))
    |> maybe_add_param(:before_id, Keyword.get(opts, :before_id))
    |> maybe_add_param(:after_id, Keyword.get(opts, :after_id))
  end

  defp maybe_add_param(params, _key, nil), do: params
  defp maybe_add_param(params, key, value), do: [{key, value} | params]

  defp parse_jsonl_line(line) do
    case Poison.decode(line, keys: :atoms) do
      {:ok, data} -> data
      {:error, _} -> nil
    end
  end
end
