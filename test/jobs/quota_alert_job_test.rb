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
