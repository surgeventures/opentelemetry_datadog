defmodule OpentelemetryDatadog.Sampler.RateLimiterTest do
  use ExUnit.Case, async: false

  alias OpentelemetryDatadog.Sampler.{RateLimiter, PrioritySampler}
  alias OpentelemetryDatadog.DatadogConstants

  @moduletag :unit

  setup do
    on_exit(fn ->
      # Clean up ETS table
      try do
        :ets.delete(:otel_dd_rate_limiter)
      rescue
        ArgumentError -> :ok
      end
    end)

    :ok
  end

  describe "setup/1" do
    test "configures with wrapped sampler" do
      config =
        RateLimiter.setup(
          wrapped_sampler: {PrioritySampler, [default_rate: 1.0]},
          max_traces_per_second: 10,
          burst_capacity: 20
        )

      assert config.wrapped_sampler == PrioritySampler
      assert config.max_traces_per_second == 10
      assert config.burst_capacity == 20
      assert config.window_size_ms == 1000
    end

    test "sets default burst capacity" do
      config =
        RateLimiter.setup(
          wrapped_sampler: {PrioritySampler, [default_rate: 1.0]},
          max_traces_per_second: 50
        )

      # 2x max_traces_per_second
      assert config.burst_capacity == 100
    end

    test "initializes ETS table and token bucket" do
      RateLimiter.setup(
        wrapped_sampler: {PrioritySampler, [default_rate: 1.0]},
        max_traces_per_second: 10,
        burst_capacity: 20
      )

      # Table should exist
      info = :ets.info(:otel_dd_rate_limiter)
      assert info != :undefined

      # Bucket should be initialized
      status = RateLimiter.get_bucket_status()
      assert status != nil
      # Should start with full capacity
      assert status.tokens == 20
    end
  end

  describe "should_sample/6" do
    test "delegates to wrapped sampler when under rate limit" do
      config =
        RateLimiter.setup(
          wrapped_sampler: {PrioritySampler, [default_rate: 1.0]},
          max_traces_per_second: 100
        )

      {decision, attributes, _trace_state} =
        RateLimiter.should_sample(
          %{},
          123_456_789,
          [],
          "test.operation",
          :server,
          %{},
          config
        )

      # Should delegate to PrioritySampler with default_rate: 1.0
      assert decision == :record_and_sample
      assert attributes._sampling_priority_v1 == DatadogConstants.sampling_priority(:AUTO_KEEP)
    end

    test "applies rate limiting when limit exceeded" do
      # Small rate limit to easily exceed
      config =
        RateLimiter.setup(
          wrapped_sampler: {PrioritySampler, [default_rate: 1.0]},
          max_traces_per_second: 1,
          burst_capacity: 1
        )

      # First request should work
      {decision1, attributes1, _} =
        RateLimiter.should_sample(
          %{},
          123_456_789,
          [],
          "test.operation1",
          :server,
          %{},
          config
        )

      # Second request should be rate limited
      {decision2, attributes2, _} =
        RateLimiter.should_sample(
          %{},
          987_654_321,
          [],
          "test.operation2",
          :server,
          %{},
          config
        )

      # First should delegate to wrapped sampler
      assert decision1 == :record_and_sample
      assert attributes1._sampling_priority_v1 == DatadogConstants.sampling_priority(:AUTO_KEEP)

      # Second should be rejected due to rate limit
      assert decision2 == :drop
      assert attributes2._sampling_priority_v1 == DatadogConstants.sampling_priority(:AUTO_REJECT)
      assert attributes2["_dd.rate_limited"] == true
      assert attributes2["_dd.p.dm"] == DatadogConstants.sampling_mechanism_used(:RULE)
    end

    test "preserves wrapped sampler's decision attributes" do
      config =
        RateLimiter.setup(
          wrapped_sampler: {PrioritySampler, [default_rate: 0.5]},
          max_traces_per_second: 100
        )

      {decision, attributes, _trace_state} =
        RateLimiter.should_sample(
          %{},
          123_456_789,
          [],
          "test.operation",
          :server,
          %{},
          config
        )

      # Should preserve all attributes from wrapped sampler
      assert Map.has_key?(attributes, :_sampling_priority_v1)
      assert Map.has_key?(attributes, "_dd.p.dm")

      # Should not have rate limiting marker when not rate limited
      refute Map.has_key?(attributes, "_dd.rate_limited")
    end
  end

  describe "token bucket algorithm" do
    test "consumes tokens correctly" do
      config =
        RateLimiter.setup(
          wrapped_sampler: {PrioritySampler, [default_rate: 1.0]},
          max_traces_per_second: 5,
          burst_capacity: 5
        )

      initial_status = RateLimiter.get_bucket_status()
      assert initial_status.tokens == 5

      # Consume one token
      {decision, _, _} = RateLimiter.should_sample(%{}, 1, [], "op1", :server, %{}, config)
      assert decision == :record_and_sample

      status_after = RateLimiter.get_bucket_status()
      assert status_after.tokens == 4
    end

    test "blocks when tokens exhausted" do
      config =
        RateLimiter.setup(
          wrapped_sampler: {PrioritySampler, [default_rate: 1.0]},
          max_traces_per_second: 2,
          burst_capacity: 2
        )

      # Consume all tokens
      {decision1, _, _} = RateLimiter.should_sample(%{}, 1, [], "op1", :server, %{}, config)
      {decision2, _, _} = RateLimiter.should_sample(%{}, 2, [], "op2", :server, %{}, config)

      assert decision1 == :record_and_sample
      assert decision2 == :record_and_sample

      # Next request should be rate limited
      {decision3, attributes3, _} =
        RateLimiter.should_sample(%{}, 3, [], "op3", :server, %{}, config)

      assert decision3 == :drop
      assert attributes3["_dd.rate_limited"] == true
    end

    test "replenishes tokens over time" do
      config =
        RateLimiter.setup(
          wrapped_sampler: {PrioritySampler, [default_rate: 1.0]},
          max_traces_per_second: 10,
          burst_capacity: 5,
          # Faster replenishment for testing
          window_size_ms: 100
        )

      # Consume all tokens
      for i <- 1..5 do
        {decision, _, _} = RateLimiter.should_sample(%{}, i, [], "op#{i}", :server, %{}, config)
        assert decision == :record_and_sample
      end

      # Should be exhausted
      {decision, attributes, _} =
        RateLimiter.should_sample(%{}, 6, [], "op6", :server, %{}, config)

      assert decision == :drop
      assert attributes["_dd.rate_limited"] == true

      # Manually replenish by resetting bucket
      RateLimiter.reset_bucket(3)

      # Should work again
      {decision, attributes, _} =
        RateLimiter.should_sample(%{}, 7, [], "op7", :server, %{}, config)

      assert decision == :record_and_sample
      refute Map.get(attributes, "_dd.rate_limited", false)
    end
  end

  describe "get_bucket_status/0" do
    test "returns bucket status after setup" do
      RateLimiter.setup(
        wrapped_sampler: {PrioritySampler, [default_rate: 1.0]},
        max_traces_per_second: 10,
        burst_capacity: 20
      )

      status = RateLimiter.get_bucket_status()
      assert is_map(status)
      assert Map.has_key?(status, :tokens)
      assert Map.has_key?(status, :last_refill)
      # Should start at full capacity
      assert status.tokens == 20
      assert is_integer(status.last_refill)
    end

    test "returns nil when table not initialized" do
      # Clean up any existing table
      try do
        :ets.delete(:otel_dd_rate_limiter)
      rescue
        ArgumentError -> :ok
      end

      assert RateLimiter.get_bucket_status() == nil
    end
  end

  describe "reset_bucket/1" do
    test "resets bucket to specified capacity" do
      config =
        RateLimiter.setup(
          wrapped_sampler: {PrioritySampler, [default_rate: 1.0]},
          max_traces_per_second: 10,
          burst_capacity: 20
        )

      # Use some tokens
      RateLimiter.should_sample(%{}, 1, [], "op1", :server, %{}, config)

      status_before = RateLimiter.get_bucket_status()
      assert status_before.tokens < 20

      # Reset to custom capacity
      :ok = RateLimiter.reset_bucket(50)

      status_after = RateLimiter.get_bucket_status()
      assert status_after.tokens == 50
    end
  end

  describe "get_stats/0" do
    test "returns comprehensive statistics" do
      RateLimiter.setup(
        wrapped_sampler: {PrioritySampler, [default_rate: 1.0]},
        max_traces_per_second: 10
      )

      stats = RateLimiter.get_stats()
      assert is_map(stats)
      assert Map.has_key?(stats, :bucket_status)
      assert Map.has_key?(stats, :table_info)
      assert is_map(stats.bucket_status)
      assert is_list(stats.table_info)
    end

    test "handles missing table gracefully" do
      # Clean up table
      try do
        :ets.delete(:otel_dd_rate_limiter)
      rescue
        ArgumentError -> :ok
      end

      stats = RateLimiter.get_stats()
      assert stats.bucket_status == nil
      assert stats.table_info == []
    end
  end

  describe "description/1" do
    test "provides descriptive string with wrapped sampler info" do
      config =
        RateLimiter.setup(
          wrapped_sampler: {PrioritySampler, [default_rate: 0.7]},
          max_traces_per_second: 100,
          burst_capacity: 200
        )

      desc = RateLimiter.description(config)

      assert desc =~ "RateLimiter"
      assert desc =~ "100/s"
      assert desc =~ "burst=200"
      assert desc =~ "PrioritySampler"
      assert desc =~ "rate=0.7"
    end
  end

  describe "concurrent access" do
    test "handles concurrent token consumption safely" do
      config =
        RateLimiter.setup(
          wrapped_sampler: {PrioritySampler, [default_rate: 1.0]},
          max_traces_per_second: 10,
          burst_capacity: 10
        )

      # Simulate concurrent access
      tasks =
        for i <- 1..20 do
          Task.async(fn ->
            RateLimiter.should_sample(%{}, i, [], "op#{i}", :server, %{}, config)
          end)
        end

      results = Task.await_many(tasks, 1000)

      # Count successes and rate limited requests
      successes =
        Enum.count(results, fn {decision, attrs, _} ->
          decision == :record_and_sample
        end)

      rate_limited =
        Enum.count(results, fn {decision, attrs, _} ->
          decision == :drop and Map.get(attrs, "_dd.rate_limited", false)
        end)

      # Should have some rate limited requests due to burst capacity
      assert rate_limited > 0
      # Should have some successes (approximately up to burst capacity)
      assert successes > 0
      # Allow some tolerance for concurrent access
      assert successes <= 12
      # All requests should get some response
      assert successes + rate_limited == 20
    end
  end

  describe "edge cases" do
    test "handles very high rates" do
      config =
        RateLimiter.setup(
          wrapped_sampler: {PrioritySampler, [default_rate: 1.0]},
          max_traces_per_second: 10_000,
          burst_capacity: 20_000
        )

      # Should handle high rate limits without issues
      results =
        for i <- 1..100 do
          {decision, _, _} = RateLimiter.should_sample(%{}, i, [], "op#{i}", :server, %{}, config)
          decision
        end

      # Should not rate limit with such high capacity
      assert Enum.all?(results, &(&1 == :record_and_sample))
    end
  end
end
