defmodule OpentelemetryDatadog.ConfigTest do
  use ExUnit.Case, async: false

  import OpentelemetryDatadog.TestHelpers

  alias OpentelemetryDatadog.{Config, ConfigError}

  @moduletag :unit

  doctest OpentelemetryDatadog.Config

  setup do
    reset_env()
    :ok
  end

  describe "load/0" do
    test "returns error when DD_AGENT_HOST is not set" do
      assert {:error, :missing_required_config, "DD_AGENT_HOST is required"} = Config.load()
    end

    test "returns error when DD_AGENT_HOST is empty" do
      put_env(%{"DD_AGENT_HOST" => ""})
      assert {:error, :missing_required_config, "DD_AGENT_HOST cannot be empty"} = Config.load()
    end

    test "loads minimal configuration with only required host" do
      minimal_config()

      assert {:ok, config} = Config.load()
      assert config.host == "localhost"
      assert config.port == 8126
      assert is_nil(config.service)
      assert is_nil(config.version)
      assert is_nil(config.env)
      assert is_nil(config.tags)
      assert is_nil(config.sample_rate)
      assert config.timeout_ms == 2000
      assert config.connect_timeout_ms == 500
    end

    test "loads custom port" do
      put_env(%{"DD_AGENT_HOST" => "localhost", "DD_TRACE_AGENT_PORT" => "9126"})

      assert {:ok, config} = Config.load()
      assert config.port == 9126
    end

    test "returns error for invalid port" do
      invalid_port_config()

      assert {:error, :invalid_config, message} = Config.load()
      assert message =~ "DD_TRACE_AGENT_PORT must be a valid integer"
    end

    test "returns error for port out of range" do
      port_out_of_range_config()

      assert {:error, :invalid_config, message} = Config.load()
      assert message =~ "DD_TRACE_AGENT_PORT must be a valid port number"
    end

    test "loads service metadata" do
      put_env(%{
        "DD_AGENT_HOST" => "localhost",
        "DD_SERVICE" => "my-service",
        "DD_VERSION" => "1.2.3",
        "DD_ENV" => "production"
      })

      assert {:ok, config} = Config.load()
      assert config.service == "my-service"
      assert config.version == "1.2.3"
      assert config.env == "production"
    end

    test "ignores empty service metadata" do
      put_env(%{
        "DD_AGENT_HOST" => "localhost",
        "DD_SERVICE" => "",
        "DD_VERSION" => "",
        "DD_ENV" => ""
      })

      assert {:ok, config} = Config.load()
      assert is_nil(config.service)
      assert is_nil(config.version)
      assert is_nil(config.env)
    end

    test "loads valid sample rate" do
      put_env(%{"DD_AGENT_HOST" => "localhost", "DD_TRACE_SAMPLE_RATE" => "0.5"})

      assert {:ok, config} = Config.load()
      assert config.sample_rate == 0.5
    end

    test "returns error for invalid sample rate" do
      invalid_sample_rate_config()

      assert {:error, :invalid_config, message} = Config.load()
      assert message =~ "DD_TRACE_SAMPLE_RATE must be a float between 0.0 and 1.0"
    end

    test "loads custom timeout" do
      put_env(%{"DD_AGENT_HOST" => "localhost", "DD_EXPORT_TIMEOUT_MS" => "5000"})

      assert {:ok, config} = Config.load()
      assert config.timeout_ms == 5000
    end

    test "returns error for invalid timeout" do
      put_env(%{"DD_AGENT_HOST" => "localhost", "DD_EXPORT_TIMEOUT_MS" => "invalid"})

      assert {:error, :invalid_config, message} = Config.load()
      assert message =~ "DD_EXPORT_TIMEOUT_MS must be a valid integer"
    end

    test "returns error for negative timeout" do
      put_env(%{"DD_AGENT_HOST" => "localhost", "DD_EXPORT_TIMEOUT_MS" => "-1000"})

      assert {:error, :invalid_config, message} = Config.load()
      assert message =~ "DD_EXPORT_TIMEOUT_MS must be a positive integer"
    end

    test "returns error for zero timeout" do
      put_env(%{"DD_AGENT_HOST" => "localhost", "DD_EXPORT_TIMEOUT_MS" => "0"})

      assert {:error, :invalid_config, message} = Config.load()
      assert message =~ "DD_EXPORT_TIMEOUT_MS must be a positive integer"
    end

    test "loads custom connect timeout" do
      put_env(%{"DD_AGENT_HOST" => "localhost", "DD_EXPORT_CONNECT_TIMEOUT_MS" => "1000"})

      assert {:ok, config} = Config.load()
      assert config.connect_timeout_ms == 1000
    end

    test "returns error for invalid connect timeout" do
      invalid_connect_timeout_config()

      assert {:error, :invalid_config, message} = Config.load()
      assert message =~ "DD_EXPORT_CONNECT_TIMEOUT_MS must be a valid integer"
    end

    test "returns error for negative connect timeout" do
      negative_connect_timeout_config()

      assert {:error, :invalid_config, message} = Config.load()
      assert message =~ "DD_EXPORT_CONNECT_TIMEOUT_MS must be a positive integer"
    end

    test "returns error for zero connect timeout" do
      zero_connect_timeout_config()

      assert {:error, :invalid_config, message} = Config.load()
      assert message =~ "DD_EXPORT_CONNECT_TIMEOUT_MS must be a positive integer"
    end

    @tag_test_cases [
      {"env:prod,version:1.0,team:backend",
       %{"env" => "prod", "version" => "1.0", "team" => "backend"}},
      {" env:prod , version:1.0 , team:backend ",
       %{"env" => "prod", "version" => "1.0", "team" => "backend"}},
      {"debug,env:prod", %{"debug" => "true", "env" => "prod"}},
      {"key:value", %{"key" => "value"}},
      {"flag", %{"flag" => "true"}},
      {"", %{}}
    ]

    for {tags_str, expected_tags} <- @tag_test_cases do
      test "parses tags: #{inspect(tags_str)} -> #{inspect(expected_tags)}" do
        put_env(%{
          "DD_AGENT_HOST" => "localhost",
          "DD_TAGS" => unquote(tags_str)
        })

        assert {:ok, config} = Config.load()
        expected_tags = unquote(Macro.escape(expected_tags))

        if expected_tags == %{} do
          assert is_nil(config.tags) or config.tags == %{}
        else
          assert config.tags == expected_tags
        end
      end
    end

    @invalid_tag_cases [
      "env:prod:extra",
      "key1:value1,key2:value2:extra"
    ]

    for invalid_tags <- @invalid_tag_cases do
      test "returns error for malformed tags: #{inspect(invalid_tags)}" do
        put_env(%{
          "DD_AGENT_HOST" => "localhost",
          "DD_TAGS" => unquote(invalid_tags)
        })

        assert {:error, :invalid_config, message} = Config.load()
        assert message =~ "Must be comma-separated key:value pairs"
      end
    end
  end

  describe "load!/0" do
    test "returns config when valid" do
      put_env(%{"DD_AGENT_HOST" => "localhost"})

      config = Config.load!()
      assert config.host == "localhost"
      assert config.port == 8126
    end

    test "raises exception when invalid" do
      assert_raise OpentelemetryDatadog.ConfigError,
                   ~r/Configuration error.*DD_AGENT_HOST is required/,
                   fn ->
                     Config.load!()
                   end
    end
  end

  describe "validate/1" do
    test "validates successful config" do
      config = %{host: "localhost", port: 8126}
      assert :ok = Config.validate(config)
    end

    @validation_error_cases [
      {%{port: 8126}, :missing_required_config, "host is required"},
      {%{host: "localhost"}, :missing_required_config, "port is required"},
      {%{host: "localhost", port: 0}, :invalid_config, "port must be a valid port number"},
      {%{host: "localhost", port: -1}, :invalid_config, "port must be a valid port number"},
      {%{host: "localhost", port: 65536}, :invalid_config, "port must be a valid port number"},
      {%{host: "localhost", port: 8126, sample_rate: -0.1}, :invalid_config,
       "sample_rate must be a float between 0.0 and 1.0"},
      {%{host: "localhost", port: 8126, sample_rate: 1.1}, :invalid_config,
       "sample_rate must be a float between 0.0 and 1.0"},
      {%{host: "localhost", port: 8126, timeout_ms: 0}, :invalid_config,
       "timeout_ms must be a positive integer"},
      {%{host: "localhost", port: 8126, timeout_ms: -1000}, :invalid_config,
       "timeout_ms must be a positive integer"},
      {%{host: "localhost", port: 8126, connect_timeout_ms: 0}, :invalid_config,
       "connect_timeout_ms must be a positive integer"},
      {%{host: "localhost", port: 8126, connect_timeout_ms: -500}, :invalid_config,
       "connect_timeout_ms must be a positive integer"}
    ]

    for {config, expected_type, expected_message_part} <- @validation_error_cases do
      test "returns error for #{inspect(config)}" do
        config = unquote(Macro.escape(config))
        expected_type = unquote(expected_type)
        expected_message_part = unquote(expected_message_part)

        assert {:error, ^expected_type, message} = Config.validate(config)
        assert message =~ expected_message_part
      end
    end

    test "validates struct configuration" do
      config = %Config{
        host: "localhost",
        port: 8126,
        service: nil,
        version: nil,
        env: nil,
        tags: nil,
        sample_rate: nil,
        timeout_ms: 2000,
        connect_timeout_ms: 500
      }

      assert :ok = Config.validate(config)
    end
  end

  describe "to_exporter_config/1" do
    test "converts map to keyword list" do
      config = %{
        host: "localhost",
        port: 8126,
        service: "my-service",
        version: nil,
        env: "production"
      }

      result = Config.to_exporter_config(config)

      assert is_list(result)
      assert result[:host] == "localhost"
      assert result[:port] == 8126
      assert result[:service] == "my-service"
      assert result[:env] == "production"
      refute Keyword.has_key?(result, :version)
    end

    test "converts struct to keyword list" do
      config = %Config{
        host: "localhost",
        port: 8126,
        service: "my-service",
        version: "1.0.0",
        env: nil,
        tags: %{"team" => "backend"},
        sample_rate: 0.5,
        timeout_ms: 3000,
        connect_timeout_ms: 1000
      }

      result = Config.to_exporter_config(config)

      assert is_list(result)
      assert result[:host] == "localhost"
      assert result[:port] == 8126
      assert result[:service] == "my-service"
      assert result[:version] == "1.0.0"
      assert result[:tags] == %{"team" => "backend"}
      assert result[:sample_rate] == 0.5
      assert result[:timeout_ms] == 3000
      assert result[:connect_timeout_ms] == 1000
      refute Keyword.has_key?(result, :env)
    end

    test "filters out nil values" do
      config = %{
        host: "localhost",
        port: 8126,
        service: nil,
        version: nil,
        env: nil
      }

      result = Config.to_exporter_config(config)

      assert length(result) == 2
      assert result[:host] == "localhost"
      assert result[:port] == 8126
      refute Keyword.has_key?(result, :service)
      refute Keyword.has_key?(result, :version)
      refute Keyword.has_key?(result, :env)
    end
  end

  describe "struct behavior" do
    test "load/0 returns struct" do
      put_env(%{"DD_AGENT_HOST" => "localhost"})

      assert {:ok, %Config{} = config} = Config.load()
      assert config.host == "localhost"
      assert config.port == 8126
      assert config.timeout_ms == 2000
      assert config.connect_timeout_ms == 500
    end

    test "struct pattern matching works" do
      put_env(%{
        "DD_AGENT_HOST" => "localhost",
        "DD_SERVICE" => "test-service"
      })

      {:ok, config} = Config.load()

      case config do
        %Config{host: "localhost", service: service} when not is_nil(service) ->
          assert service == "test-service"

        _ ->
          flunk("Pattern matching failed")
      end
    end

    test "struct enforces required keys at compile time" do
      config = %Config{
        host: "test-host",
        port: 8126,
        service: nil,
        version: nil,
        env: nil,
        tags: nil,
        sample_rate: nil,
        timeout_ms: 1500,
        connect_timeout_ms: 750
      }

      assert config.host == "test-host"
      assert config.port == 8126
      assert config.timeout_ms == 1500
      assert config.connect_timeout_ms == 750
      assert config.__struct__ == Config
    end
  end

  describe "custom exception handling" do
    test "load!/0 raises ConfigError" do
      try do
        Config.load!()
        flunk("Expected ConfigError to be raised")
      rescue
        error in ConfigError ->
          assert error.type == :missing_required_config
          assert error.message == "DD_AGENT_HOST is required"

          formatted_message = Exception.message(error)

          assert formatted_message =~
                   "Configuration error (missing_required_config): DD_AGENT_HOST is required"
      end
    end

    test "ConfigError has proper structure" do
      try do
        Config.load!()
        flunk("Expected ConfigError to be raised")
      rescue
        error in ConfigError ->
          assert error.type == :missing_required_config
          assert error.message == "DD_AGENT_HOST is required"

        other ->
          flunk("Unexpected exception: #{inspect(other)}")
      end
    end
  end

  describe "get_config/0" do
    test "returns configuration" do
      put_env(%{"DD_AGENT_HOST" => "test-host"})

      assert {:ok, config} = Config.get_config()
      assert config[:host] == "test-host"
    end

    test "returns error when configuration is invalid" do
      assert {:error, :missing_required_config, _} = Config.get_config()
    end
  end

  describe "get_config!/0" do
    test "returns configuration" do
      put_env(%{"DD_AGENT_HOST" => "test-host"})

      config = Config.get_config!()
      assert config[:host] == "test-host"
    end

    test "raises when configuration is invalid" do
      assert_raise OpentelemetryDatadog.ConfigError, fn ->
        Config.get_config!()
      end
    end
  end
end
