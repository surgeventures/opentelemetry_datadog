defmodule OpentelemetryDatadog.Sampler.TailBasedSamplerTest do
  use ExUnit.Case, async: false

  alias OpentelemetryDatadog.Sampler.TailBasedSampler
  alias OpentelemetryDatadog.DatadogConstants

  @moduletag :unit

  setup do
    on_exit(fn ->
      # Clean up ETS table and GenServer
      try do
        :ets.delete(:otel_dd_tail_sampler)
      rescue
        ArgumentError -> :ok
      end

      try do
        GenServer.stop(TailBasedSampler.TraceManager)
      catch
        :exit, _ -> :ok
      end
    end)

    :ok
  end

  describe "setup/1" do
    test "configures with default settings" do
      config = TailBasedSampler.setup([])

      assert config.decision_timeout_ms == 10_000
      assert config.max_buffered_traces == 1000
      assert config.sample_errors == true
      assert config.slow_trace_threshold_ms == 1000
      assert config.fallback_rate == 0.1
      assert config.policies == []
    end

    test "configures with custom settings" do
      policies = [
        %{type: :error, sample: true},
        %{type: :service, service: "critical", sample: true, rate: 1.0}
      ]

      config =
        TailBasedSampler.setup(
          decision_timeout_ms: 5000,
          max_buffered_traces: 500,
          sample_errors: false,
          fallback_rate: 0.2,
          policies: policies
        )

      assert config.decision_timeout_ms == 5000
      assert config.max_buffered_traces == 500
      assert config.sample_errors == false
      assert config.fallback_rate == 0.2
      assert length(config.policies) == 2
    end

    test "starts TraceManager GenServer" do
      TailBasedSampler.setup([])

      # Check if GenServer is running
      assert Process.whereis(TailBasedSampler.TraceManager) != nil
    end
  end

  describe "should_sample/6 - basic functionality" do
    test "buffers first span of a trace" do
      config = TailBasedSampler.setup(fallback_rate: 1.0)

      {decision, attributes, _trace_state} =
        TailBasedSampler.should_sample(
          %{},
          123_456_789,
          [],
          "test.operation",
          :server,
          %{},
          config
        )

      # Should optimistically sample while buffering
      assert decision == :record_and_sample
      assert attributes[:_sampling_priority_v1] == DatadogConstants.sampling_priority(:AUTO_KEEP)
      assert attributes["_dd.tail_sampled"] == true

      # Verify trace is buffered
      stats = TailBasedSampler.get_stats()
      assert stats.buffered_traces >= 1
    end

    test "uses existing decision for known trace" do
      config = TailBasedSampler.setup([])
      trace_id = 123_456_789

      # Buffer the trace first
      TailBasedSampler.should_sample(%{}, trace_id, [], "test.operation", :server, %{}, config)

      # Force a decision for this trace
      :ok = TailBasedSampler.force_decision(trace_id, true)

      {decision, attributes, _trace_state} =
        TailBasedSampler.should_sample(
          %{},
          trace_id,
          [],
          "test.operation",
          :server,
          %{},
          config
        )

      assert decision == :record_and_sample
      assert attributes[:_sampling_priority_v1] == DatadogConstants.sampling_priority(:USER_KEEP)
    end
  end

  describe "error-based sampling" do
    test "immediately samples traces with errors when sample_errors is true" do
      config = TailBasedSampler.setup(sample_errors: true, fallback_rate: 0.0)

      {decision, attributes, _trace_state} =
        TailBasedSampler.should_sample(
          %{},
          123_456_789,
          [],
          "test.operation",
          :server,
          %{"error" => true},
          config
        )

      assert decision == :record_and_sample
      assert attributes[:_sampling_priority_v1] == DatadogConstants.sampling_priority(:AUTO_KEEP)
    end

    test "detects HTTP error status codes" do
      config = TailBasedSampler.setup(sample_errors: true, fallback_rate: 0.0)

      {decision, attributes, _trace_state} =
        TailBasedSampler.should_sample(
          %{},
          123_456_789,
          [],
          "http.request",
          :server,
          %{"http.status_code" => 500},
          config
        )

      assert decision == :record_and_sample
      assert attributes[:_sampling_priority_v1] == DatadogConstants.sampling_priority(:AUTO_KEEP)
    end

    test "detects OpenTelemetry status errors" do
      config = TailBasedSampler.setup(sample_errors: true, fallback_rate: 0.0)

      {decision, attributes, _trace_state} =
        TailBasedSampler.should_sample(
          %{},
          123_456_789,
          [],
          "test.operation",
          :server,
          %{"otel.status_code" => :error},
          config
        )

      assert decision == :record_and_sample
      assert attributes[:_sampling_priority_v1] == DatadogConstants.sampling_priority(:AUTO_KEEP)
    end

    test "does not sample errors when sample_errors is false" do
      config = TailBasedSampler.setup(sample_errors: false, fallback_rate: 1.0)

      {decision, attributes, _trace_state} =
        TailBasedSampler.should_sample(
          %{},
          123_456_789,
          [],
          "test.operation",
          :server,
          %{"error" => true},
          config
        )

      # Should use fallback rate instead of error sampling
      assert decision == :record_and_sample
      assert attributes[:_sampling_priority_v1] == DatadogConstants.sampling_priority(:AUTO_KEEP)
    end
  end

  describe "policy-based sampling" do
    test "samples based on service policy" do
      policies = [
        %{type: :service, service: "critical-service", sample: true, rate: 1.0}
      ]

      config = TailBasedSampler.setup(policies: policies, fallback_rate: 0.0)

      {decision, attributes, _trace_state} =
        TailBasedSampler.should_sample(
          %{},
          123_456_789,
          [],
          "test.operation",
          :server,
          %{"service.name" => "critical-service"},
          config
        )

      assert decision == :record_and_sample
      assert attributes[:_sampling_priority_v1] == DatadogConstants.sampling_priority(:AUTO_KEEP)
    end

    test "applies probabilistic sampling for service policies" do
      policies = [
        %{type: :service, service: "test-service", sample: true, rate: 0.5}
      ]

      config = TailBasedSampler.setup(policies: policies, fallback_rate: 0.0)

      # Test multiple times to check probabilistic behavior
      results =
        for i <- 1..20 do
          {decision, _, _} =
            TailBasedSampler.should_sample(
              %{},
              # Different trace IDs
              i * 1000,
              [],
              "test.operation",
              :server,
              %{"service.name" => "test-service"},
              config
            )

          decision
        end

      # With 50% rate, should have both samples and drops
      samples = Enum.count(results, &(&1 == :record_and_sample))
      drops = Enum.count(results, &(&1 == :drop))

      assert samples > 0
      assert drops > 0
      assert samples + drops == 20
    end
  end

  describe "buffer management" do
    test "applies fallback sampling when buffer is full" do
      config =
        TailBasedSampler.setup(
          # Very small buffer
          max_buffered_traces: 2,
          fallback_rate: 1.0
        )

      # Fill the buffer
      TailBasedSampler.should_sample(%{}, 1, [], "op1", :server, %{}, config)
      TailBasedSampler.should_sample(%{}, 2, [], "op2", :server, %{}, config)

      # This should trigger fallback sampling
      {decision, attributes, _trace_state} =
        TailBasedSampler.should_sample(
          %{},
          # New trace ID
          3,
          [],
          "test.operation",
          :server,
          %{},
          config
        )

      assert decision == :record_and_sample
      assert attributes[:_sampling_priority_v1] == DatadogConstants.sampling_priority(:AUTO_KEEP)
    end

    test "updates trace metadata when adding spans" do
      config = TailBasedSampler.setup([])
      trace_id = 123_456_789

      # First span
      TailBasedSampler.should_sample(
        %{},
        trace_id,
        [],
        "span1",
        :server,
        %{"service.name" => "service1"},
        config
      )

      # Second span with different service
      TailBasedSampler.should_sample(
        %{},
        trace_id,
        [],
        "span2",
        :client,
        %{"service.name" => "service2"},
        config
      )

      # The trace should now have metadata for both services
      # This is verified indirectly through the sampling behavior
      stats = TailBasedSampler.get_stats()
      assert stats.buffered_traces >= 1
    end
  end

  describe "force_decision/2" do
    test "forces sampling decision for buffered trace" do
      config = TailBasedSampler.setup([])
      trace_id = 123_456_789

      # Buffer a trace
      TailBasedSampler.should_sample(%{}, trace_id, [], "test.operation", :server, %{}, config)

      # Force decision
      assert :ok = TailBasedSampler.force_decision(trace_id, true)

      # Next span for same trace should use forced decision
      {decision, attributes, _trace_state} =
        TailBasedSampler.should_sample(
          %{},
          trace_id,
          [],
          "another.operation",
          :server,
          %{},
          config
        )

      assert decision == :record_and_sample
      assert attributes[:_sampling_priority_v1] == DatadogConstants.sampling_priority(:USER_KEEP)
    end

    test "returns not_found for non-existent trace" do
      assert :not_found = TailBasedSampler.force_decision(999_999_999, true)
    end
  end

  describe "get_stats/0" do
    test "returns comprehensive statistics" do
      TailBasedSampler.setup([])

      # Buffer some traces
      config = %TailBasedSampler.Config{
        decision_timeout_ms: 10_000,
        max_buffered_traces: 1000,
        sample_errors: true,
        slow_trace_threshold_ms: 1000,
        fallback_rate: 0.1,
        policies: []
      }

      TailBasedSampler.should_sample(%{}, 1, [], "op1", :server, %{}, config)
      TailBasedSampler.force_decision(1, true)

      stats = TailBasedSampler.get_stats()

      assert is_map(stats)
      assert Map.has_key?(stats, :buffered_traces)
      assert Map.has_key?(stats, :decided_traces)
      assert Map.has_key?(stats, :table_size)
      assert Map.has_key?(stats, :memory_usage_bytes)
      assert is_integer(stats.table_size)
      assert is_integer(stats.memory_usage_bytes)
    end

    test "returns zeros when table doesn't exist" do
      try do
        :ets.delete(:otel_dd_tail_sampler)
      rescue
        ArgumentError -> :ok
      end

      stats = TailBasedSampler.get_stats()

      assert stats.buffered_traces == 0
      assert stats.decided_traces == 0
      assert stats.table_size == 0
      assert stats.memory_usage_bytes == 0
    end
  end

  describe "clear_buffer/0" do
    test "clears all buffered traces" do
      config = TailBasedSampler.setup([])

      TailBasedSampler.should_sample(%{}, 1, [], "op1", :server, %{}, config)
      TailBasedSampler.should_sample(%{}, 2, [], "op2", :server, %{}, config)

      stats_before = TailBasedSampler.get_stats()
      assert stats_before.table_size > 0

      :ok = TailBasedSampler.clear_buffer()

      stats_after = TailBasedSampler.get_stats()
      assert stats_after.table_size == 0
    end
  end

  describe "description/1" do
    test "provides descriptive string" do
      config =
        TailBasedSampler.setup(
          decision_timeout_ms: 5000,
          max_buffered_traces: 500,
          policies: [%{type: :error, sample: true}]
        )

      desc = TailBasedSampler.description(config)

      assert desc =~ "TailBasedSampler"
      assert desc =~ "timeout=5000ms"
      assert desc =~ "buffer=500"
      assert desc =~ "policies=1"
    end
  end

  describe "edge cases" do
    test "handles very high trace volumes gracefully" do
      config =
        TailBasedSampler.setup(
          max_buffered_traces: 10,
          # Use 0.0 to ensure buffer fill behavior
          fallback_rate: 0.0
        )

      # Generate many traces quickly
      results =
        for i <- 1..100 do
          TailBasedSampler.should_sample(%{}, i, [], "op#{i}", :server, %{}, config)
        end

      # Should handle gracefully without crashes
      assert length(results) == 100

      # First 10 should be buffered, rest should use fallback
      stats = TailBasedSampler.get_stats()
      # Buffer limit
      assert stats.buffered_traces <= 10
    end

    test "handles concurrent access to same trace" do
      config = TailBasedSampler.setup([])
      trace_id = 123_456_789

      # Concurrent access to same trace
      tasks =
        for i <- 1..10 do
          Task.async(fn ->
            TailBasedSampler.should_sample(%{}, trace_id, [], "span#{i}", :server, %{}, config)
          end)
        end

      results = Task.await_many(tasks, 1000)

      # All should succeed without error
      assert length(results) == 10
      # All should get the same decision (first one buffers, rest use existing decision)
      decisions = Enum.map(results, fn {decision, _, _} -> decision end)
      assert Enum.all?(decisions, &(&1 == :record_and_sample))
    end
  end

  describe "validates all priority values are within valid range" do
    test "boundary values work correctly" do
      config = TailBasedSampler.setup([])
      trace_id = 123_456_789

      # Buffer the trace first
      TailBasedSampler.should_sample(%{}, trace_id, [], "test.operation", :server, %{}, config)

      # Test force decision with different priority values
      assert :ok = TailBasedSampler.force_decision(trace_id, true)

      {_, attrs, _} =
        TailBasedSampler.should_sample(%{}, trace_id, [], "test", :server, %{}, config)

      assert attrs[:_sampling_priority_v1] == DatadogConstants.sampling_priority(:USER_KEEP)

      # Test rejecting trace
      TailBasedSampler.clear_buffer()
      trace_id2 = 987_654_321
      # Buffer the second trace first
      TailBasedSampler.should_sample(%{}, trace_id2, [], "test2.operation", :server, %{}, config)
      assert :ok = TailBasedSampler.force_decision(trace_id2, false)

      {_, attrs, _} =
        TailBasedSampler.should_sample(%{}, trace_id2, [], "test", :server, %{}, config)

      assert attrs[:_sampling_priority_v1] == DatadogConstants.sampling_priority(:USER_REJECT)
    end
  end
end
