require "test_helper"

class PrecomputeEnterpriseMausJobTest < ActiveSupport::TestCase
  fixtures :instances, :projects, :devices, :visitors

  setup do
    @instance = instances(:one)
    @cache = ActiveSupport::Cache::MemoryStore.new
    EnterpriseSubscription.delete_all
  end

  test "computes real distinct-visitor MAU and writes it to cache" do
    EnterpriseSubscription.create!(instance: @instance, active: true,
                                   start_date: Date.current.beginning_of_month,
                                   end_date: 1.year.from_now, total_maus: 50_000)
    VisitorDailyStatistic.delete_all
    [visitors(:ios_visitor), visitors(:android_visitor)].each do |v|
      VisitorDailyStatistic.create!(visitor: v, project_id: v.project_id,
                                    event_date: Date.current, platform: "ios", views: 1)
    end

    Rails.stub(:cache, @cache) do
      PrecomputeEnterpriseMausJob.new.perform
    end

    assert_equal 2, @cache.read("enterprise_mau:#{@instance.id}"),
      "two distinct visitors this month = 2 MAUs"
  end

  test "skips inactive subscriptions" do
    EnterpriseSubscription.create!(instance: @instance, active: false,
                                   start_date: 2.months.ago, end_date: 1.year.from_now, total_maus: 50_000)

    Rails.stub(:cache, @cache) do
      PrecomputeEnterpriseMausJob.new.perform
    end

    assert_nil @cache.read("enterprise_mau:#{@instance.id}")
  end

  test "a failure logs and does not raise" do
    EnterpriseSubscription.create!(instance: @instance, active: true,
                                   start_date: 2.months.ago, end_date: 1.year.from_now, total_maus: 50_000)

    failing = Object.new
    def failing.compute_maus_per_month_total(*) = raise("db timeout")

    Rails.stub(:cache, @cache) do
      ProjectService.stub(:new, failing) do
        assert_nothing_raised { PrecomputeEnterpriseMausJob.new.perform }
      end
    end
    assert_nil @cache.read("enterprise_mau:#{@instance.id}")
  end

  # Must outlive the 30-min cron, or a web request recomputes the exact read itself.
  test "the cached value outlives the precompute interval" do
    EnterpriseSubscription.create!(instance: @instance, active: true,
                                   start_date: Date.current.beginning_of_month,
                                   end_date: 1.year.from_now, total_maus: 50_000)
    captured = nil

    Rails.stub(:cache, @cache) do
      @cache.stub(:write, ->(_k, _v, opts) { captured = opts[:expires_in] }) do
        PrecomputeEnterpriseMausJob.new.perform
      end
    end

    assert_operator captured, :>, 30.minutes, "TTL must exceed the cron interval"
  end
end
