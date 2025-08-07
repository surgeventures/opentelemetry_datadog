defmodule OpentelemetryDatadog.Config.Parser do
  @moduledoc """
  Environment variable parser and type converter for Datadog configuration.
  """

  @type validation_error :: {:error, :missing_required_config | :invalid_config, String.t()}

  @doc "Unified environment variable getter with type conversion and validation."
  @spec get_env(String.t(), atom(), keyword()) :: {:ok, any()} | validation_error()
  def get_env(env_var, type, opts \\ []) do
    default = Keyword.get(opts, :default)
    validate_fn = Keyword.get(opts, :validate)
    error_var_name = Keyword.get(opts, :env_var_name, env_var)

    case System.get_env(env_var) do
      nil ->
        {:ok, default}

      "" ->
        {:ok, default}

      value_str ->
        with {:ok, typed_value} <- convert_type(value_str, type, error_var_name),
             :ok <- apply_validation(typed_value, validate_fn) do
          {:ok, typed_value}
        end
    end
  end

  @spec convert_type(String.t(), atom(), String.t()) :: {:ok, any()} | validation_error()
  defp convert_type(value, :string, _env_var_name), do: {:ok, value}

  defp convert_type(value, :integer, "DD_TRACE_AGENT_PORT") do
    case Integer.parse(value) do
      {int, ""} -> {:ok, int}
      _ -> {:error, :invalid_config, "DD_TRACE_AGENT_PORT must be a valid port number (1-65535)"}
    end
  end

  defp convert_type(value, :integer, "DD_EXPORT_TIMEOUT_MS") do
    case Integer.parse(value) do
      {int, ""} -> {:ok, int}
      _ -> {:error, :invalid_config, "DD_EXPORT_TIMEOUT_MS must be a positive integer"}
    end
  end

  defp convert_type(value, :integer, "DD_EXPORT_CONNECT_TIMEOUT_MS") do
    case Integer.parse(value) do
      {int, ""} -> {:ok, int}
      _ -> {:error, :invalid_config, "DD_EXPORT_CONNECT_TIMEOUT_MS must be a positive integer"}
    end
  end

  defp convert_type(value, :integer, env_var_name) do
    case Integer.parse(value) do
      {int, ""} -> {:ok, int}
      _ -> {:error, :invalid_config, "#{env_var_name} must be a valid integer"}
    end
  end

  defp convert_type(value, :float, "DD_TRACE_SAMPLE_RATE") do
    case Float.parse(value) do
      {float, ""} -> {:ok, float}
      _ -> {:error, :invalid_config, "DD_TRACE_SAMPLE_RATE must be a float between 0.0 and 1.0"}
    end
  end

  defp convert_type(value, :float, env_var_name) do
    case Float.parse(value) do
      {float, ""} -> {:ok, float}
      _ -> {:error, :invalid_config, "#{env_var_name} must be a valid float"}
    end
  end

  @spec apply_validation(any(), function() | nil) :: :ok | validation_error()
  defp apply_validation(_value, nil), do: :ok

  defp apply_validation(value, validate_fn) when is_function(validate_fn, 1) do
    validate_fn.(value)
  end
end
