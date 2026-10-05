defmodule Claudio.Batches do
  @moduledoc """
  Client for the Anthropic Message Batches API.

  The Batches API allows you to process multiple Messages API requests asynchronously
  in a single batch operation. This is ideal for large-scale, non-urgent processing
  scenarios where you need to process thousands or millions of requests.

  ## Features

  - Process up to **100,000 requests** per batch
  - Maximum batch size of **256 MB**
  - Asynchronous processing (up to **24 hours**)
  - All Messages API features supported (streaming, tools, caching, etc.)
  - Results provided as downloadable `.jsonl` file
  - Support for beta features via client configuration

  ## Limits and Quotas

  - **Request limit**: 100,000 requests per batch
  - **Size limit**: 256 MB per batch
  - **Processing time**: Up to 24 hours
  - **Rate limits**: Applied separately from Messages API

  ## Batch Lifecycle

  1. **Creating**: Batch is being created and validated
  2. **In progress**: Batch is being processed
  3. **Ended**: Processing complete (check `request_counts` for results)
  4. Results available for download as JSONL

  ## Complete Example

      alias Claudio.Batches

      # Create a batch of requests
      requests = [
        %{
          custom_id: "req-1",
          params: %{
            model: "claude-opus-5-5",
            max_tokens: 1024,
            messages: [%{role: "user", content: "Hello"}]
          }
        },
        %{
          custom_id: "req-2",
          params: %{
            model: "claude-opus-5-5",
            max_tokens: 1024,
            messages: [%{role: "user", content: "Hi there"}]
          }
        }
      ]

      # Submit batch
      {:ok, batch} = Batches.create(client, requests)
      IO.puts("Batch ID: \#{batch["id"]}")

      # Wait for completion with progress updates (poll_interval in seconds)
      {:ok, _completed} =
        Batches.wait_for_completion(client, batch["id"],
          poll_interval: 30,
          callback: fn status ->
            counts = status["request_counts"]
            IO.puts("Progress: \#{counts["succeeded"]} succeeded, \#{counts["processing"]} processing")
          end
        )

      # Download results: a list of decoded (string-keyed) maps
      {:ok, results} = Batches.get_results(client, batch["id"])

      # Process each result
      Enum.each(results, fn result ->
        case result do
          %{"result" => %{"type" => "succeeded", "message" => message}} ->
            IO.puts("Success: \#{result["custom_id"]}")

          %{"result" => %{"type" => "errored", "error" => error}} ->
            IO.puts("Error: \#{error["message"]}")
        end
      end)

  ## Polling vs Wait

  You can either manually poll for status or use `wait_for_completion/3`:

      # Manual polling
      {:ok, status} = Batches.get(client, batch_id)

      case status["processing_status"] do
        "ended" -> IO.puts("Complete!")
        "in_progress" -> IO.puts("Still processing...")
        "canceling" -> IO.puts("Canceling...")
      end

      # Automatic waiting (recommended)
      {:ok, completed} = Batches.wait_for_completion(
        client,
        batch_id,
        callback: &progress_callback/1,
        poll_interval: 5  # seconds
      )
      {:ok, batches} = Batches.list(client)

      # Cancel a batch
      {:ok, _} = Batches.cancel(client, batch["id"])
  """

  alias Claudio.APIError
  alias Claudio.Messages.Request

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

  - `client` - Req request configured with authentication
  - `requests` - List of batch requests, each with a `custom_id` and `params`

  ## Example

      requests = [
        %{
          "custom_id" => "my-request-1",
          "params" => %{
            "model" => "claude-opus-5-5",
            "max_tokens" => 1024,
            "messages" => [%{"role" => "user", "content" => "Hello"}]
          }
        }
      ]

      {:ok, batch} = Claudio.Batches.create(client, requests)
  """
  @spec create(Req.Request.t(), list(batch_request())) :: {:ok, map()} | {:error, APIError.t()}
  def create(client, requests) when is_list(requests) do
    {prepared, beta_lists} =
      requests
      |> Enum.map(&prepare_item/1)
      |> Enum.unzip()

    betas = beta_lists |> List.flatten() |> Enum.uniq()
    client = Claudio.Client.with_betas(client, betas)
    payload = %{"requests" => prepared}

    case Req.post(client, url: "messages/batches", json: payload) do
      {:ok, %Req.Response{status: 200, body: body}} ->
        {:ok, body}

      {:ok, %Req.Response{status: status, body: body}} ->
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
  @spec get(Req.Request.t(), String.t()) :: {:ok, map()} | {:error, APIError.t()}
  def get(client, batch_id) when is_binary(batch_id) do
    case Req.get(client, url: "messages/batches/#{batch_id}") do
      {:ok, %Req.Response{status: 200, body: body}} ->
        {:ok, body}

      {:ok, %Req.Response{status: status, body: body}} ->
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
          %{"custom_id" => id, "result" => %{"type" => "succeeded", "message" => message}} ->
            IO.puts("Success for \#{id}")
            IO.inspect(Claudio.Messages.Response.from_map(message))

          %{"custom_id" => id, "result" => %{"type" => type} = outcome} ->
            IO.puts("\#{type} for \#{id}")
            IO.inspect(outcome["error"])
        end
      end)
  """
  @spec get_results(Req.Request.t(), String.t()) ::
          {:ok, list(map())}
          | {:error, APIError.t() | {:invalid_result_line, pos_integer(), String.t()} | term()}
  def get_results(client, batch_id) when is_binary(batch_id) do
    case Req.get(client, url: "messages/batches/#{batch_id}/results") do
      {:ok, %Req.Response{status: 200, body: body}} when is_binary(body) ->
        # Results are JSONL (one JSON object per line).
        parse_jsonl(body)

      {:ok, %Req.Response{status: 200, body: body}} when is_list(body) ->
        {:ok, body}

      # A one-result body served as JSON is decoded by Req into a single map.
      {:ok, %Req.Response{status: 200, body: body}} when is_map(body) ->
        {:ok, [body]}

      {:ok, %Req.Response{status: status, body: body}} ->
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
  @spec list(Req.Request.t(), keyword()) :: {:ok, map()} | {:error, APIError.t()}
  def list(client, opts \\ []) do
    opts =
      Claudio.Options.validate!(opts, [:limit, :before_id, :after_id], "Claudio.Batches.list/2")

    query_params = build_query_params(opts)

    case Req.get(client, url: "messages/batches", params: query_params) do
      {:ok, %Req.Response{status: 200, body: body}} ->
        {:ok, body}

      {:ok, %Req.Response{status: status, body: body}} ->
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
  @spec cancel(Req.Request.t(), String.t()) :: {:ok, map()} | {:error, APIError.t()}
  def cancel(client, batch_id) when is_binary(batch_id) do
    case Req.post(client, url: "messages/batches/#{batch_id}/cancel", json: %{}) do
      {:ok, %Req.Response{status: 200, body: body}} ->
        {:ok, body}

      {:ok, %Req.Response{status: status, body: body}} ->
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
  @spec delete(Req.Request.t(), String.t()) :: {:ok, map()} | {:error, APIError.t()}
  def delete(client, batch_id) when is_binary(batch_id) do
    case Req.delete(client, url: "messages/batches/#{batch_id}") do
      {:ok, %Req.Response{status: 200, body: body}} ->
        {:ok, body}

      {:ok, %Req.Response{status: status, body: body}} ->
        {:error, APIError.from_response(status, body)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Waits for a batch to complete, polling at regular intervals.

  ## Options

  All time values are in **seconds**.

  - `:poll_interval` - Seconds between status checks (default: 30)
  - `:timeout` - Maximum seconds to wait (default: 86400 = 24 hours)
  - `:callback` - 1-arity function called with the batch on each poll

  `:poll_interval` and `:timeout` must be positive integers and `:callback` a 1-arity
  function (or `nil`); anything else raises `ArgumentError`.

  ## Example

      {:ok, final_batch} = Claudio.Batches.wait_for_completion(
        client,
        batch_id,
        callback: &IO.inspect/1,
        poll_interval: 5
      )

      {:ok, results} = Claudio.Batches.get_results(client, final_batch["id"])
  """
  @spec wait_for_completion(Req.Request.t(), String.t(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def wait_for_completion(client, batch_id, opts \\ []) do
    opts =
      Claudio.Options.validate!(
        opts,
        [:poll_interval, :timeout, :callback],
        "Claudio.Batches.wait_for_completion/3"
      )

    validate_wait_opts!(opts)

    poll_interval = Keyword.get(opts, :poll_interval, 30) * 1000
    timeout = Keyword.get(opts, :timeout, 86_400) * 1000
    callback = Keyword.get(opts, :callback)
    start_time = System.monotonic_time(:millisecond)

    do_wait_for_completion(client, batch_id, poll_interval, timeout, start_time, callback)
  end

  # Private functions

  defp validate_wait_opts!(opts) do
    for key <- [:poll_interval, :timeout], Keyword.has_key?(opts, key) do
      value = Keyword.fetch!(opts, key)

      unless is_integer(value) and value > 0 do
        raise ArgumentError,
              "Claudio.Batches.wait_for_completion/3: #{inspect(key)} must be a positive " <>
                "integer (seconds); got #{inspect(value)}"
      end
    end

    callback = Keyword.get(opts, :callback)

    unless is_nil(callback) or is_function(callback, 1) do
      raise ArgumentError,
            "Claudio.Batches.wait_for_completion/3: :callback must be nil or a 1-arity " <>
              "function; got #{inspect(callback)}"
    end

    :ok
  end

  # Batch items are never streamed: a request built with enable_streaming/1 drops `stream`.
  defp prepare_item(%{params: %Request{} = req} = item),
    do: {%{item | params: batch_params(req)}, Request.required_betas(req)}

  defp prepare_item(%{"params" => %Request{} = req} = item),
    do: {Map.put(item, "params", batch_params(req)), Request.required_betas(req)}

  defp prepare_item(item), do: {item, []}

  defp batch_params(req), do: req |> Request.to_map() |> Map.delete("stream")

  defp do_wait_for_completion(client, batch_id, poll_interval, timeout, start_time, callback) do
    elapsed = System.monotonic_time(:millisecond) - start_time

    if elapsed > timeout do
      {:error, :timeout}
    else
      case get(client, batch_id) do
        {:ok, batch} ->
          if callback, do: callback.(batch)

          status = batch[:processing_status] || batch["processing_status"]

          # credo:disable-for-next-line Credo.Check.Refactor.Nesting
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

  # String keys, like every other response Claudio returns (and no atoms created from
  # API data). A malformed line is reported, never silently dropped.
  defp parse_jsonl(body) do
    body
    |> String.split("\n", trim: true)
    |> Enum.with_index(1)
    |> Enum.reduce_while({:ok, []}, fn {line, number}, {:ok, acc} ->
      case Jason.decode(line) do
        {:ok, result} -> {:cont, {:ok, [result | acc]}}
        {:error, _} -> {:halt, {:error, {:invalid_result_line, number, line}}}
      end
    end)
    |> case do
      {:ok, results} -> {:ok, Enum.reverse(results)}
      error -> error
    end
  end
end
