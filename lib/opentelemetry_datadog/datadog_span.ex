defmodule OpentelemetryDatadog.DatadogSpan do
  @type t :: %__MODULE__{}

  defstruct [
    :trace_id,
    :span_id,
    :parent_id,
    :name,
    :start,
    :duration,
    :error,
    :resource,
    :service,
    :type,
    :meta,
    :metrics
  ]
end
