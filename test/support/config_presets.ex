defmodule OpentelemetryDatadog.ConfigPresets do
  @moduledoc """
  Pre-configured environment variable setups for common scenarios.

  Provides convenient functions for setting up typical Datadog configurations
  used in different environments (development, production, staging, etc.).
  """

  alias OpentelemetryDatadog.EnvHelpers

  @doc """
  Sets up minimal configuration (only DD_AGENT_HOST).

  ## Examples

      iex> minimal_config()
      :ok
      iex> System.get_env("DD_AGENT_HOST")
      "localhost"
      
      iex> minimal_config("custom-host")
      :ok
      iex> System.get_env("DD_AGENT_HOST")
      "custom-host"
  """
  @spec minimal_config(String.t()) :: :ok
  def minimal_config(host \\ "localhost") do
    EnvHelpers.put_env(%{"DD_AGENT_HOST" => host})
  end

  @doc """
  Sets up development environment configuration.

  ## Examples

      iex> dev_config()
      :ok
      iex> System.get_env("DD_ENV")
      "development"
      
      iex> dev_config("my-app")
      :ok
      iex> System.get_env("DD_SERVICE")
      "my-app"
  """
  @spec dev_config(String.t()) :: :ok
  def dev_config(service \\ "test-app") do
    EnvHelpers.put_env(%{
      "DD_AGENT_HOST" => "localhost",
      "DD_SERVICE" => service,
      "DD_ENV" => "development"
    })
  end

  @doc """
  Sets up production environment configuration.

  ## Examples

      iex> prod_config()
      :ok
      iex> System.get_env("DD_ENV")
      "production"
      
      iex> prod_config("user-service", "v1.2.3")
      :ok
      iex> System.get_env("DD_VERSION")
      "v1.2.3"
  """
  @spec prod_config(String.t(), String.t()) :: :ok
  def prod_config(service \\ "api-service", version \\ "v1.0.0") do
    EnvHelpers.put_env(%{
      "DD_AGENT_HOST" => "datadog-agent.kube-system.svc.cluster.local",
      "DD_TRACE_AGENT_PORT" => "8126",
      "DD_SERVICE" => service,
      "DD_VERSION" => version,
      "DD_ENV" => "production",
      "DD_TAGS" => "team:backend,component:api,datacenter:us-east-1",
      "DD_TRACE_SAMPLE_RATE" => "0.1"
    })
  end

  @doc """
  Sets up containerized application configuration.

  ## Examples

      iex> containerized_config()
      :ok
      iex> System.get_env("DD_AGENT_HOST")
      "dd-agent"
      
      iex> containerized_config("api-service", "1.0.0", "staging")
      :ok
      iex> System.get_env("DD_ENV")
      "staging"
  """
  @spec containerized_config(String.t(), String.t(), String.t()) :: :ok
  def containerized_config(service \\ "api-service", version \\ "1.0.0", env \\ "production") do
    EnvHelpers.put_env(%{
      "DD_AGENT_HOST" => "dd-agent",
      "DD_TRACE_AGENT_PORT" => "8126",
      "DD_SERVICE" => service,
      "DD_VERSION" => version,
      "DD_ENV" => env,
      "DD_TAGS" => "container:docker,orchestrator:k8s,cluster:prod",
      "DD_TRACE_SAMPLE_RATE" => "0.2"
    })
  end

  @doc """
  Sets up Phoenix application configuration.

  ## Examples

      iex> phoenix_config()
      :ok
      iex> System.get_env("DD_TAGS")
      "framework:phoenix,language:elixir"
      
      iex> phoenix_config("my-phoenix-app")
      :ok
      iex> System.get_env("DD_SERVICE")
      "my-phoenix-app"
  """
  @spec phoenix_config(String.t()) :: :ok
  def phoenix_config(service \\ "phoenix-app") do
    EnvHelpers.put_env(%{
      "DD_AGENT_HOST" => "localhost",
      "DD_SERVICE" => service,
      "DD_ENV" => "development",
      "DD_TAGS" => "framework:phoenix,language:elixir"
    })
  end

  @doc """
  Sets up staging environment configuration.

  ## Examples

      iex> staging_config()
      :ok
      iex> System.get_env("DD_ENV")
      "staging"
  """
  @spec staging_config(String.t(), String.t()) :: :ok
  def staging_config(service \\ "staging-app", version \\ "latest") do
    EnvHelpers.put_env(%{
      "DD_AGENT_HOST" => "datadog-agent.staging.svc.cluster.local",
      "DD_SERVICE" => service,
      "DD_VERSION" => version,
      "DD_ENV" => "staging",
      "DD_TAGS" => "environment:staging,deploy:blue-green",
      "DD_TRACE_SAMPLE_RATE" => "0.5"
    })
  end

  @doc """
  Sets up CI/testing environment configuration.

  ## Examples

      iex> ci_config()
      :ok
      iex> System.get_env("DD_TRACE_SAMPLE_RATE")
      "1.0"
  """
  @spec ci_config(String.t()) :: :ok
  def ci_config(service \\ "ci-test") do
    EnvHelpers.put_env(%{
      "DD_AGENT_HOST" => "localhost",
      "DD_SERVICE" => service,
      "DD_ENV" => "test",
      "DD_TAGS" => "ci:true,environment:test",
      "DD_TRACE_SAMPLE_RATE" => "1.0"
    })
  end

  @doc """
  Sets up microservice architecture configuration.

  ## Examples

      iex> microservice_config("user-service", "auth")
      :ok
      iex> System.get_env("DD_TAGS")
      "component:auth,architecture:microservice,mesh:istio"
  """
  @spec microservice_config(String.t(), String.t()) :: :ok
  def microservice_config(service, component) do
    EnvHelpers.put_env(%{
      "DD_AGENT_HOST" => "datadog-agent.istio-system.svc.cluster.local",
      "DD_SERVICE" => service,
      "DD_ENV" => "production",
      "DD_TAGS" => "component:#{component},architecture:microservice,mesh:istio",
      "DD_TRACE_SAMPLE_RATE" => "0.1"
    })
  end
end
