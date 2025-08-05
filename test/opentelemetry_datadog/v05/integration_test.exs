defmodule OpentelemetryDatadog.V05.IntegrationTest do
  use ExUnit.Case, async: false
  use OpentelemetryDatadog.TestHelpers

  alias OpentelemetryDatadog.V05.{Config, Exporter, Encoder}

  @moduletag :integration

  describe "v0.5 integration" do
    test "can configure v0.5 exporter from environment" do
      minimal_config()

      assert {:ok, config} = Config.get_config()
      assert config[:protocol] == :v05
      assert config[:host] == "localhost"
      assert config[:port] == OpentelemetryDatadog.DatadogConstants.default(:port)
    end

    test "can initialize v0.5 exporter" do
      config = [
        host: "localhost",
        port: 8126,
        protocol: :v05
      ]

      assert {:ok, state} = Exporter.init(config)
      assert state.protocol == :v05
      assert state.host == "localhost"
      assert state.port == 8126
    end

    test "can encode spans for v0.5 API" do
      spans = [
        %{
          trace_id: 123_456_789,
          span_id: 987_654_321,
          parent_id: nil,
          name: "integration.test",
          service: "test-service",
          resource: "integration test",
          type: "test",
          start: 1_640_995_200_000_000_000,
          duration: 50_000_000,
          error: 0,
          meta: %{"test.type" => "integration"},
          metrics: %{"test.count" => 1}
        }
      ]

      assert {:ok, encoded} = Encoder.encode(spans)
      assert is_binary(encoded)

      {:ok, decoded} = Msgpax.unpack(encoded)
      assert is_list(decoded)
      assert length(decoded) == 1

      [span] = decoded
      assert span["trace_id"] == 123_456_789
      assert span["span_id"] == 987_654_321
      assert span["name"] == "integration.test"
      assert span["service"] == "test-service"
      assert span["resource"] == "integration test"
      assert span["type"] == "test"
      assert span["error"] == 0
      assert span["meta"]["test.type"] == "integration"
      assert span["metrics"]["test.count"] == 1
    end

    test "v0.5 configuration is independent of v0.4" do
      standard_config = [host: "localhost", port: 8126]
      config_map = Enum.into(standard_config, %{})
      assert OpentelemetryDatadog.Config.validate(config_map) == :ok

      # v0.5 config should work independently
      v05_config = Config.to_v05_exporter_config(standard_config)
      assert v05_config[:protocol] == :v05
      assert v05_config[:host] == "localhost"
      assert v05_config[:port] == 8126
    end

    test "demonstrates v0.5 usage pattern" do
      # 1. Set up environment and load configuration
      dev_config("example-service")
      assert {:ok, config} = Config.get_config()

      # 2. Initialize exporter
      assert {:ok, exporter_state} = Exporter.init(config)
      assert exporter_state.protocol == :v05

      # 3. Create sample span data
      span_data = %{
        trace_id: 999_888_777,
        span_id: 111_222_333,
        parent_id: nil,
        name: "example.operation",
        service: "example-service",
        resource: "GET /api/example",
        type: "web",
        start: System.system_time(:nanosecond),
        # 25ms
        duration: 25_000_000,
        error: 0,
        meta: %{
          "http.method" => "GET",
          "http.url" => "/api/example",
          "http.status_code" => "200"
        },
        metrics: %{
          "http.response_time" => 0.025
        }
      }

      # 4. Encode for transmission
      assert {:ok, encoded} = Encoder.encode([span_data])
      assert is_binary(encoded)

      # 5. Verify encoding is correct
      {:ok, decoded} = Msgpax.unpack(encoded)
      [decoded_span] = decoded

      assert decoded_span["trace_id"] == 999_888_777
      assert decoded_span["service"] == "example-service"
      assert decoded_span["resource"] == "GET /api/example"
      assert decoded_span["type"] == "web"
      assert decoded_span["meta"]["http.method"] == "GET"
      assert decoded_span["metrics"]["http.response_time"] == 0.025
    end

    test "works with production configuration" do
      prod_config("api-service", "v1.2.3")

      assert {:ok, config} = Config.get_config()
      assert config[:protocol] == :v05
      assert config[:host] == "datadog-agent.kube-system.svc.cluster.local"

      assert {:ok, exporter_state} = Exporter.init(config)
      assert exporter_state.protocol == :v05
    end

    test "works with containerized configuration" do
      containerized_config("container-service", "v2.0.0", "staging")

      assert {:ok, config} = Config.get_config()
      assert config[:protocol] == :v05
      assert config[:host] == "dd-agent"

      assert {:ok, exporter_state} = Exporter.init(config)
      assert exporter_state.protocol == :v05
    end

    test "works with Phoenix configuration" do
      phoenix_config("phoenix-web-app")

      assert {:ok, config} = Config.get_config()
      assert config[:protocol] == :v05
      assert config[:host] == "localhost"

      assert {:ok, exporter_state} = Exporter.init(config)
      assert exporter_state.protocol == :v05
    end

    test "handles error scenarios gracefully" do
      # Test that configuration errors are handled properly
      invalid_port_config()

      assert {:error, :invalid_config, _} = Config.get_config()
    end

    test "works with CI configuration" do
      ci_config("ci-test-service")

      assert {:ok, config} = Config.get_config()
      assert config[:protocol] == :v05
      assert config[:host] == "localhost"

      # CI config should have full sampling
      {:ok, base_config} = OpentelemetryDatadog.Config.load()
      assert base_config.sample_rate == 1.0
    end
  end
end
