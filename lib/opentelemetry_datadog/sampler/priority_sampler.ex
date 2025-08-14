defmodule OpentelemetryDatadog.Sampler.PrioritySampler do
  @moduledoc """
  Advanced sampler with priority sampling support.

  Implements Datadog's priority sampling with the following priority values:
  - USER_REJECT (-1): User explicitly rejects this trace
  - AUTO_REJECT (0): Automatic rejection (default for dropped traces)
  - AUTO_KEEP (1): Automatic keep (default for sampled traces)
  - USER_KEEP (2): User explicitly keeps this trace
  """

  @behaviour :otel_sampler

  require Logger
  alias OpentelemetryDatadog.DatadogConstants
  alias Monitor.OTelTracer

  @max_uint64 18_446_744_073_709_551_615
  @knuth_factor 111_111_111_111_111_1111

  defmodule Config do
    @enforce_keys [:default_rate]
    defstruct [
      :default_rate,
      :rules,
      :enable_user_priority
    ]

    @type sampling_rule :: %{
            service: String.t() | :any,
            operation: String.t() | :any,
            rate: float(),
            priority: integer() | nil
          }

    @type t :: %__MODULE__{
            default_rate: float(),
            rules: [sampling_rule()] | nil,
            enable_user_priority: boolean()
          }
  end

  @impl true
  def setup(sampler_opts) do
    default_rate = Keyword.get(sampler_opts, :default_rate, 1.0)
    rules = Keyword.get(sampler_opts, :rules, [])
    enable_user_priority = Keyword.get(sampler_opts, :enable_user_priority, true)

    config = %Config{
      default_rate: validate_rate(default_rate),
      rules: Enum.map(rules, &validate_rule/1),
      enable_user_priority: enable_user_priority
    }

    Logger.debug("Priority sampler configured: #{inspect(config)}")
    config
  end

  @impl true
  def description(config) do
    "PrioritySampler[rate=#{config.default_rate}, rules=#{length(config.rules || [])}]"
  end

  @impl true
  def should_sample(ctx, trace_id, _links, span_name, span_kind, attributes, config) do
    OTelTracer.span(
      "datadog.sampling_decision",
      [
        kind: :internal,
        attributes: %{
          "sampling.span_name" => to_string(span_name),
          "sampling.span_kind" => to_string(span_kind),
          "sampling.default_rate" => config.default_rate,
          "sampling.rules_count" => length(config.rules || [])
        }
      ],
      fn ->
        span_ctx = :otel_tracer.current_span_ctx(ctx)

        # Check for manual sampling priority first
        case get_manual_sampling_decision(ctx, attributes, config) do
          {decision, priority} when decision != nil ->
            OTelTracer.add_event("sampling.manual_decision", %{
              "decision" => to_string(decision),
              "priority" => priority,
              "source" => "manual"
            })

            result = build_sampling_result(decision, priority, span_ctx, :MANUAL, config)
            OTelTracer.set_status(:ok)
            result

          _ ->
            OTelTracer.add_event("sampling.applying_automatic")
            # Apply automatic sampling logic
            result =
              apply_automatic_sampling(
                trace_id,
                span_name,
                span_kind,
                attributes,
                span_ctx,
                config
              )

            OTelTracer.set_status(:ok)
            result
        end
      end
    )
  end

  defp get_manual_sampling_decision(ctx, attributes, config) do
    if config.enable_user_priority do
      # Check OpenTelemetry context for manual sampling decisions
      case :otel_ctx.get_value(ctx, :datadog_sampling_priority, :undefined) do
        :undefined ->
          # Check attributes for manual sampling priority
          case Map.get(attributes, "_sampling_priority_v1") ||
                 Map.get(attributes, "sampling.priority") do
            priority when is_integer(priority) and priority >= -1 and priority <= 2 ->
              decision = if priority > 0, do: :record_and_sample, else: :drop
              {decision, priority}

            _ ->
              {nil, nil}
          end

        priority when is_integer(priority) and priority >= -1 and priority <= 2 ->
          decision = if priority > 0, do: :record_and_sample, else: :drop
          {decision, priority}

        _ ->
          {nil, nil}
      end
    else
      {nil, nil}
    end
  end

  defp apply_automatic_sampling(trace_id, span_name, span_kind, attributes, span_ctx, config) do
    rule = find_matching_rule(span_name, span_kind, attributes, config.rules)

    sampling_rate = if rule, do: rule.rate, else: config.default_rate
    forced_priority = if rule, do: rule.priority, else: nil
    sampled = should_sample_probabilistic?(trace_id, sampling_rate)

    OTelTracer.set_attributes(%{
      "sampling.rule_matched" => rule != nil,
      "sampling.rate_used" => sampling_rate,
      "sampling.probabilistic_result" => sampled
    })

    {decision, priority} =
      case {sampled, forced_priority} do
        {true, nil} ->
          {:record_and_sample, DatadogConstants.sampling_priority(:AUTO_KEEP)}

        {false, nil} ->
          {:drop, DatadogConstants.sampling_priority(:AUTO_REJECT)}

        {_, priority} when is_integer(priority) and priority >= -1 and priority <= 2 ->
          decision = if priority > 0, do: :record_and_sample, else: :drop
          {decision, priority}

        {true, _} ->
          {:record_and_sample, DatadogConstants.sampling_priority(:AUTO_KEEP)}

        {false, _} ->
          {:drop, DatadogConstants.sampling_priority(:AUTO_REJECT)}
      end

    mechanism = if rule, do: :RULE, else: :DEFAULT
    build_sampling_result(decision, priority, span_ctx, mechanism, config, rule)
  end

  defp find_matching_rule(span_name, _span_kind, attributes, rules) do
    Enum.find(rules, fn rule ->
      matches_service?(rule.service, attributes) and
        matches_operation?(rule.operation, span_name)
    end)
  end

  defp matches_service?(:any, _attributes), do: true

  defp matches_service?(service, attributes) do
    case Map.get(attributes, "service.name") || Map.get(attributes, :service) do
      ^service -> true
      _ -> false
    end
  end

  defp matches_operation?(:any, _span_name), do: true

  defp matches_operation?(operation, span_name) do
    operation == span_name or String.contains?(span_name, operation)
  end

  defp should_sample_probabilistic?(_trace_id, rate) when rate >= 1.0, do: true
  defp should_sample_probabilistic?(_trace_id, rate) when rate <= 0.0, do: false

  defp should_sample_probabilistic?(trace_id, rate) do
    threshold = trunc(rate * @max_uint64)
    trace_id_dd = id_to_datadog_id(trace_id)
    rem(trace_id_dd * @knuth_factor, @max_uint64) <= threshold
  end

  defp build_sampling_result(decision, priority, span_ctx, mechanism, config, rule \\ nil) do
    base_attributes = %{
      "_dd.p.dm" => DatadogConstants.sampling_mechanism_used(mechanism),
      _sampling_priority_v1: priority
    }

    attributes =
      case rule do
        %{rate: rate} when is_float(rate) ->
          Map.put(base_attributes, "_dd.rule_psr", rate)

        _ ->
          if config.default_rate < 1.0 do
            Map.put(base_attributes, "_dd.rule_psr", config.default_rate)
          else
            base_attributes
          end
      end

    trace_state = :otel_span.tracestate(span_ctx)
    {decision, attributes, trace_state}
  end

  defp id_to_datadog_id(nil), do: 0

  defp id_to_datadog_id(trace_id) do
    <<_upper::integer-size(64), lower::integer-size(64)>> = <<trace_id::integer-size(128)>>
    lower
  end

  defp validate_rate(rate) when is_float(rate) and rate >= 0.0 and rate <= 1.0, do: rate
  defp validate_rate(rate) when is_number(rate), do: max(0.0, min(1.0, rate * 1.0))

  defp validate_rate(_),
    do: raise(ArgumentError, "Sampling rate must be a number between 0.0 and 1.0")

  defp validate_rule(rule) when is_map(rule) do
    %{
      service: Map.get(rule, :service, :any),
      operation: Map.get(rule, :operation, :any),
      rate: validate_rate(Map.get(rule, :rate, 1.0)),
      priority: validate_priority(Map.get(rule, :priority, nil))
    }
  end

  defp validate_rule(rule),
    do: raise(ArgumentError, "Sampling rule must be a map, got: #{inspect(rule)}")

  defp validate_priority(nil), do: nil

  defp validate_priority(priority) when is_integer(priority) and priority >= -1 and priority <= 2,
    do: priority

  defp validate_priority(_), do: raise(ArgumentError, "Priority must be between -1 and 2")

  @doc """
  Sets manual sampling priority for the current trace.

  ## Priority values:
  - USER_REJECT (-1): User explicitly rejects this trace
  - AUTO_REJECT (0): Automatic rejection (default for dropped traces)  
  - AUTO_KEEP (1): Automatic keep (default for sampled traces)
  - USER_KEEP (2): User explicitly keeps this trace

  ## Examples

      # Force keeping a trace
      OpentelemetryDatadog.Sampler.PrioritySampler.set_sampling_priority(:USER_KEEP)
      
      # Force dropping a trace  
      OpentelemetryDatadog.Sampler.PrioritySampler.set_sampling_priority(:USER_REJECT)
  """
  @spec set_sampling_priority(:USER_REJECT | :AUTO_REJECT | :AUTO_KEEP | :USER_KEEP | integer()) ::
          :ok
  def set_sampling_priority(priority)
      when priority in [:USER_REJECT, :AUTO_REJECT, :AUTO_KEEP, :USER_KEEP] do
    numeric_priority = DatadogConstants.sampling_priority(priority)
    set_sampling_priority(numeric_priority)
  end

  def set_sampling_priority(priority)
      when is_integer(priority) and priority >= -1 and priority <= 2 do
    ctx = :otel_ctx.get_current()
    new_ctx = :otel_ctx.set_value(ctx, :datadog_sampling_priority, priority)
    :otel_ctx.attach(new_ctx)
    :ok
  end

  def set_sampling_priority(priority) do
    raise ArgumentError,
          "Invalid sampling priority: #{inspect(priority)}. Must be -1, 0, 1, 2 or equivalent atoms."
  end

  @doc """
  Gets the current sampling priority from context.
  """
  @spec get_sampling_priority() :: integer() | :undefined
  def get_sampling_priority do
    ctx = :otel_ctx.get_current()
    :otel_ctx.get_value(ctx, :datadog_sampling_priority, :undefined)
  end
end
