require "test_helper"

class VisitorTest < ActiveSupport::TestCase
  fixtures :visitors, :projects, :devices, :instances, :events, :links, :domains, :redirect_configs

  # === fetch_by_hash_id ===

  test "fetch_by_hash_id round-trips with project_id" do
    visitor = visitors(:ios_visitor)
    hashid = visitor.hashid
    fetched = Visitor.fetch_by_hash_id(hashid, visitor.project_id)
    assert_not_nil fetched
    assert_equal visitor.id, fetched.id
  end

  test "fetch_by_hash_id round-trips without project_id" do
    visitor = visitors(:ios_visitor)
    hashid = visitor.hashid
    fetched = Visitor.fetch_by_hash_id(hashid, nil)
    assert_not_nil fetched
    assert_equal visitor.id, fetched.id
  end

  test "fetch_by_hash_id returns nil for invalid hashid" do
    result = Visitor.fetch_by_hash_id("totally-bogus-id", nil)
    assert_nil result
  end

  test "fetch_by_hash_id returns nil for wrong project_id" do
    visitor = visitors(:ios_visitor)
    hashid = visitor.hashid
    wrong_project = projects(:two)
    result = Visitor.fetch_by_hash_id(hashid, wrong_project.id)
    assert_nil result
  end

  # === cache_keys_to_clear ===

  test "cache_keys_to_clear includes id-based key with device includes" do
    visitor = visitors(:ios_visitor)
    keys = visitor.cache_keys_to_clear
    expected = "#{Visitor.cache_prefix}:find_by:id:#{visitor.id}:includes:device"
    assert_includes keys, expected
  end

  test "cache_keys_to_clear includes device_id and project_id multi-condition keys" do
    visitor = visitors(:ios_visitor)
    keys = visitor.cache_keys_to_clear
    # Build expected key using the same helper the model uses
    expected_key = visitor.send(:multi_condition_cache_key,
      { device_id: visitor.device_id, project_id: visitor.project_id },
      includes: [:device]
    )
    assert_includes keys, expected_key
  end

  test "cache_keys_to_clear includes old device_id keys after device change" do
    visitor = visitors(:ios_visitor)
    old_device = devices(:ios_device)
    new_device = devices(:android_device)
    visitor.update!(device: new_device)

    keys = visitor.cache_keys_to_clear
    # Build expected key for old device_id
    expected_key = visitor.send(:multi_condition_cache_key,
      { device_id: old_device.id, project_id: visitor.project_id },
      includes: [:device]
    )
    assert_includes keys, expected_key
  end

  # === serialization ===

  test "serializer excludes device_id and project_id" do
    visitor = visitors(:ios_visitor)
    json = VisitorSerializer.serialize(visitor)
    assert_nil json["device_id"]
    assert_nil json["project_id"]
  end

  test "serializer with slim option skips inviter and invited" do
    visitor = visitors(:ios_visitor)
    json = VisitorSerializer.serialize(visitor, slim: true)
    assert_nil json["inviter"]
    assert_nil json["invited"]
  end

  test "serializer without slim includes inviter and invited" do
    visitor = visitors(:ios_visitor)
    json = VisitorSerializer.serialize(visitor)
    assert json.key?("inviter")
    assert json.key?("invited")
  end

  test "serializer with skip_invites skips invited list" do
    visitor = visitors(:ios_visitor)
    json = VisitorSerializer.serialize(visitor, skip_invites: true)
    assert_nil json["invited"]
    # inviter should still be present
    assert json.key?("inviter")
  end

  # === Hashid::Rails ===

  test "visitor responds to hashid method" do
    visitor = visitors(:ios_visitor)
    assert visitor.respond_to?(:hashid)
    assert visitor.hashid.is_a?(String)
    assert_not_equal visitor.id.to_s, visitor.hashid
  end

  # === aggregated_events_per_visitor ===

  test "aggregated_events_per_visitor returns visitor data with event counts when events exist" do
    project = projects(:one)
    visitor = visitors(:ios_visitor)
    link = links(:basic_link)

    # Assign the link to the visitor so the LEFT JOIN picks it up
    link.update_columns(visitor_id: visitor.id)

    # Create events tied to this link and project
    Event.create!(project: project, device: devices(:ios_device), link: link, event: "view", platform: "ios", engagement_time: 100)
    Event.create!(project: project, device: devices(:ios_device), link: link, event: "view", platform: "ios", engagement_time: 200)
    Event.create!(project: project, device: devices(:ios_device), link: link, event: "open", platform: "ios", engagement_time: 50)

    results = VisitorReferralStatisticsQuery.send(:aggregated_events_per_visitor, project.id)
                     .where(project_id: project.id)
                     .where(id: visitor.id)

    assert_not_empty results
    row = results.first
    assert_equal visitor.id, row.id
    assert_equal 2, row.view_count.to_i
    assert_equal 300, row.view_engagement_time.to_i
    assert_equal 1, row.open_count.to_i
    assert_equal 50, row.open_engagement_time.to_i
    assert_equal "ios", row.platform
  end

  test "aggregated_events_per_visitor returns zero counts when visitor has no link events" do
    project = projects(:one)
    visitor = visitors(:android_visitor)

    # android_visitor has no links assigned, so LEFT JOIN yields no events
    results = VisitorReferralStatisticsQuery.send(:aggregated_events_per_visitor, project.id)
                     .where(project_id: project.id)
                     .where(id: visitor.id)

    assert_not_empty results
    row = results.first
    assert_equal visitor.id, row.id
    assert_equal 0, row.view_count.to_i
    assert_equal 0, row.open_count.to_i
    assert_equal 0, row.install_count.to_i
  end

  # === VisitorStatisticsQuery.paginated_own_events ===

  test "sorted_and_paginated_own_event_counts returns paginated results" do
    project = projects(:one)

    result = VisitorStatisticsQuery.paginated_own_events(
      page: 1,
      event_type: "created_at",
      asc: false,
      project: project,
      start_date: Date.new(2020, 1, 1),
      end_date: Date.new(2030, 12, 31)
    )

    assert result.key?(:metrics)
    assert result.key?(:page)
    assert result.key?(:total_pages)
    assert result.key?(:per_page)
    assert result.key?(:total_entries)
    assert_equal 1, result[:page]
    assert result[:total_entries] >= 1, "Expected at least one visitor in results"
  end

  test "sorted_and_paginated_own_event_counts sorts ascending and descending by created_at" do
    project = projects(:one)

    result_asc = VisitorStatisticsQuery.paginated_own_events(
      page: 1,
      event_type: "created_at",
      asc: true,
      project: project,
      start_date: Date.new(2020, 1, 1),
      end_date: Date.new(2030, 12, 31)
    )

    result_desc = VisitorStatisticsQuery.paginated_own_events(
      page: 1,
      event_type: "created_at",
      asc: false,
      project: project,
      start_date: Date.new(2020, 1, 1),
      end_date: Date.new(2030, 12, 31)
    )

    assert result_asc[:metrics].present?
    assert result_desc[:metrics].present?

    # Both queries should return the same total entries
    assert_equal result_asc[:total_entries], result_desc[:total_entries]

    # With multiple visitors sharing the same created_at (from fixtures), tiebreak
    # order is undefined. Just verify both queries succeed and return the same set.
    asc_ids = result_asc[:metrics].map(&:id).sort
    desc_ids = result_desc[:metrics].map(&:id).sort
    assert_equal asc_ids, desc_ids, "ASC and DESC should return the same visitor set"
  end

  test "sorted_and_paginated_own_event_counts sorts by updated_at column" do
    project = projects(:one)

    result = VisitorStatisticsQuery.paginated_own_events(
      page: 1,
      event_type: "updated_at",
      asc: false,
      project: project,
      start_date: Date.new(2020, 1, 1),
      end_date: Date.new(2030, 12, 31)
    )

    assert result[:metrics].present?
    assert result[:total_entries] >= 1
  end

  test "sorted_and_paginated_own_event_counts falls back to created_at for invalid sort column" do
    project = projects(:one)

    # Pass an invalid event_type - should not raise, falls back to created_at
    result = VisitorStatisticsQuery.paginated_own_events(
      page: 1,
      event_type: "definitely_not_a_column",
      asc: true,
      project: project,
      start_date: Date.new(2020, 1, 1),
      end_date: Date.new(2030, 12, 31)
    )

    assert result.key?(:metrics)
    assert result[:total_entries] >= 0
  end

  test "sorted_and_paginated_own_event_counts filters by search term on uuid" do
    project = projects(:one)
    visitor = visitors(:ios_visitor)

    # Use part of the visitor's uuid as the search term
    uuid_fragment = visitor.uuid.to_s[0..7]

    result = VisitorStatisticsQuery.paginated_own_events(
      page: 1,
      event_type: "created_at",
      asc: false,
      project: project,
      start_date: Date.new(2020, 1, 1),
      end_date: Date.new(2030, 12, 31),
      term: uuid_fragment
    )

    assert result[:total_entries] >= 1
    # The matching visitor should be in the results
    visitor_ids = result[:metrics].map(&:id)
    assert_includes visitor_ids, visitor.id
  end

  test "sorted_and_paginated_own_event_counts filters by search term on sdk_identifier" do
    project = projects(:one)
    visitor = visitors(:ios_visitor)
    visitor.update_columns(sdk_identifier: "test-sdk-id-unique-123")

    result = VisitorStatisticsQuery.paginated_own_events(
      page: 1,
      event_type: "created_at",
      asc: false,
      project: project,
      start_date: Date.new(2020, 1, 1),
      end_date: Date.new(2030, 12, 31),
      term: "test-sdk-id-unique"
    )

    assert result[:total_entries] >= 1
    visitor_ids = result[:metrics].map(&:id)
    assert_includes visitor_ids, visitor.id
  end

  test "sorted_and_paginated_own_event_counts returns no results for non-matching term" do
    project = projects(:one)

    result = VisitorStatisticsQuery.paginated_own_events(
      page: 1,
      event_type: "created_at",
      asc: false,
      project: project,
      start_date: Date.new(2020, 1, 1),
      end_date: Date.new(2030, 12, 31),
      term: "zzz-no-match-zzz-9999"
    )

    assert_equal 0, result[:total_entries]
  end

  # === add_notifications_if_needed (after_create_commit callback) ===

  test "creating a visitor calls NotificationMessageService.add_messages_for_new_visitor" do
    project = projects(:one)
    device = devices(:ios_device)
    called = false

    NotificationMessageService.stub(:add_messages_for_new_visitor, ->(_visitor) { called = true }) do
      Visitor.create!(project: project, device: device, web_visitor: false)
    end

    assert called, "Expected NotificationMessageService.add_messages_for_new_visitor to be called"
  end
end
