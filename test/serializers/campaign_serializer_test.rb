require "test_helper"

class CampaignSerializerTest < ActiveSupport::TestCase
  fixtures :campaigns, :projects, :instances, :links, :domains, :redirect_configs

  # ---------------------------------------------------------------------------
  # 1. VALUE VERIFICATION
  # ---------------------------------------------------------------------------

  test "serializes all declared attributes with correct values" do
    campaign = campaigns(:one)
    result = CampaignSerializer.serialize(campaign)

    assert_equal campaign.id, result["id"]
    assert_equal "Spring 2026 Campaign", result["name"]
    assert_equal false, result["archived"]
  end

  test "serializes computed has_links field as false when campaign has no links" do
    campaign = campaigns(:one)
    result = CampaignSerializer.serialize(campaign)

    # No links are assigned to campaign(:one) in fixtures
    assert_equal false, result["has_links"]
  end

  test "serializes campaign two with its own values" do
    campaign = campaigns(:two)
    result = CampaignSerializer.serialize(campaign)

    assert_equal campaign.id, result["id"]
    assert_equal "Summer Promo", result["name"]
    assert_equal false, result["archived"]
    assert_equal false, result["has_links"]
  end

  # ---------------------------------------------------------------------------
  # 2. EXCLUSION
  # ---------------------------------------------------------------------------

  test "excludes updated_at and project_id" do
    result = CampaignSerializer.serialize(campaigns(:one))

    %w[updated_at project_id].each do |field|
      assert_not_includes result.keys, field
    end
  end

  # ---------------------------------------------------------------------------
  # 3. NIL HANDLING
  # ---------------------------------------------------------------------------

  test "returns nil for nil input" do
    assert_nil CampaignSerializer.serialize(nil)
  end

  # ---------------------------------------------------------------------------
  # 4. COLLECTION HANDLING
  # ---------------------------------------------------------------------------

  test "serializes a collection with correct size and values" do
    campaigns_list = [campaigns(:one), campaigns(:two)]
    results = CampaignSerializer.serialize(campaigns_list)

    assert_equal 2, results.size
    assert_equal campaigns(:one).id, results[0]["id"]
    assert_equal campaigns(:two).id, results[1]["id"]
    assert_equal "Spring 2026 Campaign", results[0]["name"]
    assert_equal "Summer Promo", results[1]["name"]
  end

  # ---------------------------------------------------------------------------
  # 5. EDGE CASES -- computed field variations
  # ---------------------------------------------------------------------------

  test "has_links is true when non-archived campaign has active links" do
    campaign = campaigns(:one)
    link = links(:basic_link)
    link.update!(campaign: campaign)

    result = CampaignSerializer.serialize(campaign)

    assert_equal true, result["has_links"]
  end

  test "has_links is false when non-archived campaign has only inactive links" do
    campaign = campaigns(:one)
    link = links(:inactive_link)
    link.update!(campaign: campaign)

    result = CampaignSerializer.serialize(campaign)

    assert_equal false, result["has_links"]
  end

  test "archived campaign with no links returns has_links false" do
    campaign = campaigns(:one)
    campaign.update!(archived: true)

    result = CampaignSerializer.serialize(campaign)

    assert_equal true, result["archived"]
    assert_equal false, result["has_links"]
  end

  test "archived campaign with any link returns has_links true" do
    campaign = campaigns(:one)
    campaign.update!(archived: true)
    link = links(:inactive_link)
    link.update!(campaign: campaign)

    result = CampaignSerializer.serialize(campaign)

    # archived? uses record.links.exists? (all links, not just active)
    assert_equal true, result["has_links"]
  end

  test "archived campaign with active link also returns has_links true" do
    campaign = campaigns(:one)
    campaign.update!(archived: true)
    link = links(:basic_link)
    link.update!(campaign: campaign)

    result = CampaignSerializer.serialize(campaign)

    assert_equal true, result["has_links"]
  end
end
