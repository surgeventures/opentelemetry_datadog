Code.require_file("support/env_helpers.ex", __DIR__)
Code.require_file("support/config_presets.ex", __DIR__)
Code.require_file("support/error_scenarios.ex", __DIR__)
Code.require_file("support/test_fixtures.ex", __DIR__)
Code.require_file("support/test_helpers.ex", __DIR__)
Code.require_file("support/testcontainers.ex", __DIR__)

# Start Testcontainers for integration tests
{:ok, _} = Testcontainers.start_link()

ExUnit.start()
