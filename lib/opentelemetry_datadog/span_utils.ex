defmodule OpentelemetryDatadog.SpanUtils do
  @moduledoc """
  Common utilities for span processing shared between v0.4 and v0.5 exporters.
  """

  @doc "Converts various term types to strings for metadata."
  @spec term_to_string(term()) :: String.t()
  def term_to_string(term) when is_boolean(term), do: inspect(term)
  def term_to_string(term) when is_binary(term), do: term
  def term_to_string(term) when is_atom(term), do: Atom.to_string(term)
  def term_to_string(term), do: inspect(term)

  @doc "Converts :undefined to nil, passes through other values."
  @spec nil_if_undefined(term()) :: term()
  def nil_if_undefined(:undefined), do: nil
  def nil_if_undefined(value), do: value

  @doc """
  Converts OpenTelemetry trace ID to Datadog format.
  
  Takes a 128-bit trace ID and returns the upper 64 bits as required by Datadog.
  
  ## Examples
  
      iex> OpentelemetryDatadog.SpanUtils.id_to_datadog_id(nil)
      nil
      
      iex> # Simple example with known values
      iex> trace_id = 0x123456789ABCDEF0FEDCBA0987654321
      iex> OpentelemetryDatadog.SpanUtils.id_to_datadog_id(trace_id)
      1311768467463790320
  """
  @spec id_to_datadog_id(integer() | nil) :: integer() | nil
  def id_to_datadog_id(nil), do: nil
  def id_to_datadog_id(trace_id) do
    <<upper::integer-size(64), _lower::integer-size(64)>> = <<trace_id::integer-size(128)>>
    upper
  end

  @doc """
  Extracts service name from resource map.
  
  ## Examples
  
      iex> data = %{resource_map: %{"service.name" => "my-service"}}
      iex> OpentelemetryDatadog.SpanUtils.get_service_from_resource(data)
      "my-service"
      
      iex> data = %{resource_map: %{}}
      iex> OpentelemetryDatadog.SpanUtils.get_service_from_resource(data)
      "unknown-service"
  """
  @spec get_service_from_resource(map()) :: String.t()
  def get_service_from_resource(data) do
    case get_in(data, [:resource_map, "service.name"]) do
      nil -> "unknown-service"
      service -> service
    end
  end

  @doc """
  Extracts environment from resource map.
  
  ## Examples
  
      iex> data = %{resource_map: %{"deployment.environment" => "production"}}
      iex> OpentelemetryDatadog.SpanUtils.get_env_from_resource(data)
      "production"
      
      iex> data = %{resource_map: %{}}
      iex> OpentelemetryDatadog.SpanUtils.get_env_from_resource(data)
      "unknown"
  """
  @spec get_env_from_resource(map()) :: String.t()
  def get_env_from_resource(data) do
    case get_in(data, [:resource_map, "deployment.environment"]) do
      nil -> "unknown"
      env -> env
    end
  end

  @doc """
  Builds resource name from span name and metadata.
  
  Tries to create a meaningful resource name from HTTP attributes,
  falls back to span name.
  
  ## Examples
  
      iex> meta = %{"http.method" => "GET", "http.route" => "/api/users"}
      iex> OpentelemetryDatadog.SpanUtils.get_resource_from_span("web.request", meta)
      "GET /api/users"
      
      iex> meta = %{}
      iex> OpentelemetryDatadog.SpanUtils.get_resource_from_span("db.query", meta)
      "db.query"
  """
  @spec get_resource_from_span(String.t(), map()) :: String.t()
  def get_resource_from_span(name, meta) do
    case Map.get(meta, "http.route") || Map.get(meta, "http.target") do
      nil -> name
      route -> "#{Map.get(meta, "http.method", "GET")} #{route}"
    end
  end

  @doc """
  Maps OpenTelemetry span kind to Datadog span type.
  
  ## Examples
  
      iex> OpentelemetryDatadog.SpanUtils.get_type_from_span("server")
      "web"
      
      iex> OpentelemetryDatadog.SpanUtils.get_type_from_span("client")
      "http"
      
      iex> OpentelemetryDatadog.SpanUtils.get_type_from_span("unknown")
      "custom"
  """
  @spec get_type_from_span(String.t()) :: String.t()
  def get_type_from_span(span_kind) do
    case span_kind do
      "server" -> "web"
      "client" -> "http"
      "producer" -> "queue"
      "consumer" -> "queue"
      "internal" -> "custom"
      _ -> "custom"
    end
  end

  @doc """
  Gets container ID from cgroup file.
  
  Reads /proc/self/cgroup and extracts container ID using regex patterns
  for different container runtimes.
  
  ## Examples
  
      iex> OpentelemetryDatadog.SpanUtils.get_container_id()
      nil  # or container ID string if running in container
  """
  @spec get_container_id() :: String.t() | nil
  def get_container_id do
    cgroup_uuid = "[0-9a-f]{8}[-_][0-9a-f]{4}[-_][0-9a-f]{4}[-_][0-9a-f]{4}[-_][0-9a-f]{12}"
    cgroup_ctnr = "[0-9a-f]{64}"
    cgroup_task = "[0-9a-f]{32}-\\d+"
    
    cgroup_regex = Regex.compile!(
      ".*(#{cgroup_uuid}|#{cgroup_ctnr}|#{cgroup_task})(?:\\.scope)?$",
      "m"
    )

    with {:ok, file_binary} <- File.read("/proc/self/cgroup"),
         [_, container_id] <- Regex.run(cgroup_regex, file_binary) do
      container_id
    else
      _ -> nil
    end
  end
end