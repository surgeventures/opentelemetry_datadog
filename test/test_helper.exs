[
  "support/env_helpers.ex",
  "support/config_presets.ex",
  "support/error_scenarios.ex",
  "support/test_fixtures.ex",
  "support/test_helpers.ex",
  "support/telemetry_handler.ex"
]
|> Enum.each(&Code.require_file(&1, __DIR__))

ExUnit.start()
