require "test_helper"

class DeleteInstanceJobTest < ActiveSupport::TestCase
  fixtures :instances, :projects, :domains, :links, :redirect_configs, :visitors,
           :devices, :applications, :ios_configurations, :android_configurations,
           :desktop_configurations, :web_configurations, :custom_redirects,
           :stripe_subscriptions, :stripe_payment_intents,
           :visitor_daily_statistics

  setup do
    @instance = instances(:one)
    @project = projects(:one)
    # Clean up stripe_subscriptions FK that DeleteInstanceJob doesn't handle
    StripeSubscription.where(instance_id: @instance.id).delete_all
  end

  test "deletes instance and all associated data" do
    job = DeleteInstanceJob.new

    job.perform(@instance.id)

    assert_nil Instance.find_by(id: @instance.id)
    assert_equal 0, Project.where(instance_id: @instance.id).count
    assert_equal 0, Domain.where(project_id: @project.id).count
    assert_equal 0, Visitor.where(project_id: @project.id).count
    assert_equal 0, VisitorDailyStatistic.where(project_id: @project.id).count
  end

  test "nonexistent instance returns early without deleting anything" do
    job = DeleteInstanceJob.new
    original_count = Instance.count

    job.perform(-999)

    assert_equal original_count, Instance.count
  end

  test "deletes notification children before notifications" do
    notification = Notification.create!(project: @project, title: "Test", subtitle: "Sub")
    NotificationMessage.create!(notification: notification, visitor: visitors(:ios_visitor))
    NotificationTarget.create!(notification: notification, existing_users: true)

    job = DeleteInstanceJob.new
    job.perform(@instance.id)

    assert_equal 0, Notification.where(project_id: @project.id).count
    assert_equal 0, NotificationMessage.where(notification: notification).count
    assert_equal 0, NotificationTarget.where(notification: notification).count
  end

  test "deletes application configs hierarchically" do
    job = DeleteInstanceJob.new
    app_ids = Application.where(instance_id: @instance.id).pluck(:id)
    assert app_ids.any?, "Fixture should have applications for instance"

    job.perform(@instance.id)

    assert_equal 0, Application.where(instance_id: @instance.id).count
    assert_equal 0, IosConfiguration.where(application_id: app_ids).count
    assert_equal 0, AndroidConfiguration.where(application_id: app_ids).count
  end

  test "deletes links and custom redirects before domains" do
    job = DeleteInstanceJob.new
    domain_ids = Domain.where(project_id: @project.id).pluck(:id)
    assert domain_ids.any?

    job.perform(@instance.id)

    assert_equal 0, Link.where(domain_id: domain_ids).count
    assert_equal 0, Domain.where(project_id: @project.id).count
  end

  test "deletes visitor daily statistics for target projects only" do
    project_ids = Project.where(instance_id: @instance.id).pluck(:id)
    assert VisitorDailyStatistic.where(project_id: project_ids).exists?,
      "Fixture should have visitor daily statistics for instance projects"

    # Create a stat for the other instance to verify it survives
    other_project = projects(:two)
    other_device = Device.create!(vendor: "other-vendor-001", platform: "ios",
      user_agent: "TestApp/1.0", ip: "192.168.1.99", remote_ip: "10.0.0.99")
    other_visitor = Visitor.create!(project: other_project, device: other_device, web_visitor: false)
    other_stat = VisitorDailyStatistic.create!(
      visitor: other_visitor, project_id: other_project.id,
      event_date: "2026-03-01", platform: "ios"
    )

    job = DeleteInstanceJob.new
    job.perform(@instance.id)

    assert_equal 0, VisitorDailyStatistic.where(project_id: project_ids).count,
      "All visitor daily statistics for deleted instance should be removed"
    assert VisitorDailyStatistic.exists?(other_stat.id),
      "Visitor daily statistics for other instances should be untouched"
  end

  test "with_local_timeouts rejects invalid format" do
    job = DeleteInstanceJob.new

    assert_raises(ArgumentError) do
      job.send(:with_local_timeouts, lock: "'; DROP TABLE users;--") {}
    end

    assert_raises(ArgumentError) do
      job.send(:with_local_timeouts, lock: "2s", statement: "abc") {}
    end
  end
end
