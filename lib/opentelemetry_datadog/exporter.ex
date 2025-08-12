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
<<<<<<< HEAD
      :timeout_ms,
      :connect_timeout_ms
    ]
  end

  alias OpentelemetryDatadog.{Mapper, SpanUtils}
  alias OpentelemetryDatadog.Core.Retry
=======
      :protocol
    ]
  end

  alias OpentelemetryDatadog.{Mapper, SpanUtils, Encoder}
>>>>>>> revert-3-revert-2-env-based-configuration
  alias OpentelemetryDatadog.Exporter.Shared
  alias OpentelemetryDatadog.SpanProcessor

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
      timeout_ms: Keyword.get(config, :timeout_ms, 2000),
      connect_timeout_ms: Keyword.get(config, :connect_timeout_ms, 500),
      protocol: protocol
    }

    {:ok, state}
  end

  @impl true
  def export(:traces, tid, resource, %{protocol: :v05} = state) do
    data = Shared.build_resource_data(resource)

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
      headers = Shared.build_headers(count, state.container_id)

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

        error_response ->
          handle_export_failure(error_response, formatted, state)
      end
    rescue
      exception ->
        # Handle exceptions as export failures
        handle_export_failure({:exception, exception}, formatted, state)
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

  def push_v05(body, headers, %State{
        host: host,
        port: port,
        timeout_ms: timeout_ms,
        connect_timeout_ms: connect_timeout_ms
      }) do
    Logger.debug(
      "Datadog export request: #{host}:#{port}/v0.5/traces (timeout: #{timeout_ms}ms, connect_timeout: #{connect_timeout_ms}ms)"
    )

    Retry.with_retry_attempt(
      fn attempt ->
        result =
          Req.put(
            "http://#{host}:#{port}/v0.5/traces",
            body: body,
            headers: headers,
            retry: false,
            receive_timeout: timeout_ms,
            connect_options: [timeout: connect_timeout_ms]
          )

        case result do
          {:error, %Mint.TransportError{reason: :timeout}} ->
            emit_timeout_telemetry(timeout_ms, attempt)
            result

          {:error, %Mint.HTTPError{reason: :timeout}} ->
            emit_timeout_telemetry(timeout_ms, attempt)
            result

          {:error, :timeout} ->
            emit_timeout_telemetry(timeout_ms, attempt)
            result

          {:error, %Mint.TransportError{reason: :connect_timeout}} ->
            emit_connect_timeout_telemetry(connect_timeout_ms, attempt)
            result

          {:error, %Mint.HTTPError{reason: :connect_timeout}} ->
            emit_connect_timeout_telemetry(connect_timeout_ms, attempt)
            result

          _ ->
            result
        end
      end,
      host: host,
      port: port
    )
  end

  defp emit_timeout_telemetry(timeout_ms, attempt) do
    :telemetry.execute(
      [:opentelemetry_datadog, :export, :timeout],
      %{count: 1},
      %{timeout_ms: timeout_ms, attempt: attempt}
    )
  end

  defp emit_connect_timeout_telemetry(connect_timeout_ms, attempt) do
    :telemetry.execute(
      [:opentelemetry_datadog, :export, :connect_timeout],
      %{count: 1},
      %{connect_timeout_ms: connect_timeout_ms, attempt: attempt}
    )
  end

  # Handles export failures gracefully by logging appropriate messages and emitting telemetry.
  # This function categorizes different types of failures and emits specific telemetry events
  # to help with monitoring and debugging agent connectivity issues.
  defp handle_export_failure(response, formatted_spans, state) do
    span_count = length(formatted_spans)
    trace_ids = extract_trace_ids(formatted_spans)
    maybe_set_trace_metadata(trace_ids)

    case categorize_failure(response) do
      {:agent_unavailable, reason} ->
        log_failure_with_trace_ids(
          "Datadog agent unavailable: #{reason}. Dropping #{span_count} spans.",
          trace_ids,
          state
        )

        emit_failure_telemetry(:agent_unavailable, reason, span_count, trace_ids, state)

      {:network_error, reason} ->
        log_failure_with_trace_ids(
          "Network error exporting to Datadog: #{reason}. Dropping #{span_count} spans.",
          trace_ids,
          state
        )

        emit_failure_telemetry(:network_error, reason, span_count, trace_ids, state)

      {:http_error, status, reason} ->
        log_failure_with_trace_ids(
          "HTTP error #{status} exporting to Datadog: #{reason}. Dropping #{span_count} spans.",
          trace_ids,
          state
        )

        emit_failure_telemetry(:http_error, "#{status}: #{reason}", span_count, trace_ids, state)

      {:unknown_error, reason} ->
        log_failure_with_trace_ids(
          "Unknown error exporting to Datadog: #{reason}. Dropping #{span_count} spans.",
          trace_ids,
          state
        )

        emit_failure_telemetry(:unknown_error, reason, span_count, trace_ids, state)
    end
  end

  defp log_failure_with_trace_ids(message, trace_ids, state) do
    destination = if state, do: " destination=#{state.host}:#{state.port}", else: ""

    case trace_ids do
      [] ->
        Logger.warning("#{message}#{destination}")

      [single_trace_id] ->
        Logger.warning("#{message}#{destination} [trace_id: #{single_trace_id}]")

      multiple_trace_ids when length(multiple_trace_ids) <= 5 ->
        trace_ids_str = Enum.join(multiple_trace_ids, ", ")
        Logger.warning("#{message}#{destination} [trace_ids: #{trace_ids_str}]")

      multiple_trace_ids ->
        first_few = Enum.take(multiple_trace_ids, 3)
        remaining_count = length(multiple_trace_ids) - 3
        trace_ids_str = Enum.join(first_few, ", ")

        Logger.warning(
          "#{message}#{destination} [trace_ids: #{trace_ids_str} and #{remaining_count} more]"
        )
    end
  end

  defp maybe_set_trace_metadata(trace_ids) do
    case trace_ids do
      [first_trace_id | _] -> Logger.metadata(trace_id: first_trace_id)
      [] -> :ok
    end
  end

  # Categorizes different types of export failures for appropriate handling.
  defp categorize_failure(response) do
    case response do
      # Exception handling
      {:exception, exception} ->
        {:unknown_error, "Exception: #{Exception.message(exception)}"}
      # Connection refused - agent is down
      {:error, %Mint.TransportError{reason: :econnrefused}} ->
        {:agent_unavailable, "connection refused"}

      {:error, :econnrefused} ->
        {:agent_unavailable, "connection refused"}

      # Connection reset by peer - agent closed connection
      {:error, %Mint.TransportError{reason: :econnreset}} ->
        {:agent_unavailable, "connection reset by peer"}

      {:error, :econnreset} ->
        {:agent_unavailable, "connection reset by peer"}

      # Connection closed - agent closed connection abruptly
      {:error, %Mint.TransportError{reason: :closed}} ->
        {:agent_unavailable, "connection closed by agent"}

      {:error, :closed} ->
        {:agent_unavailable, "connection closed by agent"}

      # Host/network unreachable - agent or network issues
      {:error, %Mint.TransportError{reason: :ehostunreach}} ->
        {:agent_unavailable, "host unreachable"}

      {:error, :ehostunreach} ->
        {:agent_unavailable, "host unreachable"}

      {:error, %Mint.TransportError{reason: :enetunreach}} ->
        {:network_error, "network unreachable"}

      {:error, :enetunreach} ->
        {:network_error, "network unreachable"}

      # Network is down
      {:error, %Mint.TransportError{reason: :enetdown}} ->
        {:network_error, "network is down"}

      {:error, :enetdown} ->
        {:network_error, "network is down"}

      # DNS resolution failures
      {:error, %Mint.TransportError{reason: :nxdomain}} ->
        {:network_error, "DNS resolution failed"}

      {:error, :nxdomain} ->
        {:network_error, "DNS resolution failed"}

      # Timeout errors
      {:error, %Mint.TransportError{reason: :timeout}} ->
        {:network_error, "connection timeout"}

      {:error, %Mint.HTTPError{reason: :timeout}} ->
        {:network_error, "HTTP timeout"}

      {:error, :timeout} ->
        {:network_error, "timeout"}

      # HTTP status errors
      {:ok, %{status: status} = resp} when status >= 400 ->
        body = Map.get(resp, :body, "")
        reason = if is_binary(body) and String.length(body) > 0, do: body, else: "HTTP #{status}"
        {:http_error, status, reason}

      # Other errors
      {:error, reason} when is_atom(reason) ->
        {:unknown_error, Atom.to_string(reason)}

      {:error, reason} when is_binary(reason) ->
        {:unknown_error, reason}

      {:error, %{__struct__: struct} = error} ->
        {:unknown_error, "#{struct}: #{inspect(error)}"}

      other ->
        {:unknown_error, inspect(other)}
    end
  end

  defp emit_failure_telemetry(failure_type, reason, span_count, trace_ids, state) do
    :telemetry.execute(
      [:opentelemetry_datadog, :export, :failure],
      %{span_count: span_count, trace_count: length(trace_ids)},
      %{
        reason: reason,
        failure_type: failure_type,
        trace_ids: trace_ids,
        host: state.host,
        port: state.port
      }
    )
  end

  defp extract_trace_ids(formatted_spans) do
    formatted_spans
    |> List.flatten()
    |> Enum.map(fn span_data ->
      case span_data do
        %{trace_id: trace_id} -> trace_id
        span when is_map(span) -> Map.get(span, :trace_id)
        _ -> nil
      end
    end)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

  def format_span_v05(span_record, data, state) do
    processing_state = Shared.build_processing_state(span_record, data)

    dd_span = Shared.format_span_base(span_record, data, state)

    dd_span_kind = Atom.to_string(Keyword.fetch!(span(span_record), :kind))

    dd_span = %{
      dd_span
      | meta: Map.put(dd_span.meta, :env, SpanUtils.get_env_from_resource(data)),
        service: SpanUtils.get_service_from_resource(data),
        resource: SpanUtils.get_resource_from_span(dd_span.name, dd_span.meta),
        type: SpanUtils.get_type_from_span(dd_span_kind),
        error: 0
    }

    span = apply_mappers(dd_span, span(span_record), processing_state)

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

  def format_span_with_processor(span_record, data, state) do
    processor = %SpanProcessor.V05{}
    processing_state = Map.put(state, :mappers, @mappers)
    SpanProcessor.process_span(processor, span_record, data, processing_state)
  end

  def apply_mappers(span, otel_span, state) do
    Shared.apply_mappers(@mappers, span, otel_span, state)
  end
end
