defmodule OpentelemetryDatadog.ExporterResilienceTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog
  require OpentelemetryDatadog.Exporter

  alias OpentelemetryDatadog.Exporter

  @moduletag :unit

  describe "retry_delay/1" do
    test "calculates exponential backoff with jitter" do
      # Test multiple attempts to verify exponential growth
      delay1 = Exporter.retry_delay(1)
      delay2 = Exporter.retry_delay(2)
      delay3 = Exporter.retry_delay(3)

      # Base delays should be around 2^attempt * 500ms with 10% jitter
      # Attempt 1: ~1000ms ± 100ms (900-1000ms range due to jitter)
      # Attempt 2: ~2000ms ± 200ms (1800-2000ms range due to jitter)
      # Attempt 3: ~4000ms ± 400ms (3600-4000ms range due to jitter)

      assert delay1 >= 900 and delay1 <= 1000
      assert delay2 >= 1800 and delay2 <= 2000
      assert delay3 >= 3600 and delay3 <= 4000

      # Verify exponential growth pattern
      assert delay2 > delay1
      assert delay3 > delay2
    end

    test "returns integer values" do
      for attempt <- 1..5 do
        delay = Exporter.retry_delay(attempt)
        assert is_integer(delay)
        assert delay > 0
      end
    end

    test "jitter provides variation in delays" do
      # Run multiple times to verify jitter creates variation
      delays = for _ <- 1..10, do: Exporter.retry_delay(1)
      
      # All delays should be in expected range but not identical
      assert Enum.all?(delays, &(&1 >= 900 and &1 <= 1000))
      assert length(Enum.uniq(delays)) > 1, "Jitter should create variation"
    end
  end

  describe "push/3 error handling" do
    setup do
      # Create test state with short timeouts for faster tests
      state = %Exporter.State{
        host: "unreachable-host-12345",
        port: 8126,
        timeout_ms: 100,
        connect_timeout_ms: 50,
        protocol: :v05
      }

      {:ok, state: state}
    end

    test "handles connection errors gracefully", %{state: state} do
      body = "test-body"
      headers = [{"Content-Type", "application/msgpack"}]

      # This should fail with connection error but not crash
      result = capture_log(fn ->
        response = Exporter.push(body, headers, state)
        # Should return error tuple, not crash
        assert match?({:error, _}, response)
      end)

      # Should not contain any crash logs
      refute result =~ "** (EXIT)"
      refute result =~ "GenServer terminating"
    end

    test "respects timeout configuration", %{state: state} do
      body = "test-body"
      headers = [{"Content-Type", "application/msgpack"}]

      # Measure time taken for timeout
      start_time = System.monotonic_time(:millisecond)
      
      capture_log(fn ->
        {:error, _} = Exporter.push(body, headers, state)
      end)
      
      end_time = System.monotonic_time(:millisecond)
      elapsed = end_time - start_time

      # Should timeout within reasonable bounds (connect_timeout + some buffer)
      # Connect timeout is 50ms, so should fail quickly
      assert elapsed < 1000, "Should timeout quickly with unreachable host"
    end

    test "constructs correct URL with protocol detection", %{state: state} do
      # Test with host that already has protocol
      https_state = %{state | host: "https://api.datadoghq.com"}
      http_state = %{state | host: "http://localhost"}
      plain_state = %{state | host: "localhost"}

      # We can't easily test the actual URL construction without mocking Req,
      # but we can verify the function doesn't crash with different host formats
      body = "test"
      headers = []

      capture_log(fn ->
        assert match?({:error, _}, Exporter.push(body, headers, https_state))
        assert match?({:error, _}, Exporter.push(body, headers, http_state))
        assert match?({:error, _}, Exporter.push(body, headers, plain_state))
      end)
    end
  end

  describe "export/4 error scenarios" do
    setup do
      # Create ETS table for spans
      tid = :ets.new(:test_spans, [:set, :public])
      
      # Create minimal resource
      empty_attributes = Exporter.attributes()
      resource = Exporter.resource(attributes: empty_attributes)

      # Create state with unreachable host
      state = %Exporter.State{
        host: "unreachable-host-12345",
        port: 8126,
        timeout_ms: 100,
        connect_timeout_ms: 50,
        protocol: :v05
      }

      on_exit(fn -> 
        if :ets.info(tid) != :undefined do
          :ets.delete(tid) 
        end
      end)

      {:ok, tid: tid, resource: resource, state: state}
    end

    test "export returns :ok even with connection failures", %{tid: tid, resource: resource, state: state} do
      # Test with empty table (no spans to export)
      log_output = capture_log(fn ->
        result = Exporter.export(:traces, tid, resource, state)
        assert result == :ok
      end)

      # Should log the connection error
      assert log_output =~ "Trace export failed with request error"
    end

    test "emits telemetry events on failure", %{tid: tid, resource: resource, state: state} do
      # Attach telemetry handler
      test_pid = self()
      
      :telemetry.attach(
        "test-export-failure-resilience",
        [:opentelemetry_datadog, :export, :stop],
        fn event, measurements, metadata, _config ->
          send(test_pid, {:telemetry_event, {event, measurements, metadata}})
        end,
        nil
      )

      capture_log(fn ->
        Exporter.export(:traces, tid, resource, state)
      end)

      # Should receive telemetry event
      assert_receive {:telemetry_event, {[:opentelemetry_datadog, :export, :stop], _measurements, metadata}}, 1000

      # Metadata should contain error information
      assert Map.has_key?(metadata, :error)
      assert metadata.retry == true  # Connection errors should be retryable

      :telemetry.detach("test-export-failure-resilience")
    end

    test "handles empty span table gracefully", %{tid: tid, resource: resource, state: state} do
      # Don't add any spans - table is empty
      
      log_output = capture_log(fn ->
        result = Exporter.export(:traces, tid, resource, state)
        assert result == :ok
      end)

      # Should still try to export and fail gracefully
      assert log_output =~ "Trace export failed with request error"
    end
  end

  describe "build_headers/2" do
    test "builds correct headers without container ID" do
      headers = Exporter.build_headers(5, nil)
      
      expected_headers = [
        {"Content-Type", "application/msgpack"},
        {"Datadog-Meta-Lang", "elixir"},
        {"Datadog-Meta-Lang-Version", System.version()},
        {"Datadog-Meta-Tracer-Version", Application.spec(:opentelemetry_datadog)[:vsn] || "unknown"},
        {"X-Datadog-Trace-Count", "5"}
      ]
      
      assert headers == expected_headers
    end

    test "builds correct headers with container ID" do
      headers = Exporter.build_headers(3, "container-123")
      
      # Should include container ID header
      assert {"Datadog-Container-ID", "container-123"} in headers
      assert {"X-Datadog-Trace-Count", "3"} in headers
      assert {"Content-Type", "application/msgpack"} in headers
    end

    test "handles zero trace count" do
      headers = Exporter.build_headers(0, nil)
      
      assert {"X-Datadog-Trace-Count", "0"} in headers
    end
  end
end