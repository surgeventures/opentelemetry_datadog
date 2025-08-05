defmodule OpentelemetryDatadog.Testcontainers do
  @moduledoc """
  Utilities for managing a Datadog Agent container during integration tests.

  Requires the `testcontainers`, `docker_engine_api`, and `req` libraries.
  """

  alias Testcontainers.Container

  @default_image "datadog/agent:7.52.0"
  @default_port 8126
  @default_log_level "info"
  @default_wait_timeout 60_000

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
    |> Container.with_environment("DD_BIND_HOST", "0.0.0.0")
    |> Container.with_environment("DD_APM_RECEIVER_PORT", Integer.to_string(port))
    |> Container.with_exposed_port(port)
    |> Testcontainers.start_container()
    |> handle_container_start()
  end

  defp handle_container_start({:ok, container}) do
    Process.sleep(3000)
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
    case check_container_status(id) do
      :running ->
        get_container_logs(id)
      
      status ->
        "Container is not running (status: #{status}). Cannot retrieve logs."
    end
  end

  defp check_container_status(container_id) do
    conn = DockerEngineAPI.Connection.new()
    
    try do
      case DockerEngineAPI.Api.Container.container_inspect(conn, container_id) do
        {:ok, %{"State" => %{"Status" => status}}} -> String.to_atom(status)
        {:ok, %{state: %{status: status}}} -> String.to_atom(status)
        {:error, _} -> :not_found
        _ -> :unknown
      end
    rescue
      _ -> :error
    catch
      _, _ -> :error
    end
  end

  defp get_container_logs(container_id) do
    conn = DockerEngineAPI.Connection.new()

    try do
      case DockerEngineAPI.Api.Container.container_logs(conn, container_id,
             stdout: true,
             stderr: true,
             timestamps: false,
             tail: "100"
           ) do
        {:ok, %{"body" => logs}} when is_binary(logs) -> logs
        {:ok, %{body: logs}} when is_binary(logs) -> logs
        {:ok, logs} when is_binary(logs) -> logs
        {:error, reason} -> "Failed to get logs: #{inspect(reason)}"
        other -> "Unexpected response: #{inspect(other)}"
      end
    rescue
      error -> "Exception while getting logs: #{Exception.format(:error, error, __STACKTRACE__)}"
    catch
      :exit, reason -> "Exit while getting logs: #{inspect(reason)}"
      error -> "Error while getting logs: #{inspect(error)}"
    end
  end

  @doc """
  Waits for the Datadog Agent to become available.

  Checks `/info` endpoint repeatedly until it responds with 200 or times out.
  """
  @spec wait_for_agent(Container.t(), pos_integer()) :: :ok | {:error, :timeout}
  def wait_for_agent(container, timeout \\ @default_wait_timeout) do
    {host, port} = get_connection_info(container)
    url = "http://#{host}:#{port}/info"
    
    Process.sleep(2000)
    
    wait_until_ready(url, timeout, System.monotonic_time(:millisecond))
  end

  @doc """
  Pings the Datadog agent to verify it's up and responding.
  """
  @spec check_agent_health!(Container.t() | %{host: String.t(), port: pos_integer()}) :: :ok
  def check_agent_health!(%Container{} = container) do
    {host, port} = get_connection_info(container)
    check_agent_health!(%{host: host, port: port})
  end

  def check_agent_health!(%{host: host, port: port}) do
    url = "http://#{host}:#{port}/info"

    case safe_http_get(url) do
      {:ok, %{status: 200}} -> :ok
      other -> raise "Datadog agent is not healthy (#{url}): #{inspect(other)}"
    end
  end

  @doc false
  defp wait_until_ready(url, timeout, start_time) do
    now = System.monotonic_time(:millisecond)

    cond do
      now - start_time > timeout ->
        {:error, :timeout}

      true ->
        case safe_http_get(url) do
          {:ok, %{status: 200}} ->
            :ok

          error ->
            require Logger
            Logger.debug("Waiting for agent at #{url}, got: #{inspect(error)}")
            Process.sleep(1000)
            wait_until_ready(url, timeout, start_time)
        end
    end
  end

  defp safe_http_get(url) do
    try do
      Req.get(url, connect_options: [timeout: 5000], receive_timeout: 5000)
    rescue
      error -> {:error, error}
    catch
      :exit, reason -> {:error, {:exit, reason}}
      error -> {:error, error}
    end
  end
end
