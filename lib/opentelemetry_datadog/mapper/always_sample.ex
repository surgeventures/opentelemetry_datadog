defmodule OpentelemetryDatadog.Mapper.AlwaysSample do
  @behaviour OpentelemetryDatadog.Mapper

  @impl true
  def map(span, _otel_span, _config, _state) do
    {:next, %{span | meta: Map.put(span.meta, :"manual.keep", "1")}}
  end
end
