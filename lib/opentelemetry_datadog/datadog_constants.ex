defmodule OpentelemetryDatadog.DatadogConstants do
  @moduledoc """
  Centralized constants for Datadog environment variables and configuration.
  """

  @env_vars [
    "DD_AGENT_HOST",
    "DD_TRACE_AGENT_PORT",
    "DD_SERVICE",
    "DD_VERSION",
    "DD_ENV",
    "DD_TAGS",
    "DD_TRACE_SAMPLE_RATE",
    "DD_EXPORT_TIMEOUT_MS"
  ]

  @doc "Returns list of all supported Datadog environment variables."
  @spec env_vars() :: [String.t()]
  def env_vars, do: @env_vars

  @doc "Default values for configuration parameters."
  @defaults %{
    port: 8126,
    sample_rate: nil,
    service: nil,
    version: nil,
    env: nil,
    tags: nil,
    timeout_ms: 2000
  }

  def defaults, do: @defaults

  @doc "Get default value for a specific configuration key."
  def default(key)
      when key in [:port, :sample_rate, :service, :version, :env, :tags, :timeout_ms] do
    Map.get(@defaults, key)
  end

  @sampling_mechanism_used %{
    DEFAULT: 0,
    AGENT: 1,
    RULE: 3,
    MANUAL: 4
  }

  @sampling_priority %{
    USER_REJECT: -1,
    AUTO_REJECT: 0,
    AUTO_KEEP: 1,
    USER_KEEP: 2
  }

  def sampling_mechanism_used do
    @sampling_mechanism_used
  end

  def sampling_mechanism_used(:DEFAULT), do: 0
  def sampling_mechanism_used(:AGENT), do: 1
  def sampling_mechanism_used(:RULE), do: 3
  def sampling_mechanism_used(:MANUAL), do: 4

  def sampling_priority do
    @sampling_priority
  end

  def sampling_priority(:USER_REJECT), do: -1
  def sampling_priority(:AUTO_REJECT), do: 0
  def sampling_priority(:AUTO_KEEP), do: 1
  def sampling_priority(:USER_KEEP), do: 2
end
