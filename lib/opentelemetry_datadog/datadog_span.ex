defmodule OpentelemetryDatadog.DatadogSpan do
  @type t :: %__MODULE__{}

  defstruct [
    :trace_id,
    :span_id,
    :parent_id,
    :name,
    :start,
    :duration,
    # 0 if no error, 1 if error
    :error,
    :resource,
    :service,
    :type,
    :meta,
    :metrics
  ]
end
