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
      :timeout_ms,
      :connect_timeout_ms,
      :protocol
    ]
  end

  alias OpentelemetryDatadog.{Mapper, Encoder, Formatter}
  alias OpentelemetryDatadog.Utils.Span
  alias Monitor.OTelTracer

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
      timeout_ms: Keyword.get(config, :timeout_ms, 2000),
      connect_timeout_ms: Keyword.get(config, :connect_timeout_ms, 500),
      protocol: protocol
    }

    {:ok, state}
  end

  @impl true
  def export(:traces, tid, resource, state) do
    OTelTracer.span(
      "datadog.export",
      [
        kind: :client,
        attributes: %{
          "datadog.endpoint" => "/v0.5/traces",
          "datadog.host" => state.host,
          "datadog.port" => state.port,
          "export.protocol" => "v0.5"
        }
      ],
      fn ->
        endpoint = "/v0.5/traces"
        start_metadata = %{endpoint: endpoint, host: state.host, port: state.port}

        :telemetry.span(
          [:opentelemetry_datadog, :export],
          start_metadata,
          fn ->
            OTelTracer.add_event("export.started")

            data =
              OTelTracer.span("datadog.build_resource_data", fn ->
                Formatter.build_resource_data(resource)
              end)

            {formatted, span_count} =
              OTelTracer.span(
                "datadog.format_spans",
                [
                  attributes: %{"operation" => "format_spans"}
                ],
                fn ->
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
                  OTelTracer.set_attribute("formatted.span_count", count)
                  {formatted, count}
                end
              )

            headers = build_headers(span_count, state.container_id)
            OTelTracer.set_attribute("export.span_count", span_count)

            response =
              OTelTracer.span(
                "datadog.http_request",
                [
                  kind: :client,
                  attributes: %{
                    "http.method" => "POST",
                    "http.url" => "http://#{state.host}:#{state.port}/v0.5/traces",
                    "http.request_content_length" => byte_size(encode_v05(formatted))
                  }
                ],
                fn ->
                  formatted
                  |> encode_v05()
                  |> push_v05(headers, state)
                end
              )

            stop_metadata = Map.merge(start_metadata, %{span_count: span_count})

            case response do
              {:ok, %{status: status_code}} when status_code in 200..299 ->
                OTelTracer.add_event("export.success", %{
                  "http.status_code" => status_code,
                  "spans.exported" => span_count
                })

                OTelTracer.set_status(:ok)
                OTelTracer.set_attribute("http.response.status_code", status_code)
                {response, Map.put(stop_metadata, :status_code, status_code)}

              {:ok, %{status: status_code}} ->
                Logger.error("Trace export failed with HTTP error", response: response)

                OTelTracer.add_event("export.http_error", %{
                  "http.status_code" => status_code,
                  "error.type" => "http_error"
                })

                OTelTracer.set_status(:error, "HTTP error: #{status_code}")
                OTelTracer.set_attribute("http.response.status_code", status_code)

                error_metadata =
                  Map.merge(stop_metadata, %{
                    error: "HTTP error: #{status_code}",
                    retry: false,
                    status_code: status_code
                  })

                {response, error_metadata}

              {:error, error} ->
                Logger.error("Trace export failed with request error", error: error)

                OTelTracer.add_event("export.request_error", %{
                  "error.type" => "request_error",
                  "error.message" => inspect(error)
                })

                OTelTracer.record_exception(error)
                OTelTracer.set_status(:error, "Request failed: #{inspect(error)}")

                error_metadata =
                  Map.merge(stop_metadata, %{
                    error: "Request error: #{inspect(error)}",
                    retry: false
                  })

                {response, error_metadata}
            end
          end
        )

        :ok
      end
    )
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
    url =
      if String.starts_with?(host, ["http://", "https://"]) do
        "#{host}:#{port}/v0.5/traces"
      else
        # Default to http for backward compatibility with local agent
        "http://#{host}:#{port}/v0.5/traces"
      end

    Req.put(
      url: url,
      body: body,
      headers: headers,
      decode_json: false,
      decode_body: false
    )
  end

  def format_span_v05(span, resource_data, _state) do
    span
    |> run_mappers(@mappers, [])
    |> case do
      # Skip spans that couldn't be processed
      %{skip: true} -> []
      span_data -> [span_data]
    end
    |> Enum.map(&Map.merge(&1, resource_data))
  end

  defp run_mappers(span, [], _acc) do
    span
  end

  defp run_mappers(span, [{mapper, config} | rest], acc) do
    case mapper.map(span, config) do
      %{skip: true} = span_data -> span_data
      span_data -> run_mappers(span_data, rest, acc)
    end
  end

  defp build_headers(span_count, container_id) do
    headers = [
      {"Content-Type", "application/msgpack"},
      {"Datadog-Meta-Tracer-Version", "opentelemetry_elixir"},
      {"X-Datadog-Trace-Count", to_string(span_count)}
    ]

    case container_id do
      nil -> headers
      id -> [{"Datadog-Container-ID", id} | headers]
    end
  end
end
