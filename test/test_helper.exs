Application.get_env(
  :opentelemetry,
  text_map_propagators: [
    :baggage,
    :trace_context,
    OpentelemetryDatadog.Propagator.Datadog
  ]
)

ExUnit.start()
