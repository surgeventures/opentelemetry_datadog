defmodule OpentelemetryDatadog.TestHelpersTest do
  use ExUnit.Case, async: false

  import OpentelemetryDatadog.TestHelpers

  @moduletag :test_helpers

  setup do
    original_env = get_env_state()

    on_exit(fn ->
      restore_env_state(original_env)
    end)

    :ok
  end

  describe "reset_env/0" do
    test "removes all DD_* environment variables" do
      put_env(%{
        "DD_AGENT_HOST" => "localhost",
        "DD_SERVICE" => "test-service",
        "DD_TRACE_SAMPLE_RATE" => "0.5"
      })

      assert System.get_env("DD_AGENT_HOST") == "localhost"
      assert System.get_env("DD_SERVICE") == "test-service"
      assert System.get_env("DD_TRACE_SAMPLE_RATE") == "0.5"

      reset_env()

      assert System.get_env("DD_AGENT_HOST") == nil
      assert System.get_env("DD_SERVICE") == nil
      assert System.get_env("DD_TRACE_SAMPLE_RATE") == nil
    end
  end

  describe "put_env/1" do
    test "sets multiple environment variables from map" do
      vars = %{
        "DD_AGENT_HOST" => "example.com",
        "DD_SERVICE" => "my-service",
        "DD_VERSION" => "1.0.0"
      }

      put_env(vars)

      assert System.get_env("DD_AGENT_HOST") == "example.com"
      assert System.get_env("DD_SERVICE") == "my-service"
      assert System.get_env("DD_VERSION") == "1.0.0"
    end
  end

  describe "configuration presets" do
    test "minimal_config/0 sets only DD_AGENT_HOST" do
      reset_env()
      minimal_config()

      assert System.get_env("DD_AGENT_HOST") == "localhost"
      assert System.get_env("DD_SERVICE") == nil
      assert System.get_env("DD_ENV") == nil
    end

    test "minimal_config/1 sets custom host" do
      minimal_config("custom-host")

      assert System.get_env("DD_AGENT_HOST") == "custom-host"
    end

    test "dev_config/0 sets development environment" do
      dev_config()

      assert System.get_env("DD_AGENT_HOST") == "localhost"
      assert System.get_env("DD_SERVICE") == "test-app"
      assert System.get_env("DD_ENV") == "development"
    end

    test "prod_config/0 sets production environment" do
      prod_config()

      assert System.get_env("DD_AGENT_HOST") == "datadog-agent.kube-system.svc.cluster.local"
      assert System.get_env("DD_SERVICE") == "api-service"
      assert System.get_env("DD_ENV") == "production"
      assert System.get_env("DD_TRACE_SAMPLE_RATE") == "0.1"
    end

    test "phoenix_config/0 sets Phoenix app configuration" do
      phoenix_config()

      assert System.get_env("DD_AGENT_HOST") == "localhost"
      assert System.get_env("DD_SERVICE") == "phoenix-app"
      assert System.get_env("DD_ENV") == "development"
      assert System.get_env("DD_TAGS") == "framework:phoenix,language:elixir"
    end
  end

  describe "error scenario helpers" do
    test "invalid_port_config/0 sets invalid port" do
      invalid_port_config()

      assert System.get_env("DD_AGENT_HOST") == "localhost"
      assert System.get_env("DD_TRACE_AGENT_PORT") == "invalid"
    end

    test "invalid_sample_rate_config/0 sets invalid sample rate" do
      invalid_sample_rate_config()

      assert System.get_env("DD_AGENT_HOST") == "localhost"
      assert System.get_env("DD_TRACE_SAMPLE_RATE") == "1.5"
    end

    test "port_out_of_range_config/0 sets port out of range" do
      port_out_of_range_config()

      assert System.get_env("DD_AGENT_HOST") == "localhost"
      assert System.get_env("DD_TRACE_AGENT_PORT") == "99999"
    end

    test "malformed_tags_config/0 sets malformed tags" do
      malformed_tags_config()

      assert System.get_env("DD_AGENT_HOST") == "localhost"
      assert System.get_env("DD_TAGS") == "key1:value1,key2:value2:extra"
    end
  end

  describe "new configuration presets" do
    test "staging_config/0 sets staging environment" do
      staging_config()

      assert System.get_env("DD_AGENT_HOST") == "datadog-agent.staging.svc.cluster.local"
      assert System.get_env("DD_SERVICE") == "staging-app"
      assert System.get_env("DD_ENV") == "staging"
      assert System.get_env("DD_TRACE_SAMPLE_RATE") == "0.5"
    end

    test "ci_config/0 sets CI environment" do
      ci_config()

      assert System.get_env("DD_AGENT_HOST") == "localhost"
      assert System.get_env("DD_SERVICE") == "ci-test"
      assert System.get_env("DD_ENV") == "test"
      assert System.get_env("DD_TRACE_SAMPLE_RATE") == "1.0"
    end

    test "microservice_config/2 sets microservice environment" do
      microservice_config("user-service", "auth")

      assert System.get_env("DD_AGENT_HOST") == "datadog-agent.istio-system.svc.cluster.local"
      assert System.get_env("DD_SERVICE") == "user-service"
      assert System.get_env("DD_ENV") == "production"
      assert System.get_env("DD_TAGS") == "component:auth,architecture:microservice,mesh:istio"
    end
  end

  describe "utility functions" do
    test "has_minimal_config?/0 checks for required config" do
      reset_env()
      assert has_minimal_config?() == false

      minimal_config()
      assert has_minimal_config?() == true
    end

    test "current_dd_vars/0 returns currently set variables" do
      reset_env()
      assert current_dd_vars() == []

      put_env(%{"DD_AGENT_HOST" => "localhost", "DD_SERVICE" => "test"})
      current_vars = current_dd_vars()

      assert "DD_AGENT_HOST" in current_vars
      assert "DD_SERVICE" in current_vars
      assert length(current_vars) == 2
    end
  end

  describe "env_vars/0" do
    test "returns list of all DD_* environment variables" do
      vars = env_vars()

      assert is_list(vars)
      assert "DD_AGENT_HOST" in vars
      assert "DD_TRACE_AGENT_PORT" in vars
      assert "DD_SERVICE" in vars
      assert "DD_VERSION" in vars
      assert "DD_ENV" in vars
      assert "DD_TAGS" in vars
      assert "DD_TRACE_SAMPLE_RATE" in vars
    end
  end

  describe "environment state management" do
    test "get_env_state/0 and restore_env_state/1" do
      put_env(%{"DD_AGENT_HOST" => "initial-host", "DD_SERVICE" => "initial-service"})

      state = get_env_state()
      assert state["DD_AGENT_HOST"] == "initial-host"
      assert state["DD_SERVICE"] == "initial-service"

      put_env(%{"DD_AGENT_HOST" => "changed-host", "DD_SERVICE" => "changed-service"})
      assert System.get_env("DD_AGENT_HOST") == "changed-host"

      restore_env_state(state)
      assert System.get_env("DD_AGENT_HOST") == "initial-host"
      assert System.get_env("DD_SERVICE") == "initial-service"
    end

    test "put_dd_env/2 validates DD_* variables" do
      assert put_dd_env("DD_AGENT_HOST", "localhost") == :ok
      assert System.get_env("DD_AGENT_HOST") == "localhost"

      assert put_dd_env("SOME_OTHER_VAR", "value") == {:error, :unknown_variable}
    end

    test "get_dd_env/2 gets DD_* variables with default" do
      reset_env()
      put_env(%{"DD_AGENT_HOST" => "test-host"})

      assert get_dd_env("DD_AGENT_HOST") == "test-host"
      assert get_dd_env("DD_SERVICE", "default-service") == "default-service"
    end

    test "get_env_state/0 captures nil values correctly" do
      reset_env()
      state = get_env_state()

      Enum.each(env_vars(), fn var ->
        assert Map.has_key?(state, var)
        assert is_nil(state[var])
      end)
    end

    test "restore_env_state/1 handles nil values" do
      put_env(%{"DD_AGENT_HOST" => "test-host", "DD_SERVICE" => "test-service"})

      nil_state = Enum.into(env_vars(), %{}, fn var -> {var, nil} end)

      restore_env_state(nil_state)

      Enum.each(env_vars(), fn var ->
        assert System.get_env(var) == nil
      end)
    end
  end

  describe "error scenario utilities" do
    test "all_error_scenarios/0 returns list of available scenarios" do
      scenarios = all_error_scenarios()

      assert is_list(scenarios)
      assert :invalid_port_config in scenarios
      assert :malformed_tags_config in scenarios
      assert :missing_required_host_config in scenarios
    end

    test "apply_scenario/1 applies error scenarios by name" do
      assert apply_scenario(:invalid_port_config) == :ok
      assert System.get_env("DD_TRACE_AGENT_PORT") == "invalid"

      reset_env()
      assert apply_scenario(:missing_required_host_config) == :ok
      assert System.get_env("DD_AGENT_HOST") == nil
      assert System.get_env("DD_SERVICE") == "test-service"

      assert apply_scenario(:unknown_scenario) == {:error, :unknown_scenario}
    end
  end

  describe "test fixtures integration" do
    test "TestFixtures is available via alias" do
      configs = OpentelemetryDatadog.TestFixtures.valid_configs()
      assert is_list(configs)
      assert length(configs) > 0

      invalid_configs = OpentelemetryDatadog.TestFixtures.invalid_configs()
      assert is_list(invalid_configs)
      assert length(invalid_configs) > 0
    end
  end
end
