defmodule OpentelemetryDatadog.V05.Config do
  @moduledoc """
  Configuration utilities for v0.5 Datadog exporter.

  Provides helper functions to configure the v0.5 exporter alongside
  the existing configuration system without modifying existing code.
  """

  alias OpentelemetryDatadog.{Config, ConfigError}

  @doc """
  Converts standard Datadog configuration to v0.5 exporter configuration.

  Takes the same configuration format as the standard exporter but ensures
  the protocol is set to :v05 for the v0.5 exporter.

  ## Examples

      iex> config = [host: "localhost", port: 8126, service: "my-service"]
      iex> v05_config = OpentelemetryDatadog.V05.Config.to_v05_exporter_config(config)
      iex> v05_config[:protocol]
      :v05
      iex> v05_config[:host]
      "localhost"
  """
  @spec to_v05_exporter_config(keyword() | map()) :: keyword()
  def to_v05_exporter_config(config) when is_list(config) do
    config
    |> Keyword.put(:protocol, :v05)
  end

  def to_v05_exporter_config(config) when is_map(config) do
    config
    |> Config.to_exporter_config()
    |> to_v05_exporter_config()
  end

  @doc """
  Sets up the v0.5 Datadog exporter with configuration from environment variables.

  This is a convenience function that loads configuration from environment
  variables and configures the v0.5 exporter.

  ## Examples

      # With environment variables set
      iex> System.put_env("DD_AGENT_HOST", "localhost")
      iex> OpentelemetryDatadog.V05.Config.setup()
      :ok
  """
  @spec setup() :: :ok | {:error, Config.validation_error()}
  def setup do
    case Config.load() do
      {:ok, config} ->
        config
        |> Config.to_exporter_config()
        |> to_v05_exporter_config()
        |> setup()

      {:error, _, _} = error ->
        error
    end
  end

  @doc """
  Sets up the v0.5 Datadog exporter with the provided configuration.

  ## Examples

      iex> config = [host: "localhost", port: 8126]
      iex> OpentelemetryDatadog.V05.Config.setup(config)
      :ok
  """
  @spec setup(keyword()) :: :ok | {:error, Config.validation_error()}
  def setup(config) when is_list(config) do
    # Extract protocol to validate it's v05, then validate the rest
    {protocol, base_config} = Keyword.pop(config, :protocol, :v05)

    case protocol do
      :v05 ->
        config_map = Enum.into(base_config, %{})

        case Config.validate(config_map) do
          :ok ->
            # TODO: Automatically configure and register v0.5 OpenTelemetry exporter
            :ok

          {:error, _, _} = error ->
            error
        end

      other ->
        {:error, :invalid_config, "v0.5 exporter requires protocol: :v05, got: #{inspect(other)}"}
    end
  end

  @doc """
  Sets up the v0.5 Datadog exporter, raising an exception on failure.

  ## Examples

      # With environment variables set
      iex> System.put_env("DD_AGENT_HOST", "localhost")
      iex> OpentelemetryDatadog.V05.Config.setup!()
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
  Sets up the v0.5 Datadog exporter with the provided configuration, raising an exception on failure.

  ## Examples

      iex> config = [host: "localhost", port: 8126, protocol: :v05]
      iex> OpentelemetryDatadog.V05.Config.setup!(config)
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
  Returns the current configuration for v0.5 exporter.

  This loads the standard configuration and adds the v0.5 protocol setting.

  ## Examples

      iex> System.put_env("DD_AGENT_HOST", "localhost")
      iex> {:ok, config} = OpentelemetryDatadog.V05.Config.get_config()
      iex> config[:protocol]
      :v05
  """
  @spec get_config() :: {:ok, keyword()} | {:error, Config.validation_error()}
  def get_config do
    case Config.load() do
      {:ok, config} ->
        v05_config =
          config
          |> Config.to_exporter_config()
          |> to_v05_exporter_config()

        {:ok, v05_config}

      {:error, _, _} = error ->
        error
    end
  end

  @doc """
  Returns the current configuration for v0.5 exporter, raising an exception on failure.

  ## Examples

      iex> System.put_env("DD_AGENT_HOST", "localhost")
      iex> config = OpentelemetryDatadog.V05.Config.get_config!()
      iex> config[:protocol]
      :v05
  """
  @spec get_config!() :: keyword()
  def get_config! do
    case get_config() do
      {:ok, config} -> config
      {:error, type, message} -> raise ConfigError, {type, message}
    end
  end
end
