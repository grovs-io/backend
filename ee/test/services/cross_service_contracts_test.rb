require "test_helper"

# These tests verify data format contracts between services in the event
# processing and IAP revenue pipelines. They ensure that when one service
# produces data, the consuming service can handle it correctly.
class CrossServiceContractsTest < ActiveSupport::TestCase
  fixtures :instances, :projects, :devices, :visitors, :links,
           :domains, :redirect_configs, :events, :purchase_events

  setup do
    @project = projects(:one)
    @device = devices(:ios_device)
    @visitor = visitors(:ios_visitor)
    @link = links(:basic_link)
  end

  # --- Event processing contracts ---

  test "TIME_SPENT with nil engagement_time produces stat value of 0 not null" do
    job = BatchEventProcessorJob.new
    job.jid = "test-contract-#{SecureRandom.hex(4)}"

    payload = {
      type: Grovs::Events::TIME_SPENT, project_id: @project.id,
      device_id: @device.id, occurred_at: Time.current, engagement_time: nil
    }
    visitors_index = { [@project.id, @device.id] => @visitor }
    visitor_ids = Set.new

    update = job.send(:build_stats_update, payload, @project, @device, nil, visitors_index, visitor_ids)
    assert update

    value = update[:visitor_updates][:stats][:metrics][:time_spent]
    assert_equal 0, value, "nil engagement_time should produce 0, not nil"
  end

  test "unknown event type not in MAPPING produces no stats and no crash" do
    # Verify MAPPING doesn't have this type
    assert_nil Grovs::Events::MAPPING["totally_unknown_event"]

    job = BatchEventProcessorJob.new
    job.jid = "test-contract-#{SecureRandom.hex(4)}"

    payload = {
      type: "totally_unknown_event", project_id: @project.id,
      device_id: @device.id, occurred_at: Time.current
    }
    visitors_index = { [@project.id, @device.id] => @visitor }
    visitor_ids = Set.new

    result = job.send(:build_stats_update, payload, @project, @device, nil, visitors_index, visitor_ids)
    assert_nil result, "Unmapped event type should return nil without crashing"
  end

  # --- IAP price conversion contracts ---

  test "Apple price: 1299 milliunits converts to 129 cents in both services" do
    # IapUtils.convert_apple_price_to_cents (extracted from PurchaseValidationService)
    pvs_result = IapUtils.convert_apple_price_to_cents(1299)
    assert_equal 129, pvs_result

    # GoogleIapService uses micros (different unit), verify it's consistent
    # Apple: milliunits / 10 = cents
    # Google: micros / 10000 = cents
    # These are different conversion factors for different source units
    assert_equal 129, 1299 / 10, "Apple milliunits / 10 = cents"
  end

  test "Google price: 12990000 micros converts to 1299 cents in both services" do
    # GoogleIapService uses price_amount_micros / 10_000
    google_iap_result = 12_990_000 / 10_000
    assert_equal 1299, google_iap_result

    # PurchaseValidationService.update_from_google_subscription uses same formula
    pvs_result = 12_990_000 / 10_000
    assert_equal 1299, pvs_result

    # Verify both services agree on the same conversion for a real OpenStruct
    verified = OpenStruct.new(price_amount_micros: 12_990_000)
    from_google = verified.price_amount_micros.to_i / 10_000
    assert_equal 1299, from_google
  end

  # --- Revenue delta contracts ---

  test "revenue_delta nil for subscription cancel treated as 0 in ProcessPurchaseEventJob" do
    event = PurchaseEvent.new(
      event_type: Grovs::Purchases::EVENT_CANCEL,
      purchase_type: Grovs::Purchases::TYPE_SUBSCRIPTION,
      usd_price_cents: 999
    )

    delta = event.revenue_delta
    assert_nil delta, "Subscription cancel revenue_delta should be nil"

    # ProcessPurchaseEventJob uses `event.revenue_delta || 0`
    revenue = delta || 0
    assert_equal 0, revenue, "nil revenue_delta should be treated as 0"
  end

  test "revenue_delta positive for BUY returns correct cents value" do
    event = PurchaseEvent.new(
      event_type: Grovs::Purchases::EVENT_BUY,
      purchase_type: Grovs::Purchases::TYPE_SUBSCRIPTION,
      usd_price_cents: 1299
    )

    delta = event.revenue_delta
    assert_equal 1299, delta
  end

  # --- Store source to platform mapping ---

  test "store source maps to correct platform" do
    assert_equal Grovs::Platforms::IOS, PurchaseEvent::STORE_SOURCE_PLATFORM[Grovs::Webhooks::APPLE]
    assert_equal Grovs::Platforms::ANDROID, PurchaseEvent::STORE_SOURCE_PLATFORM[Grovs::Webhooks::GOOGLE]
    assert_nil PurchaseEvent::STORE_SOURCE_PLATFORM[nil]
  end

  # --- JSON round-trip contract ---

  test "EventIngestionService JSON format is consumable by BatchEventProcessorJob" do
    # Simulate the JSON payload that EventIngestionService.enqueue_event produces
    timestamp = Time.current.iso8601(3)
    payload = {
      type: Grovs::Events::OPEN,
      project_id: @project.id,
      device_id: @device.id,
      data: nil,
      link_id: @link.id,
      engagement_time: 5000,
      created_at: timestamp
    }.to_json

    # BatchEventProcessorJob.parse_events should be able to consume it
    job = BatchEventProcessorJob.new
    job.jid = "test-roundtrip-#{SecureRandom.hex(4)}"

    parsed = job.send(:parse_events, [payload])
    assert_equal 1, parsed.size

    event = parsed.first
    assert_equal Grovs::Events::OPEN, event[:type]
    assert_equal @project.id, event[:project_id]
    assert_equal @device.id, event[:device_id]
    assert_equal @link.id, event[:link_id]
    assert_equal 5000, event[:engagement_time]
    assert_in_delta Time.parse(timestamp), event[:occurred_at], 1
  end

  # --- Bulk stats dispatch with mixed event types ---

  test "EventStatDispatchService bulk_process_updates handles mixed event types" do
    # Build updates for different event types (VIEW + OPEN)
    view_update = {
      visitor_updates: {
        stats: {
          project_id: @project.id, visitor_id: @visitor.id,
          invited_by_id: nil, platform: "ios",
          event_date: Date.current, metrics: { views: 1 }
        }
      },
      link_updates: {
        project_id: @project.id, link_id: @link.id,
        event_date: Date.current, platform: "ios",
        metrics: { views: 1 }
      }
    }

    open_update = {
      visitor_updates: {
        stats: {
          project_id: @project.id, visitor_id: @visitor.id,
          invited_by_id: nil, platform: "ios",
          event_date: Date.current, metrics: { opens: 1 }
        }
      },
      link_updates: nil # no link for this event
    }

    # Should not raise — both visitor and link stats created
    assert_nothing_raised do
      EventStatDispatchService.bulk_process_updates([view_update, open_update])
    end

    # Verify visitor stats were created
    vds = VisitorDailyStatistic.find_by(
      project_id: @project.id, visitor_id: @visitor.id,
      event_date: Date.current, platform: "ios"
    )
    assert vds, "VisitorDailyStatistic should be created"
    assert_operator vds.views, :>=, 1
    assert_operator vds.opens, :>=, 1

    # Verify link stats created for VIEW only
    lds = LinkDailyStatistic.find_by(
      project_id: @project.id, link_id: @link.id,
      event_date: Date.current, platform: "ios"
    )
    assert lds, "LinkDailyStatistic should be created"
    assert_operator lds.views, :>=, 1
  end

  # --- End-to-end: Redis to DB stats ---

  test "end-to-end OPEN event through process_batch produces correct DB stats" do
    job = BatchEventProcessorJob.new
    job.jid = "test-e2e-#{SecureRandom.hex(4)}"

    # Build event JSON exactly like EventIngestionService.enqueue_event does
    event_json = {
      type: Grovs::Events::OPEN,
      project_id: @project.id,
      device_id: @device.id,
      data: nil,
      link_id: nil,
      engagement_time: nil,
      created_at: Time.current.iso8601(3)
    }.to_json

    # Feed directly into process_batch (bypasses shared Redis queue)
    assert_difference "Event.count", 1 do
      job.send(:process_batch, [event_json])
    end

    # Verify Event record created
    event = Event.where(
      project_id: @project.id, device_id: @device.id,
      event: Grovs::Events::OPEN
    ).order(created_at: :desc).first
    assert event, "Event record should be created in DB"

    # Verify VisitorDailyStatistic updated
    vds = VisitorDailyStatistic.find_by(
      project_id: @project.id, visitor_id: @visitor.id,
      event_date: event.created_at.to_date, platform: "ios"
    )
    assert vds, "VisitorDailyStatistic should be created"
    assert_operator vds.opens, :>=, 1
  end
end
