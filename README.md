# OpentelemetryDatadog

Datadog exporter for OpenTelemetry in Elixir. Exports traces directly to the Datadog Agent using native Datadog protocol over MessagePack.

Uses the `/v0.5/traces` endpoint.

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
export DD_EXPORT_TIMEOUT_MS=5000
export DD_EXPORT_CONNECT_TIMEOUT_MS=1000
```

Configuration is loaded automatically when the exporter initializes. 
You can validate configuration manually if needed:

```elixir
# Validate environment configuration
{:ok, config} = OpentelemetryDatadog.Config.load()
:ok = OpentelemetryDatadog.Config.validate(config)
```

| Variable                      | Required | Default | Description |
|-------------------------------|----------|---------|-------------|
| `DD_AGENT_HOST`               | yes      | -       | Agent hostname |
| `DD_TRACE_AGENT_PORT`         | no       | 8126    | Agent port |
| `DD_SERVICE`                  | no       | -       | Service name |
| `DD_VERSION`                  | no       | -       | App version |
| `DD_ENV`                      | no       | -       | Environment |
| `DD_TAGS`                     | no       | -       | Tags (comma-separated) |
| `DD_TRACE_SAMPLE_RATE`        | no       | -       | Sample rate (0.0-1.0) |
| `DD_EXPORT_TIMEOUT_MS`        | no       | 2000    | HTTP request timeout in milliseconds |
| `DD_EXPORT_CONNECT_TIMEOUT_MS`| no       | 500     | Connection timeout in milliseconds |

### Manual Configuration

You can validate configuration manually:

```elixir
config = [
  host: "localhost", 
  port: 8126,
  service: "my-app",
  version: "1.0.0", 
  env: "staging"
]

:ok = OpentelemetryDatadog.Config.validate(config)
```

## OpenTelemetry Setup

```elixir
config :opentelemetry,
  traces_exporter: {OpentelemetryDatadog.Exporter, []},
  sampler: {:otel_sampler_parent_based, %{root: {:otel_sampler_always_on, %{}}}},
  text_map_propagators: [OpentelemetryDatadog.Propagator.Datadog],
  propagators: [:otel_process_propagator],
  instrumentations: [:otel_function_wrapper],
  resource: %{
    "service.name": "my-app",
    "deployment.environment": "production",
    "service.version": "1.2.3"
  }
```

## v0.5 API

Required fields: `trace_id`, `span_id`, `parent_id`, `name`, `service`, `resource`, `type`, `start`, `duration`, `error`, `meta`, `metrics`.

## Handling Datadog Agent Failures

When the exporter cannot reach the Datadog agent, it handles failures gracefully:

- **No application crashes**: The exporter never crashes your application due to agent connectivity issues
- **Spans are dropped**: Failed spans are dropped and not retried to prevent memory buildup
- **Telemetry events**: A telemetry event `[:opentelemetry_datadog, :export, :failure]` is emitted for monitoring
- **Detailed logging**: Errors are logged with contextual information including trace IDs when available

### Failure Types

The exporter categorizes failures into specific types for better monitoring:

| Failure Type | Description | Common Causes |
|--------------|-------------|---------------|
| `:agent_unavailable` | Agent is not reachable | Agent down, wrong host/port, firewall |
| `:network_error` | Network-level issues | DNS failures, network unreachable, timeouts |
| `:http_error` | HTTP-level errors | 4xx/5xx responses from agent |
| `:unknown_error` | Unexpected errors | Malformed responses, encoding issues |

### Telemetry Event

The failure telemetry event includes:

```elixir
:telemetry.execute(
  [:opentelemetry_datadog, :export, :failure],
  %{span_count: 5, trace_count: 2},  # Measurements
  %{                                 # Metadata
    reason: "connection refused",
    failure_type: :agent_unavailable,
    trace_ids: [123456789, 987654321],
    host: "localhost",
    port: 8126
  }
)
```

### Example Monitoring

```elixir
:telemetry.attach(
  "datadog-export-failures",
  [:opentelemetry_datadog, :export, :failure],
  fn _event, measurements, metadata, _config ->
    Logger.error("Datadog export failed: #{metadata.reason} " <>
                 "(#{measurements.span_count} spans dropped)")
    
    # Send to your monitoring system
    MyMetrics.increment("datadog.export.failures", 
      tags: [failure_type: metadata.failure_type])
  end,
  nil
)
```

## Testing

```bash
mix test
```

### Integration Tests

```bash
MIX_ENV=test mix test --include integration
```

Integration tests automatically start a Datadog Agent container (requires Docker).
