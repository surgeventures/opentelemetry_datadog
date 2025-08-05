# OpentelemetryDatadog

Datadog exporter for OpenTelemetry in Elixir. Exports traces directly to the Datadog Agent using native Datadog protocol over MessagePack.

Supports `/v0.4/traces` (default) and `/v0.5/traces` endpoints.

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

### Environment Variables

```bash
export DD_AGENT_HOST=localhost
export DD_SERVICE=my-service
export DD_ENV=production
export DD_TAGS="team:platform,env:prod"
export DD_TRACE_SAMPLE_RATE=0.25
```

```elixir
OpentelemetryDatadog.setup()
```

| Variable               | Required | Default | Description |
|------------------------|----------|---------|-------------|
| `DD_AGENT_HOST`        | yes      | -       | Agent hostname |
| `DD_TRACE_AGENT_PORT`  | no       | 8126    | Agent port |
| `DD_SERVICE`           | no       | -       | Service name |
| `DD_VERSION`           | no       | -       | App version |
| `DD_ENV`               | no       | -       | Environment |
| `DD_TAGS`              | no       | -       | Tags (comma-separated) |
| `DD_TRACE_SAMPLE_RATE` | no       | -       | Sample rate (0.0-1.0) |

### Manual Configuration

```elixir
OpentelemetryDatadog.setup([
  host: "localhost",
  port: 8126,
  service: "my-app",
  version: "1.0.0",
  env: "staging"
])
```

## OpenTelemetry Setup

### Using v0.4 API (default)

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

### Using v0.5 API

```elixir
config :opentelemetry,
  traces_exporter: {OpentelemetryDatadog.V05.Exporter, [protocol: :v05]},
  sampler: {:otel_sampler_parent_based, %{root: {:otel_sampler_always_on, %{}}}},
  text_map_propagators: [OpentelemetryDatadog.Propagator.Datadog],
  resource: %{
    "service.name": "my-app",
    "deployment.environment": "production",
    "service.version": "1.2.3"
  }
```

## v0.5 API

Required fields: `trace_id`, `span_id`, `parent_id`, `name`, `service`, `resource`, `type`, `start`, `duration`, `error`, `meta`, `metrics`.

## Testing

```bash
mix test
```

### Integration Tests

```bash
MIX_ENV=test mix test --include integration
```

Integration tests automatically start a Datadog Agent container (requires Docker).
