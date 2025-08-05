[
  "support/env_helpers.ex",
  "support/config_presets.ex",
  "support/error_scenarios.ex",
  "support/test_fixtures.ex",
  "support/test_helpers.ex",
  "support/testcontainers.ex",
  "support/telemetry_handler.ex"
]
|> Enum.each(&Code.require_file(&1, __DIR__))

only_tags =
  System.argv()
  |> Enum.chunk_every(2, 1, :discard)
  |> Enum.filter(fn [flag, _] -> flag == "--only" end)
  |> Enum.map(fn [_flag, tag] -> tag end)

if only_tags == [] or "integration" in only_tags do
  {:ok, _} = Testcontainers.start_link()
end

ExUnit.start()
