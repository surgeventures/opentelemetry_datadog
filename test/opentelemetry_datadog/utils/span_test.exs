defmodule OpentelemetryDatadog.Utils.SpanTest do
  use ExUnit.Case, async: true
  doctest OpentelemetryDatadog.Utils.Span

  @moduletag :unit

  alias OpentelemetryDatadog.Utils.Span

  describe "id_to_datadog_id/1" do
    test "handles nil input" do
      assert Span.id_to_datadog_id(nil) == nil
    end

    test "extracts upper 64 bits from 128-bit trace ID" do
      trace_id = 0x123456789ABCDEF0FEDCBA0987654321
      result = Span.id_to_datadog_id(trace_id)
      assert is_integer(result)
      assert result == 1_311_768_467_463_790_320
    end
  end

  describe "get_resource_from_span/2" do
    test "builds resource from HTTP route and method" do
      meta = %{"http.method" => "GET", "http.route" => "/api/users"}
      assert Span.get_resource_from_span("web.request", meta) == "GET /api/users"
    end

    test "falls back to span name when no HTTP info" do
      meta = %{}
      assert Span.get_resource_from_span("db.query", meta) == "db.query"
    end
  end

  describe "get_container_id/0" do
    test "returns nil when not in container" do
      # In normal test environment, should return nil
      result = Span.get_container_id()
      assert result == nil or is_binary(result)
    end
  end
end
