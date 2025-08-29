defmodule OpentelemetryDatadog.TestFixtures do
  @spec valid_configs() :: [map()]
  def valid_configs do
    [
      %{
        host: "localhost",
        port: 8126
      },
      %{
        host: "localhost",
        port: 8126,
        service: "dev-app",
        env: "development",
        tags: %{"framework" => "phoenix", "language" => "elixir"}
      },
      %{
        host: "datadog-agent.kube-system.svc.cluster.local",
        port: 8126,
        service: "api-service",
        version: "1.0.0",
        env: "production",
        tags: %{"team" => "backend", "component" => "api"},
        sample_rate: 0.1
      },
      %{
        host: "staging-agent.example.com",
        port: 9126,
        service: "staging-app",
        version: "v2.0.0-rc1",
        env: "staging",
        tags: %{"deploy" => "blue-green", "region" => "us-west-2"},
        sample_rate: 0.5
      },
      %{
        host: "dd-agent.istio-system.svc.cluster.local",
        port: 8126,
        service: "user-service",
        version: "3.1.4",
        env: "production",
        tags: %{
          "component" => "auth",
          "architecture" => "microservice",
          "mesh" => "istio",
          "team" => "identity"
        },
        sample_rate: 0.1
      }
    ]
  end

  @spec invalid_configs() :: [map()]
  def invalid_configs do
    [
      %{
        port: 8126,
        service: "test-service"
      },
      %{
        host: "localhost",
        port: "invalid"
      },
      %{
        host: "localhost",
        port: 70000
      },
      %{
        host: "localhost",
        port: 8126,
        sample_rate: 1.5
      },
      %{
        host: "localhost",
        port: 8126,
        sample_rate: -0.1
      },
      %{
        host: "",
        port: 8126
      },
      %{
        host: nil,
        port: 8126
      },
      %{
        host: "localhost",
        port: 0
      },
      %{
        host: "localhost",
        port: -1
      }
    ]
  end
end
