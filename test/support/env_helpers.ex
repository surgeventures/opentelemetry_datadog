defmodule OpentelemetryDatadog.EnvHelpers do
  @moduledoc """
  Environment variable management utilities for Datadog tests.

  Provides functions for setting, resetting, and managing DD_* environment
  variables consistently across tests.
  """

  alias OpentelemetryDatadog.DatadogConstants

  @doc """
  Returns list of all Datadog environment variables.

  ## Examples

      iex> env_vars()
      ["DD_AGENT_HOST", "DD_TRACE_AGENT_PORT", "DD_SERVICE", ...]
  """
  @spec env_vars() :: [String.t()]
  def env_vars, do: DatadogConstants.env_vars()

  @doc """
  Removes all Datadog environment variables.

  Useful for clean test setup to ensure no variables from previous tests interfere.

  ## Examples

      iex> put_env(%{"DD_AGENT_HOST" => "localhost", "DD_SERVICE" => "test"})
      :ok
      iex> reset_env()
      :ok
      iex> System.get_env("DD_AGENT_HOST")
      nil
      
  ## Usage in tests

      setup do
        EnvHelpers.reset_env()
        :ok
      end
  """
  @spec reset_env() :: :ok
  def reset_env do
    Enum.each(env_vars(), &System.delete_env/1)
  end

  @doc """
  Sets multiple environment variables from a map.

  ## Examples

      iex> put_env(%{"DD_AGENT_HOST" => "localhost", "DD_SERVICE" => "test-app"})
      :ok
      
      iex> put_env(%{
      ...>   "DD_AGENT_HOST" => "datadog-agent.kube-system.svc.cluster.local",
      ...>   "DD_TRACE_AGENT_PORT" => "8126",
      ...>   "DD_SERVICE" => "user-service",
      ...>   "DD_VERSION" => "v2.1.0",
      ...>   "DD_ENV" => "production"
      ...> })
      :ok
  """
  @spec put_env(map()) :: :ok
  def put_env(vars) when is_map(vars) do
    Enum.each(vars, fn {k, v} -> System.put_env(k, v) end)
  end

  @doc """
  Sets a single DD_* environment variable with validation.

  Only allows setting known Datadog environment variables.

  ## Examples

      iex> put_dd_env("DD_AGENT_HOST", "localhost")
      :ok
      iex> put_dd_env("SOME_OTHER_VAR", "value")
      {:error, :unknown_variable}
  """
  @spec put_dd_env(String.t(), String.t()) :: :ok | {:error, :unknown_variable}
  def put_dd_env(var, value) when is_binary(var) and is_binary(value) do
    if var in env_vars() do
      System.put_env(var, value)
      :ok
    else
      {:error, :unknown_variable}
    end
  end

  @doc """
  Gets a DD_* environment variable with optional default.

  ## Examples

      iex> put_env(%{"DD_AGENT_HOST" => "localhost"})
      :ok
      iex> get_dd_env("DD_AGENT_HOST")
      "localhost"
      iex> get_dd_env("DD_SERVICE", "default-service")
      "default-service"
  """
  @spec get_dd_env(String.t(), String.t() | nil) :: String.t() | nil
  def get_dd_env(var, default \\ nil) when is_binary(var) do
    System.get_env(var, default)
  end

  @doc """
  Captures current state of all Datadog environment variables.

  Returns a map of variable names to their current values (or nil if not set).
  Useful for saving state before test modifications.

  ## Examples

      iex> put_env(%{"DD_AGENT_HOST" => "localhost"})
      :ok
      iex> state = get_env_state()
      iex> state["DD_AGENT_HOST"]
      "localhost"
      iex> is_nil(state["DD_SERVICE"])
      true
  """
  @spec get_env_state() :: %{String.t() => String.t() | nil}
  def get_env_state do
    Enum.into(env_vars(), %{}, fn var ->
      {var, System.get_env(var)}
    end)
  end

  @doc """
  Restores environment variables to a previously captured state.

  Takes a state map (usually from get_env_state/0) and restores all
  DD_* variables to those values.

  ## Examples

      iex> original_state = get_env_state()
      iex> put_env(%{"DD_AGENT_HOST" => "test-host", "DD_SERVICE" => "test-service"})
      :ok
      iex> restore_env_state(original_state)
      :ok
      iex> System.get_env("DD_AGENT_HOST")
      nil
  """
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
