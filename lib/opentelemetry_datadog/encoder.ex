defmodule OpentelemetryDatadog.Encoder do
  @moduledoc """
  Encoder for Datadog traces API.
  """

  alias OpentelemetryDatadog.DatadogSpan

  @doc "Encodes a list of spans to MessagePack format for the Datadog API."
  @spec encode([DatadogSpan.t() | map()]) :: {:ok, binary()} | {:error, term()}
  def encode(spans) when is_list(spans) do
    try do
      validated_spans = Enum.map(spans, &normalize_span/1)
      encoded = validated_spans |> Msgpax.pack!() |> IO.iodata_to_binary()
      {:ok, encoded}
    rescue
      error -> {:error, error}
    end
  end

  def encode(invalid_input) do
    {:error,
     "Input must be a list of DatadogSpan structs or maps, got: #{inspect(invalid_input)}"}
  end

  @doc """
  Normalizes a span (either DatadogSpan struct or map) to a map suitable for MessagePack encoding.

  Validates that all required fields are present and properly typed.
  """
  @spec normalize_span(DatadogSpan.t() | map()) :: map()
  def normalize_span(%DatadogSpan{} = span) do
    datadog_span_to_map(span)
  end

  def normalize_span(span) when is_map(span) do
    validate_and_normalize_span(span)
  end

  # Converts a DatadogSpan struct to a map suitable for MessagePack encoding.
  # Validates that all required fields are present and properly typed.
  @spec datadog_span_to_map(DatadogSpan.t()) :: map()
  defp datadog_span_to_map(%DatadogSpan{} = span) do
    %{
      trace_id: validate_integer(span.trace_id, :trace_id),
      span_id: validate_integer(span.span_id, :span_id),
      parent_id: validate_optional_integer(span.parent_id, :parent_id),
      name: validate_string(span.name, :name),
      service: validate_string(span.service, :service),
      resource: validate_string(span.resource, :resource),
      type: validate_string(span.type, :type),
      start: validate_integer(span.start, :start),
      duration: validate_integer(span.duration, :duration),
      error: validate_error_flag(span.error),
      meta: validate_meta(span.meta),
      metrics: validate_metrics(span.metrics)
    }
  end

  @doc """
  Validates and normalizes a single span for the format.

  Ensures all mandatory fields are present and properly typed.
  """
  @spec validate_and_normalize_span(map()) :: map()
  def validate_and_normalize_span(span) when is_map(span) do
    %{
      trace_id: get_required_integer(span, :trace_id),
      span_id: get_required_integer(span, :span_id),
      parent_id: get_optional_integer(span, :parent_id),
      name: get_required_string(span, :name),
      service: get_required_string(span, :service),
      resource: get_required_string(span, :resource),
      type: get_required_string(span, :type),
      start: get_required_integer(span, :start),
      duration: get_required_integer(span, :duration),
      error: get_error_flag(span),
      meta: get_meta(span),
      metrics: get_metrics(span)
    }
  end

  # New validation functions for DatadogSpan structs
  defp validate_integer(value, _field) when is_integer(value), do: value

  defp validate_integer(nil, field) do
    raise ArgumentError, "Missing required field: #{field}"
  end

  defp validate_integer(value, field) do
    raise ArgumentError, "Field #{field} must be an integer, got: #{inspect(value)}"
  end

  defp validate_optional_integer(nil, _field), do: nil
  defp validate_optional_integer(value, _field) when is_integer(value), do: value

  defp validate_optional_integer(value, field) do
    raise ArgumentError, "Field #{field} must be an integer or nil, got: #{inspect(value)}"
  end

  defp validate_string(value, _field) when is_binary(value) and value != "", do: value

  defp validate_string(nil, field) do
    raise ArgumentError, "Missing required field: #{field}"
  end

  defp validate_string("", field) do
    raise ArgumentError, "Field #{field} cannot be empty"
  end

  defp validate_string(value, field) do
    raise ArgumentError, "Field #{field} must be a string, got: #{inspect(value)}"
  end

  defp validate_error_flag(0), do: 0
  defp validate_error_flag(1), do: 1
  defp validate_error_flag(true), do: 1
  defp validate_error_flag(false), do: 0
  defp validate_error_flag(nil), do: 0

  defp validate_error_flag(value) do
    raise ArgumentError, "Field error must be 0, 1, true, false, or nil, got: #{inspect(value)}"
  end

  defp validate_meta(meta) when is_map(meta) do
    # Ensure all keys and values are strings
    Enum.into(meta, %{}, fn
      {k, v} when is_binary(k) and is_binary(v) -> {k, v}
      {k, v} when is_atom(k) and is_binary(v) -> {Atom.to_string(k), v}
      {k, v} when is_binary(k) -> {k, to_string(v)}
      {k, v} when is_atom(k) -> {Atom.to_string(k), to_string(v)}
      {k, v} -> {to_string(k), to_string(v)}
    end)
  end

  defp validate_meta(nil), do: %{}

  defp validate_meta(value) do
    raise ArgumentError, "Field meta must be a map, got: #{inspect(value)}"
  end

  defp validate_metrics(metrics) when is_map(metrics) do
    # Ensure all keys are strings and values are numbers
    Enum.into(metrics, %{}, fn
      {k, v} when is_binary(k) and is_number(v) ->
        {k, v}

      {k, v} when is_atom(k) and is_number(v) ->
        {Atom.to_string(k), v}

      {k, v} when is_binary(k) ->
        case parse_number(v) do
          {:ok, num} -> {k, num}
          :error -> raise ArgumentError, "Metrics value must be a number, got: #{inspect(v)}"
        end

      {k, v} when is_atom(k) ->
        case parse_number(v) do
          {:ok, num} -> {Atom.to_string(k), num}
          :error -> raise ArgumentError, "Metrics value must be a number, got: #{inspect(v)}"
        end

      {k, v} ->
        case parse_number(v) do
          {:ok, num} -> {to_string(k), num}
          :error -> raise ArgumentError, "Metrics value must be a number, got: #{inspect(v)}"
        end
    end)
  end

  defp validate_metrics(nil), do: %{}

  defp validate_metrics(value) do
    raise ArgumentError, "Field metrics must be a map, got: #{inspect(value)}"
  end

  # Legacy validation functions for backward compatibility
  defp get_required_integer(span, key) do
    case Map.get(span, key) do
      value when is_integer(value) -> value
      nil -> raise ArgumentError, "Missing required field: #{key}"
      value -> raise ArgumentError, "Field #{key} must be an integer, got: #{inspect(value)}"
    end
  end

  defp get_optional_integer(span, key) do
    case Map.get(span, key) do
      nil ->
        nil

      value when is_integer(value) ->
        value

      value ->
        raise ArgumentError, "Field #{key} must be an integer or nil, got: #{inspect(value)}"
    end
  end

  defp get_required_string(span, key) do
    case Map.get(span, key) do
      value when is_binary(value) and value != "" -> value
      nil -> raise ArgumentError, "Missing required field: #{key}"
      "" -> raise ArgumentError, "Field #{key} cannot be empty"
      value -> raise ArgumentError, "Field #{key} must be a string, got: #{inspect(value)}"
    end
  end

  defp get_error_flag(span) do
    case Map.get(span, :error, 0) do
      0 ->
        0

      1 ->
        1

      true ->
        1

      false ->
        0

      nil ->
        0

      value ->
        raise ArgumentError,
              "Field error must be 0, 1, true, false, or nil, got: #{inspect(value)}"
    end
  end

  defp get_meta(span) do
    case Map.get(span, :meta, %{}) do
      meta when is_map(meta) ->
        # Ensure all keys and values are strings
        Enum.into(meta, %{}, fn
          {k, v} when is_binary(k) and is_binary(v) -> {k, v}
          {k, v} when is_atom(k) and is_binary(v) -> {Atom.to_string(k), v}
          {k, v} when is_binary(k) -> {k, to_string(v)}
          {k, v} when is_atom(k) -> {Atom.to_string(k), to_string(v)}
          {k, v} -> {to_string(k), to_string(v)}
        end)

      nil ->
        %{}

      value ->
        raise ArgumentError, "Field meta must be a map, got: #{inspect(value)}"
    end
  end

  defp get_metrics(span) do
    case Map.get(span, :metrics, %{}) do
      metrics when is_map(metrics) ->
        # Ensure all keys are strings and values are numbers
        Enum.into(metrics, %{}, fn
          {k, v} when is_binary(k) and is_number(v) ->
            {k, v}

          {k, v} when is_atom(k) and is_number(v) ->
            {Atom.to_string(k), v}

          {k, v} when is_binary(k) ->
            case parse_number(v) do
              {:ok, num} -> {k, num}
              :error -> raise ArgumentError, "Metrics value must be a number, got: #{inspect(v)}"
            end

          {k, v} when is_atom(k) ->
            case parse_number(v) do
              {:ok, num} -> {Atom.to_string(k), num}
              :error -> raise ArgumentError, "Metrics value must be a number, got: #{inspect(v)}"
            end

          {k, v} ->
            case parse_number(v) do
              {:ok, num} -> {to_string(k), num}
              :error -> raise ArgumentError, "Metrics value must be a number, got: #{inspect(v)}"
            end
        end)

      nil ->
        %{}

      value ->
        raise ArgumentError, "Field metrics must be a map, got: #{inspect(value)}"
    end
  end

  defp parse_number(value) when is_number(value), do: {:ok, value}

  defp parse_number(value) when is_binary(value) do
    case Float.parse(value) do
      {num, ""} ->
        {:ok, num}

      _ ->
        case Integer.parse(value) do
          {num, ""} -> {:ok, num}
          _ -> :error
        end
    end
  end

  defp parse_number(_), do: :error
end
