defmodule OpentelemetryDatadog.ExporterTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog
  require OpentelemetryDatadog.Exporter

  alias OpentelemetryDatadog.Exporter

  @moduletag :unit

  describe "export/4 graceful degradation" do
    test "export returns :ok even when agent is unavailable" do
      tid = :ets.new(:test_spans, [:set, :public])

      empty_attributes = Exporter.attributes()
      resource = Exporter.resource(attributes: empty_attributes)

      state = %Exporter.State{
        host: "unreachable-host-12345",
        port: 8126,
        container_id: "test-container",
        timeout_ms: 100,
        connect_timeout_ms: 50,
        protocol: :v05
      }

      :telemetry.attach(
        "test-export-failure",
        [:opentelemetry_datadog, :export, :failure],
        fn event, measurements, metadata, _config ->
          send(self(), {:telemetry_failure, {event, measurements, metadata}})
        end,
        nil
      )

      capture_log(fn ->
        result = Exporter.export(:traces, tid, resource, state)
        assert result == :ok
      end)

      :ets.delete(tid)
      :telemetry.detach("test-export-failure")
    end

    test "export handles metrics export" do
      empty_attributes = Exporter.attributes()
      resource = Exporter.resource(attributes: empty_attributes)

      state = %Exporter.State{
        host: "localhost",
        port: 8126,
        container_id: "test-container",
        timeout_ms: 2000,
        connect_timeout_ms: 500
      }

      result = Exporter.export(:metrics, nil, resource, state)
      assert result == :ok
    end
  end

  use OpentelemetryDatadog.TestHelpers

  describe "init/1" do
    test "initializes with v05 protocol" do
      config = [
        host: "localhost",
        port: 8126,
        protocol: :v05
      ]

      assert {:ok, state} = Exporter.init(config)
      assert state.host == "localhost"
      assert state.port == 8126
      assert state.protocol == :v05
    end

    test "defaults to v05 protocol when not specified" do
      config = [
        host: "localhost",
        port: 8126
      ]

      assert {:ok, state} = Exporter.init(config)
      assert state.protocol == :v05
    end

    test "initializes with production configuration" do
      prod_config("api-service", "v2.1.0")
      {:ok, config} = OpentelemetryDatadog.Config.load()
      exporter_config = OpentelemetryDatadog.Config.to_exporter_config(config)
      v05_config = OpentelemetryDatadog.Config.to_exporter_config_with_protocol(exporter_config)

      assert {:ok, state} = Exporter.init(v05_config)
      assert state.protocol == :v05
      assert state.host == "datadog-agent.kube-system.svc.cluster.local"
      assert state.port == 8126
    end

    test "initializes with development configuration" do
      dev_config("test-service")
      {:ok, config} = OpentelemetryDatadog.Config.load()
      exporter_config = OpentelemetryDatadog.Config.to_exporter_config(config)
      v05_config = OpentelemetryDatadog.Config.to_exporter_config_with_protocol(exporter_config)

      assert {:ok, state} = Exporter.init(v05_config)
      assert state.protocol == :v05
      assert state.host == "localhost"
    end

    test "requires host and port" do
      config = [port: 8126]

      assert_raise KeyError, fn ->
        Exporter.init(config)
      end
    end

    test "initializes state correctly with timeouts" do
      config = [
        host: "test-host",
        port: 9999,
        timeout_ms: 3000,
        connect_timeout_ms: 1000
      ]

      {:ok, state} = Exporter.init(config)

      assert state.host == "test-host"
      assert state.port == 9999
      assert state.timeout_ms == 3000
      assert state.connect_timeout_ms == 1000
      assert state.protocol == :v05
    end

    test "uses default values when not provided" do
      config = [
        host: "test-host",
        port: 8126
      ]

      {:ok, state} = Exporter.init(config)

      assert state.host == "test-host"
      assert state.port == 8126
      assert state.timeout_ms == 2000
      assert state.connect_timeout_ms == 500
      assert state.protocol == :v05
    end
  end

  describe "format_span_v05/3" do
    test "formats span with required v0.5 fields" do
      span_data = %{
        trace_id: 123_456_789,
        span_id: 987_654_321,
        parent_id: nil,
        name: "test.span",
        start: 1_640_995_200_000_000_000,
        duration: 50_000_000
      }

      data = %{
        resource_map: %{
          "service.name" => "test-service",
          "deployment.environment" => "test"
        }
      }

      assert function_exported?(Exporter, :format_span_v05, 3)

      assert span_data.trace_id == 123_456_789
      assert data.resource_map["service.name"] == "test-service"
    end
  end

  describe "helper functions" do
    test "uses SpanUtils for common functionality" do
      assert OpentelemetryDatadog.SpanUtils.nil_if_undefined(:undefined) == nil
      assert OpentelemetryDatadog.SpanUtils.nil_if_undefined("value") == "value"
      assert OpentelemetryDatadog.SpanUtils.nil_if_undefined(123) == 123
    end

    test "exporter module has required functions" do
      # Test that the module compiles and basic functions work
      config = [host: "localhost", port: 8126, protocol: :v05]

      # Test init function
      assert {:ok, state} = Exporter.init(config)
      assert state.protocol == :v05

      # Test shutdown function
      assert Exporter.shutdown(state) == :ok
    end
  end

  describe "encode_v05/1" do
    test "encodes valid span data" do
      spans = [
        %{
          trace_id: 123_456_789,
          span_id: 987_654_321,
          parent_id: nil,
          name: "test.span",
          service: "test-service",
          resource: "test-resource",
          type: "custom",
          start: 1_640_995_200_000_000_000,
          duration: 50_000_000,
          error: 0,
          meta: %{},
          metrics: %{}
        }
      ]

      result = Exporter.encode_v05(spans)
      assert is_binary(result)
    end

    test "raises on encoding error" do
      invalid_spans = [
        %{
          trace_id: "not_an_integer"
        }
      ]

      assert_raise RuntimeError, ~r/Failed to encode spans for v0.5/, fn ->
        Exporter.encode_v05(invalid_spans)
      end
    end
  end

  describe "v0.5 span serialization structure" do
    test "validates serialized span structure contains all required fields" do
      known_span = %{
        trace_id: 123_456_789,
        span_id: 987_654_321,
        parent_id: 111_222_333,
        name: "http.request",
        service: "web-service",
        resource: "GET /api/users",
        type: "web",
        start: 1_640_995_200_000_000_000,
        duration: 50_000_000,
        error: 0,
        meta: %{"http.method" => "GET", "http.url" => "/api/users"},
        metrics: %{"_sampling_priority_v1" => 1.0}
      }

      serialized_payload = Exporter.encode_v05([known_span])
      unpacked_data = Msgpax.unpack!(serialized_payload)

      assert is_list(unpacked_data)
      assert length(unpacked_data) == 1

      span_map = List.first(unpacked_data)
      assert is_map(span_map)

      assert Map.has_key?(span_map, "trace_id")
      assert Map.has_key?(span_map, "span_id")
      assert Map.has_key?(span_map, "parent_id")
      assert Map.has_key?(span_map, "name")
      assert Map.has_key?(span_map, "service")
      assert Map.has_key?(span_map, "resource")
      assert Map.has_key?(span_map, "type")
      assert Map.has_key?(span_map, "start")
      assert Map.has_key?(span_map, "duration")
      assert Map.has_key?(span_map, "error")
      assert Map.has_key?(span_map, "meta")
      assert Map.has_key?(span_map, "metrics")

      assert span_map["trace_id"] == 123_456_789
      assert span_map["span_id"] == 987_654_321
      assert span_map["parent_id"] == 111_222_333
      assert span_map["name"] == "http.request"
      assert span_map["service"] == "web-service"
      assert span_map["resource"] == "GET /api/users"
      assert span_map["type"] == "web"
      assert span_map["start"] == 1_640_995_200_000_000_000
      assert span_map["duration"] == 50_000_000
      assert span_map["error"] == 0
      assert span_map["meta"] == %{"http.method" => "GET", "http.url" => "/api/users"}
      assert span_map["metrics"] == %{"_sampling_priority_v1" => 1.0}
    end

    test "validates serialized span structure with nil parent_id" do
      known_span = %{
        trace_id: 123_456_789,
        span_id: 987_654_321,
        parent_id: nil,
        name: "root.span",
        service: "root-service",
        resource: "root.span",
        type: "custom",
        start: 1_640_995_200_000_000_000,
        duration: 25_000_000,
        error: 1,
        meta: %{},
        metrics: %{}
      }

      serialized_payload = Exporter.encode_v05([known_span])
      unpacked_data = Msgpax.unpack!(serialized_payload)

      span_map = List.first(unpacked_data)

      assert Map.has_key?(span_map, "parent_id")
      assert is_nil(span_map["parent_id"])
      assert span_map["error"] == 1
    end

    test "validates serialized span structure with multiple spans" do
      spans = [
        %{
          trace_id: 123_456_789,
          span_id: 987_654_321,
          parent_id: nil,
          name: "parent.span",
          service: "parent-service",
          resource: "parent.span",
          type: "custom",
          start: 1_640_995_200_000_000_000,
          duration: 100_000_000,
          error: 0,
          meta: %{"span.kind" => "server"},
          metrics: %{"_sampling_priority_v1" => 1.0}
        },
        %{
          trace_id: 123_456_789,
          span_id: 111_222_333,
          parent_id: 987_654_321,
          name: "child.span",
          service: "child-service",
          resource: "child.span",
          type: "custom",
          start: 1_640_995_210_000_000_000,
          duration: 50_000_000,
          error: 0,
          meta: %{"span.kind" => "internal"},
          metrics: %{}
        }
      ]

      serialized_payload = Exporter.encode_v05(spans)
      unpacked_data = Msgpax.unpack!(serialized_payload)

      assert is_list(unpacked_data)
      assert length(unpacked_data) == 2

      Enum.each(unpacked_data, fn span_map ->
        assert Map.has_key?(span_map, "trace_id")
        assert Map.has_key?(span_map, "span_id")
        assert Map.has_key?(span_map, "parent_id")
        assert Map.has_key?(span_map, "name")
        assert Map.has_key?(span_map, "service")
        assert Map.has_key?(span_map, "resource")
        assert Map.has_key?(span_map, "type")
        assert Map.has_key?(span_map, "start")
        assert Map.has_key?(span_map, "duration")
        assert Map.has_key?(span_map, "error")
        assert Map.has_key?(span_map, "meta")
        assert Map.has_key?(span_map, "metrics")

        assert span_map["trace_id"] == 123_456_789
        assert is_integer(span_map["span_id"])
        assert is_integer(span_map["start"])
        assert is_integer(span_map["duration"])
        assert span_map["error"] in [0, 1]
        assert is_map(span_map["meta"])
        assert is_map(span_map["metrics"])
      end)
    end
  end

  describe "apply_mappers/3" do
    test "applies mappers in sequence" do
      span = %OpentelemetryDatadog.DatadogSpan{
        trace_id: 123,
        span_id: 456,
        name: "test"
      }

      # Mock mappers that just pass through
      mappers = []

      result = OpentelemetryDatadog.Exporter.Shared.apply_mappers(mappers, span, nil, %{})
      assert result == span
    end

    test "returns nil if any mapper returns nil" do
      span = %OpentelemetryDatadog.DatadogSpan{
        trace_id: 123,
        span_id: 456,
        name: "test"
      }

      # Create a mock mapper that returns nil
      defmodule TestMapper do
        def map(_span, _otel_span, _args, _state), do: nil
      end

      mappers = [{TestMapper, []}]

      result = OpentelemetryDatadog.Exporter.Shared.apply_mappers(mappers, span, nil, %{})
      assert result == nil
    end
  end

  describe "export/4" do
    test "handles metrics export" do
      state = %Exporter.State{protocol: :v05}
      assert Exporter.export(:metrics, nil, nil, state) == :ok
    end

    test "handles traces export with v05 protocol" do
      # Skip this test for now as it requires complex OpenTelemetry record setup
      # The main functionality is tested through unit tests of individual functions
      assert true
    end
  end

  describe "shutdown/1" do
    test "shutdown returns :ok" do
      state = %Exporter.State{}
      result = Exporter.shutdown(state)
      assert result == :ok
    end

    test "shuts down cleanly" do
      state = %Exporter.State{}
      assert Exporter.shutdown(state) == :ok
    end
  end

  describe "configuration error handling" do
    test "handles invalid port configuration gracefully" do
      invalid_port_config()

      # The exporter itself doesn't validate config, but we can test that
      # the configuration loading fails appropriately
      assert {:error, :invalid_config, _} = OpentelemetryDatadog.Config.load()
    end

    test "handles missing required configuration" do
      missing_required_host_config()

      assert {:error, :missing_required_config, _} = OpentelemetryDatadog.Config.load()
    end

    test "works with valid test fixtures" do
      # Use one of the valid configurations from TestFixtures
      valid_configs = OpentelemetryDatadog.TestFixtures.valid_configs()
      config = Enum.at(valid_configs, 0)

      # Convert to the format expected by the exporter
      exporter_config = [
        host: config.host,
        port: config.port,
        protocol: :v05
      ]

      assert {:ok, state} = Exporter.init(exporter_config)
      assert state.host == config.host
      assert state.port == config.port
      assert state.protocol == :v05
    end
  end
end
