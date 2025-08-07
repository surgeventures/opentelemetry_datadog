defmodule OpentelemetryDatadog.Exporter do
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
      :container_id
    ]
  end

  alias OpentelemetryDatadog.{Mapper, SpanUtils, Retry}
  alias OpentelemetryDatadog.Exporter.Shared
  alias OpentelemetryDatadog.SpanProcessor

  @mappers [
    {Mapper.LiftError, []},
    {Mapper.InferDatadogFields, []}
    # {Mapper.AlwaysSample, []},
  ]

  @impl true
  def init(config) do
    state = %State{
      host: Keyword.fetch!(config, :host),
      port: Keyword.fetch!(config, :port),
      container_id: SpanUtils.get_container_id()
    }

    {:ok, state}
  end

  @impl true
  def export(:traces, tid, resource, %{container_id: container_id} = state) do
    data = Shared.build_resource_data(resource)

    formatted =
      :ets.foldl(
        fn span, acc ->
          [format_span(span, data, state) | acc]
        end,
        [],
        tid
      )

    count = Enum.count(formatted)
    headers = Shared.build_headers(count, container_id)

    response =
      formatted
      |> encode()
      |> push(headers, state)

    case response do
      {:ok, %{status: 200} = resp} ->
        # https://github.com/DataDog/datadog-agent/issues/3031
        %{"rate_by_service" => _rate_by_service} = resp.body
        nil

      _ ->
        IO.inspect({:trace_error_response, response})
    end

    :ok
  end

  def export(:metrics, _tid, _resource, _state) do
    :ok
  end

  @impl true
  def shutdown(_state) do
    :ok
  end

  defp encode(data) do
    data
    |> Shared.deep_remove_nils()
    |> Msgpax.pack!(data)
  end

  def push(body, headers, %State{host: host, port: port}) do
    Retry.with_retry(fn ->
      Req.put(
        "#{host}:#{port}/v0.4/traces",
        body: body,
        headers: headers,
        retry: false
      )
    end)
  end

  def format_span(span_record, data, state) do
    processing_state = Shared.build_processing_state(span_record, data)

    dd_span = Shared.format_span_base(span_record, data, state)

    dd_span = %{dd_span | meta: Map.put(dd_span.meta, :env, "hans-local-testing")}

    span = apply_mappers(dd_span, span(span_record), processing_state)

    case span do
      nil ->
        []

      span ->
        span = Map.delete(span, :__struct__)
        [span]
    end
  end

  def format_span_with_processor(span_record, data, state) do
    processor = %SpanProcessor.V04{}
    processing_state = Map.put(state, :mappers, @mappers)
    SpanProcessor.process_span(processor, span_record, data, processing_state)
  end

  def apply_mappers(span, otel_span, state) do
    Shared.apply_mappers(@mappers, span, otel_span, state)
  end
end
