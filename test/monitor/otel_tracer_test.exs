defmodule Monitor.OTelTracerTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Monitor.OTelTracer

  setup do
    # Clear any existing tracer state
    :otel_tracer.set_current_span(:undefined)
    :ok
  end

  describe "span/3" do
    test "executes function and returns its result" do
      result =
        OTelTracer.span("test.operation", fn ->
          :success
        end)

      assert result == :success
    end

    test "accepts two argument form with function as second parameter" do
      result =
        OTelTracer.span("test.operation", fn ->
          :success
        end)

      assert result == :success
    end

    test "handles function that raises exception" do
      assert_raise RuntimeError, "test error", fn ->
        OTelTracer.span("test.error", fn ->
          raise "test error"
        end)
      end
    end

    test "accepts attributes in options" do
      result =
        OTelTracer.span("test.with_attributes", [attributes: %{"test.key" => "test.value"}], fn ->
          :success
        end)

      assert result == :success
    end

    test "accepts span kind in options" do
      result =
        OTelTracer.span("test.client_span", [kind: :client], fn ->
          :client_success
        end)

      assert result == :client_success
    end

    test "accepts options like attributes" do
      result =
        OTelTracer.span(
          "test.span_with_opts",
          [
            attributes: %{"span.test" => true}
          ],
          fn ->
            :span_with_opts
          end
        )

      assert result == :span_with_opts
    end
  end

  describe "continue_trace_lazy/1" do
    test "executes function when no active span context" do
      result =
        OTelTracer.continue_trace_lazy(fn ->
          :no_context_success
        end)

      assert result == :no_context_success
    end

    test "executes function within existing trace context" do
      result =
        OTelTracer.span("parent.span", fn ->
          OTelTracer.continue_trace_lazy(fn ->
            :within_context
          end)
        end)

      assert result == :within_context
    end
  end

  describe "set_attribute/2" do
    test "logs warning when no active span" do
      log =
        capture_log(fn ->
          OTelTracer.set_attribute("test.key", "value")
        end)

      assert log =~ "Attempted to set attribute"
    end

    test "accepts string keys" do
      OTelTracer.span("test.span", fn ->
        OTelTracer.set_attribute("string.key", "value")
      end)

      # Function completes without error
      assert true
    end

    test "accepts atom keys" do
      OTelTracer.span("test.span", fn ->
        OTelTracer.set_attribute(:atom_key, "value")
      end)

      # Function completes without error
      assert true
    end

    test "accepts various value types" do
      OTelTracer.span("test.span", fn ->
        OTelTracer.set_attribute("string_val", "text")
        OTelTracer.set_attribute("int_val", 42)
        OTelTracer.set_attribute("float_val", 3.14)
        OTelTracer.set_attribute("bool_val", true)
        OTelTracer.set_attribute("list_val", [1, 2, 3])
      end)

      # Function completes without error
      assert true
    end
  end

  describe "add_event/2" do
    test "logs warning when no active span" do
      log =
        capture_log(fn ->
          OTelTracer.add_event("test.event")
        end)

      assert log =~ "Attempted to add event"
    end

    test "adds event with default empty attributes" do
      OTelTracer.span("test.span", fn ->
        OTelTracer.add_event("test.event")
      end)

      # Function completes without error
      assert true
    end

    test "adds event with custom attributes" do
      OTelTracer.span("test.span", fn ->
        OTelTracer.add_event("test.event", %{
          "event.type" => "user_action",
          "user.id" => "123"
        })
      end)

      # Function completes without error
      assert true
    end
  end

  describe "set_attributes/1" do
    test "logs warning when no active span" do
      log =
        capture_log(fn ->
          OTelTracer.set_attributes(%{"key" => "value"})
        end)

      assert log =~ "Attempted to set attributes"
    end

    test "sets multiple attributes" do
      OTelTracer.span("test.span", fn ->
        OTelTracer.set_attributes(%{
          "attr1" => "value1",
          "attr2" => 42,
          "attr3" => true
        })
      end)

      # Function completes without error
      assert true
    end
  end

  describe "record_exception/2" do
    test "logs warning when no active span" do
      log =
        capture_log(fn ->
          exception = %RuntimeError{message: "Test exception"}
          OTelTracer.record_exception(exception)
        end)

      assert log =~ "Attempted to record exception"
    end

    test "records exception with default attributes" do
      OTelTracer.span("test.span", fn ->
        exception = %RuntimeError{message: "Test exception"}
        OTelTracer.record_exception(exception)
      end)

      # Function completes without error
      assert true
    end

    test "records exception with custom attributes" do
      OTelTracer.span("test.span", fn ->
        exception = %RuntimeError{message: "Test exception with attributes"}

        OTelTracer.record_exception(exception, %{
          "error.context" => "test"
        })
      end)

      # Function completes without error
      assert true
    end
  end

  describe "set_status/2" do
    test "logs warning when no active span" do
      log =
        capture_log(fn ->
          OTelTracer.set_status(:ok)
        end)

      assert log =~ "Attempted to set span status"
    end

    test "sets ok status" do
      OTelTracer.span("test.span", fn ->
        OTelTracer.set_status(:ok)
      end)

      # Function completes without error
      assert true
    end

    test "sets error status with description" do
      OTelTracer.span("test.span", fn ->
        OTelTracer.set_status(:error, "Something went wrong")
      end)

      # Function completes without error
      assert true
    end

    test "sets cancelled status" do
      OTelTracer.span("test.span", fn ->
        OTelTracer.set_status(:cancelled, "Operation cancelled")
      end)

      # Function completes without error
      assert true
    end
  end

  describe "current_span_ctx/0" do
    test "returns :undefined when no active span" do
      span_ctx = OTelTracer.current_span_ctx()
      assert span_ctx == :undefined
    end

    test "returns span context when inside a span" do
      span_ctx =
        OTelTracer.span("test.span", fn ->
          OTelTracer.current_span_ctx()
        end)

      # Should return some span context (not :undefined)
      refute span_ctx == :undefined
    end
  end

  describe "integration scenarios" do
    test "nested spans work correctly" do
      result =
        OTelTracer.span("outer.span", fn ->
          OTelTracer.set_attribute("outer.attr", "outer_value")

          inner_result =
            OTelTracer.span("inner.span", fn ->
              OTelTracer.set_attribute("inner.attr", "inner_value")
              "inner_done"
            end)

          {inner_result, "outer_done"}
        end)

      assert result == {"inner_done", "outer_done"}
    end

    test "error handling with span status" do
      assert_raise RuntimeError, fn ->
        OTelTracer.span("error.operation", fn ->
          OTelTracer.add_event("error.about_to_happen")
          OTelTracer.set_status(:error, "About to fail")
          raise "Something bad happened"
        end)
      end
    end

    test "trace with all features" do
      result =
        OTelTracer.span(
          "complex.operation",
          [
            attributes: %{
              "user.id" => "123",
              "operation.type" => "complex"
            },
            kind: :internal
          ],
          fn ->
            # Add more attributes
            OTelTracer.set_attributes(%{
              "step.current" => 1,
              "step.total" => 3
            })

            # Add events
            OTelTracer.add_event("processing.started", %{
              "timestamp" => DateTime.utc_now() |> DateTime.to_iso8601()
            })

            # Add individual attribute
            OTelTracer.set_attribute("processing.stage", "validation")

            # Simulate some work
            Process.sleep(1)

            # Add completion event
            OTelTracer.add_event("processing.completed")

            # Set successful status
            OTelTracer.set_status(:ok)

            # Return result
            %{
              result: "complex_operation_completed",
              processed_items: 42
            }
          end
        )

      assert result.result == "complex_operation_completed"
      assert result.processed_items == 42
    end
  end
end
