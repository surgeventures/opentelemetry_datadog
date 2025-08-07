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
end
