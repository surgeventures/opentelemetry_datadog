defmodule OpentelemetryDatadog.Formatter do
  @moduledoc """
  Formats OpenTelemetry spans into Datadog span data structures.

  Takes OpenTelemetry spans and converts them into DatadogSpan structures
  that can be encoded and sent to the Datadog Agent API.
  """

  require Record
  @deps_dir Mix.Project.deps_path()
  Record.defrecord(
    :span,
    Record.extract(:span, from: "#{@deps_dir}/opentelemetry/include/otel_span.hrl")
  )

  Record.defrecord(
    :attributes,
    Record.extract(:attributes, from: "#{@deps_dir}/opentelemetry_api/src/otel_attributes.erl")
  )

  Record.defrecord(
    :resource,
    Record.extract(:resource, from: "#{@deps_dir}/opentelemetry/src/otel_resource.erl")
  )

  alias OpentelemetryDatadog.{DatadogSpan, Utils.Span}

  @type mapper_config :: {module(), any()}
  @type otel_span :: Keyword.t()
  @type span_data :: map()
  @type span_record :: tuple()

  @doc """
  Formats an OpenTelemetry span into a DatadogSpan structure.

  This is the base formatting logic that converts OpenTelemetry spans
  into the internal DatadogSpan representation.
  """
  @spec format_span_base(span_record(), span_data(), map()) :: DatadogSpan.t()
  def format_span_base(span_record, _data, _state) do
    span = span(span_record)
    attributes_record = Keyword.fetch!(span, :attributes)
    attributes_data = attributes(attributes_record)

    dd_span_kind = Atom.to_string(Keyword.fetch!(span, :kind))
    start_time_nanos = :opentelemetry.timestamp_to_nano(Keyword.fetch!(span, :start_time))
    end_time_nanos = :opentelemetry.timestamp_to_nano(Keyword.fetch!(span, :end_time))

    meta =
      Keyword.fetch!(attributes_data, :map)
      |> Map.put(:"span.kind", dd_span_kind)
      |> Enum.map(fn {k, v} -> {k, Span.term_to_string(v)} end)
      |> Enum.into(%{})

    name = Keyword.fetch!(span, :name)

    %DatadogSpan{
      trace_id: Span.id_to_datadog_id(Keyword.fetch!(span, :trace_id)),
      span_id: Keyword.fetch!(span, :span_id),
      parent_id: Span.nil_if_undefined(Keyword.fetch!(span, :parent_span_id)),
      name: name,
      start: start_time_nanos,
      duration: end_time_nanos - start_time_nanos,
      meta: meta,
      metrics: %{}
    }
  end

  @doc """
  Applies a list of mappers to transform a DatadogSpan.

  Each mapper can either return {:next, updated_span} to continue processing
  or nil to filter out the span entirely.
  """
  @spec apply_mappers([mapper_config()], DatadogSpan.t(), otel_span(), map()) ::
          DatadogSpan.t() | nil
  def apply_mappers(mappers, span, otel_span, state) do
    apply_mappers_recursive(mappers, span, otel_span, state)
  end

  defp apply_mappers_recursive([{mapper, mapper_arg} | rest], span, otel_span, state) do
    case mapper.map(span, otel_span, mapper_arg, state) do
      {:next, span} -> apply_mappers_recursive(rest, span, otel_span, state)
      nil -> nil
    end
  end

  defp apply_mappers_recursive([], span, _, _), do: span

  @doc """
  Builds resource data structure from OpenTelemetry resource.
  """
  @spec build_resource_data(tuple()) :: map()
  def build_resource_data(resource) do
    resource_data = resource(resource)
    attributes_record = Keyword.fetch!(resource_data, :attributes)
    attributes_data = attributes(attributes_record)

    %{
      resource: resource_data,
      resource_attrs: attributes_data,
      resource_map: Keyword.fetch!(attributes_data, :map)
    }
  end

  @doc """
  Accessor function for span record.
  """
  @spec get_span(span_record()) :: otel_span()
  def get_span(span_record), do: span(span_record)
end
