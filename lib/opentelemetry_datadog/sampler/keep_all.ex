defmodule OpentelemetryDatadog.Sampler.KeepAll do
  @behaviour :otel_sampler

  alias OpentelemetryDatadog.DatadogConstants

  @impl true
  def setup(_sampler_opts) do
    %{}
  end

  @impl true
  def description(_sampler_config) do
    "KeepAll"
  end

  @impl true
  def should_sample(ctx, _trace_id, _links, _span_name, _span_kind, _attributes, _sampler_config) do
    span_ctx = :otel_tracer.current_span_ctx(ctx)

    attributes = %{
      _sampling_priority_v1: DatadogConstants.sampling_priority(:AUTO_KEEP),
      "_dd.p.dm": DatadogConstants.sampling_mechanism_used(:DEFAULT)
    }

    {:record_and_sample, attributes, :otel_span.tracestate(span_ctx)}
  end
end
