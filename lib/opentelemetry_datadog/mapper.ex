defmodule OpentelemetryDatadog.Mapper do
  alias OpentelemetryDatadog.DatadogSpan

  @type state :: %{}
  @type arg :: any()
  @type otel_span :: Keyword.t()

  @callback init(state :: state()) :: state()
  @callback map(span :: DatadogSpan.t(), otel_span :: otel_span(), arg :: any(), state :: state()) :: {:next, DatadogSpan.t()} | nil
end
