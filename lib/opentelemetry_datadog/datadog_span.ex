defmodule OpentelemetryDatadog.DatadogSpan do
  @moduledoc """
  Represents a Datadog span structure compatible with the v0.5 traces API.

  This struct contains all the required fields for a Datadog span as defined
  in the Datadog Agent API specification.
  """

  @type t :: %__MODULE__{
          trace_id: non_neg_integer(),
          span_id: non_neg_integer(),
          parent_id: non_neg_integer() | nil,
          name: String.t(),
          start: non_neg_integer(),
          duration: non_neg_integer(),
          error: 0 | 1,
          resource: String.t(),
          service: String.t(),
          type: String.t(),
          meta: map(),
          metrics: map()
        }

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
