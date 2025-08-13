defmodule OpentelemetryDatadog.ResourceAttributesTest do
  use ExUnit.Case, async: true

  alias OpentelemetryDatadog.ResourceAttributes

  require Record
  @deps_dir Mix.Project.deps_path()

  Record.defrecord(
    :resource,
    Record.extract(:resource, from: "#{@deps_dir}/opentelemetry/src/otel_resource.erl")
  )

  Record.defrecord(
    :attributes,
    Record.extract(:attributes, from: "#{@deps_dir}/opentelemetry_api/src/otel_attributes.erl")
  )

  @moduletag :unit

  describe "extract/1" do
    test "extracts basic resource attributes with defaults" do
      resource_tuple = build_resource(%{})

      attrs = ResourceAttributes.extract(resource_tuple)

      assert attrs["service.name"] == "unknown-service"
      assert attrs["service.version"] == "unknown"
      assert attrs["deployment.environment"] == "unknown"
      assert attrs["telemetry.sdk.name"] == "opentelemetry"
      assert attrs["telemetry.sdk.language"] == "elixir"
      assert is_binary(attrs["telemetry.sdk.version"])
    end

    test "extracts service name from resource" do
      resource_map = %{"service.name" => "my-service"}
      resource_tuple = build_resource(resource_map)

      attrs = ResourceAttributes.extract(resource_tuple)

      assert attrs["service.name"] == "my-service"
    end

    test "extracts service version from resource" do
      resource_map = %{"service.version" => "1.2.3"}
      resource_tuple = build_resource(resource_map)

      attrs = ResourceAttributes.extract(resource_tuple)

      assert attrs["service.version"] == "1.2.3"
    end

    test "extracts deployment environment from resource" do
      resource_map = %{"deployment.environment" => "production"}
      resource_tuple = build_resource(resource_map)

      attrs = ResourceAttributes.extract(resource_tuple)

      assert attrs["deployment.environment"] == "production"
    end

    test "includes additional resource attributes" do
      resource_map = %{
        "service.name" => "my-service",
        "custom.attribute" => "custom-value",
        "another.attribute" => "another-value"
      }

      resource_tuple = build_resource(resource_map)

      attrs = ResourceAttributes.extract(resource_tuple)

      assert attrs["service.name"] == "my-service"
      assert attrs["custom.attribute"] == "custom-value"
      assert attrs["another.attribute"] == "another-value"
    end

    test "converts non-string values to strings" do
      resource_map = %{
        "service.name" => :my_service,
        "numeric.value" => 42,
        "boolean.value" => true
      }

      resource_tuple = build_resource(resource_map)

      attrs = ResourceAttributes.extract(resource_tuple)

      assert attrs["service.name"] == "my_service"
      assert attrs["numeric.value"] == "42"
      assert attrs["boolean.value"] == "true"
    end
  end

  describe "from_resource_data/1" do
    test "extracts from pre-processed resource data" do
      resource_data = %{
        resource_map: %{
          "service.name" => "test-service",
          "service.version" => "0.1.0",
          "deployment.environment" => "staging",
          "custom.attr" => "custom-val"
        }
      }

      attrs = ResourceAttributes.from_resource_data(resource_data)

      assert attrs["service.name"] == "test-service"
      assert attrs["service.version"] == "0.1.0"
      assert attrs["deployment.environment"] == "staging"
      assert attrs["telemetry.sdk.name"] == "opentelemetry"
      assert attrs["telemetry.sdk.language"] == "elixir"
      assert attrs["custom.attr"] == "custom-val"
    end

    test "handles empty resource data with defaults" do
      resource_data = %{resource_map: %{}}

      attrs = ResourceAttributes.from_resource_data(resource_data)

      assert attrs["service.name"] == "unknown-service"
      assert attrs["service.version"] == "unknown"
      assert attrs["deployment.environment"] == "unknown"
      assert attrs["telemetry.sdk.name"] == "opentelemetry"
      assert attrs["telemetry.sdk.language"] == "elixir"
      assert is_binary(attrs["telemetry.sdk.version"])
    end
  end

  describe "individual attribute getters" do
    test "get_service_name/1 returns service name or default" do
      assert ResourceAttributes.get_service_name(%{"service.name" => "my-service"}) ==
               "my-service"

      assert ResourceAttributes.get_service_name(%{}) == "unknown-service"
    end

    test "get_service_version/1 returns service version or default" do
      assert ResourceAttributes.get_service_version(%{"service.version" => "1.0.0"}) == "1.0.0"
      assert ResourceAttributes.get_service_version(%{}) == "unknown"
    end

    test "get_deployment_environment/1 returns environment or default" do
      assert ResourceAttributes.get_deployment_environment(%{"deployment.environment" => "prod"}) ==
               "prod"

      assert ResourceAttributes.get_deployment_environment(%{}) == "unknown"
    end

    test "get_sdk_version/0 returns OpenTelemetry version" do
      version = ResourceAttributes.get_sdk_version()
      assert is_binary(version)
      assert version != ""
    end
  end

  describe "integration with expected output format" do
    test "produces expected attribute structure" do
      resource_map = %{
        "service.name" => "my-service",
        "service.version" => "1.2.3",
        "deployment.environment" => "production"
      }

      resource_tuple = build_resource(resource_map)
      attrs = ResourceAttributes.extract(resource_tuple)

      expected_keys = [
        "service.name",
        "service.version",
        "deployment.environment",
        "telemetry.sdk.name",
        "telemetry.sdk.language"
      ]

      for key <- expected_keys do
        assert Map.has_key?(attrs, key), "Missing expected key: #{key}"

        assert is_binary(attrs[key]),
               "Value for #{key} should be string, got: #{inspect(attrs[key])}"
      end

      assert attrs["service.name"] == "my-service"
      assert attrs["service.version"] == "1.2.3"
      assert attrs["deployment.environment"] == "production"
      assert attrs["telemetry.sdk.name"] == "opentelemetry"
      assert attrs["telemetry.sdk.language"] == "elixir"
    end
  end

  defp build_resource(resource_map) do
    attributes_record = attributes(map: resource_map, dropped: 0)
    resource(attributes: attributes_record, schema_url: :undefined)
  end
end
