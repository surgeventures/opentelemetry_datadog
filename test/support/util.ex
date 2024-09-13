defmodule OpentelemetryDatadog.Test.Util do
  @moduledoc false

  require Record
  @deps_dir Mix.Project.deps_path()

  @fields Record.extract(:span, from: "#{@deps_dir}/opentelemetry/include/otel_span.hrl")
  Record.defrecord(:span, @fields)

  @fields Record.extract(:tracer, from: "#{@deps_dir}/opentelemetry/src/otel_tracer.hrl")
  Record.defrecord(:tracer, @fields)

  @fields Record.extract(:span_ctx, from: "#{@deps_dir}/opentelemetry_api/include/opentelemetry.hrl")
  Record.defrecord(:span_ctx, @fields)

  @fields Record.extract(:attributes, from: "#{@deps_dir}/opentelemetry_api/src/otel_attributes.erl")
  Record.defrecord(:attributes, @fields)


  def setup_test do
    Application.load(:opentelemetry)

    Application.put_env(:opentelemetry, :processors, [
      {:otel_simple_processor, %{exporter: {:otel_exporter_pid, self()}}}
    ])

    {:ok, _} = Application.ensure_all_started(:opentelemetry)

    ExUnit.Callbacks.on_exit(fn ->
      Application.stop(:opentelemetry)
      Application.unload(:opentelemetry)
    end)
  end
end
