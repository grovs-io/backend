require "test_helper"

class ProjectDailyActiveUserTest < ActiveSupport::TestCase
  fixtures :instances, :projects

  # === validations ===

  test "valid with project_id and event_date" do
    record = ProjectDailyActiveUser.new(
      project: projects(:one),
      event_date: Date.today,
      active_users: 10,
      platform: "web"
    )
    assert record.valid?
  end

  test "invalid without project_id" do
    record = ProjectDailyActiveUser.new(
      event_date: Date.today,
      active_users: 5
    )
    assert_not record.valid?
    assert_includes record.errors[:project_id], "can't be blank"
  end

  test "invalid without event_date" do
    record = ProjectDailyActiveUser.new(
      project: projects(:one),
      active_users: 5
    )
    assert_not record.valid?
    assert_includes record.errors[:event_date], "can't be blank"
  end

  test "enforces unique constraint on project_id, event_date, and platform" do
    ProjectDailyActiveUser.create!(
      project: projects(:one),
      event_date: Date.new(2026, 1, 1),
      active_users: 10,
      platform: "ios"
    )

    duplicate = ProjectDailyActiveUser.new(
      project: projects(:one),
      event_date: Date.new(2026, 1, 1),
      active_users: 20,
      platform: "ios"
    )

    assert_raises(ActiveRecord::RecordNotUnique) { duplicate.save! }
  end

  test "allows same project and date with different platforms" do
    record1 = ProjectDailyActiveUser.create!(
      project: projects(:one),
      event_date: Date.new(2026, 2, 1),
      active_users: 10,
      platform: "ios"
    )

    record2 = ProjectDailyActiveUser.create!(
      project: projects(:one),
      event_date: Date.new(2026, 2, 1),
      active_users: 20,
      platform: "android"
    )

    assert record1.persisted?
    assert record2.persisted?
  end
end
