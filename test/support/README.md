# Test Support Modules

This directory contains modular test utilities and helpers for OpenTelemetry Datadog tests.

## Module Structure

### `test_helpers.ex` - Main Entry Point
Central module that re-exports all test utilities through `defdelegate`. Import this module in your tests to access all functionality:

```elixir
import OpentelemetryDatadog.TestHelpers
```

### `env_helpers.ex` - Environment Management
Handles Datadog environment variables (DD_*):

- `env_vars()` - List of all DD_* variables
- `reset_env()` - Clear all DD_* variables
- `put_env(map)` - Set multiple variables
- `put_dd_env(var, value)` - Set single DD_* variable with validation
- `get_dd_env(var, default)` - Get DD_* variable with optional default
- `get_env_state()` - Capture current state
- `restore_env_state(state)` - Restore previous state
- `has_minimal_config?()` - Check if basic config is set
- `current_dd_vars()` - List currently set variables

### `config_presets.ex` - Configuration Presets
Ready-to-use configuration setups for different environments:

- `minimal_config(host \\ "localhost")` - Basic DD_AGENT_HOST only
- `dev_config(service \\ "test-app")` - Development environment
- `prod_config(service \\ "api-service", version \\ "1.0.0")` - Production setup
- `phoenix_config(service \\ "phoenix-app")` - Phoenix application config
- `containerized_config(service, version, env)` - Docker/K8s setup
- `staging_config(service, version)` - Staging environment
- `ci_config(service)` - CI/CD environment
- `microservice_config(service, component)` - Microservice with tags

### `error_scenarios.ex` - Error Testing
Invalid configurations for testing error handling:

- `invalid_port_config()` - Non-numeric port
- `invalid_sample_rate_config()` - Sample rate > 1.0
- `port_out_of_range_config()` - Port > 65535
- `malformed_tags_config()` - Invalid tag format
- `missing_required_host_config()` - No DD_AGENT_HOST
- `all_error_scenarios()` - List all scenario names
- `apply_scenario(name)` - Apply scenario by name

### `test_fixtures.ex` - Test Data
Static test data for validation and mocking:

- `valid_configs()` - List of valid configuration maps
- `invalid_configs()` - List of invalid configuration maps

## Usage Examples

### Basic Test Setup
```elixir
defmodule MyTest do
  use ExUnit.Case
  import OpentelemetryDatadog.TestHelpers

  setup do
    reset_env()
    :ok
  end

  test "with minimal config" do
    minimal_config()
    # your test code
  end
end
```

### Error Testing
```elixir
test "handles invalid port" do
  invalid_port_config()
  assert_error_handling()
end

test "all error scenarios" do
  for scenario <- all_error_scenarios() do
    reset_env()
    apply_scenario(scenario)
    assert_proper_error_handling()
  end
end
```

### Environment State Management
```elixir
test "preserves environment" do
  original_state = get_env_state()
  
  # modify environment for test
  prod_config("test-service", "v1.0")
  
  # restore original state
  restore_env_state(original_state)
end
```
