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
