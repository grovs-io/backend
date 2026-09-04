require "test_helper"

class ProjectServiceTest < ActiveSupport::TestCase
  fixtures :instances, :projects, :visitors, :devices, :visitor_daily_statistics

  setup do
    @service = ProjectService.new
    @instance = instances(:one)
    @project = projects(:one) # production project for instance :one (test: false)

    # Instance :one needs a test project for compute_mau_for_dates to work
    # (it checks instance.test and instance.production; both must be non-nil)
    @test_project = Project.create!(
      name: "Test Project Test Env",
      identifier: "test-project-001-test",
      instance: @instance,
      test: true
    )

    # Clear fixture data and create controlled test data so counts
    # don't break when someone adds a new fixture to visitor_daily_statistics.yml
    VisitorDailyStatistic.where(project_id: @project.id).delete_all

    # 3 stats: ios_visitor on day1+day2, android_visitor on day1
    # => 2 distinct visitors in March
    VisitorDailyStatistic.create!(visitor: visitors(:ios_visitor), project_id: @project.id,
      event_date: "2026-03-01", platform: "ios",
      views: 50, opens: 20, installs: 5, reinstalls: 1,
      time_spent: 3000, revenue: 500, reactivations: 0, app_opens: 10, user_referred: 2)
    VisitorDailyStatistic.create!(visitor: visitors(:ios_visitor), project_id: @project.id,
      event_date: "2026-03-02", platform: "ios",
      views: 80, opens: 30, installs: 8, reinstalls: 2,
      time_spent: 5000, revenue: 800, reactivations: 1, app_opens: 20, user_referred: 4)
    VisitorDailyStatistic.create!(visitor: visitors(:android_visitor), project_id: @project.id,
      event_date: "2026-03-01", platform: "android",
      views: 30, opens: 10, installs: 3, reinstalls: 0,
      time_spent: 2000, revenue: 300, reactivations: 0, app_opens: 8, user_referred: 1)
  end

  # --- compute_mau_for_dates ---

  test "compute_mau_for_dates counts distinct visitors across test and production projects" do
    start_date = Date.new(2026, 3, 1).beginning_of_day
    end_date = Date.new(2026, 3, 31).end_of_day

    # Fixtures have ios_visitor (2 stats: day1+day2) and android_visitor (1 stat: day1)
    # Both on project :one (production). They are distinct visitors => 2
    result = @service.send(:compute_mau_for_dates, @instance, start_date, end_date)
    assert_equal 2, result
  end

  test "compute_mau_for_dates returns 0 when instance is nil" do
    start_date = Date.new(2026, 3, 1).beginning_of_day
    end_date = Date.new(2026, 3, 31).end_of_day

    result = @service.send(:compute_mau_for_dates, nil, start_date, end_date)
    assert_equal 0, result
  end

  test "compute_mau_for_dates returns 0 when instance has no test project" do
    # Instance :two has project :two (production) but no test project
    instance_two = instances(:two)

    start_date = Date.new(2026, 3, 1).beginning_of_day
    end_date = Date.new(2026, 3, 31).end_of_day

    result = @service.send(:compute_mau_for_dates, instance_two, start_date, end_date)
    assert_equal 0, result
  end

  test "compute_mau_for_dates returns 0 when no stats exist in date range" do
    # April has no fixture stats
    start_date = Date.new(2026, 4, 1).beginning_of_day
    end_date = Date.new(2026, 4, 30).end_of_day

    result = @service.send(:compute_mau_for_dates, @instance, start_date, end_date)
    assert_equal 0, result
  end

  # --- compute_maus_per_month_total ---

  test "compute_maus_per_month_total sums MAUs across multiple months" do
    # Create a stat in February so there's data across two months
    feb_visitor = visitors(:ios_visitor)
    VisitorDailyStatistic.create!(
      visitor: feb_visitor,
      project_id: @project.id,
      event_date: Date.new(2026, 2, 15),
      platform: "ios",
      views: 10, opens: 5, installs: 0, reinstalls: 0,
      time_spent: 0, revenue: 0, reactivations: 0, app_opens: 0, user_referred: 0
    )

    start_date = Date.new(2026, 2, 1)
    end_date = Date.new(2026, 3, 31)

    result = @service.compute_maus_per_month_total(@instance, start_date, end_date)

    # Feb: 1 distinct visitor (ios_visitor)
    # Mar: 2 distinct visitors (ios_visitor + android_visitor from fixtures)
    # Total = 1 + 2 = 3
    assert_equal 3, result
  end

  test "compute_maus_per_month_total handles single-month range" do
    start_date = Date.new(2026, 3, 1)
    end_date = Date.new(2026, 3, 31)

    result = @service.compute_maus_per_month_total(@instance, start_date, end_date)

    # Mar: 2 distinct visitors (ios_visitor + android_visitor)
    assert_equal 2, result
  end

  # --- current_mau ---

  test "current_mau returns MAU for the current month" do
    travel_to Date.new(2026, 3, 15) do
      result = @service.current_mau(@instance)

      # March 2026 has fixture stats: ios_visitor + android_visitor = 2
      assert_equal 2, result
    end
  end

  # --- last_month_mau ---

  test "last_month_mau returns MAU for the previous month" do
    # Create a stat in February
    VisitorDailyStatistic.create!(
      visitor: visitors(:ios_visitor),
      project_id: @project.id,
      event_date: Date.new(2026, 2, 10),
      platform: "ios",
      views: 5, opens: 2, installs: 0, reinstalls: 0,
      time_spent: 0, revenue: 0, reactivations: 0, app_opens: 0, user_referred: 0
    )

    travel_to Date.new(2026, 3, 15) do
      result = @service.last_month_mau(@instance)

      # February 2026: 1 distinct visitor (ios_visitor)
      assert_equal 1, result
    end
  end

  test "last_month_mau returns 0 when no stats exist for previous month" do
    travel_to Date.new(2026, 3, 15) do
      result = @service.last_month_mau(@instance)

      # February 2026 has no fixture stats
      assert_equal 0, result
    end
  end

  # --- CH-primary mode (billing sources from ClickHouse) ---

  test "primary mode reads every billing month exact — the rollup never serves billing" do
    with_primary_mode do
      ClickhouseReadService.stub(:billing_active_visitors_exact, ->(*_a, **_k) { 5 }) do
        ClickhouseReadService.stub(:billing_active_visitors, ->(*_a, **_k) { flunk "rebuild-fed rollup must never serve billing" }) do
          travel_to Date.new(2026, 3, 15) do
            assert_equal 5, @service.current_mau(@instance)          # open month
            assert_equal 5, @service.compute_mau(@instance, 2, 2026) # closed month
            assert_equal 5, @service.compute_mau(@instance, 11, 2025) # long-settled month
          end
        end
      end
    end
  end

  test "primary mode raises MauReadUnavailable on CH failure instead of falling back to PG" do
    # March PG fixtures exist (2 visitors) — a fallback would return 2, not raise.
    with_primary_mode do
      ClickhouseReadService.stub(:billing_active_visitors_exact, ->(*_a, **_k) { nil }) do
        travel_to Date.new(2026, 3, 15) do
          assert_raises(ProjectService::MauReadUnavailable) { @service.current_mau(@instance) }
        end
      end
    end
  end

  test "primary mode returns 0 without CH reads when instance has no projects" do
    with_primary_mode do
      ClickhouseReadService.stub(:billing_active_visitors_exact, ->(*_a, **_k) { flunk "no CH read expected" }) do
        assert_equal 0, @service.send(:compute_mau_for_dates, instances(:two), Date.new(2026, 3, 1), Date.new(2026, 3, 31))
      end
    end
  end

  test "fresh_unsettled_months bypasses the open-month cache read in primary mode" do
    cache = ActiveSupport::Cache::MemoryStore.new
    with_primary_mode do
      Rails.stub(:cache, cache) do
        travel_to Date.new(2026, 3, 15) do
          cache.write("mau:ch:#{@instance.id}:2026-03", 999)

          ClickhouseReadService.stub(:billing_active_visitors_exact, ->(*_a, **_k) { 5 }) do
            result = @service.compute_maus_per_month_total(
              @instance, Date.new(2026, 3, 1), Date.new(2026, 3, 31), fresh_unsettled_months: true
            )
            assert_equal 5, result
          end

          assert_equal 5, cache.read("mau:ch:#{@instance.id}:2026-03"), "fresh value must be written back"
        end
      end
    end
  end

  test "primary mode never reads PG-era cache entries (separate CH namespace)" do
    cache = ActiveSupport::Cache::MemoryStore.new
    with_primary_mode do
      Rails.stub(:cache, cache) do
        travel_to Date.new(2026, 3, 15) do
          cache.write("mau:#{@instance.id}:2026-03", 999) # stale PG-mode value

          ClickhouseReadService.stub(:billing_active_visitors_exact, ->(*_a, **_k) { 5 }) do
            result = @service.compute_maus_per_month_total(
              @instance, Date.new(2026, 3, 1), Date.new(2026, 3, 31)
            )
            assert_equal 5, result, "flipping CLICKHOUSE_PRIMARY must not serve PG-derived cache"
          end
        end
      end
    end
  end

  test "a just-closed month inside the grace window is not frozen into the 30-day cache" do
    cache = ActiveSupport::Cache::MemoryStore.new
    with_primary_mode do
      Rails.stub(:cache, cache) do
        travel_to Date.new(2026, 3, 2) do
          cache.write("mau:ch:#{@instance.id}:2026-02", 999) # stale pre-late-flush value

          ClickhouseReadService.stub(:billing_active_visitors_exact, ->(*_a, **_k) { 4 }) do
            result = @service.compute_maus_per_month_total(
              @instance, Date.new(2026, 2, 1), Date.new(2026, 2, 28), fresh_unsettled_months: true
            )
            assert_equal 4, result, "just-closed month must recompute on the billing path during grace"
          end
        end
      end
    end
  end

  test "primary mode degrades when a drainable spill backlog covers the billed window" do
    spill = ClickhouseEventSpill.create!(
      project_id: @project.id,
      event_id: "spill-#{SecureRandom.hex(6)}",
      ch_row: { project_id: @project.id },
      event_created_at: Time.utc(2026, 3, 10),
      spilled_at: Time.current
    )

    with_primary_mode do
      ClickhouseReadService.stub(:billing_active_visitors_exact, ->(*_a, **_k) { flunk "must not read while events are still spilled" }) do
        travel_to Date.new(2026, 3, 15) do
          assert_raises(ProjectService::MauReadUnavailable) { @service.current_mau(@instance) }
        end
      end
    end
  ensure
    spill&.destroy
  end

  test "an exhausted (poison) spill row does not block billing" do
    spill = ClickhouseEventSpill.create!(
      project_id: @project.id,
      event_id: "poison-#{SecureRandom.hex(6)}",
      ch_row: { project_id: @project.id },
      event_created_at: Time.utc(2026, 3, 10),
      spilled_at: Time.current,
      attempts: ClickhouseEventSpill::MAX_DRAIN_ATTEMPTS,
      last_error: "bad row"
    )

    with_primary_mode do
      ClickhouseReadService.stub(:billing_active_visitors_exact, ->(*_a, **_k) { 5 }) do
        travel_to Date.new(2026, 3, 15) do
          assert_equal 5, @service.current_mau(@instance), "poison rows are surfaced for review, never a permanent billing block"
        end
      end
    end
  ensure
    spill&.destroy
  end

  test "fresh_unsettled_months still serves the cache outside primary mode" do
    cache = ActiveSupport::Cache::MemoryStore.new
    Rails.stub(:cache, cache) do
      travel_to Date.new(2026, 3, 15) do
        cache.write("mau:#{@instance.id}:2026-03", 999)

        result = @service.compute_maus_per_month_total(
          @instance, Date.new(2026, 3, 1), Date.new(2026, 3, 31), fresh_unsettled_months: true
        )
        assert_equal 999, result
      end
    end
  end

  test "fresh_unsettled_months keeps settled-month caches in primary mode" do
    cache = ActiveSupport::Cache::MemoryStore.new
    with_primary_mode do
      Rails.stub(:cache, cache) do
        travel_to Date.new(2026, 3, 15) do
          cache.write("mau:ch:#{@instance.id}:2026-02", 42)

          ClickhouseReadService.stub(:billing_active_visitors, ->(*_a, **_k) { flunk "settled cached month must not hit CH" }) do
            result = @service.compute_maus_per_month_total(
              @instance, Date.new(2026, 2, 1), Date.new(2026, 2, 28), fresh_unsettled_months: true
            )
            assert_equal 42, result
          end
        end
      end
    end
  end

  test "bust_mau_cache clears both cache namespaces for the affected months" do
    cache = ActiveSupport::Cache::MemoryStore.new
    Rails.stub(:cache, cache) do
      cache.write("mau:#{@instance.id}:2026-05", 9)
      cache.write("mau:ch:#{@instance.id}:2026-05", 9)
      cache.write("mau:ch:#{@instance.id}:2026-06", 9)
      cache.write("mau:ch:#{@instance.id}:2026-07", 9) # untouched month

      ProjectService.bust_mau_cache(@project.id, %w[202605 202606])

      assert_nil cache.read("mau:#{@instance.id}:2026-05")
      assert_nil cache.read("mau:ch:#{@instance.id}:2026-05")
      assert_nil cache.read("mau:ch:#{@instance.id}:2026-06")
      assert_equal 9, cache.read("mau:ch:#{@instance.id}:2026-07")
    end
  end

  test "bust_mau_cache is a safe no-op for unknown projects or empty partitions" do
    assert_nothing_raised do
      ProjectService.bust_mau_cache(-1, %w[202605])
      ProjectService.bust_mau_cache(@project.id, [])
      ProjectService.bust_mau_cache(@project.id, nil)
    end
  end

  private

  def with_primary_mode
    prev = Rails.application.config.clickhouse_primary
    Rails.application.config.clickhouse_primary = true
    yield
  ensure
    Rails.application.config.clickhouse_primary = prev
  end
end
