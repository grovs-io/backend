require "test_helper"

class Grovs::MetricsTest < ActiveSupport::TestCase
  setup do
    Grovs::Metrics.reset!
  end

  test "boots cleanly in test env without raising (OTel SDK not loaded; default no-op provider)" do
    assert_nothing_raised do
      Grovs::Metrics.increment("test.counter", tags: { provider: "branch" })
      Grovs::Metrics.histogram("test.latency", 42, tags: { provider: "branch" })
    end
  end

  test "increment accepts tags with symbol keys and stringifies them for OTel attributes" do
    counter = Minitest::Mock.new
    counter.expect(:add, nil, [1], attributes: { "provider" => "branch", "kind" => "redirect" })

    Grovs::Metrics.stub(:counter_for, counter) do
      Grovs::Metrics.increment("migration.outcome", tags: { provider: "branch", kind: :redirect })
    end

    assert_mock counter
  end

  test "increment passes the `by` value through to OTel counter add" do
    counter = Minitest::Mock.new
    counter.expect(:add, nil, [5], attributes: {})

    Grovs::Metrics.stub(:counter_for, counter) do
      Grovs::Metrics.increment("test.counter", by: 5)
    end

    assert_mock counter
  end

  test "counter_for returns the same instance on repeat calls (lazy + cached)" do
    a = Grovs::Metrics.send(:counter_for, "test.counter.idempotent")
    b = Grovs::Metrics.send(:counter_for, "test.counter.idempotent")
    assert_same a, b
  end

  test "histogram_for returns the same instance on repeat calls (lazy + cached)" do
    a = Grovs::Metrics.send(:histogram_for, "test.hist.idempotent")
    b = Grovs::Metrics.send(:histogram_for, "test.hist.idempotent")
    assert_same a, b
  end

  test "increment rescues exceptions from the underlying counter and logs a warning" do
    bad_counter = Object.new
    def bad_counter.add(*) = raise("boom")

    Grovs::Metrics.stub(:counter_for, bad_counter) do
      assert_nothing_raised do
        Grovs::Metrics.increment("test.counter.exception")
      end
    end
  end

  test "histogram rescues exceptions from the underlying histogram and logs a warning" do
    bad_hist = Object.new
    def bad_hist.record(*) = raise("boom")

    Grovs::Metrics.stub(:histogram_for, bad_hist) do
      assert_nothing_raised do
        Grovs::Metrics.histogram("test.hist.exception", 42)
      end
    end
  end

  test "reset! clears cached counters and histograms" do
    Grovs::Metrics.send(:counter_for, "test.reset.counter")
    Grovs::Metrics.send(:histogram_for, "test.reset.histogram")

    Grovs::Metrics.reset!

    assert_nil Grovs::Metrics.instance_variable_get(:@counters)
    assert_nil Grovs::Metrics.instance_variable_get(:@histograms)
  end
end
