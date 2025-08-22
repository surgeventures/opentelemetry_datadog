defmodule OpentelemetryDatadog.TestHelpers do
  @moduledoc """
  Test utilities for OpenTelemetry Datadog.

  - `EnvHelpers` - Environment variable management
  - `ConfigPresets` - Pre-configured scenarios  
  - `ErrorScenarios` - Error testing utilities
  - `TestFixtures` - Test data and mocks
  """

  @doc """
  Automatically imports all test helper functions and sets up environment reset.

  When you `use OpentelemetryDatadog.TestHelpers`, it:
  - Imports all helper functions
  - Adds a setup block that resets Datadog environment variables before each test

  ## Example

      defmodule MyTest do
        use ExUnit.Case
        use OpentelemetryDatadog.TestHelpers
        
        test "automatically cleaned environment" do
          dev_config("my-service")
          assert has_minimal_config?()
          # Environment will be reset before next test
        end
      end
  """
  defmacro __using__(_opts) do
    quote do
      import OpentelemetryDatadog.TestHelpers

      setup do
        OpentelemetryDatadog.TestHelpers.reset_env()
        :ok
      end
    end
  end

  defdelegate env_vars(), to: OpentelemetryDatadog.EnvHelpers
  defdelegate reset_env(), to: OpentelemetryDatadog.EnvHelpers
  defdelegate put_env(vars), to: System
  defdelegate get_env_state(), to: OpentelemetryDatadog.EnvHelpers
  defdelegate restore_env_state(state), to: OpentelemetryDatadog.EnvHelpers
  defdelegate put_dd_env(var, value), to: OpentelemetryDatadog.EnvHelpers
  defdelegate get_dd_env(var, default \\ nil), to: OpentelemetryDatadog.EnvHelpers
  defdelegate has_minimal_config?(), to: OpentelemetryDatadog.EnvHelpers
  defdelegate current_dd_vars(), to: OpentelemetryDatadog.EnvHelpers

  defdelegate minimal_config(host \\ "localhost"), to: OpentelemetryDatadog.ConfigPresets
  defdelegate dev_config(service \\ "test-app"), to: OpentelemetryDatadog.ConfigPresets

  defdelegate prod_config(service \\ "api-service", version \\ "1.0.0"),
    to: OpentelemetryDatadog.ConfigPresets

  defdelegate phoenix_config(service \\ "phoenix-app"), to: OpentelemetryDatadog.ConfigPresets

  defdelegate containerized_config(
                service \\ "api-service",
                version \\ "1.0.0",
                env \\ "production"
              ),
              to: OpentelemetryDatadog.ConfigPresets

  defdelegate microservice_config(service, component), to: OpentelemetryDatadog.ConfigPresets

  defdelegate staging_config(service \\ "staging-app", version \\ "latest"),
    to: OpentelemetryDatadog.ConfigPresets

  defdelegate ci_config(service \\ "ci-test"), to: OpentelemetryDatadog.ConfigPresets

  defdelegate invalid_port_config(), to: OpentelemetryDatadog.ErrorScenarios
  defdelegate invalid_sample_rate_config(), to: OpentelemetryDatadog.ErrorScenarios
  defdelegate port_out_of_range_config(), to: OpentelemetryDatadog.ErrorScenarios
  defdelegate malformed_tags_config(), to: OpentelemetryDatadog.ErrorScenarios
  defdelegate missing_required_host_config(), to: OpentelemetryDatadog.ErrorScenarios
  defdelegate all_error_scenarios(), to: OpentelemetryDatadog.ErrorScenarios
  defdelegate apply_scenario(scenario_name), to: OpentelemetryDatadog.ErrorScenarios
end
