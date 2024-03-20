defmodule OpentelemetryDatadog.Sampler.UseLocalSamplingRules do
  @behaviour :otel_sampler

  alias OpentelemetryDatadog.DatadogConstants

  @max_uint64 18_446_744_073_709_551_615
  @knuth_factor 111_111_111_111_111_1111

  @impl true
  def setup(_sampler_opts) do
    sampling_rate = 0.5
    threshold = trunc(sampling_rate * @max_uint64)
    {sampling_rate, threshold}
  end

  @impl true
  def description({rate, _thresh}) do
    "UseLocalSamplingRules[#{rate}]"
  end

  @impl true
  def should_sample(ctx, trace_id, _links, _span_name, _span_kind, _attributes, {rate, threshold}) do
    span_ctx = :otel_tracer.current_span_ctx(ctx)

    trace_id_dd = id_to_datadog_id(trace_id)
    sampled = rem(trace_id_dd * @knuth_factor, @max_uint64) <= threshold

    priority =
      if sampled do
        DatadogConstants.sampling_priority(:AUTO_KEEP)
      else
        DatadogConstants.sampling_priority(:AUTO_REJECT)
      end

    decision =
      if sampled do
        :record_and_sample
      else
        :drop
      end

    attributes = %{
      _sampling_priority_v1: priority,
      "_dd.p.dm": DatadogConstants.sampling_mechanism_used(:RULE),
      "_dd.rule_psr": rate
    }

    trace_state = :otel_span.tracestate(span_ctx)
    {decision, attributes, trace_state}
  end

  defp id_to_datadog_id(nil) do
    nil
  end

  defp id_to_datadog_id(trace_id) do
    <<_lower::integer-size(64), upper::integer-size(64)>> = <<trace_id::integer-size(128)>>
    upper
  end
end
