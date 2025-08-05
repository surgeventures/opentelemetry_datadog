defmodule OpentelemetryDatadog.V05.EncoderTest do
  use ExUnit.Case, async: true

  alias OpentelemetryDatadog.V05.Encoder

  describe "encode/1" do
    test "encodes valid spans to MessagePack" do
      spans = [
        %{
          trace_id: 123_456_789,
          span_id: 987_654_321,
          parent_id: nil,
          name: "web.request",
          service: "my-service",
          resource: "GET /api/users",
          type: "web",
          start: 1_640_995_200_000_000_000,
          duration: 50_000_000,
          error: 0,
          meta: %{"http.method" => "GET"},
          metrics: %{"http.status_code" => 200}
        }
      ]

      assert {:ok, encoded} = Encoder.encode(spans)
      assert is_binary(encoded)

      # Verify we can decode it back
      {:ok, decoded} = Msgpax.unpack(encoded)
      assert is_list(decoded)
      assert length(decoded) == 1

      [span] = decoded
      assert span["trace_id"] == 123_456_789
      assert span["span_id"] == 987_654_321
      assert span["name"] == "web.request"
      assert span["service"] == "my-service"
    end

    test "encodes multiple spans" do
      spans = [
        %{
          trace_id: 123_456_789,
          span_id: 987_654_321,
          parent_id: nil,
          name: "web.request",
          service: "my-service",
          resource: "GET /api/users",
          type: "web",
          start: 1_640_995_200_000_000_000,
          duration: 50_000_000,
          error: 0,
          meta: %{},
          metrics: %{}
        },
        %{
          trace_id: 123_456_789,
          span_id: 987_654_322,
          parent_id: 987_654_321,
          name: "db.query",
          service: "my-service",
          resource: "SELECT * FROM users",
          type: "db",
          start: 1_640_995_200_010_000_000,
          duration: 30_000_000,
          error: 0,
          meta: %{"db.statement" => "SELECT * FROM users"},
          metrics: %{"db.rows_affected" => 5}
        }
      ]

      assert {:ok, encoded} = Encoder.encode(spans)
      {:ok, decoded} = Msgpax.unpack(encoded)
      assert length(decoded) == 2
    end

    test "handles empty spans list" do
      assert {:ok, encoded} = Encoder.encode([])
      {:ok, decoded} = Msgpax.unpack(encoded)
      assert decoded == []
    end

    test "returns error for invalid input" do
      assert {:error, _} = Encoder.encode("not a list")
    end
  end

  describe "validate_and_normalize_span/1" do
    test "validates and normalizes a valid span" do
      span = %{
        trace_id: 123_456_789,
        span_id: 987_654_321,
        parent_id: nil,
        name: "test.span",
        service: "test-service",
        resource: "test-resource",
        type: "custom",
        start: 1_640_995_200_000_000_000,
        duration: 50_000_000,
        error: 0,
        meta: %{"key" => "value"},
        metrics: %{"count" => 1}
      }

      result = Encoder.validate_and_normalize_span(span)

      assert result.trace_id == 123_456_789
      assert result.span_id == 987_654_321
      assert result.parent_id == nil
      assert result.name == "test.span"
      assert result.service == "test-service"
      assert result.resource == "test-resource"
      assert result.type == "custom"
      assert result.start == 1_640_995_200_000_000_000
      assert result.duration == 50_000_000
      assert result.error == 0
      assert result.meta == %{"key" => "value"}
      assert result.metrics == %{"count" => 1}
    end

    test "converts atom keys to strings in meta" do
      span = %{
        trace_id: 123,
        span_id: 456,
        parent_id: nil,
        name: "test",
        service: "test",
        resource: "test",
        type: "test",
        start: 1000,
        duration: 100,
        meta: %{:atom_key => "value", "string_key" => "value2"}
      }

      result = Encoder.validate_and_normalize_span(span)
      assert result.meta == %{"atom_key" => "value", "string_key" => "value2"}
    end

    test "converts non-string values to strings in meta" do
      span = %{
        trace_id: 123,
        span_id: 456,
        parent_id: nil,
        name: "test",
        service: "test",
        resource: "test",
        type: "test",
        start: 1000,
        duration: 100,
        meta: %{"number" => 123, "boolean" => true, "atom" => :test}
      }

      result = Encoder.validate_and_normalize_span(span)
      assert result.meta == %{"number" => "123", "boolean" => "true", "atom" => "test"}
    end

    test "converts atom keys to strings in metrics" do
      span = %{
        trace_id: 123,
        span_id: 456,
        parent_id: nil,
        name: "test",
        service: "test",
        resource: "test",
        type: "test",
        start: 1000,
        duration: 100,
        metrics: %{:count => 5, "duration" => 1.5}
      }

      result = Encoder.validate_and_normalize_span(span)
      assert result.metrics == %{"count" => 5, "duration" => 1.5}
    end

    test "parses string numbers in metrics" do
      span = %{
        trace_id: 123,
        span_id: 456,
        parent_id: nil,
        name: "test",
        service: "test",
        resource: "test",
        type: "test",
        start: 1000,
        duration: 100,
        metrics: %{"count" => "5", "rate" => "1.5"}
      }

      result = Encoder.validate_and_normalize_span(span)
      assert result.metrics == %{"count" => 5, "rate" => 1.5}
    end

    test "handles boolean error values" do
      span = %{
        trace_id: 123,
        span_id: 456,
        parent_id: nil,
        name: "test",
        service: "test",
        resource: "test",
        type: "test",
        start: 1000,
        duration: 100,
        error: true
      }

      result = Encoder.validate_and_normalize_span(span)
      assert result.error == 1

      span = Map.put(span, :error, false)
      result = Encoder.validate_and_normalize_span(span)
      assert result.error == 0
    end

    test "uses default values for optional fields" do
      span = %{
        trace_id: 123,
        span_id: 456,
        parent_id: nil,
        name: "test",
        service: "test",
        resource: "test",
        type: "test",
        start: 1000,
        duration: 100
        # meta and metrics omitted
      }

      result = Encoder.validate_and_normalize_span(span)
      assert result.meta == %{}
      assert result.metrics == %{}
      assert result.error == 0
    end

    test "raises for missing required fields" do
      span = %{span_id: 456}

      assert_raise ArgumentError, "Missing required field: trace_id", fn ->
        Encoder.validate_and_normalize_span(span)
      end
    end

    test "raises for invalid field types" do
      span = %{
        trace_id: "not_an_integer",
        span_id: 456,
        parent_id: nil,
        name: "test",
        service: "test",
        resource: "test",
        type: "test",
        start: 1000,
        duration: 100
      }

      assert_raise ArgumentError, ~r/Field trace_id must be an integer/, fn ->
        Encoder.validate_and_normalize_span(span)
      end
    end

    test "raises for empty required strings" do
      span = %{
        trace_id: 123,
        span_id: 456,
        parent_id: nil,
        name: "",
        service: "test",
        resource: "test",
        type: "test",
        start: 1000,
        duration: 100
      }

      assert_raise ArgumentError, "Field name cannot be empty", fn ->
        Encoder.validate_and_normalize_span(span)
      end
    end

    test "raises for invalid error values" do
      span = %{
        trace_id: 123,
        span_id: 456,
        parent_id: nil,
        name: "test",
        service: "test",
        resource: "test",
        type: "test",
        start: 1000,
        duration: 100,
        error: "invalid"
      }

      assert_raise ArgumentError, ~r/Field error must be 0, 1, true, false, or nil/, fn ->
        Encoder.validate_and_normalize_span(span)
      end
    end

    test "raises for invalid meta type" do
      span = %{
        trace_id: 123,
        span_id: 456,
        parent_id: nil,
        name: "test",
        service: "test",
        resource: "test",
        type: "test",
        start: 1000,
        duration: 100,
        meta: "not_a_map"
      }

      assert_raise ArgumentError, ~r/Field meta must be a map/, fn ->
        Encoder.validate_and_normalize_span(span)
      end
    end

    test "raises for invalid metrics type" do
      span = %{
        trace_id: 123,
        span_id: 456,
        parent_id: nil,
        name: "test",
        service: "test",
        resource: "test",
        type: "test",
        start: 1000,
        duration: 100,
        metrics: "not_a_map"
      }

      assert_raise ArgumentError, ~r/Field metrics must be a map/, fn ->
        Encoder.validate_and_normalize_span(span)
      end
    end

    test "raises for invalid metrics values" do
      span = %{
        trace_id: 123,
        span_id: 456,
        parent_id: nil,
        name: "test",
        service: "test",
        resource: "test",
        type: "test",
        start: 1000,
        duration: 100,
        metrics: %{"invalid" => "not_a_number"}
      }

      assert_raise ArgumentError, ~r/Metrics value must be a number/, fn ->
        Encoder.validate_and_normalize_span(span)
      end
    end
  end
end
