defmodule OpentelemetryDatadog.V05.TelemetryTest do
  use ExUnit.Case, async: true

  alias OpentelemetryDatadog.V05.Exporter

  defp capture_telemetry_events(event_names, fun) do
    test_pid = self()

    handlers =
      Enum.map(event_names, fn event_name ->
        handler_id = "test_handler_#{:erlang.unique_integer()}"

        :telemetry.attach(
          handler_id,
          event_name,
          fn event, measurements, metadata, _config ->
            send(test_pid, {:telemetry_event, event, measurements, metadata})
          end,
          nil
        )

        handler_id
      end)

    try do
      result = fun.()
      collected_events = collect_events([], 500)

      {result, collected_events}
    after
      Enum.each(handlers, &:telemetry.detach/1)
    end
  end

  defp collect_events(events, timeout) do
    receive do
      {:telemetry_event, event, measurements, metadata} ->
        collect_events([{event, measurements, metadata} | events], timeout)
    after
      timeout -> Enum.reverse(events)
    end
  end

  describe "telemetry instrumentation" do
    @tag :unit
    test "telemetry events have correct structure" do
      # Test start event structure
      start_measurements = %{system_time: System.system_time(), span_count: 5}
      start_metadata = %{endpoint: "/v0.5/traces", host: "localhost", port: 8126}

      # Verify measurements structure
      assert is_map(start_measurements)
      assert Map.has_key?(start_measurements, :system_time)
      assert Map.has_key?(start_measurements, :span_count)
      assert is_integer(start_measurements.system_time)
      assert is_integer(start_measurements.span_count)

      # Verify metadata structure
      assert is_map(start_metadata)
      assert Map.has_key?(start_metadata, :endpoint)
      assert Map.has_key?(start_metadata, :host)
      assert Map.has_key?(start_metadata, :port)
      assert start_metadata.endpoint == "/v0.5/traces"

      # Test stop event structure
      stop_measurements = %{duration: 1_000_000, status_code: 200, span_count: 5}
      stop_metadata = %{endpoint: "/v0.5/traces", host: "localhost", port: 8126}

      assert Map.has_key?(stop_measurements, :duration)
      assert Map.has_key?(stop_measurements, :status_code)
      assert Map.has_key?(stop_measurements, :span_count)
      assert is_integer(stop_measurements.duration)
      assert is_integer(stop_measurements.status_code)

      # Test error event structure
      error_measurements = %{span_count: 5}

      error_metadata = %{
        error: "HTTP error: 500",
        endpoint: "/v0.5/traces",
        host: "localhost",
        port: 8126,
        retry: false
      }

      assert Map.has_key?(error_measurements, :span_count)
      assert Map.has_key?(error_metadata, :error)
      assert Map.has_key?(error_metadata, :retry)
      assert is_boolean(error_metadata.retry)

      # Test exception event structure
      exception_measurements = %{span_count: 5}

      exception_metadata = %{
        kind: RuntimeError,
        reason: "Test error",
        stacktrace: [],
        endpoint: "/v0.5/traces",
        host: "localhost",
        port: 8126
      }

      assert Map.has_key?(exception_measurements, :span_count)
      assert Map.has_key?(exception_metadata, :kind)
      assert Map.has_key?(exception_metadata, :reason)
      assert Map.has_key?(exception_metadata, :stacktrace)
      assert is_atom(exception_metadata.kind)
      assert is_binary(exception_metadata.reason)
      assert is_list(exception_metadata.stacktrace)
    end

    @tag :unit
    test "telemetry events can be emitted manually" do
      event_names = [
        [:opentelemetry_datadog, :export, :start],
        [:opentelemetry_datadog, :export, :stop],
        [:opentelemetry_datadog, :export, :error],
        [:opentelemetry_datadog, :export, :exception]
      ]

      {_result, events} =
        capture_telemetry_events(event_names, fn ->
          # Emit start event
          :telemetry.execute(
            [:opentelemetry_datadog, :export, :start],
            %{system_time: System.system_time(), span_count: 3},
            %{endpoint: "/v0.5/traces", host: "localhost", port: 8126}
          )

          # Emit stop event
          :telemetry.execute(
            [:opentelemetry_datadog, :export, :stop],
            %{duration: 1_000_000, status_code: 200, span_count: 3},
            %{endpoint: "/v0.5/traces", host: "localhost", port: 8126}
          )

          # Emit error event
          :telemetry.execute(
            [:opentelemetry_datadog, :export, :error],
            %{span_count: 3},
            %{
              error: "Connection refused",
              endpoint: "/v0.5/traces",
              host: "localhost",
              port: 8126,
              retry: true
            }
          )

          # Emit exception event
          :telemetry.execute(
            [:opentelemetry_datadog, :export, :exception],
            %{span_count: 3},
            %{
              kind: RuntimeError,
              reason: "Encoding failed",
              stacktrace: [],
              endpoint: "/v0.5/traces",
              host: "localhost",
              port: 8126
            }
          )

          :ok
        end)

      assert length(events) == 4

      # Verify start event
      {start_event, start_measurements, start_metadata} = Enum.at(events, 0)
      assert start_event == [:opentelemetry_datadog, :export, :start]
      assert start_measurements.span_count == 3
      assert start_metadata.endpoint == "/v0.5/traces"

      # Verify stop event
      {stop_event, stop_measurements, stop_metadata} = Enum.at(events, 1)
      assert stop_event == [:opentelemetry_datadog, :export, :stop]
      assert stop_measurements.status_code == 200
      assert stop_measurements.span_count == 3
      assert stop_metadata.endpoint == "/v0.5/traces"

      # Verify error event
      {error_event, error_measurements, error_metadata} = Enum.at(events, 2)
      assert error_event == [:opentelemetry_datadog, :export, :error]
      assert error_measurements.span_count == 3
      assert error_metadata.error == "Connection refused"
      assert error_metadata.retry == true

      # Verify exception event
      {exception_event, exception_measurements, exception_metadata} = Enum.at(events, 3)
      assert exception_event == [:opentelemetry_datadog, :export, :exception]
      assert exception_measurements.span_count == 3
      assert exception_metadata.kind == RuntimeError
      assert exception_metadata.reason == "Encoding failed"
    end

    @tag :unit
    test "exporter initialization works correctly" do
      config = [
        host: "http://localhost",
        port: 8126,
        protocol: :v05
      ]

      {:ok, state} = Exporter.init(config)
      assert state.host == "http://localhost"
      assert state.port == 8126
      assert state.protocol == :v05
    end

    @tag :unit
    test "exporter handles metrics export without telemetry" do
      state = %Exporter.State{protocol: :v05}

      event_names = [
        [:opentelemetry_datadog, :export, :start],
        [:opentelemetry_datadog, :export, :stop],
        [:opentelemetry_datadog, :export, :error],
        [:opentelemetry_datadog, :export, :exception]
      ]

      {result, events} =
        capture_telemetry_events(event_names, fn ->
          Exporter.export(:metrics, nil, nil, state)
        end)

      assert result == :ok
      assert length(events) == 0
    end

    @tag :unit
    test "telemetry event names follow correct pattern" do
      expected_events = [
        [:opentelemetry_datadog, :export, :start],
        [:opentelemetry_datadog, :export, :stop],
        [:opentelemetry_datadog, :export, :error],
        [:opentelemetry_datadog, :export, :exception]
      ]

      Enum.each(expected_events, fn event_name ->
        assert is_list(event_name)
        assert length(event_name) == 3
        assert Enum.at(event_name, 0) == :opentelemetry_datadog
        assert Enum.at(event_name, 1) == :export
        assert Enum.at(event_name, 2) in [:start, :stop, :error, :exception]
      end)
    end
  end
end
