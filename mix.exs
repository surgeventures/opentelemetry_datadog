defmodule OpentelemetryDatadog.MixProject do
  use Mix.Project

  def project do
    [
      app: :opentelemetry_datadog,
      version: "0.1.0",
      elixir: "~> 1.14",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      aliases: aliases(),
      description: "Datadog trace exporter for OpenTelemetry in Elixir",
      source_url: "https://github.com/surgeventures/opentelemetry_datadog",
      package: [
        licenses: ["MIT"],
        links: %{"GitHub" => "https://github.com/surgeventures/opentelemetry_datadog"}
      ]
    ]
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:logger]
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      {:opentelemetry, "~> 1.4", runtime: false},
      {:msgpax, "~> 2.4"},
      {:req, "~> 0.4.14"},
      # Optional: For context propagation across processes and tasks
      {:opentelemetry_process_propagator, "~> 0.3.0", optional: true},
      {:opentelemetry_function, "~> 0.1.0", optional: true}
    ]
  end

  defp aliases do
    [
      "test.unit": ["test --only unit"],
      "test.integration": ["test --only integration"],
      "test.all": ["test"]
    ]
  end
end
