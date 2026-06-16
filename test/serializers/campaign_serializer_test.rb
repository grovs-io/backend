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

class CampaignSerializerCollectionTest < ActiveSupport::TestCase
  fixtures :campaigns, :projects, :instances, :links, :domains, :redirect_configs

  test "resolves has_links for a collection in a single query" do
    c1 = campaigns(:one)
    c2 = campaigns(:two)
    links(:basic_link).update_columns(campaign_id: c1.id, active: true)

    queries = []
    sub = ActiveSupport::Notifications.subscribe("sql.active_record") do |*, payload|
      queries << payload[:sql] if payload[:sql] =~ /bool_or\(active\)/i
    end
    result = CampaignSerializer.serialize(Campaign.where(id: [c1.id, c2.id]).to_a)
    ActiveSupport::Notifications.unsubscribe(sub)

    assert_equal 1, queries.size, "has_links must be one grouped query for the whole collection"
    by_id = result.index_by { |h| h["id"] }
    assert_equal true, by_id[c1.id]["has_links"]
    assert_equal false, by_id[c2.id]["has_links"]
  end

  test "single-record serialization still resolves has_links" do
    c = campaigns(:one)
    links(:basic_link).update_columns(campaign_id: c.id, active: true)
    assert_equal true, CampaignSerializer.serialize(c)["has_links"]
  end
end
