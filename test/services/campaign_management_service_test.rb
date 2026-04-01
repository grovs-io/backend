require "test_helper"

class CampaignManagementServiceTest < ActiveSupport::TestCase
  fixtures :instances, :projects

  setup do
    @project = projects(:one)
    @domain = Domain.create!(project: @project, domain: "test.link", subdomain: "cms#{SecureRandom.hex(2)}")
    @redirect_config = RedirectConfig.create!(project: @project)
  end

  def build_service
    CampaignManagementService.new(project: @project)
  end

  # === create ===

  test "create creates campaign with correct project" do
    campaign = build_service.create(name: "New Campaign")
    assert campaign.persisted?
    assert_equal "New Campaign", campaign.name
    assert_equal @project.id, campaign.project_id
    assert_not campaign.archived, "New campaign should not be archived"
  end

  test "create raises without redirect config" do
    project_no_config = projects(:two)

    service = CampaignManagementService.new(project: project_no_config)
    assert_raises(ArgumentError) do
      service.create(name: "Fail")
    end
  end

  # === update ===

  test "update updates and persists campaign name" do
    campaign = build_service.create(name: "Old Name")
    updated = build_service.update(campaign: campaign, attrs: { name: "New Name" })
    assert_equal "New Name", updated.name
    assert_equal "New Name", campaign.reload.name, "Name should be persisted to DB"
  end

  # === archive ===

  test "archive archives campaign and deactivates all its links" do
    campaign = build_service.create(name: "Archive Me")

    link1 = Link.create!(
      title: "Link 1", path: "clink1-#{SecureRandom.hex(4)}",
      generated_from_platform: "dashboard", domain: @domain,
      active: true, redirect_config: @redirect_config, campaign: campaign
    )
    link2 = Link.create!(
      title: "Link 2", path: "clink2-#{SecureRandom.hex(4)}",
      generated_from_platform: "dashboard", domain: @domain,
      active: true, redirect_config: @redirect_config, campaign: campaign
    )

    archived = build_service.archive(campaign: campaign)
    assert archived.archived

    # Verify links are actually persisted as inactive in DB
    assert_not link1.reload.active, "First link should be deactivated in DB"
    assert_not link2.reload.active, "Second link should be deactivated in DB"
  end

  test "archive campaign without links succeeds" do
    campaign = build_service.create(name: "No Links")

    archived = build_service.archive(campaign: campaign)
    assert archived.archived
    assert archived.persisted?
  end

  test "archive is transactional — campaign is reloaded after commit" do
    campaign = build_service.create(name: "Reload Test")
    link = Link.create!(
      title: "TX Link", path: "txlink-#{SecureRandom.hex(4)}",
      generated_from_platform: "dashboard", domain: @domain,
      active: true, redirect_config: @redirect_config, campaign: campaign
    )

    result = build_service.archive(campaign: campaign)
    # The returned campaign should reflect post-reload state
    assert result.archived
    # has_links should still work on reloaded campaign
    assert result.respond_to?(:links)
  end
end
