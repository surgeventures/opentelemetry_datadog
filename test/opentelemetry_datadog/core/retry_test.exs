defmodule OpentelemetryDatadog.Core.RetryTest do
  use ExUnit.Case, async: true
  import ExUnit.CaptureLog

  @moduletag :unit

  alias OpentelemetryDatadog.Core.Retry

  describe "retryable?/1" do
    test "returns true for HTTP 429" do
      assert Retry.retryable?({:ok, %{status: 429}})
    end

    test "returns true for HTTP 5xx errors" do
      assert Retry.retryable?({:ok, %{status: 500}})
      assert Retry.retryable?({:ok, %{status: 502}})
      assert Retry.retryable?({:ok, %{status: 503}})
      assert Retry.retryable?({:ok, %{status: 599}})
    end

    test "returns true for timeout errors" do
      assert Retry.retryable?({:error, %Mint.TransportError{reason: :timeout}})
      assert Retry.retryable?({:error, %Mint.HTTPError{reason: :timeout}})
      assert Retry.retryable?({:error, :timeout})
    end

    test "returns true for network unreachable errors" do
      assert Retry.retryable?({:error, %Mint.TransportError{reason: :econnrefused}})
      assert Retry.retryable?({:error, %Mint.TransportError{reason: :ehostunreach}})
      assert Retry.retryable?({:error, %Mint.TransportError{reason: :enetunreach}})
      assert Retry.retryable?({:error, :econnrefused})
      assert Retry.retryable?({:error, :ehostunreach})
      assert Retry.retryable?({:error, :enetunreach})
    end

    test "returns false for successful responses" do
      refute Retry.retryable?({:ok, %{status: 200}})
      refute Retry.retryable?({:ok, %{status: 201}})
      refute Retry.retryable?({:ok, %{status: 299}})
    end

    test "returns false for 3xx and 4xx errors (except 429)" do
      refute Retry.retryable?({:ok, %{status: 300}})
      refute Retry.retryable?({:ok, %{status: 400}})
      refute Retry.retryable?({:ok, %{status: 404}})
      refute Retry.retryable?({:ok, %{status: 428}})
      refute Retry.retryable?({:ok, %{status: 430}})
    end

    test "returns false for other error types" do
      refute Retry.retryable?({:error, :some_other_error})
      refute Retry.retryable?({:error, %{reason: :unknown}})
    end
  end

  describe "should_retry?/1" do
    test "delegates to retryable?/1" do
      assert Retry.should_retry?({:ok, %{status: 429}}) == Retry.retryable?({:ok, %{status: 429}})
      assert Retry.should_retry?({:ok, %{status: 200}}) == Retry.retryable?({:ok, %{status: 200}})
      assert Retry.should_retry?({:error, :timeout}) == Retry.retryable?({:error, :timeout})
    end
  end

  describe "retry_delay/1" do
    test "returns correct base delays with jitter" do
      for _i <- 1..10 do
        delay1 = Retry.retry_delay(1)
        delay2 = Retry.retry_delay(2)
        delay3 = Retry.retry_delay(3)

        assert delay1 >= 50 and delay1 <= 150
        assert delay2 >= 100 and delay2 <= 300
        assert delay3 >= 200 and delay3 <= 600
      end
    end

    test "returns 0 for invalid attempts" do
      assert Retry.retry_delay(0) == 0
      assert Retry.retry_delay(4) == 0
      assert Retry.retry_delay(10) == 0
    end

    test "jitter produces different values" do
      delays = for _i <- 1..20, do: Retry.retry_delay(1)
      unique_delays = Enum.uniq(delays)

      assert length(unique_delays) > 1
    end
  end

  describe "retry_reason/1" do
    test "returns correct reasons for HTTP errors" do
      assert Retry.retry_reason({:ok, %{status: 429}}) == "HTTP 429 Rate Limited"
      assert Retry.retry_reason({:ok, %{status: 500}}) == "HTTP 500 Server Error"
      assert Retry.retry_reason({:ok, %{status: 503}}) == "HTTP 503 Server Error"
    end

    test "returns correct reasons for network errors" do
      assert Retry.retry_reason({:error, %Mint.TransportError{reason: :timeout}}) ==
               "Connection Timeout"

      assert Retry.retry_reason({:error, %Mint.TransportError{reason: :econnrefused}}) ==
               "Connection Refused"

      assert Retry.retry_reason({:error, %Mint.HTTPError{reason: :timeout}}) == "HTTP Timeout"
      assert Retry.retry_reason({:error, :timeout}) == "Timeout"
    end

    test "returns generic reason for unknown errors" do
      reason = Retry.retry_reason({:error, :unknown})
      assert String.starts_with?(reason, "Unknown Error:")
    end
  end

  describe "with_retry/2" do
    test "succeeds on first attempt without retry" do
      success_response = {:ok, %{status: 200}}

      log =
        capture_log(fn ->
          result = Retry.with_retry(fn -> success_response end)
          assert result == success_response
        end)

      assert log == ""
    end

    test "retries on transient errors and eventually succeeds" do
      call_count = Agent.start_link(fn -> 0 end)
      {:ok, agent} = call_count

      request_fn = fn ->
        count = Agent.get_and_update(agent, fn count -> {count + 1, count + 1} end)

        case count do
          1 -> {:ok, %{status: 500}}
          2 -> {:ok, %{status: 503}}
          3 -> {:ok, %{status: 200}}
        end
      end

      log =
        capture_log(fn ->
          result = Retry.with_retry(request_fn, log_level: :info)
          assert result == {:ok, %{status: 200}}
        end)

      assert log =~ "Datadog export retry 1/3: HTTP 500 Server Error"
      assert log =~ "Datadog export retry 2/3: HTTP 503 Server Error"
      assert log =~ "Datadog export succeeded on attempt 3/3"

      Agent.stop(agent)
    end

    test "stops retrying after max attempts" do
      failure_response = {:ok, %{status: 500}}

      log =
        capture_log(fn ->
          result = Retry.with_retry(fn -> failure_response end, log_level: :info)
          assert result == failure_response
        end)

      assert log =~ "Datadog export retry 1/3: HTTP 500 Server Error"
      assert log =~ "Datadog export retry 2/3: HTTP 500 Server Error"
      assert log =~ "Datadog export failed after 3 attempts: HTTP 500 Server Error"
    end

    test "does not retry non-retryable errors" do
      client_error = {:ok, %{status: 400}}

      log =
        capture_log(fn ->
          result = Retry.with_retry(fn -> client_error end)
          assert result == client_error
        end)

      assert log == ""
    end

    test "respects custom max_attempts" do
      failure_response = {:ok, %{status: 500}}

      log =
        capture_log(fn ->
          result = Retry.with_retry(fn -> failure_response end, max_attempts: 2, log_level: :info)
          assert result == failure_response
        end)

      assert log =~ "Datadog export retry 1/2: HTTP 500 Server Error"
      assert log =~ "Datadog export failed after 2 attempts: HTTP 500 Server Error"
      refute log =~ "retry 2/2"
    end

    test "includes timing information in logs" do
      slow_request = fn ->
        Process.sleep(50)
        {:ok, %{status: 500}}
      end

      log =
        capture_log(fn ->
          Retry.with_retry(slow_request, max_attempts: 1, log_level: :info)
        end)

      assert log =~ ~r/took \d+ms/
    end

    test "applies correct delays between retries" do
      call_times = Agent.start_link(fn -> [] end)
      {:ok, agent} = call_times

      request_fn = fn ->
        Agent.update(agent, fn times -> [System.monotonic_time(:millisecond) | times] end)
        {:ok, %{status: 500}}
      end

      capture_log(fn ->
        Retry.with_retry(request_fn, max_attempts: 3)
      end)

      times = Agent.get(agent, fn times -> Enum.reverse(times) end)
      assert length(times) == 3

      [time1, time2, time3] = times
      delay1 = time2 - time1
      delay2 = time3 - time2

      assert delay1 >= 40 and delay1 <= 200
      assert delay2 >= 80 and delay2 <= 350

      Agent.stop(agent)
    end
  end
end
