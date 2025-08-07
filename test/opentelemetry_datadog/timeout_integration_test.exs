defmodule OpentelemetryDatadog.TimeoutIntegrationTest do
  use ExUnit.Case, async: false

  import OpentelemetryDatadog.TestHelpers

  alias OpentelemetryDatadog.{Config, Exporter}

  @moduletag :integration

  setup do
    reset_env()
    :ok
  end

  describe "timeout configuration integration" do
    test "exporter uses default timeout when not configured" do
      put_env(%{"DD_AGENT_HOST" => "localhost"})

      {:ok, config} = Config.load()
      assert config.timeout_ms == 2000

      exporter_config = Config.to_exporter_config(config)
      assert exporter_config[:timeout_ms] == 2000

      {:ok, state} = Exporter.init(exporter_config)
      assert state.timeout_ms == 2000
    end

    test "exporter uses custom timeout when configured" do
      put_env(%{
        "DD_AGENT_HOST" => "localhost",
        "DD_EXPORT_TIMEOUT_MS" => "5000"
      })

      {:ok, config} = Config.load()
      assert config.timeout_ms == 5000

      exporter_config = Config.to_exporter_config(config)
      assert exporter_config[:timeout_ms] == 5000

      {:ok, state} = Exporter.init(exporter_config)
      assert state.timeout_ms == 5000
    end

    test "timeout is passed to HTTP request" do
      put_env(%{
        "DD_AGENT_HOST" => "localhost",
        "DD_EXPORT_TIMEOUT_MS" => "1500"
      })

      {:ok, config} = Config.load()
      exporter_config = Config.to_exporter_config(config)
      {:ok, state} = Exporter.init(exporter_config)

      assert state.timeout_ms == 1500
      assert state.host == "localhost"
      assert state.port == 8126
    end

    test "timeout validation prevents invalid values" do
      test_cases = [
        {"0", "DD_EXPORT_TIMEOUT_MS must be a positive integer"},
        {"-1000", "DD_EXPORT_TIMEOUT_MS must be a positive integer"},
        {"invalid", "DD_EXPORT_TIMEOUT_MS must be a positive integer"},
        {"1.5", "DD_EXPORT_TIMEOUT_MS must be a positive integer"}
      ]

      for {timeout_value, expected_error} <- test_cases do
        put_env(%{
          "DD_AGENT_HOST" => "localhost",
          "DD_EXPORT_TIMEOUT_MS" => timeout_value
        })

        assert {:error, :invalid_config, message} = Config.load()
        assert message =~ expected_error
        reset_env()
      end
    end

    test "timeout configuration is included in exporter config conversion" do
      put_env(%{
        "DD_AGENT_HOST" => "localhost",
        "DD_EXPORT_TIMEOUT_MS" => "3500"
      })

      {:ok, config} = Config.load()
      exporter_config = Config.to_exporter_config(config)

      assert Keyword.has_key?(exporter_config, :timeout_ms)
      assert exporter_config[:timeout_ms] == 3500
      assert exporter_config[:host] == "localhost"
      assert exporter_config[:port] == 8126
    end

    test "timeout errors are logged with timeout value" do
      put_env(%{
        "DD_AGENT_HOST" => "localhost",
        "DD_EXPORT_TIMEOUT_MS" => "1000"
      })

      {:ok, config} = Config.load()
      exporter_config = Config.to_exporter_config(config)
      {:ok, state} = Exporter.init(exporter_config)

      assert state.timeout_ms == 1000
      assert state.host == "localhost"
      assert state.port == 8126
    end
  end
end
