defmodule OpentelemetryDatadog.Testcontainers do
  @moduledoc """
  Datadog Agent container utilities for integration tests.
  """

  @doc "Starts a Datadog Agent container."
  @spec start_dd_agent(keyword()) :: {:ok, Testcontainers.Container.t()} | {:error, term()}
  def start_dd_agent(opts \\ []) do
    image = Keyword.get(opts, :image, "datadog/agent:latest")
    port = Keyword.get(opts, :port, 8126)
    log_level = Keyword.get(opts, :log_level, "info")
    _wait_timeout = Keyword.get(opts, :wait_timeout, 30_000)

    config = 
      Testcontainers.Container.new(image)
      |> Testcontainers.Container.with_environment("DD_APM_ENABLED", "true")
      |> Testcontainers.Container.with_environment("DD_APM_NON_LOCAL_TRAFFIC", "true")
      |> Testcontainers.Container.with_environment("DD_LOG_LEVEL", log_level)
      |> Testcontainers.Container.with_environment("DD_API_KEY", "dummy-key-for-testing")
      |> Testcontainers.Container.with_environment("DD_HOSTNAME", "test-agent")
      |> Testcontainers.Container.with_exposed_port(port)

    case Testcontainers.start_container(config) do
      {:ok, container} ->
        # Give the agent a moment to fully initialize
        Process.sleep(1000)
        {:ok, container}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc "Stops a Datadog Agent container."
  @spec stop(Testcontainers.Container.t()) :: :ok | {:error, term()}
  def stop(container) do
    Testcontainers.stop_container(container.container_id)
  end

  @doc "Gets the host and port for connecting to the Datadog Agent."
  @spec get_connection_info(Testcontainers.Container.t()) :: {String.t(), integer()}
  def get_connection_info(container) do
    host = Testcontainers.get_host(container)
    
    port = case Enum.find(container.exposed_ports, fn {container_port, _host_port} ->
      container_port == 8126 
    end) do
      {_container_port, host_port} -> host_port
      nil -> 8126
    end
    
    {host, port}
  end

  @doc "Gets the logs from the Datadog Agent container."
  @spec get_logs(Testcontainers.Container.t()) :: String.t()
  def get_logs(container) do
    Testcontainers.get_logs(container)
  end

  @doc "Waits for the Datadog Agent to be ready."
  @spec wait_for_agent(Testcontainers.Container.t(), integer()) :: :ok | {:error, :timeout}
  def wait_for_agent(container, timeout \\ 30_000) do
    {host, port} = get_connection_info(container)
    url = "http://#{host}:#{port}/info"
    
    wait_for_agent_ready(url, timeout, System.monotonic_time(:millisecond))
  end

  defp wait_for_agent_ready(url, timeout, start_time) do
    current_time = System.monotonic_time(:millisecond)
    
    if current_time - start_time > timeout do
      {:error, :timeout}
    else
      case Req.get(url) do
        {:ok, %{status: 200}} ->
          :ok
        
        _ ->
          Process.sleep(500)
          wait_for_agent_ready(url, timeout, start_time)
      end
    end
  end
end
