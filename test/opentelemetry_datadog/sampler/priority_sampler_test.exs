defmodule OpentelemetryDatadog.Sampler.PrioritySamplerTest do
  use ExUnit.Case, async: false

  alias OpentelemetryDatadog.Sampler.PrioritySampler
  alias OpentelemetryDatadog.DatadogConstants

  @moduletag :unit

  describe "priority sampling constants" do
    test "uses correct Datadog priority values" do
      assert DatadogConstants.sampling_priority(:USER_REJECT) == -1
      assert DatadogConstants.sampling_priority(:AUTO_REJECT) == 0
      assert DatadogConstants.sampling_priority(:AUTO_KEEP) == 1
      assert DatadogConstants.sampling_priority(:USER_KEEP) == 2
    end
  end

  describe "setup/1" do
    test "configures with default settings" do
      config = PrioritySampler.setup(default_rate: 0.5)

      assert config.default_rate == 0.5
      assert config.enable_user_priority == true
      assert config.rules == []
    end

    test "configures with custom rules" do
      rules = [
        %{
          service: "critical-service",
          rate: 1.0,
          priority: DatadogConstants.sampling_priority(:USER_KEEP)
        },
        %{operation: "slow-operation", rate: 0.1}
      ]

      config = PrioritySampler.setup(default_rate: 0.5, rules: rules)

      assert length(config.rules) == 2
      assert hd(config.rules).service == "critical-service"
      assert hd(config.rules).rate == 1.0
      assert hd(config.rules).priority == DatadogConstants.sampling_priority(:USER_KEEP)
    end

    test "validates sampling rates" do
      config = PrioritySampler.setup(default_rate: 1.5)
      assert config.default_rate == 1.0

      config = PrioritySampler.setup(default_rate: -0.1)
      assert config.default_rate == 0.0
    end

    test "validates priority values in rules" do
      assert_raise ArgumentError, fn ->
        PrioritySampler.setup(
          default_rate: 0.5,
          # Invalid priority
          rules: [%{service: "test", rate: 1.0, priority: 5}]
        )
      end
    end
  end

  describe "should_sample/6 with priority sampling" do
    test "applies AUTO_KEEP priority for sampled traces" do
      config = PrioritySampler.setup(default_rate: 1.0)

      {decision, attributes, _trace_state} =
        PrioritySampler.should_sample(
          %{},
          123_456_789,
          [],
          "test.operation",
          :server,
          %{},
          config
        )

      assert decision == :record_and_sample
      assert attributes._sampling_priority_v1 == DatadogConstants.sampling_priority(:AUTO_KEEP)
      assert attributes["_dd.p.dm"] == DatadogConstants.sampling_mechanism_used(:DEFAULT)
    end

    test "applies AUTO_REJECT priority for dropped traces" do
      config = PrioritySampler.setup(default_rate: 0.0)

      {decision, attributes, _trace_state} =
        PrioritySampler.should_sample(
          %{},
          123_456_789,
          [],
          "test.operation",
          :server,
          %{},
          config
        )

      assert decision == :drop
      assert attributes._sampling_priority_v1 == DatadogConstants.sampling_priority(:AUTO_REJECT)
      assert attributes["_dd.p.dm"] == DatadogConstants.sampling_mechanism_used(:DEFAULT)
    end

    test "respects priority from attributes" do
      config = PrioritySampler.setup(default_rate: 0.0)

      {decision, attributes, _trace_state} =
        PrioritySampler.should_sample(
          %{},
          123_456_789,
          [],
          "test.operation",
          :server,
          %{"_sampling_priority_v1" => DatadogConstants.sampling_priority(:USER_KEEP)},
          config
        )

      assert decision == :record_and_sample
      assert attributes._sampling_priority_v1 == DatadogConstants.sampling_priority(:USER_KEEP)
      assert attributes["_dd.p.dm"] == DatadogConstants.sampling_mechanism_used(:MANUAL)
    end

    test "ignores user priority when disabled" do
      config = PrioritySampler.setup(default_rate: 0.0, enable_user_priority: false)

      {decision, attributes, _trace_state} =
        PrioritySampler.should_sample(
          %{},
          123_456_789,
          [],
          "test.operation",
          :server,
          %{"_sampling_priority_v1" => DatadogConstants.sampling_priority(:USER_KEEP)},
          config
        )

      assert decision == :drop
      assert attributes._sampling_priority_v1 == DatadogConstants.sampling_priority(:AUTO_REJECT)
      assert attributes["_dd.p.dm"] == DatadogConstants.sampling_mechanism_used(:DEFAULT)
    end
  end

  describe "sampling rules with priorities" do
    test "applies rule-based priority" do
      rules = [
        %{
          service: "critical-service",
          rate: 0.5,
          priority: DatadogConstants.sampling_priority(:USER_KEEP)
        }
      ]

      config = PrioritySampler.setup(default_rate: 0.0, rules: rules)

      {decision, attributes, _trace_state} =
        PrioritySampler.should_sample(
          %{},
          123_456_789,
          [],
          "test.operation",
          :server,
          %{"service.name" => "critical-service"},
          config
        )

      assert decision == :record_and_sample
      assert attributes._sampling_priority_v1 == DatadogConstants.sampling_priority(:USER_KEEP)
      assert attributes["_dd.p.dm"] == DatadogConstants.sampling_mechanism_used(:RULE)
      assert attributes["_dd.rule_psr"] == 0.5
    end

    test "applies rule-based rejection priority" do
      rules = [
        %{
          service: "noisy-service",
          rate: 1.0,
          priority: DatadogConstants.sampling_priority(:USER_REJECT)
        }
      ]

      config = PrioritySampler.setup(default_rate: 1.0, rules: rules)

      {decision, attributes, _trace_state} =
        PrioritySampler.should_sample(
          %{},
          123_456_789,
          [],
          "test.operation",
          :server,
          %{"service.name" => "noisy-service"},
          config
        )

      assert decision == :drop
      assert attributes._sampling_priority_v1 == DatadogConstants.sampling_priority(:USER_REJECT)
      assert attributes["_dd.p.dm"] == DatadogConstants.sampling_mechanism_used(:RULE)
    end

    test "uses probabilistic sampling when no priority is forced in rule" do
      rules = [
        # No priority specified
        %{service: "normal-service", rate: 1.0}
      ]

      config = PrioritySampler.setup(default_rate: 0.0, rules: rules)

      {decision, attributes, _trace_state} =
        PrioritySampler.should_sample(
          %{},
          123_456_789,
          [],
          "test.operation",
          :server,
          %{"service.name" => "normal-service"},
          config
        )

      assert decision == :record_and_sample
      assert attributes._sampling_priority_v1 == DatadogConstants.sampling_priority(:AUTO_KEEP)
      assert attributes["_dd.p.dm"] == DatadogConstants.sampling_mechanism_used(:RULE)
    end
  end

  describe "set_sampling_priority/1" do
    test "sets priority with atom values" do
      assert :ok = PrioritySampler.set_sampling_priority(:USER_KEEP)
      assert :ok = PrioritySampler.set_sampling_priority(:USER_REJECT)
      assert :ok = PrioritySampler.set_sampling_priority(:AUTO_KEEP)
      assert :ok = PrioritySampler.set_sampling_priority(:AUTO_REJECT)
    end

    test "sets priority with numeric values" do
      # USER_REJECT
      assert :ok = PrioritySampler.set_sampling_priority(-1)
      # AUTO_REJECT
      assert :ok = PrioritySampler.set_sampling_priority(0)
      # AUTO_KEEP
      assert :ok = PrioritySampler.set_sampling_priority(1)
      # USER_KEEP
      assert :ok = PrioritySampler.set_sampling_priority(2)
    end

    test "rejects invalid priority values" do
      assert_raise ArgumentError, fn ->
        PrioritySampler.set_sampling_priority(5)
      end

      assert_raise ArgumentError, fn ->
        PrioritySampler.set_sampling_priority(-5)
      end

      assert_raise ArgumentError, fn ->
        PrioritySampler.set_sampling_priority(:invalid)
      end
    end
  end

  describe "probabilistic sampling behavior" do
    test "samples deterministically based on trace ID" do
      config = PrioritySampler.setup(default_rate: 0.5)

      {decision1, _, _} =
        PrioritySampler.should_sample(
          %{},
          123_456_789_123_456_789,
          [],
          "test.operation",
          :server,
          %{},
          config
        )

      {decision2, _, _} =
        PrioritySampler.should_sample(
          %{},
          123_456_789_123_456_789,
          [],
          "test.operation",
          :server,
          %{},
          config
        )

      assert decision1 == decision2
    end

    test "samples at 100% when rate is 1.0" do
      config = PrioritySampler.setup(default_rate: 1.0)

      results =
        for i <- 1..100 do
          {decision, _, _} =
            PrioritySampler.should_sample(
              %{},
              i * 1000,
              [],
              "test.operation",
              :server,
              %{},
              config
            )

          decision
        end

      assert Enum.all?(results, &(&1 == :record_and_sample))
    end

    test "drops all when rate is 0.0" do
      config = PrioritySampler.setup(default_rate: 0.0)

      results =
        for i <- 1..100 do
          {decision, _, _} =
            PrioritySampler.should_sample(
              %{},
              i * 1000,
              [],
              "test.operation",
              :server,
              %{},
              config
            )

          decision
        end

      assert Enum.all?(results, &(&1 == :drop))
    end
  end

  describe "rule matching" do
    test "matches service names" do
      rules = [%{service: "api-service", rate: 1.0}]
      config = PrioritySampler.setup(default_rate: 0.0, rules: rules)

      {decision, _, _} =
        PrioritySampler.should_sample(
          %{},
          123_456_789,
          [],
          "test.operation",
          :server,
          %{"service.name" => "api-service"},
          config
        )

      assert decision == :record_and_sample
    end

    test "matches operation names" do
      rules = [%{operation: "db.query", rate: 1.0}]
      config = PrioritySampler.setup(default_rate: 0.0, rules: rules)

      {decision, _, _} =
        PrioritySampler.should_sample(
          %{},
          123_456_789,
          [],
          "db.query",
          :client,
          %{},
          config
        )

      assert decision == :record_and_sample
    end

    test "uses default rate when no rules match" do
      rules = [%{service: "other-service", rate: 1.0}]
      config = PrioritySampler.setup(default_rate: 0.0, rules: rules)

      {decision, _, _} =
        PrioritySampler.should_sample(
          %{},
          123_456_789,
          [],
          "test.operation",
          :server,
          %{"service.name" => "my-service"},
          config
        )

      assert decision == :drop
    end
  end

  describe "description/1" do
    test "provides descriptive string" do
      config =
        PrioritySampler.setup(
          default_rate: 0.7,
          rules: [%{service: "test", rate: 1.0}]
        )

      desc = PrioritySampler.description(config)

      assert desc =~ "PrioritySampler"
      assert desc =~ "rate=0.7"
      assert desc =~ "rules=1"
    end
  end

  describe "validates all priority values are within valid range" do
    test "boundary values" do
      # USER_REJECT, AUTO_REJECT, AUTO_KEEP, USER_KEEP
      priorities = [-1, 0, 1, 2]

      for priority <- priorities do
        assert :ok = PrioritySampler.set_sampling_priority(priority)
      end

      invalid_priorities = [-2, 3, 10, -10]

      for invalid_priority <- invalid_priorities do
        assert_raise ArgumentError, fn ->
          PrioritySampler.set_sampling_priority(invalid_priority)
        end
      end
    end
  end
end
