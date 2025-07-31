defmodule OpentelemetryDatadogTest do
  use ExUnit.Case
  doctest OpentelemetryDatadog

  test "greets the world" do
    assert OpentelemetryDatadog.hello() == :world
  end
end
