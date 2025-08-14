defmodule OpentelemetryDatadog.Sampler.TailBasedSampler do
  @moduledoc """
  Tail-based sampler that buffers traces and makes sampling decisions based on complete trace information.

  This sampler delays the final sampling decision until it has gathered information about the entire trace.
  It can make more intelligent sampling decisions based on factors like:
  - Presence of errors in any span
  - Service names involved in the trace
  - Total trace duration
  - Custom policies

  ## Configuration

      config = TailBasedSampler.setup([
        decision_timeout_ms: 10_000,
        max_buffered_traces: 1000,
        sample_errors: true,
        slow_trace_threshold_ms: 1000,
        fallback_rate: 0.1,
        policies: [
          %{type: :service, service: "critical-service", sample: true, rate: 1.0},
          %{type: :error, sample: true}
        ]
      ])

  ## Policies

  - `:service` - Sample traces containing specific services
  - `:error` - Sample traces with errors (when sample_errors is true)
  - `:duration` - Sample slow traces (future enhancement)

  ## Buffer Management

  When the buffer is full, the sampler will:
  1. Apply fallback probabilistic sampling for new traces
  2. Automatically decide oldest buffered traces to make room

  ## Error Detection

  The sampler detects errors through:
  - `error: true` attribute
  - HTTP status codes >= 400 in `http.status_code`
  - OpenTelemetry error status in `otel.status_code`
  """

  @behaviour :otel_sampler

  alias OpentelemetryDatadog.DatadogConstants
  require Logger

  @table_name :otel_dd_tail_sampler
  @max_uint64 18_446_744_073_709_551_615
  @knuth_factor 111_111_111_111_111_1111

  defmodule Config do
    @moduledoc false
    defstruct [
      :decision_timeout_ms,
      :max_buffered_traces,
      :sample_errors,
      :slow_trace_threshold_ms,
      :fallback_rate,
      :policies
    ]

    @type t :: %__MODULE__{
            decision_timeout_ms: pos_integer(),
            max_buffered_traces: pos_integer(),
            sample_errors: boolean(),
            slow_trace_threshold_ms: pos_integer(),
            fallback_rate: float(),
            policies: [policy()]
          }

    @type policy :: %{
            type: :service | :error | :duration,
            service: String.t() | nil,
            sample: boolean(),
            rate: float() | nil
          }
  end

  defmodule TraceManager do
    @moduledoc false
    use GenServer

    @table_name :otel_dd_tail_sampler
    @max_uint64 18_446_744_073_709_551_615
    @knuth_factor 111_111_111_111_111_1111

    def start_link(config) do
      GenServer.start_link(__MODULE__, config, name: __MODULE__)
    end

    def init(config) do
      # Create ETS table for trace buffering
      :ets.new(@table_name, [:set, :public, :named_table, {:read_concurrency, true}])

      # Schedule periodic cleanup
      Process.send_after(self(), :cleanup, config.decision_timeout_ms)

      {:ok, %{config: config}}
    end

    def handle_info(:cleanup, %{config: config} = state) do
      cleanup_expired_traces(config)
      Process.send_after(self(), :cleanup, config.decision_timeout_ms)
      {:noreply, state}
    end

    defp cleanup_expired_traces(config) do
      now = System.monotonic_time(:millisecond)
      cutoff = now - config.decision_timeout_ms

      # Find expired traces
      expired_traces =
        :ets.select(@table_name, [
          {{{:buffered, :"$1"}, :"$2", :"$3"}, [{:<, :"$2", cutoff}], [:"$1"]}
        ])

      # Make fallback decisions for expired traces
      for trace_id <- expired_traces do
        make_fallback_decision(trace_id, config)
      end

      # Clean up old decisions too
      old_decisions =
        :ets.select(@table_name, [
          {{{:decided, :"$1"}, :"$2", :"$3", :"$4"}, [{:<, :"$2", cutoff}], [:"$1"]}
        ])

      for trace_id <- old_decisions do
        :ets.delete(@table_name, {:decided, trace_id})
      end
    end

    defp make_fallback_decision(trace_id, config) do
      case :ets.lookup(@table_name, {:buffered, trace_id}) do
        [{{:buffered, ^trace_id}, _timestamp, trace_info}] ->
          decision = should_sample_fallback?(trace_id, trace_info, config)

          priority =
            if decision,
              do: DatadogConstants.sampling_priority(:AUTO_KEEP),
              else: DatadogConstants.sampling_priority(:AUTO_REJECT)

          :ets.insert(
            @table_name,
            {{:decided, trace_id}, System.monotonic_time(:millisecond), decision, priority}
          )

          :ets.delete(@table_name, {:buffered, trace_id})

        [] ->
          :ok
      end
    end

    defp should_sample_fallback?(trace_id, _trace_info, config) do
      # Use probabilistic sampling based on trace ID
      threshold = trunc(config.fallback_rate * @max_uint64)
      trace_id_dd = id_to_datadog_id(trace_id)
      rem(trace_id_dd * @knuth_factor, @max_uint64) <= threshold
    end

    defp id_to_datadog_id(trace_id) when is_integer(trace_id) do
      <<_lower::integer-size(64), upper::integer-size(64)>> = <<trace_id::integer-size(128)>>
      upper
    end
  end

  @impl true
  def setup(opts) do
    config = %Config{
      decision_timeout_ms: Keyword.get(opts, :decision_timeout_ms, 10_000),
      max_buffered_traces: Keyword.get(opts, :max_buffered_traces, 1000),
      sample_errors: Keyword.get(opts, :sample_errors, true),
      slow_trace_threshold_ms: Keyword.get(opts, :slow_trace_threshold_ms, 1000),
      fallback_rate: Keyword.get(opts, :fallback_rate, 0.1),
      policies: Keyword.get(opts, :policies, [])
    }

    Logger.debug("Tail-based sampler configured: #{inspect(config)}")

    # Start the TraceManager GenServer
    case GenServer.start_link(TraceManager, config, name: TraceManager) do
      {:ok, _pid} ->
        :ok

      {:error, {:already_started, _pid}} ->
        :ok

      error ->
        Logger.error("Failed to start TailBasedSampler.TraceManager: #{inspect(error)}")
    end

    config
  end

  @impl true
  def description(%Config{} = config) do
    "TailBasedSampler[timeout=#{config.decision_timeout_ms}ms, buffer=#{config.max_buffered_traces}, policies=#{length(config.policies)}]"
  end

  @impl true
  def should_sample(ctx, trace_id, _links, span_name, span_kind, attributes, %Config{} = config) do
    span_ctx = :otel_tracer.current_span_ctx(ctx)
    trace_state = :otel_span.tracestate(span_ctx)

    # Check if we already have a decision for this trace
    case get_existing_decision(trace_id) do
      {:ok, decision, priority} ->
        sampling_attributes = build_sampling_attributes(decision, priority, :tail_based)
        {decision_to_action(decision), sampling_attributes, trace_state}

      :not_found ->
        # Check for immediate sampling conditions
        case should_sample_immediately?(attributes, config) do
          {:sample, priority} ->
            store_decision(trace_id, true, priority)
            sampling_attributes = build_sampling_attributes(true, priority, :immediate)
            {:record_and_sample, sampling_attributes, trace_state}

          {:drop, priority} ->
            store_decision(trace_id, false, priority)
            sampling_attributes = build_sampling_attributes(false, priority, :immediate)
            {:drop, sampling_attributes, trace_state}

          :defer ->
            # Buffer the trace for tail-based decision
            case buffer_trace(trace_id, span_name, span_kind, attributes, config) do
              :ok ->
                # Optimistically sample while buffering
                priority = DatadogConstants.sampling_priority(:AUTO_KEEP)
                sampling_attributes = build_sampling_attributes(true, priority, :buffered)
                {:record_and_sample, sampling_attributes, trace_state}

              :buffer_full ->
                # Apply fallback sampling
                decision = should_sample_fallback?(trace_id, config)

                priority =
                  if decision,
                    do: DatadogConstants.sampling_priority(:AUTO_KEEP),
                    else: DatadogConstants.sampling_priority(:AUTO_REJECT)

                store_decision(trace_id, decision, priority)
                sampling_attributes = build_sampling_attributes(decision, priority, :fallback)
                {decision_to_action(decision), sampling_attributes, trace_state}
            end
        end
    end
  end

  @doc """
  Force a sampling decision for a specific trace.

  Returns :ok if the trace was found and updated, :not_found otherwise.
  """
  @spec force_decision(integer(), boolean()) :: :ok | :not_found
  def force_decision(trace_id, should_sample)
      when is_integer(trace_id) and is_boolean(should_sample) do
    case :ets.info(@table_name) do
      :undefined ->
        :not_found

      _ ->
        priority =
          if should_sample,
            do: DatadogConstants.sampling_priority(:USER_KEEP),
            else: DatadogConstants.sampling_priority(:USER_REJECT)

        case :ets.lookup(@table_name, {:buffered, trace_id}) do
          [{{:buffered, ^trace_id}, _timestamp, _trace_info}] ->
            # Move from buffered to decided
            :ets.delete(@table_name, {:buffered, trace_id})
            store_decision(trace_id, should_sample, priority)
            :ok

          [] ->
            # Check if already decided
            case :ets.lookup(@table_name, {:decided, trace_id}) do
              [{{:decided, ^trace_id}, _timestamp, _decision, _priority}] ->
                # Update existing decision
                store_decision(trace_id, should_sample, priority)
                :ok

              [] ->
                :not_found
            end
        end
    end
  end

  @doc """
  Get comprehensive statistics about the tail-based sampler.
  """
  @spec get_stats() :: %{
          buffered_traces: non_neg_integer(),
          decided_traces: non_neg_integer(),
          table_size: non_neg_integer(),
          memory_usage_bytes: non_neg_integer()
        }
  def get_stats do
    case :ets.info(@table_name) do
      :undefined ->
        %{
          buffered_traces: 0,
          decided_traces: 0,
          table_size: 0,
          memory_usage_bytes: 0
        }

      info ->
        # Count buffered traces
        buffered =
          length(
            :ets.select(@table_name, [
              {{{:buffered, :"$1"}, :"$2", :"$3"}, [], [true]}
            ])
          )

        # Count decided traces
        decided =
          length(
            :ets.select(@table_name, [
              {{{:decided, :"$1"}, :"$2", :"$3", :"$4"}, [], [true]}
            ])
          )

        %{
          buffered_traces: buffered,
          decided_traces: decided,
          table_size: Keyword.get(info, :size, 0),
          memory_usage_bytes: Keyword.get(info, :memory, 0) * :erlang.system_info(:wordsize)
        }
    end
  end

  @doc """
  Clear all buffered traces. Useful for testing and memory management.
  """
  @spec clear_buffer() :: :ok
  def clear_buffer do
    case :ets.info(@table_name) do
      :undefined ->
        :ok

      _info ->
        :ets.delete_all_objects(@table_name)
        :ok
    end
  end

  defp get_existing_decision(trace_id) do
    case :ets.lookup(@table_name, {:decided, trace_id}) do
      [{{:decided, ^trace_id}, _timestamp, decision, priority}] ->
        {:ok, decision, priority}

      [] ->
        :not_found
    end
  end

  defp should_sample_immediately?(attributes, config) do
    cond do
      # Check for errors if error sampling is enabled
      config.sample_errors and has_error?(attributes) ->
        {:sample, DatadogConstants.sampling_priority(:AUTO_KEEP)}

      # Check service-based policies for immediate decisions
      policy_decision = apply_service_policies(attributes, config.policies) ->
        policy_decision

      true ->
        :defer
    end
  end

  defp has_error?(attributes) do
    cond do
      Map.get(attributes, "error") == true ->
        true

      has_http_error?(attributes) ->
        true

      Map.get(attributes, "otel.status_code") == :error ->
        true

      true ->
        false
    end
  end

  defp has_http_error?(attributes) do
    case Map.get(attributes, "http.status_code") do
      code when is_integer(code) and code >= 400 -> true
      _ -> false
    end
  end

  defp apply_service_policies(attributes, policies) do
    service_name = Map.get(attributes, "service.name")

    case service_name do
      nil ->
        nil

      service ->
        Enum.find_value(policies, fn policy ->
          case policy do
            %{type: :service, service: ^service, sample: should_sample, rate: rate} ->
              if should_sample do
                if rate && rate < 1.0 do
                  # Apply probabilistic sampling for this service
                  if :rand.uniform() <= rate do
                    {:sample, DatadogConstants.sampling_priority(:AUTO_KEEP)}
                  else
                    {:drop, DatadogConstants.sampling_priority(:AUTO_REJECT)}
                  end
                else
                  {:sample, DatadogConstants.sampling_priority(:AUTO_KEEP)}
                end
              else
                {:drop, DatadogConstants.sampling_priority(:AUTO_REJECT)}
              end

            _ ->
              nil
          end
        end)
    end
  end

  defp buffer_trace(trace_id, span_name, span_kind, attributes, config) do
    # Check buffer size
    current_size =
      length(
        :ets.select(@table_name, [
          {{{:buffered, :"$1"}, :"$2", :"$3"}, [], [true]}
        ])
      )

    if current_size >= config.max_buffered_traces do
      :buffer_full
    else
      # Store trace info for later decision
      trace_info = %{
        spans: [%{name: span_name, kind: span_kind, attributes: attributes}],
        services: extract_services(attributes),
        has_errors: has_error?(attributes),
        start_time: System.monotonic_time(:millisecond)
      }

      :ets.insert(
        @table_name,
        {{:buffered, trace_id}, System.monotonic_time(:millisecond), trace_info}
      )

      :ok
    end
  end

  defp extract_services(attributes) do
    case Map.get(attributes, "service.name") do
      nil -> []
      service -> [service]
    end
  end

  defp should_sample_fallback?(trace_id, config) do
    threshold = trunc(config.fallback_rate * @max_uint64)
    trace_id_dd = id_to_datadog_id(trace_id)
    rem(trace_id_dd * @knuth_factor, @max_uint64) <= threshold
  end

  defp id_to_datadog_id(trace_id) when is_integer(trace_id) do
    <<_lower::integer-size(64), upper::integer-size(64)>> = <<trace_id::integer-size(128)>>
    upper
  end

  defp store_decision(trace_id, decision, priority) do
    :ets.insert(
      @table_name,
      {{:decided, trace_id}, System.monotonic_time(:millisecond), decision, priority}
    )
  end

  defp decision_to_action(true), do: :record_and_sample
  defp decision_to_action(false), do: :drop

  defp build_sampling_attributes(_decision, priority, mechanism) do
    base = %{
      :_sampling_priority_v1 => priority,
      "_dd.p.dm" => mechanism_to_datadog(mechanism)
    }

    case mechanism do
      :buffered -> Map.put(base, "_dd.tail_sampled", true)
      :fallback -> Map.put(base, "_dd.fallback_sampled", true)
      _ -> base
    end
  end

  defp mechanism_to_datadog(:tail_based), do: DatadogConstants.sampling_mechanism_used(:RULE)
  defp mechanism_to_datadog(:immediate), do: DatadogConstants.sampling_mechanism_used(:RULE)
  defp mechanism_to_datadog(:buffered), do: DatadogConstants.sampling_mechanism_used(:RULE)
  defp mechanism_to_datadog(:fallback), do: DatadogConstants.sampling_mechanism_used(:DEFAULT)
end
