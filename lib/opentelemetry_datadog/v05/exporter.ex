defmodule OpentelemetryDatadog.V05.Exporter do
  @moduledoc """
  Datadog v0.5 traces exporter for OpenTelemetry.
  
  This exporter sends traces to the Datadog Agent using the /v0.5/traces endpoint
  with MessagePack serialization. It maintains compatibility with the existing
  exporter while providing v0.5 specific functionality.
  """

  @behaviour :otel_exporter

  require Record
  @deps_dir Mix.Project.deps_path()
  Record.defrecord(
    :span,
    Record.extract(:span, from: "#{@deps_dir}/opentelemetry/include/otel_span.hrl")
  )

  Record.defrecord(
    :resource,
    Record.extract(:resource, from: "#{@deps_dir}/opentelemetry/src/otel_resource.erl")
  )

  Record.defrecord(
    :attributes,
    Record.extract(:attributes, from: "#{@deps_dir}/opentelemetry_api/src/otel_attributes.erl")
  )

  defmodule State do
    @type t :: %State{}

    defstruct [
      :http,
      :host,
      :port,
      :service_name,
      :container_id,
      :protocol
    ]
  end

  @headers [
    {"Content-Type", "application/msgpack"},
    {"Datadog-Meta-Lang", "elixir"},
    {"Datadog-Meta-Lang-Version", System.version()},
    {"Datadog-Meta-Tracer-Version", Application.spec(:opentelemetry_datadog)[:vsn]}
  ]

  alias OpentelemetryDatadog.{Mapper, DatadogSpan, SpanUtils}
  alias OpentelemetryDatadog.V05.Encoder

  @mappers [
    {Mapper.LiftError, []},
    {Mapper.InferDatadogFields, []}
  ]

  @impl true
  def init(config) do
    protocol = Keyword.get(config, :protocol, :v05)
    
    state = %State{
      host: Keyword.fetch!(config, :host),
      port: Keyword.fetch!(config, :port),
      container_id: SpanUtils.get_container_id(),
      protocol: protocol
    }

    {:ok, state}
  end

  @impl true
  def export(:traces, tid, resource, %{protocol: :v05} = state) do
    resource = resource(resource)
    resource_attrs = attributes(Keyword.fetch!(resource, :attributes))

    data = %{
      resource: resource,
      resource_attrs: resource_attrs,
      resource_map: Keyword.fetch!(resource_attrs, :map)
    }

    formatted =
      :ets.foldl(
        fn span, acc ->
          case format_span_v05(span, data, state) do
            [] -> acc
            span_data -> [span_data | acc]
          end
        end,
        [],
        tid
      )

    count = Enum.count(formatted)
    
    # Emit telemetry start event
    start_time = System.monotonic_time()
    system_time = System.system_time()
    endpoint = "/v0.5/traces"
    
    :telemetry.execute(
      [:opentelemetry_datadog, :export, :start],
      %{system_time: system_time, span_count: count},
      %{endpoint: endpoint, host: state.host, port: state.port}
    )

    try do
      headers = @headers ++ [{"X-Datadog-Trace-Count", count}]
      headers = headers ++ List.wrap(if state.container_id, do: {"Datadog-Container-ID", state.container_id})

      response =
        formatted
        |> encode_v05()
        |> push_v05(headers, state)

      duration = System.monotonic_time() - start_time

      case response do
        {:ok, %{status: status_code} = resp} when status_code in 200..299 ->
          # Emit success telemetry event
          :telemetry.execute(
            [:opentelemetry_datadog, :export, :stop],
            %{duration: duration, status_code: status_code, span_count: count},
            %{endpoint: endpoint, host: state.host, port: state.port}
          )
          
          # v0.5 API response handling
          case resp.body do
            %{"rate_by_service" => _rate_by_service} -> nil
            _ -> nil
          end

        {:ok, %{status: status_code}} ->
          # Emit error telemetry event for HTTP errors
          :telemetry.execute(
            [:opentelemetry_datadog, :export, :error],
            %{span_count: count},
            %{
              error: "HTTP error: #{status_code}",
              endpoint: endpoint,
              host: state.host,
              port: state.port,
              retry: false
            }
          )
          
          IO.inspect({:trace_error_response_v05, response})

        {:error, error} ->
          # Emit error telemetry event for request errors
          :telemetry.execute(
            [:opentelemetry_datadog, :export, :error],
            %{span_count: count},
            %{
              error: inspect(error),
              endpoint: endpoint,
              host: state.host,
              port: state.port,
              retry: true
            }
          )
          
          IO.inspect({:trace_error_response_v05, {:error, error}})
      end
    rescue
      exception ->
        # Emit exception telemetry event
        :telemetry.execute(
          [:opentelemetry_datadog, :export, :exception],
          %{span_count: count},
          %{
            kind: exception.__struct__,
            reason: Exception.message(exception),
            stacktrace: __STACKTRACE__,
            endpoint: endpoint,
            host: state.host,
            port: state.port
          }
        )
        
        reraise exception, __STACKTRACE__
    end

    :ok
  end

  def export(:traces, tid, resource, state) do
    # Fallback to original behavior for non-v05 protocols
    OpentelemetryDatadog.Exporter.export(:traces, tid, resource, state)
  end

  def export(:metrics, _tid, _resource, _state) do
    :ok
  end

  @impl true
  def shutdown(_state) do
    :ok
  end

  def encode_v05(data) do
    case Encoder.encode(data) do
      {:ok, encoded} -> encoded
      {:error, error} -> 
        IO.inspect({:encoding_error_v05, error})
        raise "Failed to encode spans for v0.5: #{inspect(error)}"
    end
  end

  def push_v05(body, headers, %State{host: host, port: port}) do
    Req.put(
      "#{host}:#{port}/v0.5/traces",
      body: body,
      headers: headers,
      retry: :transient,
      retry_delay: &retry_delay/1,
      retry_log_level: false
    )
  end

  defp retry_delay(attempt) do
    # 3 retries with 10% jitter, example delays: 484ms, 945ms, 1908ms
    trunc(Integer.pow(2, attempt) * 500 * (1 - 0.1 * :rand.uniform()))
  end

  def format_span_v05(span_record, data, %{}) do
    span = span(span_record)
    attributes = attributes(Keyword.fetch!(span, :attributes))

    state =
      %{
        events: :otel_events.list(Keyword.fetch!(span, :events))
      }
      |> Map.merge(data)

    dd_span_kind = Atom.to_string(Keyword.fetch!(span, :kind))

    start_time_nanos = :opentelemetry.timestamp_to_nano(Keyword.fetch!(span, :start_time))
    end_time_nanos = :opentelemetry.timestamp_to_nano(Keyword.fetch!(span, :end_time))

    meta =
      Keyword.fetch!(attributes, :map)
      |> Map.put(:"span.kind", dd_span_kind)
      |> Enum.map(fn
        {k, v} -> {k, SpanUtils.term_to_string(v)}
      end)
      |> Enum.into(%{})
      |> Map.put(:env, SpanUtils.get_env_from_resource(data))

    name = Keyword.fetch!(span, :name)

    dd_span = %DatadogSpan{
      trace_id: SpanUtils.id_to_datadog_id(Keyword.fetch!(span, :trace_id)),
      span_id: Keyword.fetch!(span, :span_id),
      parent_id: SpanUtils.nil_if_undefined(Keyword.fetch!(span, :parent_span_id)),
      name: name,
      start: start_time_nanos,
      duration: end_time_nanos - start_time_nanos,
      meta: meta,
      metrics: %{},
      # Default values for v0.5 required fields
      service: SpanUtils.get_service_from_resource(data),
      resource: SpanUtils.get_resource_from_span(name, meta),
      type: SpanUtils.get_type_from_span(dd_span_kind),
      error: 0
    }

    span = apply_mappers(dd_span, span, state)

    case span do
      nil ->
        []

      span ->
        # Convert to v0.5 format
        span_map = %{
          trace_id: span.trace_id,
          span_id: span.span_id,
          parent_id: span.parent_id,
          name: span.name,
          service: span.service || "unknown-service",
          resource: span.resource || span.name,
          type: span.type || "custom",
          start: span.start,
          duration: span.duration,
          error: span.error || 0,
          meta: span.meta || %{},
          metrics: span.metrics || %{}
        }
        
        span_map
    end
  end

  def apply_mappers(span, otel_span, state) do
    apply_mappers(@mappers, span, otel_span, state)
  end

  def apply_mappers([{mapper, mapper_arg} | rest], span, otel_span, state) do
    case mapper.map(span, otel_span, mapper_arg, state) do
      {:next, span} -> apply_mappers(rest, span, otel_span, state)
      nil -> nil
    end
  end

  def apply_mappers([], span, _, _), do: span
end
