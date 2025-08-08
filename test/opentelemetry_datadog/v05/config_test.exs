defmodule OpentelemetryDatadog.V05.ConfigTest do
  use ExUnit.Case, async: false
  use OpentelemetryDatadog.TestHelpers

  alias OpentelemetryDatadog.V05.Config

  describe "to_v05_exporter_config/1" do
    test "adds v05 protocol to keyword list config" do
      config = [host: "localhost", port: 8126, service: "my-service"]

      result = Config.to_v05_exporter_config(config)

      assert result[:protocol] == :v05
      assert result[:host] == "localhost"
      assert result[:port] == 8126
      assert result[:service] == "my-service"
    end

    test "converts map config to keyword list with v05 protocol" do
      config = %{host: "localhost", port: 8126, service: "my-service"}

      result = Config.to_v05_exporter_config(config)

      assert result[:protocol] == :v05
      assert result[:host] == "localhost"
      assert result[:port] == 8126
      assert result[:service] == "my-service"
    end

    test "overwrites existing protocol setting" do
      config = [host: "localhost", port: 8126, protocol: :v04]

      result = Config.to_v05_exporter_config(config)

      assert result[:protocol] == :v05
    end
  end

  describe "setup/1" do
    test "validates configuration and accepts v05 protocol" do
      config = [
        host: "localhost",
        port: 8126,
        protocol: :v05
      ]

      assert Config.setup(config) == :ok
    end

    test "defaults to v05 protocol when not specified" do
      config = [
        host: "localhost",
        port: 8126
      ]

      assert Config.setup(config) == :ok
    end

    test "rejects non-v05 protocols" do
      config = [
        host: "localhost",
        port: 8126,
        protocol: :v04
      ]

      assert {:error, :invalid_config, message} = Config.setup(config)
      assert message =~ "v0.5 exporter requires protocol: :v05"
    end

    test "validates required configuration" do
      config = [
        port: 8126,
        protocol: :v05
      ]

      assert {:error, :missing_required_config, _} = Config.setup(config)
    end

    test "validates port range" do
      config = [
        host: "localhost",
        port: 99999,
        protocol: :v05
      ]

      assert {:error, :invalid_config, _} = Config.setup(config)
    end
  end

  describe "setup!/1" do
    test "raises on configuration error" do
      config = [
        port: 8126,
        protocol: :v05
      ]

      assert_raise OpentelemetryDatadog.ConfigError, fn ->
        Config.setup!(config)
      end
    end

    test "succeeds with valid configuration" do
      config = [
        host: "localhost",
        port: 8126,
        protocol: :v05
      ]

      assert Config.setup!(config) == :ok
    end
  end

  describe "setup/0 with environment variables" do
    test "loads configuration from environment variables" do
      put_env(%{
        "DD_AGENT_HOST" => "test-host",
        "DD_TRACE_AGENT_PORT" => "9999"
      })

      assert Config.setup() == :ok
    end

    test "returns error when required env vars are missing" do
      assert {:error, :missing_required_config, _} = Config.setup()
    end
  end

  describe "get_config/0" do
    test "returns configuration with v05 protocol" do
      put_env(%{"DD_AGENT_HOST" => "test-host"})

      assert {:ok, config} = Config.get_config()
      assert config[:protocol] == :v05
      assert config[:host] == "test-host"
    end

    test "returns error when configuration is invalid" do
      assert {:error, :missing_required_config, _} = Config.get_config()
    end
  end

  describe "get_config!/0" do
    test "returns configuration with v05 protocol" do
      put_env(%{"DD_AGENT_HOST" => "test-host"})

      config = Config.get_config!()
      assert config[:protocol] == :v05
      assert config[:host] == "test-host"
    end

    test "raises when configuration is invalid" do
      assert_raise OpentelemetryDatadog.ConfigError, fn ->
        Config.get_config!()
      end
    end
  end
end
