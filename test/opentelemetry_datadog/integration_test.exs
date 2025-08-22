defmodule OpentelemetryDatadog.IntegrationTest do
  use ExUnit.Case, async: false
  @moduletag :integration

  import OpentelemetryDatadog.TestHelpers

  setup do
    reset_env()
    :ok
  end

  describe "complete integration workflows" do
    test "production microservice deployment scenario" do
      prod_config("user-service", "v2.1.0")

      assert {:ok, loaded_config} = OpentelemetryDatadog.Config.load()
      assert :ok = OpentelemetryDatadog.Config.validate(loaded_config)
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
    end

    test "manual configuration override workflow" do
      config = [
        host: "manual-agent.example.com",
        port: 8127,
        service: "manual-service",
        version: "manual-version",
        env: "manual-env"
      ]

      assert :ok = OpentelemetryDatadog.Config.validate(Enum.into(config, %{}))
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

      assert :ok = OpentelemetryDatadog.Config.validate(Enum.into(app_config, %{}))
    end
  end

  describe "exception-raising variants" do
    test "load! raises ConfigError on missing configuration" do
      assert_raise OpentelemetryDatadog.ConfigError,
                   ~r/Configuration error.*DD_AGENT_HOST is required/,
                   fn ->
                     OpentelemetryDatadog.Config.load!()
                   end
    end

    test "validate with invalid config raises ConfigError" do
      config = [port: 8126]

      case OpentelemetryDatadog.Config.validate(Enum.into(config, %{})) do
        :ok ->
          flunk("Expected validation to fail")

        {:error, :missing_required_config, message} ->
          assert message =~ "host is required"
      end
    end

    test "get_config! raises ConfigError on missing configuration" do
      assert_raise OpentelemetryDatadog.ConfigError,
                   ~r/Configuration error.*DD_AGENT_HOST is required/,
                   fn ->
                     OpentelemetryDatadog.get_config!()
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
    end

    test "containerized application with full configuration" do
      containerized_config()

      config = OpentelemetryDatadog.get_config!()
      assert config.host == "dd-agent"
      assert config.service == "api-service"
      assert config.sample_rate == 0.2
      assert config.tags["container"] == "docker"
      assert config.tags["orchestrator"] == "k8s"
    end
  end

  describe "v0.5 integration" do
    test "can configure exporter from environment" do
      minimal_config()

      assert {:ok, config} = OpentelemetryDatadog.Config.get_config()
      assert config[:host] == "localhost"
      assert config[:port] == OpentelemetryDatadog.DatadogConstants.default(:port)
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

    test "demonstrates usage pattern" do
      dev_config("example-service")
      assert {:ok, config} = OpentelemetryDatadog.Config.get_config()

      assert {:ok, exporter_state} = OpentelemetryDatadog.Exporter.init(config)
      assert exporter_state.host == "localhost"

      span_data = %{
        trace_id: 999_888_777,
        span_id: 111_222_333,
        parent_id: nil,
        name: "example.operation",
        service: "example-service",
        resource: "GET /api/example",
        type: "web",
        start: System.system_time(:nanosecond),
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

      assert {:ok, encoded} = OpentelemetryDatadog.Encoder.encode([span_data])
      assert is_binary(encoded)

      {:ok, decoded} = Msgpax.unpack(encoded)
      [decoded_span] = decoded

      assert decoded_span["trace_id"] == 999_888_777
      assert decoded_span["service"] == "example-service"
      assert decoded_span["resource"] == "GET /api/example"
      assert decoded_span["type"] == "web"
      assert decoded_span["meta"]["http.method"] == "GET"
      assert decoded_span["metrics"]["http.response_time"] == 0.025
    end

    test "works with different environment configurations" do
      configurations = [
        {"production", fn -> prod_config("api-service", "v1.2.3") end,
         "datadog-agent.kube-system.svc.cluster.local"},
        {"containerized",
         fn -> containerized_config("container-service", "v2.0.0", "staging") end, "dd-agent"},
        {"phoenix", fn -> phoenix_config("phoenix-web-app") end, "localhost"}
      ]

      for {_env_name, setup_fn, expected_host} <- configurations do
        setup_fn.()

        assert {:ok, config} = OpentelemetryDatadog.Config.get_config()
        assert config[:host] == expected_host

        assert {:ok, exporter_state} = OpentelemetryDatadog.Exporter.init(config)
        assert exporter_state.host == expected_host

        reset_env()
      end
    end

    test "handles error scenarios gracefully" do
      invalid_port_config()

      assert {:error, :invalid_config, _} = OpentelemetryDatadog.Config.get_config()
    end

    test "works with CI configuration" do
      ci_config("ci-test-service")

      assert {:ok, config} = OpentelemetryDatadog.Config.get_config()
      assert config[:host] == "localhost"

      {:ok, base_config} = OpentelemetryDatadog.Config.load()
      assert base_config.sample_rate == 1.0
    end
  end
end
