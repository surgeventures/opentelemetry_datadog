defmodule OpentelemetryDatadog.Mapper.InferDatadogFields do
  @behaviour OpentelemetryDatadog.Mapper

  @impl true
  def map(span, otel_span, _config, state) do
    meta = span.meta

    service_name = Map.fetch!(state.resource_map, :"service.name")

    {:instrumentation_scope, scope_name, _version, _opts} =
      Keyword.fetch!(otel_span, :instrumentation_scope)

    name = Keyword.fetch!(otel_span, :name)
    resource = get_resource(name, meta)
    type = get_type(scope_name, meta)
    service_name = get_service_name(service_name, meta)

    span = %{
      span
      | resource: resource,
        # TODO map according to https://github.com/open-telemetry/opentelemetry-collector-contrib/blob/712278378b0e3d04cd6881c020b266b9fea56113/receiver/datadogreceiver/translator.go#L113
        # (in reverse)
        type: type,
        service: service_name,
        metrics: add_priority_metric(meta, span.metrics)
    }

    span = %{
      span
      | meta:
          span.meta
          |> Map.put(:"evaled.resource", resource)
          |> Map.put(:"evaled.type", type)
          |> Map.put(:"evaled.service", service_name)
          |> Map.put(:"evaled.name", name)
    }

    {:next, span}
  end

  # def add_priority_metric(%{_sampling_priority_v1: priority}, metrics) do
  #  Map.put(metrics, :_sampling_priority_v1, priority)
  # end

  def add_priority_metric(_meta, metrics) do
    metrics
  end

  def get_resource(_, %{:"http.target" => target}), do: target
  def get_resource(_, %{:"db.statement" => statement}), do: statement
  def get_resource(name, _), do: name

  def get_type("opentelemetry_ecto", _meta), do: "db"
  def get_type("opentelemetry_liveview", _meta), do: "web"
  def get_type("opentelemetry_phoenix", _meta), do: "web"
  def get_type(_, _), do: "custom"

  def get_service_name(_, %{"db.url": url, "db.instance": name}) do
    %URI{host: host} = URI.parse(url)
    "#{host}/#{name}"
  end

  def get_service_name(service_name, _), do: service_name
end
