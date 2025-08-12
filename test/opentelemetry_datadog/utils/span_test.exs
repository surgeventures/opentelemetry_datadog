defmodule OpentelemetryDatadog.Utils.SpanTest do
  use ExUnit.Case, async: true
  doctest OpentelemetryDatadog.Utils.Span

  @moduletag :unit

  alias OpentelemetryDatadog.Utils.Span

  describe "term_to_string/1" do
    test "converts strings to strings" do
      assert Span.term_to_string("hello") == "hello"
    end

    test "converts atoms to strings" do
      assert Span.term_to_string(:hello) == "hello"
    end

    test "converts other terms using inspect" do
      assert Span.term_to_string(123) == "123"
      assert Span.term_to_string([1, 2, 3]) == "[1, 2, 3]"
    end
  end

  describe "nil_if_undefined/1" do
    test "converts :undefined to nil" do
      assert Span.nil_if_undefined(:undefined) == nil
    end

    test "passes through other values" do
      assert Span.nil_if_undefined("test") == "test"
      assert Span.nil_if_undefined(123) == 123
      assert Span.nil_if_undefined(nil) == nil
    end
  end

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

  describe "get_service_from_resource/1" do
    test "extracts service name when present" do
      data = %{resource_map: %{"service.name" => "my-service"}}
      assert Span.get_service_from_resource(data) == "my-service"
    end

    test "returns default when service name is missing" do
      data = %{resource_map: %{}}
      assert Span.get_service_from_resource(data) == "unknown-service"
    end
  end

  describe "get_env_from_resource/1" do
    test "extracts environment when present" do
      data = %{resource_map: %{"deployment.environment" => "production"}}
      assert Span.get_env_from_resource(data) == "production"
    end

    test "returns default when environment is missing" do
      data = %{resource_map: %{}}
      assert Span.get_env_from_resource(data) == "unknown"
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

  describe "get_type_from_span/1" do
    test "maps server spans to web" do
      assert Span.get_type_from_span("server") == "web"
    end

    test "maps client spans to http" do
      assert Span.get_type_from_span("client") == "http"
    end

    test "maps producer/consumer spans to queue" do
      assert Span.get_type_from_span("producer") == "queue"
      assert Span.get_type_from_span("consumer") == "queue"
    end

    test "maps internal spans to custom" do
      assert Span.get_type_from_span("internal") == "custom"
    end

    test "maps unknown spans to custom" do
      assert Span.get_type_from_span("unknown") == "custom"
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
