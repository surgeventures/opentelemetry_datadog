defmodule OpentelemetryDatadog.SpanProcessorTest do
  use ExUnit.Case, async: true

  @moduletag :unit

  alias OpentelemetryDatadog.SpanProcessor

  describe "SpanProcessor protocol" do
    test "V05 processor struct exists" do
      processor = %SpanProcessor.V05{}
      assert processor.__struct__ == SpanProcessor.V05
    end

    test "protocol implementation exists for V05" do
      assert SpanProcessor.impl_for(%SpanProcessor.V05{}) ==
               SpanProcessor.OpentelemetryDatadog.SpanProcessor.V05
    end
  end
end
