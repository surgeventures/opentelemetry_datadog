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

  alias OpentelemetryDatadog.{DatadogSpan, ResourceAttributes, Utils.Span}

  @type mapper_config :: {module(), any()}
  @type otel_span :: Keyword.t()
  @type span_data :: map()
  @type span_record :: tuple()

  @doc """
  Formats an OpenTelemetry span into a complete DatadogSpan structure.

  This function handles all the span formatting logic, including:
  - Basic span data conversion
  - Service, environment, resource, and type inference
  - Metadata processing
  """
  @spec format_span(span_record(), tuple(), map()) :: DatadogSpan.t()
  def format_span(span_record, resource, state) when is_tuple(resource) do
    format_span(span_record, build_resource_data(resource), state)
  end

  @spec format_span(span_record(), span_data(), map()) :: DatadogSpan.t()
  def format_span(span_record, data, _state) when is_map(data) do
    span = span(span_record)
    attributes_record = Keyword.fetch!(span, :attributes)
    attributes_data = attributes(attributes_record)

    dd_span_kind = Atom.to_string(Keyword.fetch!(span, :kind))
    start_time_nanos = :opentelemetry.timestamp_to_nano(Keyword.fetch!(span, :start_time))
    end_time_nanos = :opentelemetry.timestamp_to_nano(Keyword.fetch!(span, :end_time))

    # Get instrumentation scope for advanced type inference
    {:instrumentation_scope, scope_name, _version, _opts} =
      Keyword.fetch!(span, :instrumentation_scope)

    # Build base metadata
    base_meta =
      Keyword.fetch!(attributes_data, :map)
      |> Map.put(:"span.kind", dd_span_kind)
      |> Map.put(:env, Span.get_env_from_resource(data))
      |> Enum.map(fn {k, v} -> {k, Span.term_to_string(v)} end)
      |> Enum.into(%{})

    name = Keyword.fetch!(span, :name)

    # Advanced inference using instrumentation scope and attributes
    service = infer_service_name(data, base_meta)
    resource = infer_resource_name(name, base_meta)
    type = infer_span_type(scope_name, dd_span_kind, base_meta)

    # Add debug metadata
    meta =
      base_meta
      |> Map.put(:"evaled.resource", resource)
      |> Map.put(:"evaled.type", type)
      |> Map.put(:"evaled.service", service)
      |> Map.put(:"evaled.name", name)

    %DatadogSpan{
      trace_id: Span.id_to_datadog_id(Keyword.fetch!(span, :trace_id)),
      span_id: Keyword.fetch!(span, :span_id),
      parent_id: Span.nil_if_undefined(Keyword.fetch!(span, :parent_span_id)),
      name: name,
      service: service,
      resource: resource || name,
      type: type,
      start: start_time_nanos,
      duration: end_time_nanos - start_time_nanos,
      error: 0,
      meta: meta,
      metrics: %{}
    }
  end

  # Advanced service name inference
  defp infer_service_name(data, %{"db.url": url, "db.instance": instance}) do
    case URI.parse(url) do
      %URI{host: host} when is_binary(host) -> "#{host}/#{instance}"
      _ -> Span.get_service_from_resource(data)
    end
  end

  defp infer_service_name(data, _meta), do: Span.get_service_from_resource(data)

  # Advanced resource name inference
  defp infer_resource_name(_name, %{:"http.target" => target}), do: target
  defp infer_resource_name(_name, %{:"db.statement" => statement}), do: statement
  defp infer_resource_name(name, meta), do: Span.get_resource_from_span(name, meta)

  # Advanced span type inference using instrumentation scope
  defp infer_span_type("opentelemetry_ecto", _kind, _meta), do: "db"
  defp infer_span_type("opentelemetry_liveview", _kind, _meta), do: "web"
  defp infer_span_type("opentelemetry_phoenix", _kind, _meta), do: "web"
  defp infer_span_type(_scope, kind, _meta), do: Span.get_type_from_span(kind)

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
  Builds enhanced resource data structure with extracted resource attributes.

  This includes the standard resource data plus auto-extracted resource
  attributes that follow OpenTelemetry semantic conventions.

  ## Examples

      iex> resource_tuple = build_test_resource()
      iex> data = OpentelemetryDatadog.Formatter.build_enhanced_resource_data(resource_tuple)
      iex> Map.has_key?(data, :resource_attributes)
      true
      iex> Map.has_key?(data.resource_attributes, "service.name")
      true
  """
  @spec build_enhanced_resource_data(tuple()) :: map()
  def build_enhanced_resource_data(resource) do
    base_data = build_resource_data(resource)

    # Extract standardized resource attributes
    resource_attributes = ResourceAttributes.extract(resource)

    Map.put(base_data, :resource_attributes, resource_attributes)
  end

  @doc """
  Gets resource attributes from resource data.

  Convenience function to extract resource attributes from already
  processed resource data.

  ## Examples

      iex> data = %{resource_map: %{"service.name" => "my-service"}}
      iex> attrs = OpentelemetryDatadog.Formatter.get_resource_attributes(data)
      iex> attrs["service.name"]
      "my-service"
  """
  @spec get_resource_attributes(map()) :: map()
  def get_resource_attributes(resource_data) do
    ResourceAttributes.from_resource_data(resource_data)
  end

  @doc """
  Accessor function for span record.
  """
  @spec get_span(span_record()) :: otel_span()
  def get_span(span_record), do: span(span_record)
end
