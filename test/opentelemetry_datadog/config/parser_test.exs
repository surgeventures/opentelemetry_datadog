defmodule OpentelemetryDatadog.Config.ParserTest do
  use ExUnit.Case, async: true
  import OpentelemetryDatadog.TestHelpers

  alias OpentelemetryDatadog.Config.Parser

  setup do
    reset_env()
    :ok
  end

  describe "get_env/3" do
    test "returns default when env var is nil" do
      assert {:ok, "default"} = Parser.get_env("MISSING_VAR", :string, default: "default")
    end

    test "returns default when env var is empty string" do
      put_env(%{"EMPTY_VAR" => ""})
      assert {:ok, "default"} = Parser.get_env("EMPTY_VAR", :string, default: "default")
    end

    test "parses string values" do
      put_env(%{"STRING_VAR" => "test-value"})
      assert {:ok, "test-value"} = Parser.get_env("STRING_VAR", :string)
    end

    test "parses integer values" do
      put_env(%{"INT_VAR" => "8126"})
      assert {:ok, 8126} = Parser.get_env("INT_VAR", :integer)
    end

    test "parses float values" do
      put_env(%{"FLOAT_VAR" => "0.5"})
      assert {:ok, 0.5} = Parser.get_env("FLOAT_VAR", :float)
    end

    test "handles invalid integer" do
      put_env(%{"INT_VAR" => "invalid"})
      assert {:error, :invalid_config, msg} = Parser.get_env("INT_VAR", :integer)
      assert msg =~ "must be a valid integer"
    end

    test "handles invalid float" do
      put_env(%{"FLOAT_VAR" => "invalid"})
      assert {:error, :invalid_config, msg} = Parser.get_env("FLOAT_VAR", :float)
      assert msg =~ "must be a valid float"
    end

    test "handles DD_TRACE_AGENT_PORT type conversion" do
      put_dd_env("DD_TRACE_AGENT_PORT", "invalid")
      assert {:error, :invalid_config, msg} = Parser.get_env("DD_TRACE_AGENT_PORT", :integer)
      assert msg =~ "must be a valid integer"
    end

    test "handles DD_TRACE_SAMPLE_RATE type conversion" do
      put_dd_env("DD_TRACE_SAMPLE_RATE", "invalid")
      assert {:error, :invalid_config, msg} = Parser.get_env("DD_TRACE_SAMPLE_RATE", :float)
      assert msg =~ "must be a valid float"
    end

    test "applies validation function" do
      put_env(%{"PORT_VAR" => "70000"})

      validate_port = fn port ->
        if port > 0 and port <= 65535 do
          :ok
        else
          {:error, :invalid_config, "invalid port"}
        end
      end

      assert {:error, :invalid_config, "invalid port"} =
               Parser.get_env("PORT_VAR", :integer, validate: validate_port)
    end

    test "skips validation when validate is nil" do
      put_env(%{"PORT_VAR" => "70000"})
      assert {:ok, 70000} = Parser.get_env("PORT_VAR", :integer, validate: nil)
    end
  end
end
