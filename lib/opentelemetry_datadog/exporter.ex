defmodule OpentelemetryDatadog.Exporter do
  @moduledoc """
  Datadog v0.5 traces exporter for OpenTelemetry.

  This exporter sends traces to the Datadog Agent using the /v0.5/traces endpoint
  with MessagePack serialization. It maintains compatibility with the existing
  exporter while providing v0.5 specific functionality.
  """

  @behaviour :otel_exporter

  require Logger
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

  alias OpentelemetryDatadog.{Mapper, Encoder, Formatter}
  alias OpentelemetryDatadog.Utils.Span

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
      container_id: Span.get_container_id(),
      protocol: protocol
    }

    {:ok, state}
  end

  @impl true
  def export(:traces, tid, resource, %{protocol: :v05} = state) do
    data = Formatter.build_resource_data(resource)

    formatted =
      :ets.foldl(
        fn span, acc ->
          case format_span_v05(span, data, state) do
            [] ->
              Logger.warning("Span skipped: #{inspect(span)}")
              acc

            span_data ->
              [span_data | acc]
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
      headers = build_headers(count, state.container_id)

      response =
        formatted
        |> encode_v05()
        |> push_v05(headers, state)

      duration = System.monotonic_time() - start_time

      case response do
        {:ok, %{status: status_code}} when status_code in 200..299 ->
          # Emit success telemetry event
          :telemetry.execute(
            [:opentelemetry_datadog, :export, :stop],
            %{duration: duration, status_code: status_code, span_count: count},
            %{endpoint: endpoint, host: state.host, port: state.port}
          )

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

          Logger.error("Trace export failed with HTTP error", response: response)

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

          Logger.error("Trace export failed with request error", error: error)
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
    # For non-v05 protocols, we still use the v05 implementation as default
    export(:traces, tid, resource, Map.put(state, :protocol, :v05))
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
      {:ok, encoded} ->
        encoded

      {:error, error} ->
        Logger.error("Failed to encode spans for v0.5", error: error)
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

  def format_span_v05(span_record, data, state) do
    processing_state = Formatter.build_processing_state(span_record, data)

    dd_span = Formatter.format_span_base(span_record, data, state)

    dd_span_kind = Atom.to_string(Keyword.fetch!(Formatter.get_span(span_record), :kind))

    dd_span = %{
      dd_span
      | meta: Map.put(dd_span.meta, :env, Span.get_env_from_resource(data)),
        service: Span.get_service_from_resource(data),
        resource: Span.get_resource_from_span(dd_span.name, dd_span.meta),
        type: Span.get_type_from_span(dd_span_kind),
        error: 0
    }

    span = apply_mappers(dd_span, Formatter.get_span(span_record), processing_state)

    case span do
      nil ->
        []

      span ->
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
    Formatter.apply_mappers(@mappers, span, otel_span, state)
  end

  @doc """
  Builds common headers for Datadog trace requests.
  """
  @spec build_headers(non_neg_integer(), String.t() | nil) :: [{String.t(), String.t()}]
  def build_headers(trace_count, container_id \\ nil) do
    base_headers = [
      {"Content-Type", "application/msgpack"},
      {"Datadog-Meta-Lang", "elixir"},
      {"Datadog-Meta-Lang-Version", System.version()},
      {"Datadog-Meta-Tracer-Version", Application.spec(:opentelemetry_datadog)[:vsn]},
      {"X-Datadog-Trace-Count", trace_count}
    ]

    container_headers =
      if container_id, do: [{"Datadog-Container-ID", container_id}], else: []

    base_headers ++ container_headers
  end

  @doc """
  Calculates retry delay with exponential backoff and jitter.

  Uses 3 retries with 10% jitter.
  Example delays: 484ms, 945ms, 1908ms
  """
  @spec retry_delay(non_neg_integer()) :: non_neg_integer()
  def retry_delay(attempt) do
    trunc(Integer.pow(2, attempt) * 500 * (1 - 0.1 * :rand.uniform()))
  end
end
