defmodule OpentelemetryDatadog.Testcontainers do
  @moduledoc """
  Utilities for managing a Datadog Agent container during integration tests.

  Requires the `testcontainers`, `docker_engine_api`, and `req` libraries.
  """

  alias Testcontainers.Container

  @default_image "datadog/agent:latest"
  @default_port 8126
  @default_log_level "info"
  @default_wait_timeout 30_000

  @doc """
  Starts a Datadog Agent container with optional configuration.

  ## Options

    * `:image` - Docker image to use (default: "#{@default_image}")
    * `:port` - Port to expose (default: #{@default_port})
    * `:log_level` - Datadog log level (default: "#{@default_log_level}")
  """
  @spec start_dd_agent(keyword()) :: {:ok, Container.t()} | {:error, term()}
  def start_dd_agent(opts \\ []) do
    image = Keyword.get(opts, :image, @default_image)
    port = Keyword.get(opts, :port, @default_port)
    log_level = Keyword.get(opts, :log_level, @default_log_level)

    image
    |> Container.new()
    |> Container.with_environment("DD_APM_ENABLED", "true")
    |> Container.with_environment("DD_APM_NON_LOCAL_TRAFFIC", "true")
    |> Container.with_environment("DD_LOG_LEVEL", log_level)
    |> Container.with_environment("DD_API_KEY", "dummy-key-for-testing")
    |> Container.with_environment("DD_HOSTNAME", "test-agent")
    |> Container.with_exposed_port(port)
    |> Testcontainers.start_container()
    |> handle_container_start()
  end

  defp handle_container_start({:ok, container}) do
    # Give agent time to initialize
    Process.sleep(1000)
    {:ok, container}
  end

  defp handle_container_start({:error, reason}), do: {:error, reason}

  @doc """
  Stops the Datadog Agent container.
  """
  @spec stop(Container.t()) :: :ok | {:error, term()}
  def stop(%Container{container_id: id}), do: Testcontainers.stop_container(id)

  @doc """
  Retrieves host and mapped port for connecting to the Datadog Agent.
  """
  @spec get_connection_info(Container.t()) :: {String.t(), pos_integer()}
  def get_connection_info(%Container{exposed_ports: ports}) do
    host = "localhost"

    port =
      ports
      |> Enum.find(fn {container_port, _} -> container_port == @default_port end)
      |> case do
        {_, host_port} -> host_port
        nil -> raise "Port #{@default_port} is not exposed by the container"
      end

    {host, port}
  end

  @doc """
  Retrieves the latest logs from the Datadog Agent container.

  Returns up to the last 100 lines from both stdout and stderr.
  """
  @spec get_logs(Container.t()) :: String.t()
  def get_logs(%Container{container_id: id}) do
    conn = DockerEngineAPI.Connection.new()

    case DockerEngineAPI.Api.Container.container_logs(conn, id,
           stdout: true,
           stderr: true,
           timestamps: false,
           tail: "100"
         ) do
      {:ok, %Req.Response{body: logs}} when is_binary(logs) -> logs
      {:ok, logs} when is_binary(logs) -> logs
      {:error, reason} -> "Failed to get logs: #{inspect(reason)}"
      other -> "Unexpected response: #{inspect(other)}"
    end
  rescue
    error -> "Exception while getting logs: #{inspect(error)}"
  end

  @doc """
  Waits for the Datadog Agent to become available.

  Checks `/info` endpoint repeatedly until it responds with 200 or times out.
  """
  @spec wait_for_agent(Container.t(), pos_integer()) :: :ok | {:error, :timeout}
  def wait_for_agent(container, timeout \\ @default_wait_timeout) do
    {host, port} = get_connection_info(container)
    url = "http://#{host}:#{port}/info"
    wait_until_ready(url, timeout, System.monotonic_time(:millisecond))
  end

  @doc """
  Pings the Datadog agent to verify it's up and responding.
  """
  @spec check_agent_health!(Container.t()) :: :ok | no_return()
  def check_agent_health!(%Testcontainers.Container{} = container) do
    {host, port} = get_connection_info(container)
    check_agent_health!(%{host: host, port: port})
  end

  @spec check_agent_health!(map()) :: :ok | no_return()
  def check_agent_health!(%{host: host, port: port}) do
    url = "http://#{host}:#{port}/info"

    case Req.get(url) do
      {:ok, %{status: 200}} -> :ok
      other -> raise "Datadog agent is not healthy (#{url}): #{inspect(other)}"
    end
  end

  @doc false
  defp wait_until_ready(url, timeout, start_time) do
    now = System.monotonic_time(:millisecond)

    if now - start_time > timeout do
      {:error, :timeout}
    else
      case Req.get(url) do
        {:ok, %{status: 200}} ->
          :ok

        _ ->
          Process.sleep(500)
          wait_until_ready(url, timeout, start_time)
      end
    end
  end
end
