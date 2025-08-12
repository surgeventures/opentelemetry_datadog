defmodule OpentelemetryDatadog.IntegrationTest do
  use ExUnit.Case, async: false

  import OpentelemetryDatadog.TestHelpers

  @moduletag :integration

  setup do
    reset_env()
    :ok
  end

  describe "complete integration workflows" do
    test "production microservice deployment scenario" do
      prod_config("user-service", "v2.1.0")

      assert {:ok, loaded_config} = OpentelemetryDatadog.Config.load()
      assert :ok = OpentelemetryDatadog.Config.validate(loaded_config)
      assert :ok = OpentelemetryDatadog.setup()
      assert {:ok, runtime_config} = OpentelemetryDatadog.get_config()

      assert loaded_config.host == runtime_config.host
      assert loaded_config.service == runtime_config.service
      assert loaded_config.tags == runtime_config.tags
      assert loaded_config.sample_rate == runtime_config.sample_rate
    end

    test "development environment with minimal configuration" do
      minimal_config()

      assert {:ok, config} = OpentelemetryDatadog.Config.load()
      assert config.host == "localhost"
      assert config.port == 8126
      assert is_nil(config.service)
      assert is_nil(config.tags)

      assert :ok = OpentelemetryDatadog.setup()
    end

    test "manual configuration override workflow" do
      config = [
        host: "manual-agent.example.com",
        port: 8127,
        service: "manual-service",
        version: "manual-version",
        env: "manual-env"
      ]

      assert :ok = OpentelemetryDatadog.setup(config)
    end
  end

  describe "environment override scenarios" do
    test "environment variables take precedence" do
      app_config = [
        host: "app-default-host",
        port: 8127,
        service: "app-service"
      ]

      put_env(%{
        "DD_AGENT_HOST" => "env-override-host",
        "DD_TRACE_AGENT_PORT" => "8128",
        "DD_SERVICE" => "env-service"
      })

      assert {:ok, env_config} = OpentelemetryDatadog.Config.load()
      assert env_config.host == "env-override-host"
      assert env_config.port == 8128
      assert env_config.service == "env-service"

      assert :ok = OpentelemetryDatadog.setup(app_config)
    end
  end

  describe "exception-raising variants" do
    test "setup! raises ConfigError on missing configuration" do
      assert_raise OpentelemetryDatadog.ConfigError,
                   ~r/Configuration error.*DD_AGENT_HOST is required/,
                   fn ->
                     OpentelemetryDatadog.setup!()
                   end
    end

    test "setup! with invalid config raises ConfigError" do
      config = [port: 8126]

      assert_raise OpentelemetryDatadog.ConfigError,
                   ~r/Configuration error.*host is required/,
                   fn ->
                     OpentelemetryDatadog.setup!(config)
                   end
    end

    test "get_config! raises ConfigError on missing configuration" do
      assert_raise OpentelemetryDatadog.ConfigError,
                   ~r/Configuration error.*DD_AGENT_HOST is required/,
                   fn ->
                     OpentelemetryDatadog.get_config!()
                   end
    end

    test "config load! raises ConfigError on missing configuration" do
      assert_raise OpentelemetryDatadog.ConfigError,
                   ~r/Configuration error.*DD_AGENT_HOST is required/,
                   fn ->
                     OpentelemetryDatadog.Config.load!()
                   end
    end
  end

  describe "comprehensive application startup scenarios" do
    test "typical Phoenix application startup" do
      phoenix_config()

      assert {:ok, config} = OpentelemetryDatadog.Config.load()
      assert :ok = OpentelemetryDatadog.Config.validate(config)

      exporter_config = OpentelemetryDatadog.Config.to_exporter_config(config)
      assert is_list(exporter_config)
      assert exporter_config[:host] == "localhost"
      assert exporter_config[:service] == "phoenix-app"
      assert exporter_config[:env] == "development"

      assert :ok = OpentelemetryDatadog.setup()
    end

    test "containerized application with full configuration" do
      containerized_config()

      config = OpentelemetryDatadog.get_config!()
      assert config.host == "dd-agent"
      assert config.service == "api-service"
      assert config.sample_rate == 0.2
      assert config.tags["container"] == "docker"
      assert config.tags["orchestrator"] == "k8s"

      assert :ok = OpentelemetryDatadog.setup!()
    end
  end

  describe "v0.5 integration" do
    test "can configure exporter from environment" do
      minimal_config()

      assert {:ok, config} = OpentelemetryDatadog.Config.get_config()
      assert config[:protocol] == :v05
      assert config[:host] == "localhost"
      assert config[:port] == OpentelemetryDatadog.DatadogConstants.default(:port)
    end

    test "can initialize exporter" do
      config = [
        host: "localhost",
        port: 8126,
        protocol: :v05
      ]

      assert {:ok, state} = OpentelemetryDatadog.Exporter.init(config)
      assert state.protocol == :v05
      assert state.host == "localhost"
      assert state.port == 8126
    end

    test "can encode spans for API" do
      spans = [
        %{
          trace_id: 123_456_789,
          span_id: 987_654_321,
          parent_id: nil,
          name: "integration.test",
          service: "test-service",
          resource: "integration test",
          type: "test",
          start: 1_640_995_200_000_000_000,
          duration: 50_000_000,
          error: 0,
          meta: %{"test.type" => "integration"},
          metrics: %{"test.count" => 1}
        }
      ]

      assert {:ok, encoded} = OpentelemetryDatadog.Encoder.encode(spans)
      assert is_binary(encoded)

      {:ok, decoded} = Msgpax.unpack(encoded)
      assert is_list(decoded)
      assert length(decoded) == 1

      [span] = decoded
      assert span["trace_id"] == 123_456_789
      assert span["span_id"] == 987_654_321
      assert span["name"] == "integration.test"
      assert span["service"] == "test-service"
      assert span["resource"] == "integration test"
      assert span["type"] == "test"
      assert span["error"] == 0
      assert span["meta"]["test.type"] == "integration"
      assert span["metrics"]["test.count"] == 1
    end

    test "configuration works correctly" do
      standard_config = [host: "localhost", port: 8126]
      config_map = Enum.into(standard_config, %{})
      assert OpentelemetryDatadog.Config.validate(config_map) == :ok

      # config should work correctly
      exporter_config =
        OpentelemetryDatadog.Config.to_exporter_config_with_protocol(standard_config)

      assert exporter_config[:protocol] == :v05
      assert exporter_config[:host] == "localhost"
      assert exporter_config[:port] == 8126
    end

    test "demonstrates usage pattern" do
      # 1. Set up environment and load configuration
      dev_config("example-service")
      assert {:ok, config} = OpentelemetryDatadog.Config.get_config()

      # 2. Initialize exporter
      assert {:ok, exporter_state} = OpentelemetryDatadog.Exporter.init(config)
      assert exporter_state.protocol == :v05

      # 3. Create sample span data
      span_data = %{
        trace_id: 999_888_777,
        span_id: 111_222_333,
        parent_id: nil,
        name: "example.operation",
        service: "example-service",
        resource: "GET /api/example",
        type: "web",
        start: System.system_time(:nanosecond),
        # 25ms
        duration: 25_000_000,
        error: 0,
        meta: %{
          "http.method" => "GET",
          "http.url" => "/api/example",
          "http.status_code" => "200"
        },
        metrics: %{
          "http.response_time" => 0.025
        }
      }

      # 4. Encode for transmission
      assert {:ok, encoded} = OpentelemetryDatadog.Encoder.encode([span_data])
      assert is_binary(encoded)

      # 5. Verify encoding is correct
      {:ok, decoded} = Msgpax.unpack(encoded)
      [decoded_span] = decoded

      assert decoded_span["trace_id"] == 999_888_777
      assert decoded_span["service"] == "example-service"
      assert decoded_span["resource"] == "GET /api/example"
      assert decoded_span["type"] == "web"
      assert decoded_span["meta"]["http.method"] == "GET"
      assert decoded_span["metrics"]["http.response_time"] == 0.025
    end

    test "works with production configuration" do
      prod_config("api-service", "v1.2.3")

      assert {:ok, config} = OpentelemetryDatadog.Config.get_config()
      assert config[:protocol] == :v05
      assert config[:host] == "datadog-agent.kube-system.svc.cluster.local"

      assert {:ok, exporter_state} = OpentelemetryDatadog.Exporter.init(config)
      assert exporter_state.protocol == :v05
    end

    test "works with containerized configuration" do
      containerized_config("container-service", "v2.0.0", "staging")

      assert {:ok, config} = OpentelemetryDatadog.Config.get_config()
      assert config[:protocol] == :v05
      assert config[:host] == "dd-agent"

      assert {:ok, exporter_state} = OpentelemetryDatadog.Exporter.init(config)
      assert exporter_state.protocol == :v05
    end

    test "works with Phoenix configuration" do
      phoenix_config("phoenix-web-app")

      assert {:ok, config} = OpentelemetryDatadog.Config.get_config()
      assert config[:protocol] == :v05
      assert config[:host] == "localhost"

      assert {:ok, exporter_state} = OpentelemetryDatadog.Exporter.init(config)
      assert exporter_state.protocol == :v05
    end

    test "handles error scenarios gracefully" do
      # Test that configuration errors are handled properly
      invalid_port_config()

      assert {:error, :invalid_config, _} = OpentelemetryDatadog.Config.get_config()
    end

    test "works with CI configuration" do
      ci_config("ci-test-service")

      assert {:ok, config} = OpentelemetryDatadog.Config.get_config()
      assert config[:protocol] == :v05
      assert config[:host] == "localhost"

      # CI config should have full sampling
      {:ok, base_config} = OpentelemetryDatadog.Config.load()
      assert base_config.sample_rate == 1.0
    end
  end
end
