require "test_helper"

class QuotaAlertJobTest < ActiveSupport::TestCase
  fixtures :instances, :projects, :users, :instance_roles, :stripe_subscriptions, :stripe_payment_intents, :devices, :visitors

  setup do
    @job = QuotaAlertJob.new
    @instance = instances(:one)
    @instance.stripe_subscriptions.destroy_all

    # Ensure instance has both production and test projects for ProjectService
    unless @instance.test
      Project.create!(name: "Alert Test (test)", identifier: "alert-test-#{SecureRandom.hex(4)}", instance: @instance, test: true)
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
    # Use small limits so tests are fast
    ENV['FREE_MAU_COUNT'] = '100'
    ENV['FREE_PASS_PROJECT_IDS'] = ''
    ENV['PUBLIC_GO_PROJECT_IDENTIFIER_ID'] = '0'
    @instance.update!(last_quota_exceeded_sent_at: nil, last_quota_warning_sent_at: nil)
  end

  teardown do
    @saved_env.each { |k, v| ENV[k] = v }
  end

  # --- Exceeded alerts with real MAU ---

  test "sends quota_exceeded email when real MAU exceeds limit" do
    # 150 visitors / 100 limit = 150%
    create_visitors_with_stats(@instance.production, 150)

    emails_sent = []
    mail_mock = OpenStruct.new(deliver_now: true)

    QuotaMailer.stub(:quota_exceeded, lambda { |*args| 
      emails_sent << args
      mail_mock
    }) do
      @job.perform(@instance.id)
    end

    @instance.reload
    assert @instance.last_quota_exceeded_sent_at.present?, "Should record exceeded timestamp"
    assert_not emails_sent.empty?, "Should send exceeded email"
    assert_equal 150, emails_sent.first[1], "Usage percentage should reflect real MAU (150%)"
    assert_equal 150, emails_sent.first[2], "Current MAUs should be real count"
    assert_equal 100, emails_sent.first[3], "Plan MAUs should be the free limit"
  end

  test "does not re-send exceeded email within 3 days" do
    @instance.update!(last_quota_exceeded_sent_at: 1.day.ago)
    create_visitors_with_stats(@instance.production, 200)

    exceeded_called = false
    QuotaMailer.stub(:quota_exceeded, lambda { |*_args|
      exceeded_called = true
      OpenStruct.new(deliver_now: true)
    }) do
      @job.perform(@instance.id)
    end

    assert_not exceeded_called, "Should NOT re-send within 3 days"
  end

  test "re-sends exceeded email after 3 days have passed" do
    @instance.update!(last_quota_exceeded_sent_at: 4.days.ago)
    create_visitors_with_stats(@instance.production, 200)

    exceeded_called = false
    QuotaMailer.stub(:quota_exceeded, lambda { |*_args|
      exceeded_called = true
      OpenStruct.new(deliver_now: true)
    }) do
      @job.perform(@instance.id)
    end

    assert exceeded_called, "Should re-send after 3 days"
  end

  # --- Progress alerts with real MAU ---

  test "sends quota_progress email at 85% real usage" do
    # 85 visitors / 100 limit = 85%
    create_visitors_with_stats(@instance.production, 85)

    progress_args = []
    mail_mock = OpenStruct.new(deliver_now: true)

    QuotaMailer.stub(:quota_progress, lambda { |*args| 
      progress_args << args
      mail_mock
    }) do
      @job.perform(@instance.id)
    end

    @instance.reload
    assert_not progress_args.empty?, "Should send progress email at 85%"
    assert_equal 85, progress_args.first[1], "Usage percentage should be 85"
    assert @instance.last_quota_warning_sent_at.present?, "Should record warning timestamp"
  end

  test "does not send any email at 84% — below threshold" do
    # 84 visitors / 100 limit = 84%
    create_visitors_with_stats(@instance.production, 84)

    progress_called = false
    exceeded_called = false

    QuotaMailer.stub(:quota_progress, lambda { |*_args| 
      progress_called = true
      OpenStruct.new(deliver_now: true)
    }) do
      QuotaMailer.stub(:quota_exceeded, lambda { |*_args| 
        exceeded_called = true
        OpenStruct.new(deliver_now: true)
      }) do
        @job.perform(@instance.id)
      end
    end

    assert_not progress_called, "Should NOT send progress at 84%"
    assert_not exceeded_called, "Should NOT send exceeded at 84%"
  end

  test "does not re-send progress email within 3 days" do
    @instance.update!(last_quota_warning_sent_at: 1.day.ago)
    create_visitors_with_stats(@instance.production, 90)

    progress_called = false
    QuotaMailer.stub(:quota_progress, lambda { |*_args|
      progress_called = true
      OpenStruct.new(deliver_now: true)
    }) do
      @job.perform(@instance.id)
    end

    assert_not progress_called, "Should NOT re-send warning within 3 days"
  end

  # --- Boundary tests ---

  test "sends exceeded at 101 real MAU (just over 100 limit)" do
    create_visitors_with_stats(@instance.production, 101)

    exceeded_called = false
    QuotaMailer.stub(:quota_exceeded, lambda { |*_args| 
      exceeded_called = true
      OpenStruct.new(deliver_now: true)
    }) do
      @job.perform(@instance.id)
    end

    assert exceeded_called, "Should send exceeded at 101 (just over)"
  end

  test "does not send exceeded at exactly 100 real MAU" do
    create_visitors_with_stats(@instance.production, 100)

    exceeded_called = false
    QuotaMailer.stub(:quota_exceeded, lambda { |*_args| 
      exceeded_called = true
      OpenStruct.new(deliver_now: true)
    }) do
      @job.perform(@instance.id)
    end

    assert_not exceeded_called, "Should NOT send exceeded at exactly the limit"
  end

  # --- Skip conditions ---

  test "skips alerts for free-pass instance" do
    ENV['FREE_PASS_PROJECT_IDS'] = @instance.id.to_s
    create_visitors_with_stats(@instance.production, 200)

    exceeded_called = false
    progress_called = false

    QuotaMailer.stub(:quota_exceeded, lambda { |*_| 
      exceeded_called = true
      OpenStruct.new(deliver_now: true)
    }) do
      QuotaMailer.stub(:quota_progress, lambda { |*_| 
        progress_called = true
        OpenStruct.new(deliver_now: true)
      }) do
        @job.perform(@instance.id)
      end
    end

    assert_not exceeded_called, "Free-pass should skip exceeded"
    assert_not progress_called, "Free-pass should skip progress"
  end

  test "skips alerts when instance has active Stripe subscription" do
    pi = stripe_payment_intents(:one)
    StripeSubscription.create!(
      instance: @instance, active: true, subscription_id: "sub_alert_#{SecureRandom.hex(4)}",
      customer_id: "cus_alert_test", status: "active", stripe_payment_intent: pi
    )
    create_visitors_with_stats(@instance.production, 200)

    exceeded_called = false
    progress_called = false

    QuotaMailer.stub(:quota_exceeded, lambda { |*_| 
      exceeded_called = true
      OpenStruct.new(deliver_now: true)
    }) do
      QuotaMailer.stub(:quota_progress, lambda { |*_| 
        progress_called = true
        OpenStruct.new(deliver_now: true)
      }) do
        @job.perform(@instance.id)
      end
    end

    assert_not exceeded_called, "Should NOT send exceeded when subscription active"
    assert_not progress_called, "Should NOT send progress when subscription active"
  end

  test "returns early for nonexistent instance" do
    result = @job.perform(999999)
    assert_nil result
  end

  # --- Sends to all instance users ---

  test "sends email to each user on the instance" do
    create_visitors_with_stats(@instance.production, 200)

    emailed_users = []
    mail_mock = OpenStruct.new(deliver_now: true)

    QuotaMailer.stub(:quota_exceeded, lambda { |user, *_rest|
      emailed_users << user.id
      mail_mock
    }) do
      @job.perform(@instance.id)
    end

    # Instance :one has admin_user and member_user via instance_roles fixture
    assert_includes emailed_users, users(:admin_user).id, "Should email admin user"
    assert_includes emailed_users, users(:member_user).id, "Should email member user"
  end

  # --- Self-hosted mode ---

  test "self-hosted mode sends no quota emails and exits early" do
    create_visitors_with_stats(@instance.production, 200) # would normally trigger an exceeded email

    sent = false
    ENV["GROVS_SELF_HOSTED"] = "true"
    QuotaMailer.stub(:quota_exceeded, lambda { |*_| 
      sent = true
      OpenStruct.new(deliver_now: true)
    }) do
      QuotaMailer.stub(:quota_progress, lambda { |*_| 
        sent = true
        OpenStruct.new(deliver_now: true)
      }) do
        @job.perform(@instance.id)
      end
    end

    assert_not sent, "self-hosted must not send any quota emails"
  ensure
    ENV.delete("GROVS_SELF_HOSTED")
  end

  # --- CH-primary MAU failure ---

  test "primary-mode CH MAU failure skips the alert without email or timestamp" do
    sent = false
    prev = Rails.application.config.clickhouse_primary
    Rails.application.config.clickhouse_primary = true

    mark_sent = lambda do |*_|
      sent = true
      OpenStruct.new(deliver_now: true)
    end

    ClickhouseReadService.stub(:billing_active_visitors_exact, ->(*_a, **_k) { nil }) do
      QuotaMailer.stub(:quota_exceeded, mark_sent) do
        QuotaMailer.stub(:quota_progress, mark_sent) do
          @job.perform(@instance.id) # must not raise
        end
      end
    end

    assert_not sent, "no quota email from a failed CH MAU read"
    @instance.reload
    assert_nil @instance.last_quota_exceeded_sent_at
    assert_nil @instance.last_quota_warning_sent_at
  ensure
    Rails.application.config.clickhouse_primary = prev
  end

  def subscribe_flat!(product_type: "growth_250k", active: true, status: "active")
    intent = StripePaymentIntent.create!(instance: @instance, user: users(:admin_user), intent_id: "cs_#{SecureRandom.hex(4)}", product_type: product_type)
    StripeSubscription.create!(instance: @instance, stripe_payment_intent: intent, subscription_id: "sub_#{SecureRandom.hex(4)}",
                               customer_id: "cus_b", active: active, status: status, product_type: product_type)
  end

  def capture_band_mail(kind, &block)
    sent = []
    stub_mail = lambda do |*args|
      sent << args
      OpenStruct.new(deliver_now: true)
    end
    QuotaMailer.stub(kind, stub_mail, &block)
    sent
  end

  test "flat plan over its band emails users and the owner, without blocking" do
    subscribe_flat!
    Billing::Plans.stub(:mau_cap, 100) do
      create_visitors_with_stats(@instance.production, 150)
      sent = capture_band_mail(:band_exceeded) { @job.perform(@instance.id) }
      recipients = sent.map(&:first)
      assert_includes recipients, ENV["BILLING_ALERT_EMAIL"]
      @instance.users.each { |u| assert_includes recipients, u.email }
      assert_equal [150, 150, 100], sent.first[1..3]
    end
    @instance.reload
    assert @instance.last_quota_exceeded_sent_at.present?
    assert_not @instance.quota_exceeded
  end

  test "flat plan at 85% of its band sends band_progress" do
    subscribe_flat!
    Billing::Plans.stub(:mau_cap, 100) do
      create_visitors_with_stats(@instance.production, 85)
      sent = capture_band_mail(:band_progress) { @job.perform(@instance.id) }
      assert_not sent.empty?
    end
  end

  test "flat band emails are throttled for 3 days" do
    subscribe_flat!
    @instance.update!(last_quota_exceeded_sent_at: 1.day.ago)
    Billing::Plans.stub(:mau_cap, 100) do
      create_visitors_with_stats(@instance.production, 150)
      sent = capture_band_mail(:band_exceeded) { @job.perform(@instance.id) }
      assert_empty sent
    end
  end

  test "no band email for legacy scale_up, paused flat, or enterprise" do
    create_visitors_with_stats(@instance.production, 150)
    subscribe_flat!(product_type: "scale_up")
    assert_empty capture_band_mail(:band_exceeded) { @job.perform(@instance.id) }

    @instance.stripe_subscriptions.destroy_all
    subscribe_flat!(active: false, status: "paused")
    Billing::Plans.stub(:mau_cap, 100) do
      assert_empty capture_band_mail(:band_exceeded) { @job.perform(@instance.id) }
    end

    @instance.stripe_subscriptions.destroy_all
    EnterpriseSubscription.create!(instance: @instance, active: true, total_maus: 100,
                                    start_date: 1.month.ago, end_date: 1.month.from_now)
    assert_empty capture_band_mail(:band_exceeded) { @job.perform(@instance.id) }
  end

  private

  def create_visitors_with_stats(project, count)
    count.times do
      dev = Device.create!(
        user_agent: "AlertBot/#{SecureRandom.hex(3)}",
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
