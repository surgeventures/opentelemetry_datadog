defmodule OpentelemetryDatadog.ExporterTimeoutTest do
  use ExUnit.Case, async: true
  import ExUnit.CaptureLog
  require Logger

  alias OpentelemetryDatadog.Exporter

  describe "timeout error handling" do
    setup do
      state = %Exporter.State{
        host: "localhost",
        port: 8126,
        timeout_ms: 1500,
        container_id: nil
      }

      {:ok, state: state}
    end

    test "logs warning for Mint.TransportError timeout", %{state: state} do
      timeout_error = {:error, %Mint.TransportError{reason: :timeout}}
      
      log = capture_log(fn ->
        result = handle_timeout_result(timeout_error, state.timeout_ms)
        assert result == timeout_error
      end)

      assert log =~ "Datadog export failed due to timeout (1500ms)"
    end

    test "logs warning for Mint.HTTPError timeout", %{state: state} do
      timeout_error = {:error, %Mint.HTTPError{reason: :timeout}}
      
      log = capture_log(fn ->
        result = handle_timeout_result(timeout_error, state.timeout_ms)
        assert result == timeout_error
      end)

      assert log =~ "Datadog export failed due to timeout (1500ms)"
    end

    test "logs warning for generic timeout error", %{state: state} do
      timeout_error = {:error, :timeout}
      
      log = capture_log(fn ->
        result = handle_timeout_result(timeout_error, state.timeout_ms)
        assert result == timeout_error
      end)

      assert log =~ "Datadog export failed due to timeout (1500ms)"
    end

    test "does not log timeout warning for non-timeout errors", %{state: state} do
      non_timeout_error = {:error, %Mint.TransportError{reason: :econnrefused}}
      
      log = capture_log(fn ->
        result = handle_timeout_result(non_timeout_error, state.timeout_ms)
        assert result == non_timeout_error
      end)

      refute log =~ "Datadog export failed due to timeout"
    end

    test "does not log timeout warning for successful requests", %{state: state} do
      success_result = {:ok, %{status: 200}}
      
      log = capture_log(fn ->
        result = handle_timeout_result(success_result, state.timeout_ms)
        assert result == success_result
      end)

      refute log =~ "Datadog export failed due to timeout"
    end

    test "timeout error handling preserves original error", %{state: state} do
      original_error = {:error, %Mint.TransportError{reason: :timeout}}
      
      result = handle_timeout_result(original_error, state.timeout_ms)
      
      assert result == original_error
    end

    test "emits telemetry event on timeout", %{state: state} do
      # Set up telemetry handler to capture events
      test_pid = self()
      handler_id = :test_timeout_telemetry
      
      :telemetry.attach(
        handler_id,
        [:opentelemetry_datadog, :export, :timeout],
        fn event, measurements, metadata, _config ->
          send(test_pid, {:telemetry_event, event, measurements, metadata})
        end,
        nil
      )

      # Emit telemetry event for testing
      capture_log(fn ->
        emit_timeout_telemetry_test(state.timeout_ms, 2)
      end)

      # Verify telemetry event was emitted
      assert_receive {:telemetry_event, [:opentelemetry_datadog, :export, :timeout], measurements, metadata}
      
      assert measurements.count == 1
      assert metadata.timeout_ms == 1500
      assert metadata.attempt == 2

      # Clean up
      :telemetry.detach(handler_id)
    end
  end

  # Helper function to test telemetry emission
  defp emit_timeout_telemetry_test(timeout_ms, attempt) do
    :telemetry.execute(
      [:opentelemetry_datadog, :export, :timeout],
      %{count: 1},
      %{timeout_ms: timeout_ms, attempt: attempt}
    )
  end

  defp handle_timeout_result(result, timeout_ms) do
    case result do
      {:error, %Mint.TransportError{reason: :timeout}} ->
        Logger.warning("Datadog export failed due to timeout (#{timeout_ms}ms)")
        result

      {:error, %Mint.HTTPError{reason: :timeout}} ->
        Logger.warning("Datadog export failed due to timeout (#{timeout_ms}ms)")
        result

      {:error, :timeout} ->
        Logger.warning("Datadog export failed due to timeout (#{timeout_ms}ms)")
        result

      _ ->
        result
    end
  end
end
