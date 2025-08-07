defmodule OpentelemetryDatadog.SpanProcessorTest do
  use ExUnit.Case, async: true

  alias OpentelemetryDatadog.SpanProcessor

  @moduletag :unit

  describe "SpanProcessor protocol" do
    test "V04 processor struct exists" do
      processor = %SpanProcessor.V04{}
      assert processor.__struct__ == SpanProcessor.V04
    end

    test "V05 processor struct exists" do
      processor = %SpanProcessor.V05{}
      assert processor.__struct__ == SpanProcessor.V05
    end

    test "protocol implementation exists for V04" do
      assert SpanProcessor.impl_for(%SpanProcessor.V04{}) ==
               SpanProcessor.OpentelemetryDatadog.SpanProcessor.V04
    end

    test "protocol implementation exists for V05" do
      assert SpanProcessor.impl_for(%SpanProcessor.V05{}) ==
               SpanProcessor.OpentelemetryDatadog.SpanProcessor.V05
    end
  end
end
