require "test_helper"

class SubscriptionStateServiceTest < ActiveSupport::TestCase
  fixtures :instances, :projects, :devices, :visitors, :links, :domains,
           :redirect_configs, :purchase_events, :subscription_states

  setup do
    @project = projects(:one)
    @device = devices(:ios_device)
    @link = links(:basic_link)

    # Ensure the premium_sub fixture has ALL fields populated so COALESCE tests
    # are meaningful (not testing COALESCE(NULL, NULL) = NULL which proves nothing).
    @existing = subscription_states(:premium_sub)
    @existing.update_columns(
      device_id: @device.id,
      link_id: @link.id,
      product_id: "com.test.premium",
      purchase_type: "subscription",
      latest_transaction_id: "txn_buy_002"
    )
  end

  # ---------------------------------------------------------------------------
  # Fresh insert
  # ---------------------------------------------------------------------------

  test "creates new subscription state for unseen original_transaction_id" do
    event = purchase_events(:unprocessed_buy)

    assert_difference "SubscriptionState.count", 1 do
      SubscriptionStateService.upsert(event)
    end

    state = SubscriptionState.find_by(
      project_id: event.project_id,
      original_transaction_id: event.original_transaction_id
    )

    assert_not_nil state
    assert_equal event.device_id, state.device_id
    assert_equal event.product_id, state.product_id
    assert_equal event.transaction_id, state.latest_transaction_id
    assert_equal event.purchase_type, state.purchase_type
  end

  # ---------------------------------------------------------------------------
  # COALESCE — the critical upsert logic
  # ---------------------------------------------------------------------------

  test "upsert with all non-null values replaces every field" do
    android_device = devices(:android_device)

    event = build_purchase_event(
      project_id: @existing.project_id,
      original_transaction_id: @existing.original_transaction_id,
      device_id: android_device.id,
      link_id: @link.id,
      product_id: "com.test.upgraded",
      transaction_id: "txn_new_999",
      purchase_type: "one_time"
    )

    SubscriptionStateService.upsert(event)

    state = @existing.reload
    assert_equal android_device.id, state.device_id
    assert_equal @link.id, state.link_id
    assert_equal "com.test.upgraded", state.product_id
    assert_equal "txn_new_999", state.latest_transaction_id
    assert_equal "one_time", state.purchase_type
  end

  test "upsert with ALL null values preserves every existing non-null field" do
    event = build_purchase_event(
      project_id: @existing.project_id,
      original_transaction_id: @existing.original_transaction_id,
      device_id: nil,
      link_id: nil,
      product_id: nil,
      transaction_id: "txn_sparse_renewal",
      purchase_type: nil
    )

    SubscriptionStateService.upsert(event)

    state = @existing.reload
    assert_equal @device.id, state.device_id,
                 "COALESCE(NULL, existing) should keep existing device_id"
    assert_equal @link.id, state.link_id,
                 "COALESCE(NULL, existing) should keep existing link_id"
    assert_equal "com.test.premium", state.product_id,
                 "COALESCE(NULL, existing) should keep existing product_id"
    assert_equal "subscription", state.purchase_type,
                 "COALESCE(NULL, existing) should keep existing purchase_type"
  end

  test "latest_transaction_id ALWAYS updates even when everything else is null" do
    original_txn = @existing.latest_transaction_id

    event = build_purchase_event(
      project_id: @existing.project_id,
      original_transaction_id: @existing.original_transaction_id,
      transaction_id: "txn_always_advances",
      device_id: nil, link_id: nil, product_id: nil, purchase_type: nil
    )

    SubscriptionStateService.upsert(event)

    state = @existing.reload
    assert_equal "txn_always_advances", state.latest_transaction_id,
                 "latest_transaction_id has no COALESCE — must always take new value"
    assert_not_equal original_txn, state.latest_transaction_id
  end

  test "mixed null and non-null values update selectively" do
    event = build_purchase_event(
      project_id: @existing.project_id,
      original_transaction_id: @existing.original_transaction_id,
      device_id: nil,                         # null -> keep existing
      link_id: nil,                           # null -> keep existing
      product_id: "com.test.premium.annual",  # non-null -> replace
      transaction_id: "txn_mixed_update",
      purchase_type: "subscription"           # non-null -> replace
    )

    SubscriptionStateService.upsert(event)

    state = @existing.reload
    assert_equal @device.id, state.device_id, "Null device_id should not clobber existing"
    assert_equal @link.id, state.link_id, "Null link_id should not clobber existing"
    assert_equal "com.test.premium.annual", state.product_id, "Non-null product_id should update"
    assert_equal "txn_mixed_update", state.latest_transaction_id
  end

  test "null existing value gets filled in by non-null new value" do
    # Start with a sparse subscription state (no device, no link)
    @existing.update_columns(device_id: nil, link_id: nil)

    event = build_purchase_event(
      project_id: @existing.project_id,
      original_transaction_id: @existing.original_transaction_id,
      device_id: @device.id,
      link_id: @link.id,
      product_id: nil,
      transaction_id: "txn_fill_in",
      purchase_type: nil
    )

    SubscriptionStateService.upsert(event)

    state = @existing.reload
    assert_equal @device.id, state.device_id,
                 "COALESCE(non-null, NULL) should pick up the new value"
    assert_equal @link.id, state.link_id,
                 "COALESCE(non-null, NULL) should pick up the new value"
    assert_equal "com.test.premium", state.product_id
    assert_equal "subscription", state.purchase_type
  end

  # ---------------------------------------------------------------------------
  # Timestamps — created_at preserved, updated_at advances
  # ---------------------------------------------------------------------------

  test "upsert on conflict advances updated_at but preserves created_at" do
    original_created = @existing.created_at
    original_updated = @existing.updated_at

    travel_to 1.minute.from_now do
      event = build_purchase_event(
        project_id: @existing.project_id,
        original_transaction_id: @existing.original_transaction_id,
        transaction_id: "txn_timestamp_check",
        device_id: nil, link_id: nil, product_id: nil, purchase_type: nil
      )

      SubscriptionStateService.upsert(event)
    end

    state = @existing.reload
    assert_equal original_created.to_i, state.created_at.to_i,
                 "created_at should be preserved on conflict update"
    assert state.updated_at > original_updated,
           "updated_at should advance on conflict update"
  end

  # ---------------------------------------------------------------------------
  # Guard clauses
  # ---------------------------------------------------------------------------

  test "returns nil when original_transaction_id is blank" do
    event = build_purchase_event(
      project_id: @project.id,
      original_transaction_id: nil,
      transaction_id: "txn_no_orig"
    )

    assert_no_difference "SubscriptionState.count" do
      result = SubscriptionStateService.upsert(event)
      assert_nil result
    end
  end

  test "returns nil when original_transaction_id is empty string" do
    event = build_purchase_event(
      project_id: @project.id,
      original_transaction_id: "",
      transaction_id: "txn_empty_orig"
    )

    assert_no_difference "SubscriptionState.count" do
      result = SubscriptionStateService.upsert(event)
      assert_nil result
    end
  end

  test "returns nil when project_id is blank" do
    event = build_purchase_event(
      project_id: nil,
      original_transaction_id: "orig_txn_orphan",
      transaction_id: "txn_no_project"
    )

    assert_no_difference "SubscriptionState.count" do
      result = SubscriptionStateService.upsert(event)
      assert_nil result
    end
  end

  # ---------------------------------------------------------------------------
  # Error handling
  # ---------------------------------------------------------------------------

  test "re-raises exceptions so Sidekiq can retry" do
    event = build_purchase_event(
      project_id: @project.id,
      original_transaction_id: "orig_will_fail_#{SecureRandom.hex(4)}",
      transaction_id: "txn_will_fail"
    )

    # Stub the DB connection to simulate a failure during the upsert SQL
    conn = ActiveRecord::Base.connection
    original_execute = conn.method(:execute)

    conn.stub(:execute, lambda { |sql, *args|
      if sql.include?("INSERT INTO subscription_states")
        raise ActiveRecord::StatementInvalid, "PG::ConnectionBad: connection lost"
      end
      original_execute.call(sql, *args)
    }) do
      assert_raises(ActiveRecord::StatementInvalid) do
        SubscriptionStateService.upsert(event)
      end
    end
  end

  private

  def build_purchase_event(attrs)
    event = PurchaseEvent.new(attrs)
    event.save!(validate: false)
    event
  end
end
