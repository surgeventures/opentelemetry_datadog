defmodule OpentelemetryDatadog.Exporter.SharedTest do
  use ExUnit.Case, async: true

  alias OpentelemetryDatadog.Exporter.Shared
  alias OpentelemetryDatadog.DatadogSpan

  @moduletag :unit

  describe "deep_remove_nils/1" do
    test "removes nil values from maps" do
      input = %{a: 1, b: nil, c: %{d: 2, e: nil}}
      expected = %{a: 1, c: %{d: 2}}
      assert Shared.deep_remove_nils(input) == expected
    end

    test "removes nil values from keyword lists" do
      input = [a: 1, b: nil, c: [d: 2, e: nil]]
      expected = [a: 1, c: [d: 2]]
      assert Shared.deep_remove_nils(input) == expected
    end

    test "removes nil values from regular lists" do
      input = [1, nil, [2, nil, 3]]
      expected = [1, [2, 3]]
      assert Shared.deep_remove_nils(input) == expected
    end

    test_cases = [
      {
        "all nils list becomes empty",
        [nil, nil, nil],
        []
      },
      {
        "mixed nested structures",
        [1, nil, %{a: nil, b: 2}, [nil, 3, nil]],
        [1, %{b: 2}, [3]]
      },
      {
        "empty list stays empty",
        [],
        []
      }
    ]

    for {description, input, expected} <- test_cases do
      test "handles edge cases for lists: #{description}" do
        assert Shared.deep_remove_nils(unquote(Macro.escape(input))) ==
                 unquote(Macro.escape(expected))
      end
    end

    test "handles non-collection types" do
      assert Shared.deep_remove_nils("string") == "string"
      assert Shared.deep_remove_nils(42) == 42
      assert Shared.deep_remove_nils(nil) == nil
    end
  end

  describe "apply_mappers/4" do
    test "applies mappers in sequence" do
      span = %DatadogSpan{trace_id: 123, span_id: 456, name: "test"}
      mappers = []

      result = Shared.apply_mappers(mappers, span, nil, %{})
      assert result == span
    end

    test "returns nil if any mapper returns nil" do
      defmodule TestNilMapper do
        def map(_span, _otel_span, _args, _state), do: nil
      end

      span = %DatadogSpan{trace_id: 123, span_id: 456, name: "test"}
      mappers = [{TestNilMapper, []}]

      result = Shared.apply_mappers(mappers, span, nil, %{})
      assert result == nil
    end

    test "applies transformations from mappers" do
      defmodule TestTransformMapper do
        def map(span, _otel_span, _args, _state) do
          {:next, %{span | name: "transformed"}}
        end
      end

      span = %DatadogSpan{trace_id: 123, span_id: 456, name: "test"}
      mappers = [{TestTransformMapper, []}]

      result = Shared.apply_mappers(mappers, span, nil, %{})
      assert result.name == "transformed"
    end
  end

  describe "build_headers/2" do
    test "builds basic headers without container ID" do
      headers = Shared.build_headers(5, nil)

      assert {"Content-Type", "application/msgpack"} in headers
      assert {"Datadog-Meta-Lang", "elixir"} in headers
      assert {"X-Datadog-Trace-Count", 5} in headers
      refute Enum.any?(headers, fn {key, _} -> key == "Datadog-Container-ID" end)
    end

    test "includes container ID when provided" do
      headers = Shared.build_headers(3, "container123")

      assert {"Datadog-Container-ID", "container123"} in headers
      assert {"X-Datadog-Trace-Count", 3} in headers
    end
  end

  describe "retry_delay/1" do
    test "calculates retry delays with equal jitter" do
      for _i <- 1..5 do
        delay1 = Shared.retry_delay(1)
        delay2 = Shared.retry_delay(2)
        delay3 = Shared.retry_delay(3)

        assert delay1 >= 50 and delay1 <= 150
        assert delay2 >= 100 and delay2 <= 300
        assert delay3 >= 200 and delay3 <= 600
      end
    end

    test "delegates to Retry module" do
      shared_delay1 = Shared.retry_delay(1)
      retry_delay1 = OpentelemetryDatadog.Core.Retry.retry_delay(1)

      assert shared_delay1 >= 50 and shared_delay1 <= 150
      assert retry_delay1 >= 50 and retry_delay1 <= 150

      assert Shared.retry_delay(0) == 0
      assert OpentelemetryDatadog.Core.Retry.retry_delay(0) == 0
    end
  end
end
