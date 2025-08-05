defmodule OpentelemetryDatadog.TelemetryHandler do
  @moduledoc """
  Telemetry event handler for integration and unit tests.

  Forwards telemetry events to a registered test process,
  avoiding anonymous functions which can trigger performance warnings.
  """

  @doc """
  Forwards telemetry events to the test process specified in `:test_pid` within `config`.

  ## Parameters

    - `event`: The telemetry event name (list of atoms).
    - `measurements`: A map of measurements.
    - `metadata`: A map of event metadata.
    - `config`: A keyword list expected to include `:test_pid`.

  ## Behavior

  If `:test_pid` is not a valid and alive process, the event is ignored.
  """
  @spec handle_event([atom()], map(), map(), keyword()) :: :ok
  def handle_event(event, measurements, metadata, config) do
    case Keyword.get(config, :test_pid) do
      pid when is_pid(pid) ->
        if Process.alive?(pid) do
          send(pid, {:telemetry_event, event, measurements, metadata})
        end

      _ ->
        :ok
    end

    :ok
  end
end
