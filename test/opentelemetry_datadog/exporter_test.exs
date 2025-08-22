defmodule OpentelemetryDatadog.ExporterTest do
  use ExUnit.Case, async: true
  use OpentelemetryDatadog.TestHelpers

  alias OpentelemetryDatadog.Exporter

  describe "init/1" do
    test "initializes with required configuration" do
      config = [
        host: "localhost",
        port: 8126
      ]

      assert {:ok, state} = Exporter.init(config)
      assert state.host == "localhost"
      assert state.port == 8126
    end

    test "initializes with production configuration" do
      prod_config("api-service", "v2.1.0")
      {:ok, config} = OpentelemetryDatadog.Config.load()
      exporter_config = OpentelemetryDatadog.Config.to_exporter_config(config)

      assert {:ok, state} = Exporter.init(exporter_config)
      assert state.host == "datadog-agent.kube-system.svc.cluster.local"
      assert state.port == 8126
    end

    test "initializes with development configuration" do
      dev_config("test-service")
      {:ok, config} = OpentelemetryDatadog.Config.load()
      exporter_config = OpentelemetryDatadog.Config.to_exporter_config(config)

      assert {:ok, state} = Exporter.init(exporter_config)
      assert state.host == "localhost"
    end

    test "requires host and port" do
      config = [port: 8126]

      assert_raise KeyError, fn ->
        Exporter.init(config)
      end
    end
  end

  describe "export/4" do
    test "handles metrics export" do
      {:ok, state} = Exporter.init(host: "localhost", port: 8126)
      assert Exporter.export(:metrics, nil, nil, state) == :ok
    end
  end

  describe "shutdown/1" do
    test "shuts down cleanly" do
      {:ok, state} = Exporter.init(host: "localhost", port: 8126)
      assert Exporter.shutdown(state) == :ok
    end
  end
end
