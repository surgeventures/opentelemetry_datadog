defmodule OpentelemetryDatadog.Mapper.AlwaysSample do
  @behaviour OpentelemetryDatadog.Mapper

  @impl true
  def init(state) do
    state
  end

  @impl true
  def map(span, _otel_span, _config, _state) do
    meta =
      span.meta
      |> Map.put(:"manual.keep", "1")
      |> Map.put(:env, "hans-local-testing")

    {:next, %{span | meta: meta}}
  end
end
