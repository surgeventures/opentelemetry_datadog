defmodule OpentelemetryDatadog do
  @moduledoc """
  OpenTelemetry Datadog Integration.

  This module provides integration between OpenTelemetry and Datadog, allowing
  you to export traces to Datadog Agent.

  ## Configuration

  The integration is configured via environment variables:

  - `DD_AGENT_HOST` - Datadog agent host (required)
  - `DD_TRACE_AGENT_PORT` - Datadog trace agent port (default: 8126)
  - `DD_SERVICE` - Service name
  - `DD_VERSION` - Service version
  - `DD_ENV` - Environment name
  - `DD_TAGS` - Additional tags as comma-separated key:value pairs
  - `DD_TRACE_SAMPLE_RATE` - Trace sampling rate (0.0 to 1.0)

  ## Usage

  ### Basic setup with environment variables

      # Set environment variables
      export DD_AGENT_HOST=localhost
      export DD_SERVICE=my-service
      export DD_ENV=production
      
      # Configure OpenTelemetry to use the Datadog exporter
      OpentelemetryDatadog.setup()

  ### Manual configuration

      config = [
        host: "localhost",
        port: 8126,
        service: "my-service"
      ]
      
      OpentelemetryDatadog.setup(config)
  """

  alias OpentelemetryDatadog.{Config, ConfigError}

  @doc """
  Sets up the Datadog exporter with configuration from environment variables.

  This function loads configuration from environment variables and configures
  the OpenTelemetry SDK to use the Datadog exporter.

  ## Examples

      # With environment variables set
      iex> System.put_env("DD_AGENT_HOST", "localhost")
      iex> OpentelemetryDatadog.setup()
      :ok
      
      # Returns error if required configuration is missing
      iex> System.delete_env("DD_AGENT_HOST")
      iex> OpentelemetryDatadog.setup()
      {:error, :missing_required_config, "DD_AGENT_HOST is required"}
  """
  @spec setup() :: :ok | Config.validation_error()
  def setup do
    case Config.load() do
      {:ok, config} ->
        config
        |> Config.to_exporter_config()
        |> setup()

      {:error, _, _} = error ->
        error
    end
  end

  @doc """
  Sets up the Datadog exporter with the provided configuration.

  ## Examples

      iex> config = [host: "localhost", port: 8126]
      iex> OpentelemetryDatadog.setup(config)
      :ok
  """
  @spec setup(keyword()) :: :ok | Config.validation_error()
  def setup(config) when is_list(config) do
    config_map = Enum.into(config, %{})

    case Config.validate(config_map) do
      :ok ->
        # TODO: Automatically configure and register OpenTelemetry exporter
        :ok

      {:error, _, _} = error ->
        error
    end
  end

  @doc """
  Sets up the Datadog exporter, raising an exception on failure.

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
  Sets up the Datadog exporter with the provided configuration, raising an exception on failure.

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
  @spec get_config() :: {:ok, Config.t()} | Config.validation_error()
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
