require "test_helper"

class CampaignTest < ActiveSupport::TestCase
  fixtures :campaigns, :projects, :instances, :domains, :redirect_configs

  # === validations ===

  test "valid with name and project" do
    campaign = Campaign.new(name: "Test Campaign", project: projects(:one))
    assert campaign.valid?
  end

  test "invalid without name" do
    campaign = Campaign.new(name: nil, project: projects(:one))
    assert_not campaign.valid?
    assert_includes campaign.errors[:name], "can't be blank"
  end

  test "invalid with blank name" do
    campaign = Campaign.new(name: "", project: projects(:one))
    assert_not campaign.valid?
    assert_includes campaign.errors[:name], "can't be blank"
  end

  # === serialization ===

  test "serializer excludes updated_at and project_id" do
    campaign = campaigns(:one)
    json = CampaignSerializer.serialize(campaign)

    assert_not json.key?("updated_at")
    assert_not json.key?("project_id")
  end

  test "serializer includes has_links as false when campaign has no links" do
    campaign = campaigns(:one)
    campaign.links.destroy_all
    json = CampaignSerializer.serialize(campaign)

    assert_equal false, json["has_links"]
  end

  test "serializer includes has_links as true when non-archived campaign has active links" do
    campaign = campaigns(:one)
    campaign.update!(archived: false)
    Link.create!(
      domain: domains(:one),
      redirect_config: redirect_configs(:one),
      path: "campaign-link-test",
      generated_from_platform: Grovs::Platforms::IOS,
      campaign: campaign,
      active: true
    )
    json = CampaignSerializer.serialize(campaign)

    assert_equal true, json["has_links"]
  end

  test "serializer has_links checks all links for archived campaigns" do
    campaign = campaigns(:one)
    campaign.update!(archived: true)
    Link.create!(
      domain: domains(:one),
      redirect_config: redirect_configs(:one),
      path: "campaign-link-archived",
      generated_from_platform: Grovs::Platforms::IOS,
      campaign: campaign,
      active: false
    )
    json = CampaignSerializer.serialize(campaign)

    assert_equal true, json["has_links"]
  end

  test "serializer has_links is false for non-archived campaign with only inactive links" do
    campaign = campaigns(:one)
    campaign.update!(archived: false)
    campaign.links.destroy_all
    Link.create!(
      domain: domains(:one),
      redirect_config: redirect_configs(:one),
      path: "campaign-link-inactive",
      generated_from_platform: Grovs::Platforms::IOS,
      campaign: campaign,
      active: false
    )
    json = CampaignSerializer.serialize(campaign)

    assert_equal false, json["has_links"]
  end
end
