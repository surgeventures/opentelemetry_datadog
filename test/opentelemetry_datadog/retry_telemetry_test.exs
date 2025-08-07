defmodule OpentelemetryDatadog.RetryTelemetryTest do
  use ExUnit.Case, async: true
  import ExUnit.CaptureLog

  @moduletag :unit

  alias OpentelemetryDatadog.Retry

  @telemetry_events [
    [:opentelemetry_datadog, :retry, :start],
    [:opentelemetry_datadog, :retry, :attempt],
    [:opentelemetry_datadog, :retry, :stop],
    [:opentelemetry_datadog, :retry, :exception]
  ]

  setup do
    test_pid = self()

    # Use unique handler ID for each test to avoid conflicts
    handler_id = :"test_telemetry_handler_#{:erlang.unique_integer([:positive])}"

    :telemetry.attach_many(
      handler_id,
      @telemetry_events,
      fn event, measurements, metadata, _ ->
        send(test_pid, {:telemetry_event, event, measurements, metadata})
      end,
      nil
    )

    on_exit(fn ->
      :telemetry.detach(handler_id)
    end)

    :ok
  end

  defp collect_retry_events(timeout \\ 500) do
    # First, wait for the start event to get the retry_id
    start_event =
      receive do
        {:telemetry_event, [:opentelemetry_datadog, :retry, :start] = event, measurements,
         metadata} ->
          {event, measurements, metadata}
      after
        timeout -> raise "Timeout waiting for start event"
      end

    {_, _, start_metadata} = start_event
    retry_id = Map.get(start_metadata, :retry_id)

    # Now collect all events for this retry_id
    events = collect_events_for_retry_id(retry_id, [start_event], timeout)
    events
  end

  defp collect_events_for_retry_id(retry_id, acc, timeout) do
    receive do
      {:telemetry_event, event, measurements, metadata} ->
        if Map.get(metadata, :retry_id) == retry_id do
          collect_events_for_retry_id(retry_id, [{event, measurements, metadata} | acc], timeout)
        else
          collect_events_for_retry_id(retry_id, acc, timeout)
        end
    after
      timeout -> Enum.reverse(acc)
    end
  end

  describe "telemetry events" do
    test "emits start and stop events for successful first attempt" do
      success_response = {:ok, %{status: 200}}

      capture_log(fn ->
        result = Retry.with_retry(fn -> success_response end)
        assert result == success_response
      end)

      assert_received {:telemetry_event, [:opentelemetry_datadog, :retry, :start], measurements,
                       metadata}

      assert %{system_time: _} = measurements
      assert %{max_attempts: 3} = metadata

      assert_received {:telemetry_event, [:opentelemetry_datadog, :retry, :stop], measurements,
                       metadata}

      assert %{duration: _, total_attempts: 1} = measurements
      assert %{result: :success, max_attempts: 3} = metadata

      refute_received {:telemetry_event, [:opentelemetry_datadog, :retry, :attempt], _, _}
    end

    test "emits start, attempt, and stop events for retry scenario" do
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

      capture_log(fn ->
        result = Retry.with_retry(request_fn, log_level: :info)
        assert result == {:ok, %{status: 200}}
      end)

      # Collect events for this specific retry
      events = collect_retry_events()

      start_events =
        Enum.filter(events, fn {event, _, _} ->
          event == [:opentelemetry_datadog, :retry, :start]
        end)

      attempt_events =
        Enum.filter(events, fn {event, _, _} ->
          event == [:opentelemetry_datadog, :retry, :attempt]
        end)

      stop_events =
        Enum.filter(events, fn {event, _, _} ->
          event == [:opentelemetry_datadog, :retry, :stop]
        end)

      assert length(start_events) == 1
      assert length(attempt_events) == 2
      assert length(stop_events) == 1

      # Check attempt events
      attempt_metadata = Enum.map(attempt_events, fn {_, _, metadata} -> metadata end)
      attempts = Enum.map(attempt_metadata, & &1.attempt) |> Enum.sort()
      reasons = Enum.map(attempt_metadata, & &1.reason) |> Enum.sort()

      assert attempts == [1, 2]
      assert "HTTP 500 Server Error" in reasons
      assert "HTTP 503 Server Error" in reasons

      # Check stop event
      [{_, measurements, metadata}] = stop_events
      assert %{duration: _, total_attempts: 3} = measurements
      assert %{result: :success, max_attempts: 3} = metadata

      Agent.stop(agent)
    end

    test "emits start, attempts, and stop events for failed scenario" do
      failure_response = {:ok, %{status: 500}}

      capture_log(fn ->
        result = Retry.with_retry(fn -> failure_response end, log_level: :info)
        assert result == failure_response
      end)

      # Collect events for this specific retry
      events = collect_retry_events()

      start_events =
        Enum.filter(events, fn {event, _, _} ->
          event == [:opentelemetry_datadog, :retry, :start]
        end)

      attempt_events =
        Enum.filter(events, fn {event, _, _} ->
          event == [:opentelemetry_datadog, :retry, :attempt]
        end)

      stop_events =
        Enum.filter(events, fn {event, _, _} ->
          event == [:opentelemetry_datadog, :retry, :stop]
        end)

      assert length(start_events) == 1
      assert length(attempt_events) == 2
      assert length(stop_events) == 1

      # Check attempt events
      attempt_metadata = Enum.map(attempt_events, fn {_, _, metadata} -> metadata end)
      attempts = Enum.map(attempt_metadata, & &1.attempt) |> Enum.sort()
      reasons = Enum.map(attempt_metadata, & &1.reason) |> Enum.uniq()

      assert attempts == [1, 2]
      assert reasons == ["HTTP 500 Server Error"]

      # Check stop event
      [{_, measurements, metadata}] = stop_events
      assert %{duration: _, total_attempts: 3} = measurements
      assert %{result: :failed, max_attempts: 3, reason: "HTTP 500 Server Error"} = metadata
    end

    test "emits exception event when request function raises" do
      failing_request = fn ->
        raise ArgumentError, "test error"
      end

      assert_raise ArgumentError, "test error", fn ->
        Retry.with_retry(failing_request)
      end

      assert_received {:telemetry_event, [:opentelemetry_datadog, :retry, :start], measurements,
                       metadata}

      assert %{system_time: _} = measurements
      assert %{max_attempts: 3} = metadata

      assert_received {:telemetry_event, [:opentelemetry_datadog, :retry, :exception],
                       measurements, metadata}

      assert %{duration: _} = measurements

      assert %{
               kind: ArgumentError,
               reason: "test error",
               stacktrace: _,
               attempt: 1,
               max_attempts: 3
             } = metadata
    end

    test "emits events with custom max_attempts" do
      failure_response = {:ok, %{status: 500}}

      capture_log(fn ->
        Retry.with_retry(fn -> failure_response end, max_attempts: 2, log_level: :info)
      end)

      # Collect events for this specific retry
      events = collect_retry_events()

      start_events =
        Enum.filter(events, fn {event, _, _} ->
          event == [:opentelemetry_datadog, :retry, :start]
        end)

      attempt_events =
        Enum.filter(events, fn {event, _, _} ->
          event == [:opentelemetry_datadog, :retry, :attempt]
        end)

      stop_events =
        Enum.filter(events, fn {event, _, _} ->
          event == [:opentelemetry_datadog, :retry, :stop]
        end)

      assert length(start_events) == 1
      assert length(attempt_events) == 1
      assert length(stop_events) == 1

      # Check start event
      [{_, _, metadata}] = start_events
      assert %{max_attempts: 2} = metadata

      # Check attempt event
      [{_, _, metadata}] = attempt_events
      assert %{attempt: 1, max_attempts: 2} = metadata

      # Check stop event
      [{_, _, metadata}] = stop_events
      assert %{result: :failed, max_attempts: 2, reason: "HTTP 500 Server Error"} = metadata
    end

    test "measurements contain valid timing data" do
      slow_request = fn ->
        Process.sleep(5)
        {:ok, %{status: 500}}
      end

      capture_log(fn ->
        Retry.with_retry(slow_request, max_attempts: 2, log_level: :info)
      end)

      assert_received {:telemetry_event, [:opentelemetry_datadog, :retry, :start], measurements,
                       _}

      assert measurements.system_time > 0

      assert_received {:telemetry_event, [:opentelemetry_datadog, :retry, :attempt], measurements,
                       _}

      assert measurements.duration >= 0
      assert measurements.delay >= 50 and measurements.delay <= 150

      assert_received {:telemetry_event, [:opentelemetry_datadog, :retry, :stop], measurements, _}
      assert measurements.duration >= 0
      assert measurements.total_attempts == 2
    end

    test "does not emit attempt events for non-retryable errors" do
      client_error = {:ok, %{status: 400}}

      capture_log(fn ->
        result = Retry.with_retry(fn -> client_error end)
        assert result == client_error
      end)

      assert_received {:telemetry_event, [:opentelemetry_datadog, :retry, :start], _, _}

      assert_received {:telemetry_event, [:opentelemetry_datadog, :retry, :stop], measurements,
                       metadata}

      assert %{total_attempts: 1} = measurements
      assert %{result: :success} = metadata

      refute_received {:telemetry_event, [:opentelemetry_datadog, :retry, :attempt], _, _}
    end
  end
end
