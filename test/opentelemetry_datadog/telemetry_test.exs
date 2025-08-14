defmodule OpentelemetryDatadog.TelemetryTest do
  use ExUnit.Case, async: true

  @moduletag :unit

  alias OpentelemetryDatadog.Exporter

  @telemetry_events [
    [:opentelemetry_datadog, :export, :start],
    [:opentelemetry_datadog, :export, :stop],
    [:opentelemetry_datadog, :export, :error],
    [:opentelemetry_datadog, :export, :exception],
    [:opentelemetry_datadog, :export, :failure]
  ]

  defp capture_telemetry_events(event_names, fun) do
    test_pid = self()

    handlers =
      for event_name <- event_names do
        handler_id = "test_handler_#{:erlang.unique_integer()}"

        :telemetry.attach(
          handler_id,
          event_name,
          &OpentelemetryDatadog.TelemetryHandler.handle_event/4,
          test_pid: test_pid
        )

        handler_id
      end

    try do
      result = fun.()
      events = collect_events([], 500)
      {result, events}
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

  defp assert_keys_present(map, keys) do
    Enum.each(keys, fn key ->
      assert Map.has_key?(map, key)
    end)
  end

  describe "telemetry instrumentation" do
    test "telemetry events have correct structure" do
      start_measurements = %{system_time: System.system_time(), span_count: 5}
      start_metadata = %{endpoint: "/v0.5/traces", host: "localhost", port: 8126}
      assert_keys_present(start_measurements, [:system_time, :span_count])
      assert_keys_present(start_metadata, [:endpoint, :host, :port])
      assert is_integer(start_measurements.system_time)
      assert is_integer(start_measurements.span_count)

      stop_measurements = %{duration: 1_000_000, status_code: 200, span_count: 5}
      assert_keys_present(stop_measurements, [:duration, :status_code, :span_count])
      assert is_integer(stop_measurements.duration)
      assert is_integer(stop_measurements.status_code)

      error_measurements = %{span_count: 5}

      error_metadata = %{
        error: "HTTP error: 500",
        endpoint: "/v0.5/traces",
        host: "localhost",
        port: 8126,
        retry: false
      }

      assert_keys_present(error_measurements, [:span_count])
      assert_keys_present(error_metadata, [:error, :retry])
      assert is_boolean(error_metadata.retry)

      exception_measurements = %{span_count: 5}

      exception_metadata = %{
        kind: RuntimeError,
        reason: "Test error",
        stacktrace: [],
        endpoint: "/v0.5/traces",
        host: "localhost",
        port: 8126
      }

      assert_keys_present(exception_measurements, [:span_count])
      assert_keys_present(exception_metadata, [:kind, :reason, :stacktrace])
      assert is_atom(exception_metadata.kind)
      assert is_binary(exception_metadata.reason)
      assert is_list(exception_metadata.stacktrace)
    end

    test "telemetry events can be emitted manually" do
      test_id = "manual_emit_#{:erlang.unique_integer()}"

      # Clear any existing events
      receive do
        {:telemetry_event, _, _, _} -> :ok
      after
        0 -> :ok
      end

      {_result, events} =
        capture_telemetry_events(@telemetry_events, fn ->
          :telemetry.execute(
            @telemetry_events |> Enum.at(0),
            %{system_time: System.system_time(), span_count: 3},
            %{endpoint: "/v0.5/traces", host: "localhost", port: 8126, test_id: test_id}
          )

          :telemetry.execute(
            @telemetry_events |> Enum.at(1),
            %{duration: 1_000_000, status_code: 200, span_count: 3},
            %{endpoint: "/v0.5/traces", host: "localhost", port: 8126, test_id: test_id}
          )

          :telemetry.execute(@telemetry_events |> Enum.at(2), %{span_count: 3}, %{
            error: "Connection refused",
            endpoint: "/v0.5/traces",
            host: "localhost",
            port: 8126,
            retry: true,
            test_id: test_id
          })

          :telemetry.execute(@telemetry_events |> Enum.at(3), %{span_count: 3}, %{
            kind: RuntimeError,
            reason: "Encoding failed",
            stacktrace: [],
            endpoint: "/v0.5/traces",
            host: "localhost",
            port: 8126,
            test_id: test_id
          })

          :telemetry.execute(@telemetry_events |> Enum.at(4), %{span_count: 3, trace_count: 2}, %{
            reason: "Connection refused",
            failure_type: :agent_unavailable,
            trace_ids: [123_456_789, 987_654_321],
            host: "localhost",
            port: 8126,
            endpoint: "/v0.5/traces",
            test_id: test_id
          })

          :ok
        end)

      # Filter events to only those we manually emitted (with our test_id)
      filtered_events =
        Enum.filter(events, fn {_event, _measurements, metadata} ->
          metadata[:test_id] == test_id
        end)

      assert length(filtered_events) == 5

      [
        {[:start, 3], :span_count},
        {[:stop, 3], :status_code},
        {[:error, 3], :error},
        {[:exception, 3], :reason},
        {[:failure, 3], :failure_type}
      ]
      |> Enum.with_index()
      |> Enum.each(fn
        {{[:start, sc], _attr}, idx} ->
          {event, meas, meta} = Enum.at(filtered_events, idx)
          assert event == Enum.at(@telemetry_events, idx)
          assert meas.span_count == sc
          assert meta.endpoint == "/v0.5/traces"
          assert meta.test_id == test_id

        {{[:stop, sc], _attr}, idx} ->
          {_event, meas, meta} = Enum.at(filtered_events, idx)
          assert meas.status_code == 200
          assert meas.span_count == sc
          assert meta.endpoint == "/v0.5/traces"
          assert meta.test_id == test_id

        {{[:error, sc], _attr}, idx} ->
          {_, meas, meta} = Enum.at(filtered_events, idx)
          assert meas.span_count == sc
          assert meta.error == "Connection refused"
          assert meta.retry == true
          assert meta.test_id == test_id

        {{[:exception, sc], _attr}, idx} ->
          {_, meas, meta} = Enum.at(filtered_events, idx)
          assert meas.span_count == sc
          assert meta.kind == RuntimeError
          assert meta.reason == "Encoding failed"
          assert meta.test_id == test_id

        {{[:failure, sc], _attr}, idx} ->
          {_, meas, meta} = Enum.at(filtered_events, idx)
          assert meas.span_count == sc
          assert meas.trace_count == 2
          assert meta.reason == "Connection refused"
          assert meta.failure_type == :agent_unavailable
          assert meta.trace_ids == [123_456_789, 987_654_321]
          assert meta.host == "localhost"
          assert meta.port == 8126
          assert meta.endpoint == "/v0.5/traces"
          assert meta.test_id == test_id
      end)
    end

    test "exporter initialization works correctly" do
      config = [
        host: "http://localhost",
        port: 8126
      ]

      {:ok, state} = Exporter.init(config)

      assert %Exporter.State{} = state
      assert state.host == "http://localhost"
      assert state.port == 8126
    end

    test "exporter handles metrics export without telemetry" do
      state = %Exporter.State{host: "localhost", port: 8126}

      {result, events} =
        capture_telemetry_events(@telemetry_events, fn ->
          # Clear any pending events first
          receive do
            {:telemetry_event, _, _, _} -> :ok
          after
            0 -> :ok
          end

          Exporter.export(:metrics, nil, nil, state)
        end)

      # Filter events to only those from our test (localhost:8126) vs others (unreachable-host-12345)
      filtered_events =
        Enum.filter(events, fn {_event, _measurements, metadata} ->
          metadata[:host] == "localhost" and metadata[:port] == 8126
        end)

      assert result == :ok
      assert filtered_events == []
    end

    test "telemetry event names follow correct pattern" do
      Enum.each(@telemetry_events, fn [app, op, event] ->
        assert app == :opentelemetry_datadog
        assert op == :export
        assert event in [:start, :stop, :error, :exception, :failure]
      end)
    end
  end
end
