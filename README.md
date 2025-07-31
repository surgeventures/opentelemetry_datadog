# OpentelemetryDatadog

Datadog exporter for OpenTelemetry in Elixir.  
Exports traces directly to the Datadog Agent using the native `/v0.5/traces` protocol over MessagePack.

## Why?

This library exists to provide a Datadog integration that:

- **Respects native Datadog sampling (priority sampling)**
- **Avoids OTLP translation layers**
- **Supports Datadog-specific features**, like `sampling_priority`, `x-datadog-*` headers, and structured `meta`/`metrics` fields

---

## Installation

Add the dependency to your `mix.exs`:

```elixir
def deps do
  [
    {:opentelemetry_datadog, git: "https://github.com/hansihe/opentelemetry_datadog.git"}
  ]
end
```

## Configuration

You can configure the exporter in two ways:

---

### 1. Environment-based configuration

Recommended for runtime or production use.

Set the following variables in your shell or deployment environment:

```bash
export DD_AGENT_HOST=localhost
export DD_SERVICE=my-service
export DD_ENV=production
export DD_TAGS="team:platform,env:prod"
export DD_TRACE_SAMPLE_RATE=0.25
```

Then initialize the exporter in your application:
```elixir
OpentelemetryDatadog.setup()
```

## Supported Environment Variables

| Variable               | Required   | Description                                     |
|------------------------|------------|-------------------------------------------------|
| `DD_AGENT_HOST`        | true       | Hostname for the Datadog Agent                  |
| `DD_TRACE_AGENT_PORT`  | false      | Port for the agent (default: `8126`)            |
| `DD_SERVICE`           | false      | Logical service name                            |
| `DD_VERSION`           | false      | Application version                             |
| `DD_ENV`               | false      | Environment name (`dev`, `prod`, etc.)          |
| `DD_TAGS`              | false      | Comma-separated `key:value` tags                |
| `DD_TRACE_SAMPLE_RATE` | false      | Sampling rate as a float between `0.0–1.0`      |

You can also use `setup!/0` to raise if any required configuration is missing or invalid.

---

## Manual Configuration

Instead of relying on ENV vars, you can pass configuration directly as a keyword list:

```elixir
OpentelemetryDatadog.setup([
  host: "localhost",
  port: 8126,
  service: "my-app",
  version: "1.0.0",
  env: "staging"
])
```

## OpenTelemetry Setup Example

Example configuration to wire the exporter into your OpenTelemetry setup:

```elixir
config :opentelemetry,
  traces_exporter: {OpentelemetryDatadog.Exporter, []},
  sampler: {:otel_sampler_parent_based, %{root: {:otel_sampler_always_on, %{}}}},
  text_map_propagators: [OpentelemetryDatadog.Propagator.Datadog],
  resource: %{
    "service.name": "my-app",
    "deployment.environment": "production",
    "service.version": "1.2.3"
  }
```

The above config will:
* Send traces to a DataDog agent running on `localhost:8126`
* Randomly sample traces at a rate of 0.5, while accurately reporting sampling rates to DataDog
* Setup a propagator that is compatible with the "x-datadog-*" headers
