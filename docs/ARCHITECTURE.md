# OpenTelemetry Datadog Integration Architecture

## Overview

The OpenTelemetry Datadog integration provides a native Elixir implementation for exporting OpenTelemetry traces directly to Datadog Agent using the Datadog v0.5 traces API. This integration bypasses the OpenTelemetry Collector and communicates directly with the Datadog Agent using MessagePack serialization over HTTP.

## Architecture Components

### High-Level Architecture

```
┌─────────────────┐    ┌──────────────────┐    ┌─────────────────┐    ┌─────────────────┐
│   Application   │───▶│  OpenTelemetry   │───▶│  DD Exporter    │───▶│  Datadog Agent  │
│     Code        │    │     SDK          │    │                 │    │                 │
└─────────────────┘    └──────────────────┘    └─────────────────┘    └─────────────────┘
                                │                        │
                                ▼                        ▼
                       ┌──────────────────┐    ┌─────────────────┐
                       │  DD Propagator   │    │  Configuration  │
                       │                  │    │    Manager      │
                       └──────────────────┘    └─────────────────┘
```

### Core Components

#### 1. Exporter (`OpentelemetryDatadog.Exporter`)

The main component responsible for:
- Implementing the `:otel_exporter` behavior
- Converting OpenTelemetry spans to Datadog format
- Batching and sending traces to Datadog Agent
- Handling retries with exponential backoff
- Managing telemetry events

**Key Features:**
- Uses MessagePack serialization for efficient data transfer
- Supports the Datadog v0.5 traces API endpoint (`/v0.5/traces`)
- Implements retry logic with jitter (3 retries with exponential backoff)
- Provides comprehensive telemetry instrumentation
- Configurable HTTP timeouts for connection and request handling
- Intelligent URL construction with protocol detection (HTTP/HTTPS)
- Graceful error handling with detailed logging and telemetry

#### 2. Configuration Manager (`OpentelemetryDatadog.Config`)

Handles configuration loading and validation:
- Environment variable parsing
- Configuration validation
- Default value management
- Error handling with detailed error messages

**Supported Environment Variables:**
- `DD_AGENT_HOST` (required): Datadog Agent hostname or full URL
- `DD_TRACE_AGENT_PORT` (optional, default: 8126): Agent port
- `DD_SERVICE` (optional): Service name
- `DD_VERSION` (optional): Application version
- `DD_ENV` (optional): Environment name
- `DD_TAGS` (optional): Comma-separated key:value tags
- `DD_TRACE_SAMPLE_RATE` (optional): Sampling rate (0.0-1.0)
- `DD_EXPORT_TIMEOUT_MS` (optional, default: 2000): HTTP request timeout in milliseconds
- `DD_EXPORT_CONNECT_TIMEOUT_MS` (optional, default: 500): HTTP connection timeout in milliseconds

#### 3. Span Mapper (`OpentelemetryDatadog.Mapper`)

Transforms OpenTelemetry spans to Datadog format:
- Converts span attributes to Datadog meta and metrics
- Maps OpenTelemetry span kinds to Datadog span types
- Handles error propagation and status mapping
- Applies configurable transformation rules

**Built-in Mappers:**
- `LiftError`: Promotes error information to span-level error flag
- `AlwaysSample`: Ensures spans are always sampled (configurable)

#### 4. Propagator (`OpentelemetryDatadog.Propagator.Datadog`)

Implements Datadog's trace context propagation:
- Extracts and injects Datadog trace headers
- Maintains compatibility with Datadog's distributed tracing
- Supports cross-service trace correlation

**Headers:**
- `x-datadog-trace-id`: Trace identifier
- `x-datadog-parent-id`: Parent span identifier  
- `x-datadog-sampling-priority`: Sampling decision

#### 5. Encoder (`OpentelemetryDatadog.Encoder`)

Serializes span data for transmission:
- Validates span data structure
- Converts to MessagePack format
- Ensures API compatibility with Datadog v0.5 format
- Handles data type normalization

#### 6. Formatter (`OpentelemetryDatadog.Formatter`)

Formats OpenTelemetry spans to Datadog span structure:
- Maps OpenTelemetry fields to Datadog equivalents
- Handles timing conversions (nanoseconds to microseconds)
- Applies service and resource naming conventions
- Manages span hierarchy and relationships

## Data Flow

### 1. Span Creation and Collection

```
Application Code
       │
       ▼
OpenTelemetry SDK
       │
       ▼ 
Span Collection (ETS table)
```

### 2. Export Process

```
Export Trigger
       │
       ▼
Exporter.export/4
       │
       ▼
Format Spans (Formatter)
       │
       ▼
Apply Mappers (Mapper)
       │
       ▼
Encode to MessagePack (Encoder)
       │
       ▼
HTTP POST to Datadog Agent
       │
       ▼
Telemetry Events
```

### 3. Configuration Loading

```
Environment Variables
       │
       ▼
Config.load/0
       │
       ▼
Validation
       │
       ▼
Configuration Struct
```

## Span Transformation Pipeline

### OpenTelemetry to Datadog Mapping

| OpenTelemetry Field | Datadog Field | Transformation |
|-------------------|---------------|----------------|
| `trace_id` | `trace_id` | Direct mapping |
| `span_id` | `span_id` | Direct mapping |
| `parent_span_id` | `parent_id` | Direct mapping |
| `name` | `name` | Direct mapping |
| `start_time` | `start` | Nanoseconds → Microseconds |
| `end_time - start_time` | `duration` | Nanoseconds → Microseconds |
| `status.code` | `error` | Error status → 1, else 0 |
| `attributes` | `meta` | String key-value pairs |
| `attributes` | `metrics` | Numeric key-value pairs |
| `resource.service.name` | `service` | Service identification |
| `span.kind + name` | `resource` | Resource naming |
| `span.kind` | `type` | Span type classification |

### Span Processing Steps

1. **Extraction**: Extract span data from OpenTelemetry ETS table
2. **Formatting**: Convert to Datadog span structure
3. **Mapping**: Apply transformation rules via mappers
4. **Validation**: Ensure all required fields are present
5. **Encoding**: Serialize to MessagePack format
6. **Transmission**: Send to Datadog Agent

## Error Handling and Resilience

### Retry Strategy

- **Attempts**: 3 retries maximum
- **Backoff**: Exponential with jitter (10% randomization)
- **Delays**: ~484ms, ~945ms, ~1908ms (calculated as `2^attempt * 500ms * (1 - 0.1 * random)`)
- **Conditions**: Transient HTTP errors and network failures
- **Implementation**: Uses Req library's `:transient` retry with custom delay function

### Error Categories

1. **Configuration Errors**: Missing required environment variables
2. **Validation Errors**: Invalid span data or configuration values
3. **Network Errors**: Connection failures, timeouts (marked as retryable)
4. **HTTP Errors**: 4xx/5xx responses from Datadog Agent (marked as non-retryable)
5. **Encoding Errors**: MessagePack serialization failures

### Timeout Configuration

The exporter supports two types of configurable timeouts:

- **Connection Timeout** (`DD_EXPORT_CONNECT_TIMEOUT_MS`): Time to establish connection (default: 500ms)
- **Request Timeout** (`DD_EXPORT_TIMEOUT_MS`): Total time for request completion (default: 2000ms)

Both timeouts are applied to HTTP requests to prevent hanging connections and ensure responsive error handling.

### URL Construction and Protocol Detection

The exporter intelligently constructs URLs based on the `DD_AGENT_HOST` configuration:

- **Full URL Format**: If `DD_AGENT_HOST` contains `http://` or `https://`, it's used as-is
  - Example: `DD_AGENT_HOST=https://api.datadoghq.com` → `https://api.datadoghq.com:8126/v0.5/traces`
- **Hostname Format**: If `DD_AGENT_HOST` is a plain hostname, HTTPS is assumed by default
  - Example: `DD_AGENT_HOST=localhost` → `https://localhost:8126/v0.5/traces`

This approach provides flexibility for both local development (with Datadog Agent) and cloud deployments (with Datadog SaaS).

### Telemetry Integration

The exporter emits telemetry events for monitoring:

```elixir
:telemetry.span(
  [:opentelemetry_datadog, :export],
  %{endpoint: "/v0.5/traces", host: host, port: port},
  fn -> # export logic end
)
```

**Telemetry Metadata:**
- `span_count`: Number of spans exported
- `status_code`: HTTP response status
- `error`: Error description (if any)
- `retry`: Whether the operation is retryable

## Integration Patterns

### Basic Setup

```elixir
# config/config.exs
config :opentelemetry,
  traces_exporter: {OpentelemetryDatadog.Exporter, []},
  text_map_propagators: [OpentelemetryDatadog.Propagator.Datadog]
```

### Advanced Configuration

```elixir
# Custom configuration with validation
{:ok, config} = OpentelemetryDatadog.Config.load()
:ok = OpentelemetryDatadog.Config.validate(config)

config :opentelemetry,
  traces_exporter: {OpentelemetryDatadog.Exporter, 
    OpentelemetryDatadog.Config.to_exporter_config(config)}
```

### Configuration with Custom Timeouts

```elixir
# Environment variables for timeout configuration
export DD_AGENT_HOST="https://api.datadoghq.com"
export DD_TRACE_AGENT_PORT="443"
export DD_EXPORT_TIMEOUT_MS="5000"
export DD_EXPORT_CONNECT_TIMEOUT_MS="1000"

# Or direct configuration
config :opentelemetry,
  traces_exporter: {OpentelemetryDatadog.Exporter, [
    host: "api.datadoghq.com",
    port: 443,
    timeout_ms: 5000,
    connect_timeout_ms: 1000
  ]}
```

### Custom Mappers

```elixir
defmodule MyApp.CustomMapper do
  @behaviour OpentelemetryDatadog.Mapper
  
  def map(span, otel_span, _arg, _state) do
    # Custom transformation logic
    {:next, updated_span}
  end
end
```

## Performance Considerations

### Batching Strategy

- Spans are collected in ETS tables by OpenTelemetry SDK
- Export is triggered based on configured batch size or timeout
- MessagePack provides efficient serialization (~30% smaller than JSON)

### Memory Management

- Spans are processed in batches to limit memory usage
- Failed exports don't accumulate indefinitely due to retry limits
- ETS tables are managed by OpenTelemetry SDK

### Network Optimization

- HTTP/1.1 with connection reuse via Req library
- Compression headers for reduced bandwidth
- Configurable retry delays to avoid overwhelming the agent
- Intelligent URL construction supporting both hostname and full URL formats
- Configurable connection and request timeouts for optimal performance

## Security Considerations

### Data Privacy

- No sensitive data is logged in error messages
- Configuration validation prevents exposure of credentials
- Span data follows OpenTelemetry semantic conventions

### Network Security

- Communication with Datadog Agent over HTTP (typically localhost)
- No authentication required for agent communication
- Container ID detection for proper attribution

## Monitoring and Observability

### Health Checks

Monitor the integration health through:
- Telemetry events for export success/failure rates
- HTTP response codes from Datadog Agent
- Configuration validation results

### Debugging

Enable debug logging to troubleshoot:
- Span transformation issues
- Network connectivity problems
- Configuration validation failures

### Testing and Quality Assurance

The integration includes comprehensive test coverage for resilience features:

- **Retry Logic Testing**: Validates exponential backoff with jitter calculations
- **Error Handling Testing**: Verifies graceful degradation under network failures
- **Timeout Testing**: Ensures proper timeout behavior with unreachable hosts
- **Telemetry Testing**: Validates telemetry event emission during failures
- **URL Construction Testing**: Tests protocol detection and URL building logic

Test coverage focuses on critical failure scenarios to ensure production reliability.

### Metrics to Monitor

- Export success rate
- Average export latency
- Retry frequency
- Span drop rate
- Agent connectivity status

## Deployment Considerations

### Datadog Agent Requirements

- Agent version supporting v0.5 traces API
- Proper network connectivity between application and agent
- Sufficient agent resources for trace volume

### Environment Configuration

- Set required environment variables before application start
- Validate configuration in deployment scripts
- Monitor configuration drift in production
- Configure appropriate timeout values based on network conditions:
  - Local development: Use default timeouts (500ms connect, 2000ms request)
  - Cloud deployments: Consider higher timeouts for network latency
  - High-throughput environments: Monitor timeout effectiveness

### Scaling Considerations

- Export performance scales with span volume
- Consider agent capacity when scaling applications
- Monitor memory usage during high-throughput periods
