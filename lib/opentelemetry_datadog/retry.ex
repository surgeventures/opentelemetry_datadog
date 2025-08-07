defmodule OpentelemetryDatadog.Retry do
  @moduledoc """
  Retry helper with exponential backoff and jitter for exporting spans to Datadog.

  Retries transient errors like 5xx, 429, and network timeouts up to N attempts.
  Uses fixed backoff delays (100ms, 200ms, 400ms) with equal jitter to avoid thundering herd.

  ## Telemetry Events

  This module emits the following telemetry events:

  - `[:opentelemetry_datadog, :retry, :start]` - Emitted when retry sequence starts
    - Measurements: `%{system_time: integer()}`
    - Metadata: `%{max_attempts: integer()}`

  - `[:opentelemetry_datadog, :retry, :attempt]` - Emitted on each retry attempt
    - Measurements: `%{duration: integer(), delay: integer()}`
    - Metadata: `%{attempt: integer(), max_attempts: integer(), reason: String.t()}`

  - `[:opentelemetry_datadog, :retry, :stop]` - Emitted when retry sequence completes
    - Measurements: `%{duration: integer(), total_attempts: integer()}`
    - Metadata: `%{result: :success | :failed, max_attempts: integer(), reason: String.t() | nil}`

  - `[:opentelemetry_datadog, :retry, :exception]` - Emitted when an exception occurs
    - Measurements: `%{duration: integer()}`
    - Metadata: `%{kind: atom(), reason: String.t(), stacktrace: list(), attempt: integer(), max_attempts: integer()}`
  """

  require Logger

  @max_attempts 3
  @base_delays [100, 200, 400]

  @doc """
  Determines if an HTTP response or error should be retried.
  """
  @spec should_retry?(term()) :: boolean()
  def should_retry?(response), do: retryable?(response)

  @doc """
  Checks if a response represents a retryable error condition.

  Returns `true` for transient errors:
  - HTTP 429 (rate limit)
  - HTTP 500-599 (server errors)
  - Connection timeout errors
  - Network unreachable errors

  Returns `false` for permanent errors:
  - HTTP 2xx, 3xx, 4xx (except 429)
  - Other types of errors
  """
  @spec retryable?(term()) :: boolean()
  def retryable?({:ok, %{status: 429}}), do: true
  def retryable?({:ok, %{status: status}}) when status >= 500 and status <= 599, do: true
  def retryable?({:error, %Mint.TransportError{reason: :timeout}}), do: true
  def retryable?({:error, %Mint.TransportError{reason: :econnrefused}}), do: true
  def retryable?({:error, %Mint.TransportError{reason: :ehostunreach}}), do: true
  def retryable?({:error, %Mint.TransportError{reason: :enetunreach}}), do: true
  def retryable?({:error, %Mint.HTTPError{reason: :timeout}}), do: true
  def retryable?({:error, :timeout}), do: true
  def retryable?({:error, :econnrefused}), do: true
  def retryable?({:error, :ehostunreach}), do: true
  def retryable?({:error, :enetunreach}), do: true
  def retryable?(_), do: false

  @doc """
  Calculates retry delay with equal jitter.

  Uses fixed base delays: 100ms, 200ms, 400ms
  Applies equal jitter: delay ± (delay * 0.5 * random)

  ## Examples

      iex> delay = OpentelemetryDatadog.Retry.retry_delay(1)
      iex> delay >= 50 and delay <= 150
      true

      iex> delay = OpentelemetryDatadog.Retry.retry_delay(2)
      iex> delay >= 100 and delay <= 300
      true

      iex> delay = OpentelemetryDatadog.Retry.retry_delay(3)
      iex> delay >= 200 and delay <= 600
      true
  """
  @spec retry_delay(pos_integer()) :: non_neg_integer()
  def retry_delay(attempt) when attempt > 0 and attempt <= length(@base_delays) do
    base_delay = Enum.at(@base_delays, attempt - 1)
    jitter_range = trunc(base_delay * 0.5)
    jitter = trunc(jitter_range * (2 * :rand.uniform() - 1))
    max(0, base_delay + jitter)
  end

  def retry_delay(_attempt), do: 0

  @doc """
  Gets the reason for a retry attempt for logging purposes.
  """
  @spec retry_reason(term()) :: String.t()
  def retry_reason({:ok, %{status: 429}}), do: "HTTP 429 Rate Limited"

  def retry_reason({:ok, %{status: status}}) when status >= 500 and status <= 599 do
    "HTTP #{status} Server Error"
  end

  def retry_reason({:error, %Mint.TransportError{reason: :timeout}}), do: "Connection Timeout"

  def retry_reason({:error, %Mint.TransportError{reason: :econnrefused}}),
    do: "Connection Refused"

  def retry_reason({:error, %Mint.TransportError{reason: :ehostunreach}}), do: "Host Unreachable"

  def retry_reason({:error, %Mint.TransportError{reason: :enetunreach}}),
    do: "Network Unreachable"

  def retry_reason({:error, %Mint.HTTPError{reason: :timeout}}), do: "HTTP Timeout"
  def retry_reason({:error, :timeout}), do: "Timeout"
  def retry_reason({:error, :econnrefused}), do: "Connection Refused"
  def retry_reason({:error, :ehostunreach}), do: "Host Unreachable"
  def retry_reason({:error, :enetunreach}), do: "Network Unreachable"
  def retry_reason(response), do: "Unknown Error: #{inspect(response)}"

  @doc """
  Executes an HTTP request with retry logic.

  Retries up to #{@max_attempts} times for transient errors with exponential backoff.
  Logs retry attempts with reasons and timing information.

  ## Options

  - `:max_attempts` - Maximum number of attempts (default: #{@max_attempts})
  - `:log_level` - Log level for retry messages (default: `:info`)

  ## Future Enhancement

  This function provides a natural integration point for Circuit Breaker pattern.
  A stateful error counter (via ETS or GenServer) could be added to prevent
  cascading failures when the downstream service is consistently unavailable.
  """
  @spec with_retry((-> term()), keyword()) :: term()
  def with_retry(request_fn, opts \\ []) do
    max_attempts = Keyword.get(opts, :max_attempts, @max_attempts)
    log_level = Keyword.get(opts, :log_level, :info)
    retry_id = :erlang.unique_integer([:positive])

    execute_with_retry(request_fn, 1, max_attempts, log_level, retry_id)
  end

  defp execute_with_retry(request_fn, attempt, max_attempts, log_level, retry_id) do
    if attempt == 1 do
      :telemetry.execute(
        [:opentelemetry_datadog, :retry, :start],
        %{system_time: System.system_time()},
        %{max_attempts: max_attempts, retry_id: retry_id}
      )
    end

    start_time = System.monotonic_time(:millisecond)

    try do
      response = request_fn.()
      duration = System.monotonic_time(:millisecond) - start_time

      case {should_retry?(response), attempt < max_attempts} do
        {true, true} ->
          reason = retry_reason(response)
          delay = retry_delay(attempt)

          :telemetry.execute(
            [:opentelemetry_datadog, :retry, :attempt],
            %{duration: duration, delay: delay},
            %{attempt: attempt, max_attempts: max_attempts, reason: reason, retry_id: retry_id}
          )

          Logger.log(
            log_level,
            "Datadog export retry #{attempt}/#{max_attempts}: #{reason}. " <>
              "Retrying in #{delay}ms (request took #{duration}ms)"
          )

          Process.sleep(delay)
          execute_with_retry(request_fn, attempt + 1, max_attempts, log_level, retry_id)

        {true, false} ->
          reason = retry_reason(response)

          :telemetry.execute(
            [:opentelemetry_datadog, :retry, :stop],
            %{duration: duration, total_attempts: attempt},
            %{result: :failed, reason: reason, max_attempts: max_attempts, retry_id: retry_id}
          )

          Logger.log(
            log_level,
            "Datadog export failed after #{max_attempts} attempts: #{reason}. " <>
              "Final attempt took #{duration}ms"
          )

          response

        {false, _} ->
          :telemetry.execute(
            [:opentelemetry_datadog, :retry, :stop],
            %{duration: duration, total_attempts: attempt},
            %{result: :success, max_attempts: max_attempts, retry_id: retry_id}
          )

          if attempt > 1 do
            Logger.log(
              log_level,
              "Datadog export succeeded on attempt #{attempt}/#{max_attempts} " <>
                "(took #{duration}ms)"
            )
          end

          response
      end
    rescue
      exception ->
        duration = System.monotonic_time(:millisecond) - start_time

        :telemetry.execute(
          [:opentelemetry_datadog, :retry, :exception],
          %{duration: duration},
          %{
            kind: exception.__struct__,
            reason: Exception.message(exception),
            stacktrace: __STACKTRACE__,
            attempt: attempt,
            max_attempts: max_attempts,
            retry_id: retry_id
          }
        )

        reraise exception, __STACKTRACE__
    end
  end
end
