defmodule OpentelemetryDatadog.EnvHelpers do
  @moduledoc """
  Environment variable utilities for Datadog tests.
  """

  alias OpentelemetryDatadog.DatadogConstants

  @doc "Returns list of all Datadog environment variables."
  @spec env_vars() :: [String.t()]
  def env_vars, do: DatadogConstants.env_vars()

  @doc "Removes all Datadog environment variables."
  @spec reset_env() :: :ok
  def reset_env do
    Enum.each(env_vars(), &System.delete_env/1)
  end

  @doc "Sets multiple environment variables from a map."
  @spec put_env(map()) :: :ok
  def put_env(vars) when is_map(vars) do
    Enum.each(vars, fn {k, v} -> System.put_env(k, v) end)
  end

  @doc "Sets a single DD_* environment variable with validation."
  @spec put_dd_env(String.t(), String.t()) :: :ok | {:error, :unknown_variable}
  def put_dd_env(var, value) when is_binary(var) and is_binary(value) do
    if var in env_vars() do
      System.put_env(var, value)
      :ok
    else
      {:error, :unknown_variable}
    end
  end

  @doc "Gets a DD_* environment variable with optional default."
  @spec get_dd_env(String.t(), String.t() | nil) :: String.t() | nil
  def get_dd_env(var, default \\ nil) when is_binary(var) do
    System.get_env(var, default)
  end

  @doc "Captures current state of all Datadog environment variables."
  @spec get_env_state() :: %{String.t() => String.t() | nil}
  def get_env_state do
    Enum.into(env_vars(), %{}, fn var ->
      {var, System.get_env(var)}
    end)
  end

  @doc "Restores environment variables to a previously captured state."
  @spec restore_env_state(%{String.t() => String.t() | nil}) :: :ok
  def restore_env_state(state) when is_map(state) do
    Enum.each(state, fn {var, value} ->
      if value do
        System.put_env(var, value)
      else
        System.delete_env(var)
      end
    end)
  end

  @doc """
  Checks if all required environment variables are set for a basic configuration.

  ## Examples

      iex> reset_env()
      :ok
      iex> has_minimal_config?()
      false
      iex> put_env(%{"DD_AGENT_HOST" => "localhost"})
      :ok
      iex> has_minimal_config?()
      true
  """
  @spec has_minimal_config?() :: boolean()
  def has_minimal_config? do
    not is_nil(System.get_env("DD_AGENT_HOST"))
  end

  @doc """
  Returns a list of currently set DD_* environment variables.

  ## Examples

      iex> reset_env()
      :ok
      iex> current_dd_vars()
      []
      iex> put_env(%{"DD_AGENT_HOST" => "localhost", "DD_SERVICE" => "test"})
      :ok
      iex> current_dd_vars()
      ["DD_AGENT_HOST", "DD_SERVICE"]
  """
  @spec current_dd_vars() :: [String.t()]
  def current_dd_vars do
    Enum.filter(env_vars(), fn var ->
      not is_nil(System.get_env(var))
    end)
  end
end
