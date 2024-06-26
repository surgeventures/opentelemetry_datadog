defmodule OpentelemetryDatadog.MixProject do
  use Mix.Project

  def project do
    [
      app: :opentelemetry_datadog,
      version: "0.1.0",
      elixir: "~> 1.14",
      start_permanent: Mix.env() == :prod,
      deps: deps()
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
      {:req, "~> 0.4.14"}
    ]
  end
end
