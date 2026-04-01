require "test_helper"

class LinkManagementServiceTest < ActiveSupport::TestCase
  fixtures :instances, :projects

  setup do
    @project = projects(:one)
    @domain = Domain.create!(project: @project, domain: "test.link", subdomain: "lms#{SecureRandom.hex(2)}")
    @redirect_config = RedirectConfig.create!(project: @project)
  end

  def build_service
    LinkManagementService.new(project: @project)
  end

  # === create ===

  test "create creates link with correct defaults" do
    path = "test-#{SecureRandom.hex(4)}"
    link = build_service.create(link_attrs: { title: "Test", path: path })

    assert link.persisted?
    assert link.active
    assert_equal "dashboard", link.generated_from_platform
    assert_equal @domain.id, link.domain_id
    assert_equal @redirect_config.id, link.redirect_config_id
    assert_equal path, link.path
    assert_equal "Test", link.title
  end

  test "create with image_url sets it on the link" do
    link = build_service.create(
      link_attrs: { title: "Img", path: "img-#{SecureRandom.hex(4)}" },
      image_url: "https://example.com/image.png"
    )
    assert_equal "https://example.com/image.png", link.image_url
  end

  test "create with tags parses JSON array" do
    link = build_service.create(
      link_attrs: { title: "Tagged", path: "tagged-#{SecureRandom.hex(4)}" },
      tags: '["tag1", "tag2"]'
    )
    assert_equal ["tag1", "tag2"], link.tags
  end

  test "create with non-array tags raises ArgumentError" do
    assert_raises(ArgumentError) do
      build_service.create(
        link_attrs: { title: "Bad Tags", path: "bad-#{SecureRandom.hex(4)}" },
        tags: '"not_an_array"'
      )
    end
  end

  test "create with invalid JSON tags raises" do
    assert_raises(JSON::ParserError) do
      build_service.create(
        link_attrs: { title: "Bad JSON", path: "badjson-#{SecureRandom.hex(4)}" },
        tags: "not json at all"
      )
    end
  end

  test "create with data parses JSON hash" do
    link = build_service.create(
      link_attrs: { title: "Data Link", path: "data-#{SecureRandom.hex(4)}" },
      data: '{"key": "value", "nested": {"a": 1}}'
    )
    assert_equal({ "key" => "value", "nested" => { "a" => 1 } }, link.data)
  end

  test "create with campaign associates and sets tracking_campaign" do
    campaign = Campaign.create!(name: "Test Campaign", project: @project)
    link = build_service.create(
      link_attrs: { title: "Campaign Link", path: "camp-#{SecureRandom.hex(4)}" },
      campaign_id: campaign.id
    )
    assert_equal campaign.id, link.campaign_id
    assert_equal "Test Campaign", link.tracking_campaign
  end

  test "create with campaign does not override explicit tracking_campaign" do
    campaign = Campaign.create!(name: "Auto Name", project: @project)
    link = build_service.create(
      link_attrs: { title: "Manual", path: "manual-#{SecureRandom.hex(4)}", tracking_campaign: "Custom" },
      campaign_id: campaign.id
    )
    assert_equal campaign.id, link.campaign_id
    assert_equal "Custom", link.tracking_campaign, "Explicit tracking_campaign should not be overridden"
  end

  test "create ignores campaign from different project" do
    other_project = projects(:two)
    campaign = Campaign.create!(name: "Other Project", project: other_project)

    link = build_service.create(
      link_attrs: { title: "Cross-project", path: "cross-#{SecureRandom.hex(4)}" },
      campaign_id: campaign.id
    )
    assert_nil link.campaign_id, "Campaign from different project should be ignored"
  end

  test "create raises without redirect config" do
    project_no_config = projects(:two)
    Domain.create!(project: project_no_config, domain: "test.link", subdomain: "norc#{SecureRandom.hex(2)}")

    service = LinkManagementService.new(project: project_no_config)
    assert_raises(ArgumentError) do
      service.create(link_attrs: { title: "Fail", path: "fail-#{SecureRandom.hex(4)}" })
    end
  end

  # === update ===

  test "update updates link attrs and persists" do
    link = build_service.create(link_attrs: { title: "Original", subtitle: "Sub", path: "upd-#{SecureRandom.hex(4)}" })

    updated = build_service.update(link: link, link_attrs: { title: "Updated" })
    assert_equal "Updated", updated.title
    assert_equal "Updated", link.reload.title, "Change should be persisted to DB"
  end

  test "update with data replaces existing data" do
    link = build_service.create(
      link_attrs: { title: "Data", path: "datau-#{SecureRandom.hex(4)}" },
      data: '{"old": true}'
    )

    updated = build_service.update(link: link, link_attrs: {}, data: '{"new": true}')
    assert_equal({ "new" => true }, updated.data)
    assert_nil updated.data["old"]
  end

  test "update without data clears existing data" do
    link = build_service.create(
      link_attrs: { title: "Clear", path: "clear-#{SecureRandom.hex(4)}" },
      data: '{"will_be_cleared": true}'
    )

    updated = build_service.update(link: link, link_attrs: {})
    assert_nil updated.data, "Data should be cleared when no data param provided"
  end

  test "update with invalid path raises" do
    link = build_service.create(link_attrs: { title: "Path Test", path: "pathtest-#{SecureRandom.hex(4)}" })
    build_service.create(link_attrs: { title: "Existing", path: "taken-path" })

    assert_raises(ActiveRecord::RecordInvalid) do
      build_service.update(link: link, link_attrs: { path: "taken-path" })
    end
  end

  test "update with same path does not raise" do
    path = "same-#{SecureRandom.hex(4)}"
    link = build_service.create(link_attrs: { title: "Same Path", path: path })

    updated = build_service.update(link: link, link_attrs: { path: path, title: "New Title" })
    assert_equal "New Title", updated.title
    assert_equal path, updated.path
  end

  test "update sets show_preview fields when included in link_attrs" do
    link = build_service.create(link_attrs: { title: "Set", path: "set-#{SecureRandom.hex(4)}" })
    assert_nil link.show_preview_ios

    updated = build_service.update(
      link: link, link_attrs: { show_preview_ios: true, show_preview_android: false }
    )

    assert_equal true, updated.show_preview_ios
    assert_equal false, updated.show_preview_android
    assert_equal true, link.reload.show_preview_ios, "Value should be persisted to DB"
  end

  test "update preserves show_preview fields when not included in link_attrs" do
    link = build_service.create(link_attrs: { title: "Keep", path: "keep-#{SecureRandom.hex(4)}" })
    link.update!(show_preview_ios: true, show_preview_android: false)

    updated = build_service.update(link: link, link_attrs: { title: "Changed" })

    assert_equal true, updated.show_preview_ios, "show_preview_ios should be preserved when not in link_attrs"
    assert_equal false, updated.show_preview_android, "show_preview_android should be preserved when not in link_attrs"
  end

  # === custom redirects ===

  test "update with nil custom redirect params destroys existing redirects" do
    link = build_service.create(link_attrs: { title: "Redirect", path: "redir-#{SecureRandom.hex(4)}" })
    link.custom_redirects.create!(platform: Grovs::Platforms::IOS, url: "https://example.com/ios", open_app_if_installed: true)
    link.custom_redirects.create!(platform: Grovs::Platforms::ANDROID, url: "https://example.com/android", open_app_if_installed: true)
    assert_equal 2, link.custom_redirects.count

    build_service.update(
      link: link, link_attrs: {},
      custom_redirects: { ios: nil, android: nil, desktop: nil }
    )

    assert_equal 0, link.custom_redirects.reload.count, "All custom redirects should be destroyed"
  end

  test "update with custom redirect data recreates redirect" do
    link = build_service.create(link_attrs: { title: "Redir2", path: "redir2-#{SecureRandom.hex(4)}" })
    link.custom_redirects.create!(platform: Grovs::Platforms::IOS, url: "https://old.com", open_app_if_installed: false)

    build_service.update(
      link: link, link_attrs: {},
      custom_redirects: { ios: { "url" => "https://new.com", "open_app_if_installed" => true }, android: nil, desktop: nil }
    )

    assert_equal 1, link.custom_redirects.reload.count
    ios_redirect = link.ios_custom_redirect
    assert_equal "https://new.com", ios_redirect.url
    assert ios_redirect.open_app_if_installed
  end

  # === archive ===

  test "archive sets link inactive and persists" do
    link = build_service.create(link_attrs: { title: "Archive Me", path: "arch-#{SecureRandom.hex(4)}" })
    assert link.active

    archived = build_service.archive(link: link)
    assert_not archived.active
    assert_not link.reload.active, "Inactive state should be persisted to DB"
  end

  # === path_available? ===

  test "path_available returns true for available path" do
    result = build_service.path_available?(path: "available-#{SecureRandom.hex(4)}", domain: @domain)
    assert result
  end

  test "path_available returns false for taken path" do
    build_service.create(link_attrs: { title: "Taken", path: "taken-check" })
    result = build_service.path_available?(path: "taken-check", domain: @domain)
    assert_not result
  end

  test "path_available returns false for special characters" do
    assert_not build_service.path_available?(path: "bad path!", domain: @domain)
    assert_not build_service.path_available?(path: "bad/path", domain: @domain)
    assert_not build_service.path_available?(path: "bad?path", domain: @domain)
  end

  test "path_available allows hyphens" do
    assert build_service.path_available?(path: "valid-path-here", domain: @domain)
  end

  # === generate_path ===

  test "generate_path returns a hash with valid_path key" do
    result = build_service.generate_path(domain: @domain)
    assert result.is_a?(Hash)
    assert result[:valid_path].present?
  end
end
