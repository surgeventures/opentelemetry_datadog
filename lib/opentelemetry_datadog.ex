defmodule OpentelemetryDatadog do
  @moduledoc """
  OpenTelemetry Datadog Integration.
  """

  alias OpentelemetryDatadog.Config

  @doc """
  Returns the current configuration loaded from environment variables.

  ## Examples

      iex> System.put_env("DD_AGENT_HOST", "localhost")
      iex> System.put_env("DD_SERVICE", "my-service")
      iex> {:ok, config} = OpentelemetryDatadog.get_config()
      iex> config.host
      "localhost"
      iex> config.service
      "my-service"
  """
  @spec get_config() :: {:ok, Config.t()} | {:error, Config.validation_error()}
  def get_config do
    Config.load()
  end

  @doc """
  Returns the current configuration, raising an exception on failure.

  ## Examples

      iex> System.put_env("DD_AGENT_HOST", "localhost")
      iex> System.put_env("DD_SERVICE", "my-service")  
      iex> config = OpentelemetryDatadog.get_config!()
      iex> config.host
      "localhost"
      iex> config.service
      "my-service"
  """
  @spec get_config!() :: Config.t()
  def get_config! do
    Config.load!()
  end
end
