require "test_helper"

class DisableQuotasJobTest < ActiveSupport::TestCase
  fixtures :instances, :projects, :users, :instance_roles, :stripe_subscriptions, :stripe_payment_intents, :devices, :visitors

  setup do
    @job = DisableQuotasJob.new
    @instance = instances(:one)
    @instance.stripe_subscriptions.destroy_all

    # Ensure instance has both production and test projects for ProjectService
    unless @instance.test
      Project.create!(name: "Quota Test (test)", identifier: "quota-test-#{SecureRandom.hex(4)}", instance: @instance, test: true)
    end
    @instance.reload

    # Clean any pre-existing VDS records for this instance's projects
    project_ids = [@instance.production.id, @instance.test.id]
    VisitorDailyStatistic.where(project_id: project_ids).delete_all

    @saved_env = {
      'FREE_MAU_COUNT' => ENV['FREE_MAU_COUNT'],
      'FREE_PASS_PROJECT_IDS' => ENV['FREE_PASS_PROJECT_IDS'],
      'PUBLIC_GO_PROJECT_IDENTIFIER_ID' => ENV['PUBLIC_GO_PROJECT_IDENTIFIER_ID']
    }
    ENV['FREE_MAU_COUNT'] = '10'
    ENV['FREE_PASS_PROJECT_IDS'] = ''
    ENV['PUBLIC_GO_PROJECT_IDENTIFIER_ID'] = '0'
  end

  teardown do
    @saved_env.each { |k, v| ENV[k] = v }
  end

  test "runs when FREE_PASS_PROJECT_IDS is unset" do
    ENV.delete('FREE_PASS_PROJECT_IDS')

    StripeService.stub(:set_usage, ->(_inst) { nil }) do
      QuotaAlertJob.stub(:perform_async, ->(_id) { nil }) do
        assert_nothing_raised { @job.perform }
      end
    end
  end

  # --- Real MAU computation via VisitorDailyStatistic ---

  test "sets quota_exceeded true when real MAU exceeds free limit" do
    create_visitors_with_stats(@instance.production, 11)

    StripeService.stub(:set_usage, ->(_inst) { nil }) do
      QuotaAlertJob.stub(:perform_async, ->(_id) { nil }) do
        @job.perform
      end
    end

    @instance.reload
    assert @instance.quota_exceeded?, "Should set quota_exceeded when real MAU (11) > free limit (10)"
  end

  test "sets quota_exceeded false when real MAU is under free limit" do
    @instance.update!(quota_exceeded: true)
    create_visitors_with_stats(@instance.production, 3)

    StripeService.stub(:set_usage, ->(_inst) { nil }) do
      QuotaAlertJob.stub(:perform_async, ->(_id) { nil }) do
        @job.perform
      end
    end

    @instance.reload
    assert_not @instance.quota_exceeded?, "Should clear quota_exceeded when real MAU (3) < free limit (10)"
  end

  test "exactly at free limit does NOT set quota_exceeded (> not >=)" do
    @instance.update!(quota_exceeded: false)
    create_visitors_with_stats(@instance.production, 10)

    StripeService.stub(:set_usage, ->(_inst) { nil }) do
      QuotaAlertJob.stub(:perform_async, ->(_id) { nil }) do
        @job.perform
      end
    end

    @instance.reload
    assert_not @instance.quota_exceeded?, "Should NOT set quota_exceeded at exactly the limit (> not >=)"
  end

  # --- Enterprise subscription ---

  test "clears quota_exceeded when enterprise subscription exists" do
    @instance.update!(quota_exceeded: true)
    enterprise = EnterpriseSubscription.create!(
      instance: @instance, active: true, total_maus: 50000,
      start_date: 1.month.ago, end_date: 1.month.from_now
    )

    StripeService.stub(:set_usage, ->(_inst) { nil }) do
      QuotaAlertJob.stub(:perform_async, ->(_id) { nil }) do
        @job.perform
      end
    end

    @instance.reload
    assert_not @instance.quota_exceeded?, "Enterprise subscription should clear quota"
  ensure
    enterprise&.destroy
  end

  # --- Stripe subscription skips quota check ---

  test "skips quota check when active Stripe subscription exists" do
    @instance.update!(quota_exceeded: true)
    pi = stripe_payment_intents(:one)
    StripeSubscription.create!(
      instance: @instance, active: true, subscription_id: "sub_quota_#{SecureRandom.hex(4)}",
      customer_id: "cus_quota_test", status: "active", stripe_payment_intent: pi
    )

    # Even with huge MAU, quota should not be touched
    create_visitors_with_stats(@instance.production, 50)

    StripeService.stub(:set_usage, ->(_inst) { nil }) do
      QuotaAlertJob.stub(:perform_async, ->(_id) { nil }) do
        @job.perform
      end
    end

    @instance.reload
    assert @instance.quota_exceeded?, "Should NOT modify quota when Stripe subscription active"
  end

  # --- Free pass ---

  test "skips instances in free pass list" do
    ENV['FREE_PASS_PROJECT_IDS'] = @instance.id.to_s
    @instance.update!(quota_exceeded: false)
    create_visitors_with_stats(@instance.production, 50)

    StripeService.stub(:set_usage, ->(_inst) { nil }) do
      QuotaAlertJob.stub(:perform_async, ->(_id) { nil }) do
        @job.perform
      end
    end

    @instance.reload
    assert_not @instance.quota_exceeded?, "Free pass instance should never get quota_exceeded"
  end

  # --- StripeService called ---

  # Enforcement runs first, so a Stripe outage cannot skip a whole 30-minute cycle.
  test "a Stripe failure does not suppress quota enforcement" do
    @instance.update!(quota_exceeded: false)
    create_visitors_with_stats(@instance.production, 11)

    StripeService.stub(:set_usage, ->(_inst) { raise ActiveRecord::StatementInvalid, "boom" }) do
      QuotaAlertJob.stub(:perform_async, ->(_id) { nil }) do
        assert_raises(ActiveRecord::StatementInvalid) { @job.perform }
      end
    end

    @instance.reload
    assert @instance.quota_exceeded?, "quota enforcement must complete before the Stripe push"
  end

  test "calls StripeService.set_usage for each instance" do
    called_instance_ids = []

    StripeService.stub(:set_usage, ->(inst) { called_instance_ids << inst.id }) do
      QuotaAlertJob.stub(:perform_async, ->(_id) { nil }) do
        @job.perform
      end
    end

    assert_includes called_instance_ids, @instance.id
  end

  # --- Error isolation in disable_quotas loop ---

  test "continues processing other instances when one raises in disable_quotas" do
    # Start with quota_exceeded = true. The job should set it to false
    # (MAU = 0, under free limit of 10) via save! BEFORE QuotaAlertJob.perform_async
    # raises. The per-instance rescue should catch the error and continue.
    @instance.update!(quota_exceeded: true)

    StripeService.stub(:set_usage, ->(_inst) { nil }) do
      QuotaAlertJob.stub(:perform_async, lambda { |id|
        raise "boom" if id == @instance.id
      }) do
        @job.perform # Should NOT raise despite one instance erroring
      end
    end

    # The instance's quota_exceeded was saved to false BEFORE QuotaAlertJob raised.
    # If the rescue didn't work, the job would have raised and we'd never get here.
    @instance.reload
    assert_not @instance.quota_exceeded?,
      "Instance state should persist (quota_exceeded=false) even though QuotaAlertJob raised after save"
  end

  # --- Self-hosted mode ---

  test "self-hosted mode skips the entire job: no Stripe call, no quota change" do
    @instance.update!(quota_exceeded: true)
    create_visitors_with_stats(@instance.production, 50) # would normally be evaluated
    touched = false

    ENV["GROVS_SELF_HOSTED"] = "true"
    StripeService.stub(:set_usage, ->(_inst) { touched = true }) do
      QuotaAlertJob.stub(:perform_async, ->(_id) { touched = true }) do
        @job.perform
      end
    end

    assert_not touched, "self-hosted must not call Stripe or enqueue quota alerts"
    @instance.reload
    assert @instance.quota_exceeded?, "self-hosted must not modify quota_exceeded"
  ensure
    ENV.delete("GROVS_SELF_HOSTED")
  end

  # --- CH-primary MAU failure (caller-shaped degradation) ---

  test "primary-mode CH MAU failure skips the instance without touching quota_exceeded" do
    @instance.update!(quota_exceeded: true)
    failing_ids = [@instance.production.id, @instance.test.id]
    alerted = []

    with_primary_mode do
      # Fail only this instance's read; others (if any compute) still succeed.
      ch_stub = ->(project_ids, **_k) { (project_ids & failing_ids).any? ? nil : 3 }
      ClickhouseReadService.stub(:billing_active_visitors_exact, ch_stub) do
        ClickhouseReadService.stub(:billing_active_visitors, ch_stub) do
          StripeService.stub(:set_usage, ->(_inst) { nil }) do
            QuotaAlertJob.stub(:perform_async, ->(id) { alerted << id }) do
              @job.perform # must not raise
            end
          end
        end
      end
    end

    @instance.reload
    assert @instance.quota_exceeded?, "quota_exceeded must stay untouched on a failed CH MAU read"
    assert_not_includes alerted, @instance.id, "no quota alert from a failed read"
  end

  test "a MAU failure for one instance does not abort sending usage for the rest" do
    attempted = []

    StripeService.stub(:set_usage, lambda { |inst|
      attempted << inst.id
      raise ProjectService::MauReadUnavailable, "CH down" if inst.id == @instance.id
    }) do
      @job.send_quotas_to_stripe # must not raise
    end

    assert_includes attempted, @instance.id
    assert_operator attempted.size, :>, 1, "later instances must still get usage attempts"
  end

  private

  def with_primary_mode
    prev = Rails.application.config.clickhouse_primary
    Rails.application.config.clickhouse_primary = true
    yield
  ensure
    Rails.application.config.clickhouse_primary = prev
  end

  def create_visitors_with_stats(project, count)
    count.times do
      dev = Device.create!(
        user_agent: "QuotaBot/#{SecureRandom.hex(3)}",
        ip: "172.#{rand(16..31)}.#{rand(256)}.#{rand(256)}",
        remote_ip: "172.#{rand(16..31)}.#{rand(256)}.#{rand(256)}",
        platform: "ios"
      )
      vis = Visitor.create!(device: dev, project: project)
      VisitorDailyStatistic.create!(
        visitor_id: vis.id,
        project_id: project.id,
        event_date: Date.today,
        platform: "ios",
        views: 1
      )
    end
  end
end
