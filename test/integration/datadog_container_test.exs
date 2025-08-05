defmodule OpentelemetryDatadog.DatadogContainerTest do
  use ExUnit.Case, async: false
  @moduletag :integration
  @moduletag timeout: 60_000

  import OpentelemetryDatadog.TestHelpers
  require OpenTelemetry.Tracer

  defp set_dd_env(host, port) do
    put_env(%{
      "DD_AGENT_HOST" => host,
      "DD_TRACE_AGENT_PORT" => Integer.to_string(port),
      "DD_SERVICE" => "test-service",
      "DD_ENV" => "test",
      "DD_VERSION" => "1.0.0"
    })
  end

  defp wait_span_flush, do: Process.sleep(3000)

  setup_all do
    {:ok, container} = OpentelemetryDatadog.Testcontainers.start_dd_agent(log_level: "debug")
    on_exit(fn -> OpentelemetryDatadog.Testcontainers.stop(container) end)

    :ok = OpentelemetryDatadog.Testcontainers.wait_for_agent(container, 90_000)
    {host, port} = OpentelemetryDatadog.Testcontainers.get_connection_info(container)

    :ok = OpentelemetryDatadog.Testcontainers.check_agent_health!(container)

    %{container: container, host: host, port: port}
  end

  setup %{host: host, port: port} do
    reset_env()
    set_dd_env(host, port)
    :ok
  end

  describe "Datadog Agent container integration" do
    test "agent is accessible and healthy", %{container: container} do
      assert :ok = OpentelemetryDatadog.Testcontainers.check_agent_health!(container)
    end

    test "sends a span to Datadog agent", %{container: container} do
      assert :ok = OpentelemetryDatadog.Testcontainers.check_agent_health!(container)
      assert :ok = OpentelemetryDatadog.setup()

      OpenTelemetry.Tracer.with_span "test-span", %{} do
        OpenTelemetry.Tracer.set_attributes([
          {"http.method", "GET"},
          {"http.url", "http://example.com/test"},
          {"custom.attribute", "test-value"}
        ])
      end

      wait_span_flush()

      logs = OpentelemetryDatadog.Testcontainers.get_logs(container)
      assert is_binary(logs)
      assert logs =~ "test-span"
    end

    test "handles multiple spans correctly", %{container: container} do
      assert :ok = OpentelemetryDatadog.setup()

      for i <- 1..3 do
        OpenTelemetry.Tracer.with_span "test-span-#{i}", %{} do
          OpenTelemetry.Tracer.set_attributes([
            {"span.number", i},
            {"operation", "test-operation-#{i}"}
          ])
        end
      end

      wait_span_flush()
      assert :ok = OpentelemetryDatadog.Testcontainers.check_agent_health!(container)
    end

    test "sends span with error status", %{container: container} do
      assert :ok = OpentelemetryDatadog.setup()

      OpenTelemetry.Tracer.with_span "error-span", %{} do
        OpenTelemetry.Tracer.set_attributes([
          {"error.type", "TestError"},
          {"error.message", "This is a test error"}
        ])

        OpenTelemetry.Tracer.set_status(:error, "Test error occurred")
      end

      wait_span_flush()
      assert :ok = OpentelemetryDatadog.Testcontainers.check_agent_health!(container)
    end

    test "configuration is applied correctly" do
      assert {:ok, config} = OpentelemetryDatadog.get_config()

      assert config.service == "test-service"
      assert config.env == "test"
      assert config.version == "1.0.0"
      assert is_binary(config.host)
      assert is_integer(config.port)
      assert config.port > 0
    end

    test "manual configuration works", %{host: host, port: port} do
      reset_env()

      manual_config = [
        host: host,
        port: port,
        service: "manual-test-service",
        env: "manual-test",
        version: "2.0.0"
      ]

      assert :ok = OpentelemetryDatadog.setup(manual_config)

      OpenTelemetry.Tracer.with_span "manual-config-span", %{} do
        OpenTelemetry.Tracer.set_attributes([
          {"config.type", "manual"},
          {"test.scenario", "manual-configuration"}
        ])
      end

      wait_span_flush()

      assert :ok =
               OpentelemetryDatadog.Testcontainers.check_agent_health!(%{host: host, port: port})
    end

    test "setup/0 is idempotent" do
      assert :ok = OpentelemetryDatadog.setup()
      assert :ok = OpentelemetryDatadog.setup()
    end
  end
end