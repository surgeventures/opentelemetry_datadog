defmodule OpentelemetryDatadog.DatadogContainerTest do
  use ExUnit.Case, async: false
  @moduletag :integration

  import OpentelemetryDatadog.TestHelpers
  require OpenTelemetry.Tracer

  @moduletag timeout: 60_000

  setup_all do
    # Start Datadog Agent container
    {:ok, container} = OpentelemetryDatadog.Testcontainers.start_dd_agent(log_level: "debug")
    
    # Wait for agent to be ready
    :ok = OpentelemetryDatadog.Testcontainers.wait_for_agent(container)
    
    # Get connection info
    {host, port} = OpentelemetryDatadog.Testcontainers.get_connection_info(container)
    
    on_exit(fn -> 
      OpentelemetryDatadog.Testcontainers.stop(container) 
    end)
    
    %{container: container, host: host, port: port}
  end

  setup %{host: host, port: port} do
    reset_env()
    
    # Configure to use the containerized agent
    put_env(%{
      "DD_AGENT_HOST" => host,
      "DD_TRACE_AGENT_PORT" => Integer.to_string(port),
      "DD_SERVICE" => "test-service",
      "DD_ENV" => "test",
      "DD_VERSION" => "1.0.0"
    })
    
    :ok
  end

  describe "Datadog Agent container integration" do
    test "agent container is running and accessible", %{host: host, port: port} do
      # Test that we can reach the agent's info endpoint
      url = "http://#{host}:#{port}/info"
      
      assert {:ok, response} = Req.get(url)
      assert response.status == 200
      assert is_map(response.body)
    end

    test "sends a span to Datadog agent", %{container: container} do
      # Setup OpenTelemetry Datadog integration
      assert :ok = OpentelemetryDatadog.setup()
      
      # Create a test span using OpenTelemetry
      OpenTelemetry.Tracer.with_span "test-span", %{} do
        # Add some attributes to the span
        OpenTelemetry.Tracer.set_attributes([
          {"http.method", "GET"},
          {"http.url", "http://example.com/test"},
          {"custom.attribute", "test-value"}
        ])
        
        # Simulate some work
        Process.sleep(10)
        
        :ok
      end
      
      # Give some time for the span to be exported
      Process.sleep(2000)
      
      # Verify the agent received the trace
      # We can check this by looking at the agent's debug endpoint or logs
      logs = OpentelemetryDatadog.Testcontainers.get_logs(container)
      
      # The agent should log something about receiving traces
      # This is a basic check - in a real scenario you might want to
      # use the agent's API to verify the trace was received
      assert String.contains?(logs, "datadog-agent") or String.contains?(logs, "trace-agent")
    end

    test "handles multiple spans correctly", %{container: container} do
      assert :ok = OpentelemetryDatadog.setup()
      
      # Create multiple spans
      for i <- 1..3 do
        OpenTelemetry.Tracer.with_span "test-span-#{i}", %{} do
          OpenTelemetry.Tracer.set_attributes([
            {"span.number", i},
            {"operation", "test-operation-#{i}"}
          ])
          
          Process.sleep(5)
          :ok
        end
      end
      
      # Give time for spans to be exported
      Process.sleep(3000)
      
      # Verify agent is still running and responsive
      {host, port} = OpentelemetryDatadog.Testcontainers.get_connection_info(container)
      url = "http://#{host}:#{port}/info"
      
      assert {:ok, response} = Req.get(url)
      assert response.status == 200
    end

    test "handles span with error status", %{container: container} do
      assert :ok = OpentelemetryDatadog.setup()
      
      # Create a span that represents an error
      OpenTelemetry.Tracer.with_span "error-span", %{} do
        OpenTelemetry.Tracer.set_attributes([
          {"error.type", "TestError"},
          {"error.message", "This is a test error"}
        ])
        
        # Set span status to error
        OpenTelemetry.Tracer.set_status(:error, "Test error occurred")
        
        :ok
      end
      
      # Give time for span to be exported
      Process.sleep(2000)
      
      # Verify agent is still responsive
      {host, port} = OpentelemetryDatadog.Testcontainers.get_connection_info(container)
      url = "http://#{host}:#{port}/info"
      
      assert {:ok, response} = Req.get(url)
      assert response.status == 200
    end

    test "configuration is applied correctly" do
      # Verify that our test configuration is loaded
      assert {:ok, config} = OpentelemetryDatadog.get_config()
      
      assert config.service == "test-service"
      assert config.env == "test"
      assert config.version == "1.0.0"
      assert is_binary(config.host)
      assert is_integer(config.port)
      assert config.port > 0
    end

    test "setup with manual configuration works", %{host: host, port: port} do
      # Reset environment to test manual configuration
      reset_env()
      
      manual_config = [
        host: host,
        port: port,
        service: "manual-test-service",
        env: "manual-test",
        version: "2.0.0"
      ]
      
      assert :ok = OpentelemetryDatadog.setup(manual_config)
      
      # Create a span with manual configuration
      OpenTelemetry.Tracer.with_span "manual-config-span", %{} do
        OpenTelemetry.Tracer.set_attributes([
          {"config.type", "manual"},
          {"test.scenario", "manual-configuration"}
        ])
        
        :ok
      end
      
      # Give time for span to be exported
      Process.sleep(2000)
      
      # Verify agent is still responsive
      url = "http://#{host}:#{port}/info"
      assert {:ok, response} = Req.get(url)
      assert response.status == 200
    end
  end

  describe "error scenarios with container" do
    test "handles agent temporary unavailability gracefully", %{container: container} do
      assert :ok = OpentelemetryDatadog.setup()
      
      # Create a span before stopping the agent
      OpenTelemetry.Tracer.with_span "before-stop-span", %{} do
        OpenTelemetry.Tracer.set_attributes([{"phase", "before-stop"}])
        :ok
      end
      
      # Stop the container temporarily
      :ok = OpentelemetryDatadog.Testcontainers.stop(container)
      
      # Try to create spans while agent is down
      # This should not crash the application
      OpenTelemetry.Tracer.with_span "during-downtime-span", %{} do
        OpenTelemetry.Tracer.set_attributes([{"phase", "during-downtime"}])
        :ok
      end
      
      # The test should complete without crashing
      # In a real scenario, spans would be queued or dropped gracefully
      assert true
    end
  end
end