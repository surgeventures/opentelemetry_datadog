# OpentelemetryDatadog

OpenTelemetry DataDog Exporter and utilities for Elixir.

The main reason you would use this over exporting over the DataDog Agent over otlp is that this approach supports proper sampling.

## Installation

```elixir
def deps do
  [
    {:opentelemetry_datadog, git: "https://github.com/hansihe/opentelemetry_datadog.git"}
  ]
end
```

After installing, `opentelemetry` needs to be configured with the datadog exporter:

```elixir
config :opentelemetry,
  traces_exporter: {OpentelemetryDatadog.Exporter, [host: "http://localhost", port: 8126]},
  resource: %{
    # Resources configuration go in here or are specified using env variables
    "service.name": "my-service",
    "deployment.environment": "production"
  },
  sampler: {OpentelemetryDatadog.Sampler.UseLocalSamplingRules, 0.5},
  text_map_propagators: [OpentelemetryDatadog.Propagator.Datadog]
```

The above config will:
* Send traces to a DataDog agent running on `localhost:8126`
* Randomly sample traces at a rate of 0.5, while accurately reporting sampling rates to DataDog
* Setup a propagator that is compatible with the "x-datadog-*" headers
