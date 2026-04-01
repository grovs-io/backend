require "test_helper"

class BackfillProjectDailyActiveUsersJobTest < ActiveSupport::TestCase
  fixtures :instances, :projects, :devices, :visitors

  setup do
    @job = BackfillProjectDailyActiveUsersJob.new
    @project = projects(:one)
  end

  test "generates ProjectDailyActiveUser records from real visitor stats" do
    VisitorDailyStatistic.create!(
      visitor: visitors(:ios_visitor), project_id: @project.id,
      event_date: Date.today, platform: "ios",
      views: 5
    )

    @job.perform

    pdau = ProjectDailyActiveUser.find_by(project_id: @project.id, event_date: Date.today, platform: "ios")
    assert_not_nil pdau, "Should generate ProjectDailyActiveUser record"
    assert_equal 1, pdau.active_users, "One visitor with stats = 1 active user"
  end

  test "counts multiple visitors per platform correctly" do
    # Create 3 distinct visitors on iOS for today
    3.times do
      dev = Device.create!(
        user_agent: "DAUBot/#{SecureRandom.hex(3)}",
        ip: "172.#{rand(16..31)}.#{rand(256)}.#{rand(256)}",
        remote_ip: "172.#{rand(16..31)}.#{rand(256)}.#{rand(256)}",
        platform: "ios"
      )
      vis = Visitor.create!(device: dev, project: @project)
      VisitorDailyStatistic.create!(
        visitor_id: vis.id, project_id: @project.id,
        event_date: Date.today, platform: "ios",
        views: 1
      )
    end

    @job.perform

    pdau = ProjectDailyActiveUser.find_by(project_id: @project.id, event_date: Date.today, platform: "ios")
    assert_not_nil pdau
    assert_equal 3, pdau.active_users, "Three distinct visitors = 3 active users"
  end

  test "generates separate records per platform" do
    VisitorDailyStatistic.create!(
      visitor: visitors(:ios_visitor), project_id: @project.id,
      event_date: Date.today, platform: "ios", views: 1
    )
    VisitorDailyStatistic.create!(
      visitor: visitors(:android_visitor), project_id: @project.id,
      event_date: Date.today, platform: "android", views: 1
    )

    @job.perform

    ios_pdau = ProjectDailyActiveUser.find_by(project_id: @project.id, event_date: Date.today, platform: "ios")
    android_pdau = ProjectDailyActiveUser.find_by(project_id: @project.id, event_date: Date.today, platform: "android")
    assert_not_nil ios_pdau, "Should have iOS record"
    assert_not_nil android_pdau, "Should have Android record"
  end
end
