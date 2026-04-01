require "test_helper"

class NotificationServiceTest < ActiveSupport::TestCase
  fixtures :instances, :projects

  setup do
    @project = projects(:one)
    # Clean slate for notification tests
    Notification.where(project: @project).destroy_all
  end

  def build_service
    NotificationService.new(project: @project)
  end

  # === create ===

  test "create creates notification with target and enqueues job" do
    job_called_with = nil
    SendMessagesJob.stub(:perform_async, ->(id) { job_called_with = id }) do
      notification = build_service.create(
        notification_attrs: { title: "Hello", subtitle: "World" },
        target_attrs: { new_users: true }
      )

      assert notification.persisted?
      assert_equal "Hello", notification.title
      assert_equal "World", notification.subtitle
      assert_equal @project.id, notification.project_id

      assert notification.notification_target.persisted?
      assert notification.notification_target.new_users
      assert_equal notification.id, job_called_with, "SendMessagesJob should be called with notification ID"
    end
  end

  test "create wraps notification and target in transaction" do
    # Both notification and target should be saved or neither
    SendMessagesJob.stub(:perform_async, ->(_id) {}) do
      notification = build_service.create(
        notification_attrs: { title: "TX Test" },
        target_attrs: { new_users: true, existing_users: false, platforms: ["ios"] }
      )

      assert notification.persisted?
      target = notification.notification_target
      assert target.persisted?
      assert target.new_users
      assert_not target.existing_users
      assert_includes target.platforms, "ios"
    end
  end

  # === list ===

  test "list returns paginated results with read_count" do
    3.times do |i|
      Notification.create!(title: "Notif #{i}", project: @project, archived: false).tap do |n|
        NotificationTarget.create!(notification: n, new_users: true)
      end
    end

    notifications = build_service.list(archived: false, page: 1)
    assert notifications.respond_to?(:total_pages)
    assert_equal 3, notifications.to_a.size
    # Verify read_count is available (from SQL subquery)
    assert notifications.first.respond_to?(:read_count)
  end

  test "list filters archived vs active" do
    Notification.create!(title: "Active", project: @project, archived: false).tap do |n|
      NotificationTarget.create!(notification: n, new_users: true)
    end
    Notification.create!(title: "Archived", project: @project, archived: true).tap do |n|
      NotificationTarget.create!(notification: n, new_users: true)
    end

    active = build_service.list(archived: false, page: 1)
    archived = build_service.list(archived: true, page: 1)

    assert active.to_a.all? { |n| !n.archived }, "Active list should not contain archived notifications"
    assert archived.to_a.all?(&:archived), "Archived list should only contain archived notifications"
  end

  test "list filters by for_new_users" do
    Notification.create!(title: "New Users", project: @project, archived: false).tap do |n|
      NotificationTarget.create!(notification: n, new_users: true, existing_users: false)
    end
    Notification.create!(title: "Existing Users", project: @project, archived: false).tap do |n|
      NotificationTarget.create!(notification: n, new_users: false, existing_users: true)
    end

    new_only = build_service.list(archived: false, for_new_users: true, page: 1)
    assert_equal 1, new_only.to_a.size
    assert new_only.to_a.all? { |n| n.notification_target.new_users }

    existing_only = build_service.list(archived: false, for_new_users: false, page: 1)
    assert_equal 1, existing_only.to_a.size
  end

  test "list search is case-insensitive" do
    Notification.create!(title: "UPPERCASE Test", project: @project, archived: false).tap do |n|
      NotificationTarget.create!(notification: n, new_users: true)
    end
    Notification.create!(title: "Other", project: @project, archived: false).tap do |n|
      NotificationTarget.create!(notification: n, new_users: true)
    end

    results = build_service.list(archived: false, search_term: "uppercase", page: 1)
    assert_equal 1, results.to_a.size
    assert_equal "UPPERCASE Test", results.first.title
  end

  test "list searches subtitle too" do
    Notification.create!(title: "Title", subtitle: "findme here", project: @project, archived: false).tap do |n|
      NotificationTarget.create!(notification: n, new_users: true)
    end

    results = build_service.list(archived: false, search_term: "findme", page: 1)
    assert_equal 1, results.to_a.size
  end

  test "list respects per_page" do
    5.times do |i|
      Notification.create!(title: "Page #{i}", project: @project, archived: false).tap do |n|
        NotificationTarget.create!(notification: n, new_users: true)
      end
    end

    results = build_service.list(archived: false, page: 1, per_page: 2)
    assert_equal 2, results.to_a.size
    assert_equal 3, results.total_pages
  end

  test "list orders by updated_at descending" do
    old = Notification.create!(title: "Old", project: @project, archived: false, updated_at: 2.days.ago).tap do |n|
      NotificationTarget.create!(notification: n, new_users: true)
    end
    recent = Notification.create!(title: "Recent", project: @project, archived: false).tap do |n|
      NotificationTarget.create!(notification: n, new_users: true)
    end

    results = build_service.list(archived: false, page: 1)
    assert_equal "Recent", results.first.title
  end

  # === archive ===

  test "archive sets archived flag and persists" do
    notification = Notification.create!(title: "To Archive", project: @project)
    NotificationTarget.create!(notification: notification, new_users: true)

    archived = build_service.archive(notification: notification)
    assert archived.archived
    assert notification.reload.archived, "Archived flag should be persisted to DB"
  end

  test "archive raises for existing_users notification" do
    notification = Notification.create!(title: "Existing Users", project: @project)
    NotificationTarget.create!(notification: notification, existing_users: true)

    error = assert_raises(ArgumentError) do
      build_service.archive(notification: notification)
    end
    assert_match(/existing users/, error.message)
  end

  test "archive does not change archived state on error" do
    notification = Notification.create!(title: "No Change", project: @project)
    NotificationTarget.create!(notification: notification, existing_users: true)

    assert_raises(ArgumentError) { build_service.archive(notification: notification) }
    assert_not notification.reload.archived, "Should not be archived after error"
  end
end
