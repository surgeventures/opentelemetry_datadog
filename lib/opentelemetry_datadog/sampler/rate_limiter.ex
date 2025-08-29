defmodule OpentelemetryDatadog.Sampler.RateLimiter do
  @moduledoc """
  Rate limiting sampler that wraps another sampler to prevent overwhelming downstream systems.

  Uses a token bucket algorithm to limit the number of traces sampled per second.
  When the rate limit is exceeded, traces are automatically rejected with AUTO_REJECT priority.

  ## Usage

      # Wrap an existing sampler with rate limiting
      sampler_opts = [
        wrapped_sampler: {OpentelemetryDatadog.Sampler.PrioritySampler, [default_rate: 0.5]},
        max_traces_per_second: 100,
        burst_capacity: 150
      ]
  """

  @behaviour :otel_sampler

  require Logger
  alias OpentelemetryDatadog.DatadogConstants

  # ETS table for rate limiting state
  @rate_limiter_table :otel_dd_rate_limiter

  defmodule Config do
    @enforce_keys [:wrapped_sampler, :wrapped_sampler_config, :max_traces_per_second]
    defstruct [
      :wrapped_sampler,
      :wrapped_sampler_config,
      :max_traces_per_second,
      :burst_capacity,
      :window_size_ms
    ]

    @type t :: %__MODULE__{
            wrapped_sampler: module(),
            wrapped_sampler_config: any(),
            max_traces_per_second: pos_integer(),
            burst_capacity: pos_integer(),
            window_size_ms: pos_integer()
          }
  end

  @impl true
  def setup(sampler_opts) do
    {wrapped_sampler, wrapped_opts} = Keyword.fetch!(sampler_opts, :wrapped_sampler)
    max_traces_per_second = Keyword.fetch!(sampler_opts, :max_traces_per_second)
    burst_capacity = Keyword.get(sampler_opts, :burst_capacity, max_traces_per_second * 2)
    window_size_ms = Keyword.get(sampler_opts, :window_size_ms, 1000)

    # Setup the wrapped sampler
    wrapped_config = wrapped_sampler.setup(wrapped_opts)

    # Initialize rate limiter ETS table
    ensure_rate_limiter_table()

    config = %Config{
      wrapped_sampler: wrapped_sampler,
      wrapped_sampler_config: wrapped_config,
      max_traces_per_second: max_traces_per_second,
      burst_capacity: burst_capacity,
      window_size_ms: window_size_ms
    }

    # Initialize token bucket
    initialize_token_bucket(config)

    Logger.debug("Rate limiter configured: #{inspect(config)}")
    config
  end

  @impl true
  def description(config) do
    wrapped_desc = config.wrapped_sampler.description(config.wrapped_sampler_config)

    "RateLimiter[#{config.max_traces_per_second}/s, burst=#{config.burst_capacity}, wrapped=#{wrapped_desc}]"
  end

  @impl true
  def should_sample(ctx, trace_id, links, span_name, span_kind, attributes, config) do
    # Check if we can consume a token from the bucket
    case try_consume_token(config) do
      true ->
        # We have capacity, delegate to the wrapped sampler
        config.wrapped_sampler.should_sample(
          ctx,
          trace_id,
          links,
          span_name,
          span_kind,
          attributes,
          config.wrapped_sampler_config
        )

      false ->
        # Rate limit exceeded, automatically reject
        span_ctx = :otel_tracer.current_span_ctx(ctx)
        trace_state = :otel_span.tracestate(span_ctx)

        attributes = %{
          "_dd.p.dm" => DatadogConstants.sampling_mechanism_used(:RULE),
          "_dd.rate_limited" => true,
          _sampling_priority_v1: DatadogConstants.sampling_priority(:AUTO_REJECT)
        }

        {:drop, attributes, trace_state}
    end
  end

  defp try_consume_token(config) do
    now = System.system_time(:millisecond)
    bucket_key = :token_bucket

    case :ets.lookup(@rate_limiter_table, bucket_key) do
      [{^bucket_key, {tokens, last_refill}}] ->
        # Calculate tokens to add based on time elapsed
        time_elapsed = now - last_refill

        tokens_to_add =
          min(
            div(time_elapsed * config.max_traces_per_second, config.window_size_ms),
            config.burst_capacity - tokens
          )

        new_tokens = min(tokens + tokens_to_add, config.burst_capacity)

        if new_tokens > 0 do
          # Consume a token
          :ets.update_element(@rate_limiter_table, bucket_key, [
            {2, {new_tokens - 1, now}}
          ])

          true
        else
          # No tokens available, update timestamp anyway
          :ets.update_element(@rate_limiter_table, bucket_key, [
            {2, {new_tokens, now}}
          ])

          false
        end

      [] ->
        # Initialize bucket and consume first token
        :ets.insert(@rate_limiter_table, {bucket_key, {config.burst_capacity - 1, now}})
        true
    end
  end

  defp initialize_token_bucket(config) do
    bucket_key = :token_bucket
    now = System.system_time(:millisecond)

    # Initialize with full burst capacity
    :ets.insert(@rate_limiter_table, {bucket_key, {config.burst_capacity, now}})
  end

  defp ensure_rate_limiter_table do
    case :ets.info(@rate_limiter_table) do
      :undefined ->
        :ets.new(@rate_limiter_table, [:set, :public, :named_table, {:write_concurrency, true}])
        :ok

      _ ->
        :ok
    end
  end

  @doc """
  Gets the current token bucket status.
  """
  @spec get_bucket_status() :: %{tokens: non_neg_integer(), last_refill: integer()} | nil
  def get_bucket_status do
    case :ets.info(@rate_limiter_table) do
      :undefined ->
        nil

      _ ->
        case :ets.lookup(@rate_limiter_table, :token_bucket) do
          [{:token_bucket, {tokens, last_refill}}] ->
            %{tokens: tokens, last_refill: last_refill}

          [] ->
            nil
        end
    end
  end

  @doc """
  Resets the token bucket to full capacity.
  """
  @spec reset_bucket(pos_integer()) :: :ok
  def reset_bucket(capacity \\ 100) do
    now = System.system_time(:millisecond)
    :ets.insert(@rate_limiter_table, {:token_bucket, {capacity, now}})
    :ok
  end

  @doc """
  Gets rate limiting statistics.
  """
  @spec get_stats() :: %{
          bucket_status: map() | nil,
          table_info: list()
        }
  def get_stats do
    %{
      bucket_status: get_bucket_status(),
      table_info:
        case :ets.info(@rate_limiter_table) do
          :undefined -> []
          info -> info
        end
    }
  end
end
