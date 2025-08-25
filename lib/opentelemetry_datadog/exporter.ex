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
      :container_id
    ]
  end

  alias OpentelemetryDatadog.{Mapper, Encoder, Formatter}
  alias OpentelemetryDatadog.Utils.Span

  @mappers [
    {Mapper.LiftError, []}
  ]

  @impl true
  def init(config) do
    state = %State{
      host: Keyword.fetch!(config, :host),
      port: Keyword.fetch!(config, :port),
      container_id: Span.get_container_id()
    }

    {:ok, state}
  end

  @impl true
  def export(:traces, tid, resource, state) do
    endpoint = "/v0.5/traces"
    start_metadata = %{endpoint: endpoint, host: state.host, port: state.port}

    :telemetry.span(
      [:opentelemetry_datadog, :export],
      start_metadata,
      fn ->
        formatted =
          :ets.foldl(
            fn span, acc ->
              case format_span(span, resource, state) do
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
        headers = build_headers(count, state.container_id)

        response =
          formatted
          |> encode()
          |> push(headers, state)

        stop_metadata = Map.merge(start_metadata, %{span_count: count})

        case response do
          {:ok, %{status: status_code}} when status_code in 200..299 ->
            {response, Map.put(stop_metadata, :status_code, status_code)}

          {:ok, %{status: status_code}} ->
            Logger.error("Trace export failed with HTTP error", response: response)

            error_metadata =
              Map.merge(stop_metadata, %{
                error: "HTTP error: #{status_code}",
                retry: false,
                status_code: status_code
              })

            {response, error_metadata}

          {:error, error} ->
            Logger.error("Trace export failed with request error", error: error)

            error_metadata =
              Map.merge(stop_metadata, %{
                error: inspect(error),
                retry: true
              })

            {response, error_metadata}
        end
      end
    )

    :ok
  end

  def export(:metrics, _tid, _resource, _state) do
    :ok
  end

  @impl true
  def shutdown(_state) do
    :ok
  end

  def encode(data) do
    case Encoder.encode(data) do
      {:ok, encoded} ->
        encoded

      {:error, error} ->
        Logger.error("Failed to encode spans", error: error)
        raise "Failed to encode spans: #{inspect(error)}"
    end
  end

  def push(body, headers, %State{host: host, port: port}) do
    Req.put(
      "#{host}:#{port}/v0.5/traces",
      body: body,
      headers: headers,
      retry: :transient,
      retry_delay: &retry_delay/1,
      retry_log_level: false
    )
  end

  def format_span(span_record, data, state) do
    dd_span = Formatter.format_span(span_record, data, state)
    span = apply_mappers(dd_span, Formatter.get_span(span_record), data)
    span || []
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
      {"Datadog-Meta-Tracer-Version",
       Application.spec(:opentelemetry_datadog)[:vsn] || "unknown"},
      {"X-Datadog-Trace-Count", to_string(trace_count)}
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
