defmodule OpentelemetryDatadog.Mapper.LiftError do
  require OpentelemetryDatadog.Exporter
  @behaviour OpentelemetryDatadog.Mapper

  @impl true
  def map(span, otel_span, _arg, _state) do
    events = :otel_events.list(Keyword.fetch!(otel_span, :events))

    {error_code, error_meta} =
      case Keyword.fetch!(otel_span, :status) do
        :undefined ->
          {0, %{}}

        {:status, :unset, _} ->
          {0, %{}}

        {:status, :ok, _} ->
          {0, %{}}

        {:status, :error, msg} ->
          error_event =
            events
            |> Enum.reverse()
            |> Enum.find(fn
              {:event, _time, "exception", _attrs} -> true
              _ -> false
            end)

          case error_event do
            nil ->
              {1, %{"error.message" => msg}}

            {:event, _time, "exception", attrs} ->
              attrs = Keyword.fetch!(OpentelemetryDatadog.Exporter.attributes(attrs), :map)
              {1, attrs}
          end
      end

    meta =
      span.meta
      |> Map.merge(error_meta)
      |> fix_error_keys()

    span = %{
      span |
      error: error_code,
      meta: meta
    }

    {:next, span}
  end

  def fix_error_keys(map) do
    map
    |> Enum.map(fn
      {:"exception.message", v} -> {:"error.message", v}
      {:"exception.stacktrace", v} -> {:"error.stack", v}
      {:"exception.type", v} -> {:"error.type", v}
      kv -> kv
    end)
    |> Enum.into(%{})
  end

end
