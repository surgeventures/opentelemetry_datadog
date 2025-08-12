defprotocol OpentelemetryDatadog.SpanProcessor do
  @moduledoc """
  Protocol for processing OpenTelemetry spans into Datadog format.

  This protocol allows different exporters to implement their own
  span processing logic while maintaining a consistent interface.
  """

  @doc """
  Processes an OpenTelemetry span into the appropriate format for the exporter.

  Returns the processed span data or nil if the span should be filtered out.
  """
  @spec process_span(t(), any(), map(), map()) :: any() | nil
  def process_span(processor, span_record, data, state)
end

defmodule OpentelemetryDatadog.SpanProcessor.V05 do
  @moduledoc """
  Span processor for v0.5 Datadog traces format.
  """

  defstruct []

  alias OpentelemetryDatadog.{Utils.Exporter, Utils.Span}

  defimpl OpentelemetryDatadog.SpanProcessor do
    def process_span(_processor, span_record, data, state) do
      processing_state = Exporter.build_processing_state(span_record, data)

      dd_span = Exporter.format_span_base(span_record, data, state)
      dd_span_kind = Atom.to_string(Keyword.fetch!(Exporter.get_span(span_record), :kind))

      dd_span = %{
        dd_span
        | meta: Map.put(dd_span.meta, :env, Span.get_env_from_resource(data)),
          service: Span.get_service_from_resource(data),
          resource: Span.get_resource_from_span(dd_span.name, dd_span.meta),
          type: Span.get_type_from_span(dd_span_kind),
          error: 0
      }

      case Exporter.apply_mappers(
             state.mappers,
             dd_span,
             Exporter.get_span(span_record),
             processing_state
           ) do
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
  end
end
