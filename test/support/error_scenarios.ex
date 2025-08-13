defmodule OpentelemetryDatadog.ErrorScenarios do
  @moduledoc """
  Error testing utilities for Datadog configuration validation.
  """

  alias OpentelemetryDatadog.EnvHelpers

  @doc "Sets up configuration with invalid port number."
  @spec invalid_port_config() :: :ok
  def invalid_port_config do
    EnvHelpers.put_env(%{
      "DD_AGENT_HOST" => "localhost",
      "DD_TRACE_AGENT_PORT" => "invalid"
    })
  end

  @doc "Sets up configuration with invalid sample rate."
  @spec invalid_sample_rate_config() :: :ok
  def invalid_sample_rate_config do
    EnvHelpers.put_env(%{
      "DD_AGENT_HOST" => "localhost",
      "DD_TRACE_SAMPLE_RATE" => "1.5"
    })
  end

  @doc "Sets up configuration with port number out of valid range."
  @spec port_out_of_range_config() :: :ok
  def port_out_of_range_config do
    EnvHelpers.put_env(%{
      "DD_AGENT_HOST" => "localhost",
      "DD_TRACE_AGENT_PORT" => "99999"
    })
  end

  @doc """
  Sets up configuration with malformed tags.

  Tags should be in key:value,key:value format. This creates malformed tags.

  ## Examples

      iex> malformed_tags_config()
      :ok
      iex> System.get_env("DD_TAGS") 
      "key1:value1,key2:value2:extra"
  """
  @spec malformed_tags_config() :: :ok
  def malformed_tags_config do
    EnvHelpers.put_env(%{
      "DD_AGENT_HOST" => "localhost",
      "DD_TAGS" => "key1:value1,key2:value2:extra"
    })
  end

  @doc """
  Sets up minimal config missing required DD_AGENT_HOST.

  This should trigger the missing required configuration error.
  """
  @spec missing_required_host_config() :: :ok
  def missing_required_host_config do
    EnvHelpers.put_env(%{
      "DD_SERVICE" => "test-service",
      "DD_ENV" => "test"
    })
  end

  @doc "Sets up configuration with invalid connect timeout."
  @spec invalid_connect_timeout_config() :: :ok
  def invalid_connect_timeout_config do
    EnvHelpers.put_env(%{
      "DD_AGENT_HOST" => "localhost",
      "DD_EXPORT_CONNECT_TIMEOUT_MS" => "invalid"
    })
  end

  @doc "Sets up configuration with negative connect timeout."
  @spec negative_connect_timeout_config() :: :ok
  def negative_connect_timeout_config do
    EnvHelpers.put_env(%{
      "DD_AGENT_HOST" => "localhost",
      "DD_EXPORT_CONNECT_TIMEOUT_MS" => "-500"
    })
  end

  @doc "Sets up configuration with zero connect timeout."
  @spec zero_connect_timeout_config() :: :ok
  def zero_connect_timeout_config do
    EnvHelpers.put_env(%{
      "DD_AGENT_HOST" => "localhost",
      "DD_EXPORT_CONNECT_TIMEOUT_MS" => "0"
    })
  end

  @doc """
  Generates a list of all available error scenario functions.

  Useful for parameterized tests that want to test all error conditions.
  """
  @spec all_error_scenarios() :: [atom()]
  def all_error_scenarios do
    [
      :invalid_port_config,
      :invalid_sample_rate_config,
      :port_out_of_range_config,
      :malformed_tags_config,
      :missing_required_host_config,
      :invalid_connect_timeout_config,
      :negative_connect_timeout_config,
      :zero_connect_timeout_config
    ]
  end

  @doc """
  Applies an error scenario by function name.

  ## Examples

      iex> apply_scenario(:invalid_port_config)
      :ok
      iex> System.get_env("DD_TRACE_AGENT_PORT")
      "invalid"
  """
  @spec apply_scenario(atom()) :: :ok | {:error, :unknown_scenario}
  def apply_scenario(scenario_name) when is_atom(scenario_name) do
    if scenario_name in all_error_scenarios() do
      apply(__MODULE__, scenario_name, [])
    else
      {:error, :unknown_scenario}
    end
  end
end
