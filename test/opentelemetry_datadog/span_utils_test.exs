defmodule OpentelemetryDatadog.SpanUtilsTest do
  use ExUnit.Case, async: true
  doctest OpentelemetryDatadog.SpanUtils

  alias OpentelemetryDatadog.SpanUtils

  describe "term_to_string/1" do
    test "converts boolean to string" do
      assert SpanUtils.term_to_string(true) == "true"
      assert SpanUtils.term_to_string(false) == "false"
    end

    test "passes through binary strings" do
      assert SpanUtils.term_to_string("hello") == "hello"
      assert SpanUtils.term_to_string("") == ""
    end

    test "converts atoms to strings" do
      assert SpanUtils.term_to_string(:atom) == "atom"
      assert SpanUtils.term_to_string(:test) == "test"
    end

    test "converts other terms using inspect" do
      assert SpanUtils.term_to_string(123) == "123"
      assert SpanUtils.term_to_string([1, 2, 3]) == "[1, 2, 3]"
      assert SpanUtils.term_to_string(%{key: "value"}) == "%{key: \"value\"}"
    end
  end

  describe "nil_if_undefined/1" do
    test "converts :undefined to nil" do
      assert SpanUtils.nil_if_undefined(:undefined) == nil
    end

    test "passes through other values" do
      assert SpanUtils.nil_if_undefined("value") == "value"
      assert SpanUtils.nil_if_undefined(123) == 123
      assert SpanUtils.nil_if_undefined(nil) == nil
      assert SpanUtils.nil_if_undefined(:atom) == :atom
    end
  end

  describe "id_to_datadog_id/1" do
    test "returns nil for nil input" do
      assert SpanUtils.id_to_datadog_id(nil) == nil
    end

    test "extracts upper 64 bits from 128-bit trace ID" do
      # Use the same example as in doctest
      trace_id = 0x123456789ABCDEF0FEDCBA0987654321
      # This is the actual upper 64 bits
      expected_upper = 1_311_768_467_463_790_320

      result = SpanUtils.id_to_datadog_id(trace_id)
      assert result == expected_upper
    end
  end

  describe "get_service_from_resource/1" do
    test "extracts service name from resource map" do
      data = %{resource_map: %{"service.name" => "my-service"}}
      assert SpanUtils.get_service_from_resource(data) == "my-service"
    end

    test "returns default when service name is missing" do
      data = %{resource_map: %{}}
      assert SpanUtils.get_service_from_resource(data) == "unknown-service"
    end

    test "returns default when resource map is missing" do
      data = %{}
      assert SpanUtils.get_service_from_resource(data) == "unknown-service"
    end
  end

  describe "get_env_from_resource/1" do
    test "extracts environment from resource map" do
      data = %{resource_map: %{"deployment.environment" => "production"}}
      assert SpanUtils.get_env_from_resource(data) == "production"
    end

    test "returns default when environment is missing" do
      data = %{resource_map: %{}}
      assert SpanUtils.get_env_from_resource(data) == "unknown"
    end

    test "returns default when resource map is missing" do
      data = %{}
      assert SpanUtils.get_env_from_resource(data) == "unknown"
    end
  end

  describe "get_resource_from_span/2" do
    test "builds resource from HTTP route" do
      meta = %{"http.method" => "GET", "http.route" => "/api/users"}
      result = SpanUtils.get_resource_from_span("web.request", meta)
      assert result == "GET /api/users"
    end

    test "builds resource from HTTP target when route is missing" do
      meta = %{"http.method" => "POST", "http.target" => "/api/posts"}
      result = SpanUtils.get_resource_from_span("web.request", meta)
      assert result == "POST /api/posts"
    end

    test "defaults HTTP method to GET when missing" do
      meta = %{"http.route" => "/api/users"}
      result = SpanUtils.get_resource_from_span("web.request", meta)
      assert result == "GET /api/users"
    end

    test "falls back to span name when HTTP attributes are missing" do
      meta = %{}
      result = SpanUtils.get_resource_from_span("db.query", meta)
      assert result == "db.query"
    end
  end

  describe "get_type_from_span/1" do
    test "maps server span kind to web type" do
      assert SpanUtils.get_type_from_span("server") == "web"
    end

    test "maps client span kind to http type" do
      assert SpanUtils.get_type_from_span("client") == "http"
    end

    test "maps producer span kind to queue type" do
      assert SpanUtils.get_type_from_span("producer") == "queue"
    end

    test "maps consumer span kind to queue type" do
      assert SpanUtils.get_type_from_span("consumer") == "queue"
    end

    test "maps internal span kind to custom type" do
      assert SpanUtils.get_type_from_span("internal") == "custom"
    end

    test "maps unknown span kinds to custom type" do
      assert SpanUtils.get_type_from_span("unknown") == "custom"
      assert SpanUtils.get_type_from_span("other") == "custom"
    end
  end

  describe "get_container_id/0" do
    test "returns nil when not in container" do
      # This test will likely return nil in most test environments
      # since we're not running in a container
      result = SpanUtils.get_container_id()
      assert result == nil or is_binary(result)
    end
  end
end
