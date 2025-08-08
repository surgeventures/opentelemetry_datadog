defmodule OpentelemetryDatadog.ExporterTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog
  require OpentelemetryDatadog.Exporter

  alias OpentelemetryDatadog.Exporter

  @moduletag :unit

  describe "export/4 graceful degradation" do
    test "export returns :ok even when agent is unavailable" do
      tid = :ets.new(:test_spans, [:set, :public])

      empty_attributes = Exporter.attributes()
      resource = Exporter.resource(attributes: empty_attributes)

      state = %Exporter.State{
        host: "unreachable-host-12345",
        port: 8126,
        container_id: "test-container",
        timeout_ms: 100,
        connect_timeout_ms: 50
      }

      :telemetry.attach(
        "test-export-failure",
        [:opentelemetry_datadog, :export, :failure],
        fn event, measurements, metadata, _config ->
          send(self(), {:telemetry_failure, {event, measurements, metadata}})
        end,
        nil
      )

      capture_log(fn ->
        result = Exporter.export(:traces, tid, resource, state)
        assert result == :ok
      end)

      :ets.delete(tid)
      :telemetry.detach("test-export-failure")
    end

    test "export handles metrics export" do
      empty_attributes = Exporter.attributes()
      resource = Exporter.resource(attributes: empty_attributes)

      state = %Exporter.State{
        host: "localhost",
        port: 8126,
        container_id: "test-container",
        timeout_ms: 2000,
        connect_timeout_ms: 500
      }

      result = Exporter.export(:metrics, nil, resource, state)
      assert result == :ok
    end
  end

  describe "shutdown/1" do
    test "shutdown returns :ok" do
      state = %Exporter.State{}
      result = Exporter.shutdown(state)
      assert result == :ok
    end
  end

  describe "init/1" do
    test "initializes state correctly" do
      config = [
        host: "test-host",
        port: 9999,
        timeout_ms: 3000,
        connect_timeout_ms: 1000
      ]

      {:ok, state} = Exporter.init(config)

      assert state.host == "test-host"
      assert state.port == 9999
      assert state.timeout_ms == 3000
      assert state.connect_timeout_ms == 1000
    end

    test "uses default values when not provided" do
      config = [
        host: "test-host",
        port: 8126
      ]

      {:ok, state} = Exporter.init(config)

      assert state.host == "test-host"
      assert state.port == 8126
      assert state.timeout_ms == 2000
      assert state.connect_timeout_ms == 500
    end
  end
end
