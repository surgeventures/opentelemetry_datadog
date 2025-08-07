defmodule OpentelemetryDatadog.Exporter.Shared do
  @moduledoc """
  Shared utilities for OpenTelemetry Datadog exporters.

  Contains common functionality used by both v0.4 and v0.5 exporters
  to eliminate code duplication.
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

  alias OpentelemetryDatadog.{DatadogSpan, SpanUtils}

  @type mapper_config :: {module(), any()}
  @type otel_span :: Keyword.t()
  @type span_data :: map()

  @doc """
  Accessor function for span record.
  """
  def get_span(span_record), do: span(span_record)

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
  Formats an OpenTelemetry span into a DatadogSpan structure.

  This is the base formatting logic shared between exporters.
  Version-specific formatting should be handled by the caller.
  """
  @spec format_span_base(any(), span_data(), map()) :: DatadogSpan.t()
  def format_span_base(span_record, _data, _state) do
    span = span(span_record)
    attributes = attributes(Keyword.fetch!(span, :attributes))

    dd_span_kind = Atom.to_string(Keyword.fetch!(span, :kind))
    start_time_nanos = :opentelemetry.timestamp_to_nano(Keyword.fetch!(span, :start_time))
    end_time_nanos = :opentelemetry.timestamp_to_nano(Keyword.fetch!(span, :end_time))

    meta =
      Keyword.fetch!(attributes, :map)
      |> Map.put(:"span.kind", dd_span_kind)
      |> Enum.map(fn {k, v} -> {k, SpanUtils.term_to_string(v)} end)
      |> Enum.into(%{})

    name = Keyword.fetch!(span, :name)

    %DatadogSpan{
      trace_id: SpanUtils.id_to_datadog_id(Keyword.fetch!(span, :trace_id)),
      span_id: Keyword.fetch!(span, :span_id),
      parent_id: SpanUtils.nil_if_undefined(Keyword.fetch!(span, :parent_span_id)),
      name: name,
      start: start_time_nanos,
      duration: end_time_nanos - start_time_nanos,
      meta: meta,
      metrics: %{}
    }
  end

  @doc """
  Builds the processing state for span formatting.

  Combines OpenTelemetry events with resource data.
  """
  @spec build_processing_state(any(), span_data()) :: map()
  def build_processing_state(span_record, data) do
    span = span(span_record)

    %{
      events: :otel_events.list(Keyword.fetch!(span, :events))
    }
    |> Map.merge(data)
  end

  @doc """
  Calculates retry delay with exponential backoff and equal jitter.

  Uses fixed base delays: 100ms, 200ms, 400ms with equal jitter.
  This function is kept for backward compatibility with Req's retry mechanism.
  For new implementations, use OpentelemetryDatadog.Core.Retry.retry_delay/1.
  """
  @spec retry_delay(non_neg_integer()) :: non_neg_integer()
  def retry_delay(attempt) do
    OpentelemetryDatadog.Core.Retry.retry_delay(attempt)
  end

  @doc """
  Recursively removes nil values from nested data structures.

  Handles maps, keyword lists, and regular lists appropriately.
  """
  @spec deep_remove_nils(term()) :: term()
  def deep_remove_nils(nil), do: nil

  def deep_remove_nils(term) when is_map(term) do
    term
    |> Map.to_list()
    |> Enum.reject(fn {_k, v} -> is_nil(v) end)
    |> Enum.map(fn {k, v} -> {k, deep_remove_nils(v)} end)
    |> Enum.into(%{})
  end

  def deep_remove_nils(term) when is_list(term) do
    if Keyword.keyword?(term) do
      term
      |> Enum.reject(fn {_k, v} -> is_nil(v) end)
      |> Enum.map(fn {k, v} -> {k, deep_remove_nils(v)} end)
    else
      Enum.map(term, &deep_remove_nils/1)
    end
  end

  def deep_remove_nils(term), do: term

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
  Builds resource data structure from OpenTelemetry resource.
  """
  @spec build_resource_data(any()) :: map()
  def build_resource_data(resource) do
    resource = resource(resource)
    resource_attrs = attributes(Keyword.fetch!(resource, :attributes))

    %{
      resource: resource,
      resource_attrs: resource_attrs,
      resource_map: Keyword.fetch!(resource_attrs, :map)
    }
  end
end
