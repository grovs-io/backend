require "test_helper"

class NotificationTest < ActiveSupport::TestCase
  fixtures :instances, :projects, :domains

  # === access_url ===

  test "access_url returns nil when project has no domain" do
    # Create a fresh project without a domain
    project = Project.create!(name: "No Domain Project", identifier: "no-domain-#{SecureRandom.hex(4)}", instance: instances(:one))
    notification = Notification.create!(title: "Test", project: project)

    assert_nil notification.access_url
  end

  test "access_url builds URL from project domain and hashid" do
    project = projects(:one)
    notification = Notification.create!(title: "Test Notification", project: project)

    url = notification.access_url
    if project.domain_for_project&.full_domain
      assert_includes url, notification.hashid
      assert_includes url, "/mm/"
    else
      assert_nil url
    end
  end

  # === serialization ===

  test "serializer excludes created_at and project_id" do
    project = projects(:one)
    notification = Notification.create!(title: "JSON Test", project: project)
    json = NotificationSerializer.serialize(notification)

    assert_not json.key?("created_at")
    assert_not json.key?("project_id")
  end

  test "serializer includes target and access_url keys" do
    project = projects(:one)
    notification = Notification.create!(title: "JSON Test", project: project)
    json = NotificationSerializer.serialize(notification)

    assert json.key?("target")
    assert json.key?("access_url")
  end

  test "serializer includes title and other attributes" do
    project = projects(:one)
    notification = Notification.create!(
      title: "My Title",
      subtitle: "My Subtitle",
      project: project
    )
    json = NotificationSerializer.serialize(notification)

    assert_equal "My Title", json["title"]
    assert_equal "My Subtitle", json["subtitle"]
  end

  # === access_url format ===

  test "access_url returns correct URL format with hashid and domain" do
    project = projects(:one)
    notification = Notification.create!(title: "URL Format Test", project: project)

    domain = project.domain_for_project
    if domain&.full_domain
      url = notification.access_url
      assert_not_nil url
      expected_suffix = "/mm/#{notification.hashid}"
      assert url.end_with?(expected_suffix),
        "access_url should end with /mm/<hashid>, got: #{url}"
      assert_includes url, domain.full_domain
    else
      assert_nil notification.access_url
    end
  end
end
