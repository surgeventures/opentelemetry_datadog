defmodule OpentelemetryDatadog.ResourceAttributes do
  @moduledoc """
  Auto-populates resource attributes from OpenTelemetry resources.

  This module extracts common resource attributes that are used by Datadog
  and provides them in a standardized format. The attributes are populated
  from OpenTelemetry resource information when available, with fallback
  defaults for missing values.
  """

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

  @type resource_attributes :: %{
          String.t() => String.t()
        }

  @doc """
  Extracts resource attributes from OpenTelemetry resource.

  Returns a map of standard resource attributes with OpenTelemetry
  semantic conventions keys and appropriate defaults.

  ## Examples

      iex> resource_tuple = build_test_resource()
      iex> attrs = OpentelemetryDatadog.ResourceAttributes.extract(resource_tuple)
      iex> Map.has_key?(attrs, "service.name")
      true
      iex> Map.has_key?(attrs, "telemetry.sdk.language")
      true

  ## Attributes

  The following attributes are extracted:

  - `"service.name"` - Service name, defaults to "unknown-service"
  - `"service.version"` - Service version, defaults to "unknown"
  - `"deployment.environment"` - Deployment environment, defaults to "unknown"
  - `"telemetry.sdk.name"` - Always "opentelemetry"
  - `"telemetry.sdk.language"` - Always "elixir"
  - `"telemetry.sdk.version"` - OpenTelemetry version from the application

  Additional attributes from the resource are also included if present.
  """
  @spec extract(tuple()) :: resource_attributes()
  def extract(resource_tuple) do
    resource_data = resource(resource_tuple)
    attributes_record = Keyword.fetch!(resource_data, :attributes)
    attributes_data = attributes(attributes_record)
    resource_map = Keyword.fetch!(attributes_data, :map)

    # Start with OpenTelemetry standard attributes
    base_attributes = %{
      "service.name" => get_service_name(resource_map),
      "service.version" => get_service_version(resource_map),
      "deployment.environment" => get_deployment_environment(resource_map),
      "telemetry.sdk.name" => "opentelemetry",
      "telemetry.sdk.language" => "elixir",
      "telemetry.sdk.version" => get_sdk_version()
    }

    additional_attributes =
      resource_map
      |> Enum.reject(fn {key, _value} -> Map.has_key?(base_attributes, key) end)
      |> Enum.map(fn {key, value} -> {to_string(key), to_string(value)} end)
      |> Enum.into(%{})

    Map.merge(base_attributes, additional_attributes)
  end

  @doc """
  Extracts resource attributes from resource data map (already processed).

  This is a convenience function for cases where the resource has already
  been processed by `OpentelemetryDatadog.Utils.Exporter.build_resource_data/1`.

  ## Examples

      iex> data = %{resource_map: %{"service.name" => "my-service"}}
      iex> attrs = OpentelemetryDatadog.ResourceAttributes.from_resource_data(data)
      iex> attrs["service.name"]
      "my-service"
  """
  @spec from_resource_data(map()) :: resource_attributes()
  def from_resource_data(%{resource_map: resource_map}) do
    base_attributes = %{
      "service.name" => get_service_name(resource_map),
      "service.version" => get_service_version(resource_map),
      "deployment.environment" => get_deployment_environment(resource_map),
      "telemetry.sdk.name" => "opentelemetry",
      "telemetry.sdk.language" => "elixir",
      "telemetry.sdk.version" => get_sdk_version()
    }

    additional_attributes =
      resource_map
      |> Enum.reject(fn {key, _value} -> Map.has_key?(base_attributes, key) end)
      |> Enum.map(fn {key, value} -> {to_string(key), to_string(value)} end)
      |> Enum.into(%{})

    Map.merge(base_attributes, additional_attributes)
  end

  @doc """
  Gets service name from resource attributes.

  Falls back to "unknown-service" if not present.
  """
  @spec get_service_name(map()) :: String.t()
  def get_service_name(resource_map) do
    case Map.get(resource_map, "service.name") do
      nil -> "unknown-service"
      name -> to_string(name)
    end
  end

  @doc """
  Gets service version from resource attributes.

  Falls back to "unknown" if not present.
  """
  @spec get_service_version(map()) :: String.t()
  def get_service_version(resource_map) do
    case Map.get(resource_map, "service.version") do
      nil -> "unknown"
      version -> to_string(version)
    end
  end

  @doc """
  Gets deployment environment from resource attributes.

  Falls back to "unknown" if not present.
  """
  @spec get_deployment_environment(map()) :: String.t()
  def get_deployment_environment(resource_map) do
    case Map.get(resource_map, "deployment.environment") do
      nil -> "unknown"
      env -> to_string(env)
    end
  end

  @doc """
  Gets the OpenTelemetry SDK version.

  Returns the version from the application specification or "unknown" if not available.
  """
  @spec get_sdk_version() :: String.t()
  def get_sdk_version do
    case Application.spec(:opentelemetry, :vsn) do
      nil -> "unknown"
      version -> List.to_string(version)
    end
  end
end
