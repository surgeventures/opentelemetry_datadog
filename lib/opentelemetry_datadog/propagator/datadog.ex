defmodule OpentelemetryDatadog.Propagator.Datadog do
  @behaviour :otel_propagator_text_map

  require Record
  @deps_dir Mix.Project.deps_path()
  Record.defrecord(
    :span_ctx,
    Record.extract(:span_ctx, from: "#{@deps_dir}/opentelemetry_api/include/opentelemetry.hrl")
  )

  @trace_id_header "x-datadog-trace-id"
  @parent_id_header "x-datadog-parent-id"
  @sampling_priority_header "x-datadog-sampling-priority"

  @impl true
  def fields(_propagator_options) do
    [
      @trace_id_header,
      @parent_id_header,
      @sampling_priority_header,
      #"x-datadog-origin"
    ]
  end

  @impl true

  def inject(ctx, carrier, carrier_set, _propagator_options) do
    span_ctx = :otel_tracer.current_span_ctx(ctx)

    case span_ctx do
      span_ctx(trace_id: trace_id, span_id: span_id, trace_flags: trace_flags) when trace_id != 0 and span_id != 0 and trace_flags in [0, 1] ->
        carrier = carrier_set.(@trace_id_header, Integer.to_string(trace_id), carrier)
        carrier = carrier_set.(@parent_id_header, Integer.to_string(span_id), carrier)
        carrier = carrier_set.(@sampling_priority_header, Integer.to_string(trace_flags), carrier)
        carrier

      _ ->
        carrier
    end
  end

  @impl true
  def extract(ctx, carrier, _carrier_keys, carrier_get, _propagator_options) do
    trace_id_str = carrier_get.(@trace_id_header, carrier)
    parent_id_str = carrier_get.(@parent_id_header, carrier)
    sampling_priority_str = carrier_get.(@sampling_priority_header, carrier)

    trace_id = decode_integer_id(trace_id_str)
    parent_id = decode_integer_id(parent_id_str)
    flags = decode_sampling_priority(sampling_priority_str)

    cond do
      trace_id != :undefined and parent_id != :undefined ->
        span_ctx = :otel_tracer.from_remote_span(trace_id, parent_id, flags)
        :otel_tracer.set_current_span(ctx, span_ctx)

      true ->
        ctx
    end
  end

  defp decode_integer_id(:undefined), do: :undefined
  defp decode_integer_id(bin) do
    case Integer.parse(bin) do
      {integer, _} -> integer
      _ -> :undefined
    end
  end

  # TODO should default be sampled or unsampled?
  defp decode_sampling_priority(:undefined), do: 0
  defp decode_sampling_priority("-1"), do: 0
  defp decode_sampling_priority("0"), do: 0
  defp decode_sampling_priority("1"), do: 1
  defp decode_sampling_priority("2"), do: 1

end
