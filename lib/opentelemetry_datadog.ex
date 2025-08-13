defmodule OpentelemetryDatadog do
  @moduledoc """
  OpenTelemetry Datadog Integration.
  """

  alias OpentelemetryDatadog.{Config, ConfigError}

  @doc """
  Validates Datadog exporter configuration from environment variables.

  This validates that all required environment variables are set correctly.
  The actual exporter registration should be done via application config.

  ## Examples

      # With environment variables set
      iex> System.put_env("DD_AGENT_HOST", "localhost") 
      iex> OpentelemetryDatadog.setup()
      :ok
  """
  @spec setup() :: :ok | {:error, Config.validation_error()}
  def setup, do: Config.setup()

  @doc """
  Validates the provided Datadog exporter configuration.

  ## Examples

      iex> config = [host: "localhost", port: 8126]
      iex> OpentelemetryDatadog.setup(config)
      :ok
  """
  @spec setup(keyword()) :: :ok | {:error, Config.validation_error()}
  def setup(config) when is_list(config), do: Config.setup(config)

  @doc """
  Validates Datadog exporter configuration, raising an exception on failure.

  ## Examples

      # With environment variables set
      iex> System.put_env("DD_AGENT_HOST", "localhost")
      iex> OpentelemetryDatadog.setup!()
      :ok
  """
  @spec setup!() :: :ok
  def setup! do
    case setup() do
      :ok -> :ok
      {:error, type, message} -> raise ConfigError, {type, message}
    end
  end

  @doc """
  Validates the provided Datadog exporter configuration, raising an exception on failure.

  ## Examples

      iex> config = [host: "localhost", port: 8126]
      iex> OpentelemetryDatadog.setup!(config)
      :ok
  """
  @spec setup!(keyword()) :: :ok
  def setup!(config) when is_list(config) do
    case setup(config) do
      :ok -> :ok
      {:error, type, message} -> raise ConfigError, {type, message}
    end
  end

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
