defmodule OpentelemetryDatadog.Core.RetryIntegrationTest do
  use ExUnit.Case, async: true
  import ExUnit.CaptureLog

  @moduletag :integration

  alias OpentelemetryDatadog.Core.Retry

  describe "retry integration with HTTP requests" do
    test "retries with correct timing and logging" do
      call_count = Agent.start_link(fn -> 0 end)
      {:ok, agent} = call_count

      call_times = Agent.start_link(fn -> [] end)
      {:ok, times_agent} = call_times

      mock_request = fn ->
        Agent.update(times_agent, fn times ->
          [System.monotonic_time(:millisecond) | times]
        end)

        count = Agent.get_and_update(agent, fn count -> {count + 1, count + 1} end)

        case count do
          1 -> {:ok, %{status: 500, body: "Internal Server Error"}}
          2 -> {:ok, %{status: 503, body: "Service Unavailable"}}
          3 -> {:ok, %{status: 200, body: %{"rate_by_service" => %{}}}}
        end
      end

      start_time = System.monotonic_time(:millisecond)

      log =
        capture_log(fn ->
          result = Retry.with_retry(mock_request, log_level: :info)
          assert {:ok, %{status: 200}} = result
        end)

      total_time = System.monotonic_time(:millisecond) - start_time
      call_times_list = Agent.get(times_agent, fn times -> Enum.reverse(times) end)

      assert length(call_times_list) == 3

      assert log =~ "Datadog export retry 1/3: HTTP 500 Server Error"
      assert log =~ "Datadog export retry 2/3: HTTP 503 Server Error"
      assert log =~ "Datadog export succeeded on attempt 3/3"

      assert total_time >= 150

      [time1, time2, time3] = call_times_list
      delay1 = time2 - time1
      delay2 = time3 - time2

      assert delay1 >= 40 and delay1 <= 200
      assert delay2 >= 80 and delay2 <= 350

      Agent.stop(agent)
      Agent.stop(times_agent)
    end

    test "stops retrying after max attempts with proper logging" do
      mock_request = fn ->
        {:ok, %{status: 429, body: "Rate Limited"}}
      end

      log =
        capture_log(fn ->
          result = Retry.with_retry(mock_request, max_attempts: 2, log_level: :info)
          assert {:ok, %{status: 429}} = result
        end)

      assert log =~ "Datadog export retry 1/2: HTTP 429 Rate Limited"
      assert log =~ "Datadog export failed after 2 attempts: HTTP 429 Rate Limited"
      refute log =~ "retry 2/2"
    end

    test "does not retry non-retryable errors" do
      mock_request = fn ->
        {:ok, %{status: 400, body: "Bad Request"}}
      end

      start_time = System.monotonic_time(:millisecond)

      log =
        capture_log(fn ->
          result = Retry.with_retry(mock_request)
          assert {:ok, %{status: 400}} = result
        end)

      total_time = System.monotonic_time(:millisecond) - start_time

      assert total_time < 50
      assert log == ""
    end

    test "handles network errors with appropriate retries" do
      call_count = Agent.start_link(fn -> 0 end)
      {:ok, agent} = call_count

      mock_request = fn ->
        count = Agent.get_and_update(agent, fn count -> {count + 1, count + 1} end)

        case count do
          1 -> {:error, :timeout}
          2 -> {:error, :econnrefused}
          3 -> {:ok, %{status: 200, body: %{}}}
        end
      end

      log =
        capture_log(fn ->
          result = Retry.with_retry(mock_request, log_level: :info)
          assert {:ok, %{status: 200}} = result
        end)

      assert log =~ "Datadog export retry 1/3: Timeout"
      assert log =~ "Datadog export retry 2/3: Connection Refused"
      assert log =~ "Datadog export succeeded on attempt 3/3"

      Agent.stop(agent)
    end
  end
end
