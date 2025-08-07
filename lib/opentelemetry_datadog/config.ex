defmodule OpentelemetryDatadog.ConfigError do
  @moduledoc """
  Exception raised when configuration validation fails.
  """
  defexception [:type, :message]

  @type t :: %__MODULE__{
          type: :missing_required_config | :invalid_config,
          message: String.t()
        }

  def exception({type, msg}) do
    %__MODULE__{type: type, message: msg}
  end

  def message(%__MODULE__{type: type, message: msg}) do
    "Configuration error (#{type}): #{msg}"
  end
end

defmodule OpentelemetryDatadog.Config do
  @moduledoc """
  Configuration management for OpenTelemetry Datadog integration.
  """

  alias OpentelemetryDatadog.{ConfigError, DatadogConstants}
  alias OpentelemetryDatadog.Config.Parser

  @enforce_keys [:host, :port]
  defstruct [
    :host,
    :port,
    :service,
    :version,
    :env,
    :tags,
    :sample_rate,
    :timeout_ms
  ]

  @type t :: %__MODULE__{
          host: String.t(),
          port: pos_integer(),
          service: String.t() | nil,
          version: String.t() | nil,
          env: String.t() | nil,
          tags: map() | nil,
          sample_rate: float() | nil,
          timeout_ms: pos_integer()
        }

  @type validation_error :: {:error, :missing_required_config | :invalid_config, String.t()}

  @doc "Loads configuration from environment variables."
  @spec load() :: {:ok, t()} | validation_error()
  def load do
    with {:ok, host} <- get_required_env("DD_AGENT_HOST"),
         {:ok, port} <- get_port(),
         {:ok, sample_rate} <- get_sample_rate(),
         {:ok, tags} <- get_tags(),
         {:ok, timeout_ms} <- get_timeout_ms() do
      config = %__MODULE__{
        host: host,
        port: port,
        service: get_service(),
        version: get_version(),
        env: get_environment(),
        tags: tags,
        sample_rate: sample_rate,
        timeout_ms: timeout_ms
      }

      {:ok, config}
    else
      {:error, _, _} = error -> error
    end
  end

  @doc "Loads configuration from environment variables, raising an exception on failure."
  @spec load!() :: t() | no_return()
  def load! do
    case load() do
      {:ok, config} -> config
      {:error, type, message} -> raise ConfigError, {type, message}
    end
  end

  @doc "Validates the provided configuration."
  @spec validate(t() | map()) :: :ok | validation_error()
  def validate(%__MODULE__{} = config) do
    config
    |> Map.from_struct()
    |> validate()
  end

  def validate(config) when is_map(config) do
    with :ok <- validate_required(config, :host, "host is required"),
         :ok <- validate_required(config, :port, "port is required"),
         :ok <- validate_port(config[:port]),
         :ok <- validate_sample_rate(config[:sample_rate]),
         :ok <- validate_timeout_ms(config[:timeout_ms]) do
      :ok
    end
  end

  @doc """
  Converts the configuration to a keyword list suitable for the exporter.
  """
  @spec to_exporter_config(t() | map()) :: keyword()
  def to_exporter_config(%__MODULE__{} = config) do
    config
    |> Map.from_struct()
    |> to_exporter_config()
  end

  def to_exporter_config(config) when is_map(config) do
    config
    |> Enum.reject(fn {_k, v} -> is_nil(v) end)
    |> Enum.into([])
  end

  @spec get_required_env(String.t()) :: {:ok, String.t()} | validation_error()
  defp get_required_env(var_name) do
    case System.get_env(var_name) do
      nil -> {:error, :missing_required_config, "#{var_name} is required"}
      "" -> {:error, :missing_required_config, "#{var_name} cannot be empty"}
      value -> {:ok, value}
    end
  end

  @spec get_port() :: {:ok, pos_integer()} | validation_error()
  defp get_port do
    Parser.get_env("DD_TRACE_AGENT_PORT", :integer,
      default: DatadogConstants.default(:port),
      validate: &validate_port_env/1
    )
  end

  @spec get_sample_rate() :: {:ok, float() | nil} | validation_error()
  defp get_sample_rate do
    Parser.get_env("DD_TRACE_SAMPLE_RATE", :float,
      default: DatadogConstants.default(:sample_rate),
      validate: &validate_sample_rate_env/1
    )
  end

  @spec get_timeout_ms() :: {:ok, pos_integer()} | validation_error()
  defp get_timeout_ms do
    Parser.get_env("DD_EXPORT_TIMEOUT_MS", :integer,
      default: DatadogConstants.default(:timeout_ms),
      validate: &validate_timeout_ms_env/1
    )
  end

  @spec get_service() :: String.t() | nil
  defp get_service do
    case Parser.get_env("DD_SERVICE", :string, default: DatadogConstants.default(:service)) do
      {:ok, service} -> service
      _ -> nil
    end
  end

  @spec get_version() :: String.t() | nil
  defp get_version do
    case Parser.get_env("DD_VERSION", :string, default: DatadogConstants.default(:version)) do
      {:ok, version} -> version
      _ -> nil
    end
  end

  @spec get_environment() :: String.t() | nil
  defp get_environment do
    case Parser.get_env("DD_ENV", :string, default: DatadogConstants.default(:env)) do
      {:ok, env} -> env
      _ -> nil
    end
  end

  @spec get_tags() :: {:ok, map() | nil} | validation_error()
  defp get_tags do
    case Parser.get_env("DD_TAGS", :string, default: DatadogConstants.default(:tags)) do
      {:ok, nil} ->
        {:ok, nil}

      {:ok, tags_str} ->
        tags_str
        |> String.split(",")
        |> Enum.map(&String.trim/1)
        |> Enum.reject(&(&1 == ""))
        |> parse_tags([])

      error ->
        error
    end
  end

  @spec parse_tags([String.t()], [{String.t(), String.t()}]) :: {:ok, map()} | validation_error()
  defp parse_tags([], acc) do
    {:ok, Enum.into(acc, %{})}
  end

  defp parse_tags([tag_str | rest], acc) do
    case parse_tag(tag_str) do
      {:ok, {key, value}} ->
        parse_tags(rest, [{key, value} | acc])

      {:error, _reason} ->
        {:error, :invalid_config,
         "Invalid DD_TAGS entry: '#{tag_str}'. Must be comma-separated key:value pairs (e.g., 'env:prod,version:1.0')"}
    end
  end

  @spec parse_tag(String.t()) :: {:ok, {String.t(), String.t()}} | {:error, String.t()}
  defp parse_tag(tag_str) do
    case String.split(tag_str, ":", parts: 3) do
      [_, _, _] ->
        {:error, "too many colons"}

      [key, value] ->
        {:ok, {String.trim(key), String.trim(value)}}

      [key] ->
        {:ok, {String.trim(key), "true"}}

      _ ->
        {:error, "invalid format"}
    end
  end

  @spec validate_required(map(), atom(), String.t()) :: :ok | validation_error()
  defp validate_required(config, key, error_message) do
    case Map.get(config, key) do
      nil -> {:error, :missing_required_config, error_message}
      _ -> :ok
    end
  end

  @spec validate_port(any()) :: :ok | validation_error()
  defp validate_port(port) when is_integer(port) and port > 0 and port <= 65535, do: :ok

  defp validate_port(_),
    do: {:error, :invalid_config, "port must be a valid port number (1-65535)"}

  @spec validate_sample_rate(any()) :: :ok | validation_error()
  defp validate_sample_rate(nil), do: :ok
  defp validate_sample_rate(rate) when is_float(rate) and rate >= 0.0 and rate <= 1.0, do: :ok

  defp validate_sample_rate(_),
    do: {:error, :invalid_config, "sample_rate must be a float between 0.0 and 1.0"}

  @spec validate_timeout_ms(any()) :: :ok | validation_error()
  defp validate_timeout_ms(nil), do: :ok
  defp validate_timeout_ms(timeout) when is_integer(timeout) and timeout > 0, do: :ok

  defp validate_timeout_ms(_),
    do: {:error, :invalid_config, "timeout_ms must be a positive integer"}

  @spec validate_port_env(any()) :: :ok | validation_error()
  defp validate_port_env(port) when is_integer(port) and port > 0 and port <= 65535, do: :ok

  defp validate_port_env(_),
    do: {:error, :invalid_config, "DD_TRACE_AGENT_PORT must be a valid port number (1-65535)"}

  @spec validate_sample_rate_env(any()) :: :ok | validation_error()
  defp validate_sample_rate_env(nil), do: :ok
  defp validate_sample_rate_env(rate) when is_float(rate) and rate >= 0.0 and rate <= 1.0, do: :ok

  defp validate_sample_rate_env(_),
    do: {:error, :invalid_config, "DD_TRACE_SAMPLE_RATE must be a float between 0.0 and 1.0"}

  @spec validate_timeout_ms_env(any()) :: :ok | validation_error()
  defp validate_timeout_ms_env(timeout) when is_integer(timeout) and timeout > 0, do: :ok

  defp validate_timeout_ms_env(_),
    do: {:error, :invalid_config, "DD_EXPORT_TIMEOUT_MS must be a positive integer"}
end
