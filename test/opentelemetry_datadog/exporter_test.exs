defmodule OpentelemetryDatadog.ExporterTest do
	use ExUnit.Case, async: false
	alias OpentelemetryDatadog.Exporter

  require OpentelemetryDatadog.Test.Util, as: Util

  setup do
    Util.setup_test()
  end

end
