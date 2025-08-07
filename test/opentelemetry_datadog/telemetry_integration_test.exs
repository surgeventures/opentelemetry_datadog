defmodule OpentelemetryDatadog.TelemetryIntegrationTest do
  use ExUnit.Case, async: true
  use OpentelemetryDatadog.TestHelpers
  import ExUnit.CaptureLog

  alias OpentelemetryDatadog.{Config, Exporter}

  @moduletag :integration

  describe "telemetry integration" do
    setup do
      put_env(%{
        "DD_AGENT_HOST" => "localhost",
        "DD_EXPORT_TIMEOUT_MS" => "1000"
      })

      {:ok, config} = Config.load()
      exporter_config = Config.to_exporter_config(config)
      {:ok, state} = Exporter.init(exporter_config)

      {:ok, state: state}
    end

    test "emits timeout telemetry events using attach_many", %{state: _state} do
      test_pid = self()
      handler_id = :test_telemetry_integration
      
      events = [
        [:opentelemetry_datadog, :export, :timeout]
      ]

      :telemetry.attach_many(
        handler_id,
        events,
        fn event, measurements, metadata, _config ->
          send(test_pid, {:telemetry_event, event, measurements, metadata})
        end,
        nil
      )

      capture_log(fn ->
        :telemetry.execute(
          [:opentelemetry_datadog, :export, :timeout],
          %{count: 1},
          %{timeout_ms: 1000, attempt: 1}
        )
      end)

      assert_receive {:telemetry_event, [:opentelemetry_datadog, :export, :timeout], measurements1, metadata1}
      assert measurements1.count == 1
      assert metadata1.timeout_ms == 1000
      assert metadata1.attempt == 1

      capture_log(fn ->
        :telemetry.execute(
          [:opentelemetry_datadog, :export, :timeout],
          %{count: 1},
          %{timeout_ms: 1000, attempt: 2}
        )
      end)

      assert_receive {:telemetry_event, [:opentelemetry_datadog, :export, :timeout], measurements2, metadata2}
      assert measurements2.count == 1
      assert metadata2.timeout_ms == 1000
      assert metadata2.attempt == 2

      capture_log(fn ->
        :telemetry.execute(
          [:opentelemetry_datadog, :export, :timeout],
          %{count: 1},
          %{timeout_ms: 5000, attempt: 3}
        )
      end)

      assert_receive {:telemetry_event, [:opentelemetry_datadog, :export, :timeout], measurements3, metadata3}
      assert measurements3.count == 1
      assert metadata3.timeout_ms == 5000
      assert metadata3.attempt == 3

      :telemetry.detach(handler_id)
    end

    test "timeout telemetry includes correct metadata structure" do
      test_pid = self()
      handler_id = :test_timeout_metadata
      
      :telemetry.attach(
        handler_id,
        [:opentelemetry_datadog, :export, :timeout],
        fn event, measurements, metadata, _config ->
          send(test_pid, {:timeout_telemetry, event, measurements, metadata})
        end,
        nil
      )

      :telemetry.execute(
        [:opentelemetry_datadog, :export, :timeout],
        %{count: 1},
        %{timeout_ms: 5000, attempt: 2}
      )

      assert_receive {:timeout_telemetry, event, measurements, metadata}
      
      assert event == [:opentelemetry_datadog, :export, :timeout]
      assert measurements == %{count: 1}
      assert metadata == %{timeout_ms: 5000, attempt: 2}

      :telemetry.detach(handler_id)
    end
  end
end
