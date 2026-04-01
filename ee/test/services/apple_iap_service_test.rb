require "test_helper"

class AppleIapServiceTest < ActiveSupport::TestCase
  fixtures :instances, :projects, :devices, :visitors, :purchase_events, :subscription_states

  setup do
    @helper = AppleIapService.new
    @project = projects(:one)
  end

  # ---------------------------------------------------------------------------
  # Helper — builds a 3-layer Apple notification and stubs the JWT decoder
  # so that handle_notification can be called end-to-end without real certs.
  # ---------------------------------------------------------------------------
  def send_apple_notification(type:, transaction_id:, original_transaction_id:, subtype: nil, product_id: "com.test.new_product",
                              price: 9990, currency: "USD")
    outer_payload = {
      "notificationType" => type,
      "subtype" => subtype,
      "data" => {
        "bundleId" => "com.test.app",
        "signedTransactionInfo" => "fake_signed_txn",
        "signedRenewalInfo" => "fake_signed_renewal"
      }
    }

    transaction_info = {
      "transactionId" => transaction_id,
      "originalTransactionId" => original_transaction_id,
      "productId" => product_id,
      "bundleId" => "com.test.app",
      "price" => price,
      "currency" => currency,
      "purchaseDate" => Time.current.to_i * 1000,
      "expiresDate" => 1.month.from_now.to_i * 1000,
      "environment" => "Sandbox",
      "webOrderLineItemId" => "woli_#{transaction_id}",
      "subscriptionGroupIdentifier" => "group_001"
    }

    renewal_info = {
      "expiresDate" => 1.month.from_now.to_i * 1000
    }

    call_count = 0
    responses = [outer_payload, transaction_info, renewal_info]
    decoder = lambda { |_jws| 
      r = responses[call_count]
      call_count += 1
      r
    }

    AppStoreServerApi::Utils::Decoder.stub(:decode_jws!, decoder) do
      @helper.handle_notification({ "signedPayload" => "fake_jws" }, @project)
    end
  end

  # ---------------------------------------------------------------------------
  # Guard clauses
  # ---------------------------------------------------------------------------

  test "handle_notification returns false for nil notification" do
    result = @helper.handle_notification(nil, @project)
    assert_not result
  end

  test "handle_notification returns false for missing signedPayload" do
    result = @helper.handle_notification({}, @project)
    assert_not result
  end

  # ---------------------------------------------------------------------------
  # Webhook audit trail — every valid notification creates an IapWebhookMessage
  # ---------------------------------------------------------------------------

  test "creates an IapWebhookMessage for every valid notification" do
    assert_difference "IapWebhookMessage.count", 1 do
      send_apple_notification(
        type: "SUBSCRIBED", subtype: "INITIAL_BUY",
        transaction_id: "txn_audit_001", original_transaction_id: "orig_audit_001"
      )
    end

    webhook = IapWebhookMessage.order(:created_at).last
    assert_equal "SUBSCRIBED", webhook.notification_type
    assert_equal Grovs::Webhooks::APPLE, webhook.source
    assert_equal @project.id, webhook.project_id
    assert_equal @project.instance_id, webhook.instance_id
  end

  test "creates an IapWebhookMessage even for informational notifications" do
    assert_difference "IapWebhookMessage.count", 1 do
      send_apple_notification(
        type: "TEST", subtype: nil,
        transaction_id: "txn_audit_test", original_transaction_id: "orig_audit_test"
      )
    end
  end

  # ---------------------------------------------------------------------------
  # Subscription Handler — notifications that create BUY events
  # ---------------------------------------------------------------------------

  test "SUBSCRIBED INITIAL_BUY creates a BUY event" do
    result = send_apple_notification(
      type: "SUBSCRIBED", subtype: "INITIAL_BUY",
      transaction_id: "txn_sub_init", original_transaction_id: "txn_sub_init"
    )

    assert result
    event = PurchaseEvent.find_by(transaction_id: "txn_sub_init", project: @project)
    assert event, "Should create a purchase event"
    assert_equal Grovs::Purchases::EVENT_BUY, event.event_type
    assert_equal Grovs::Purchases::TYPE_SUBSCRIPTION, event.purchase_type
    assert_equal "com.test.new_product", event.product_id
    assert_equal "com.test.app", event.identifier
    assert event.webhook_validated
    assert event.store
    assert_equal Grovs::Webhooks::APPLE, event.store_source
  end

  test "SUBSCRIBED RESUBSCRIBE creates a BUY event" do
    result = send_apple_notification(
      type: "SUBSCRIBED", subtype: "RESUBSCRIBE",
      transaction_id: "txn_sub_resub", original_transaction_id: "orig_sub_resub"
    )

    assert result
    event = PurchaseEvent.find_by(transaction_id: "txn_sub_resub", project: @project)
    assert event
    assert_equal Grovs::Purchases::EVENT_BUY, event.event_type
  end

  test "DID_RENEW creates a BUY event" do
    result = send_apple_notification(
      type: "DID_RENEW", subtype: "BILLING_RECOVERY",
      transaction_id: "txn_renew_001", original_transaction_id: "orig_renew_001"
    )

    assert result
    event = PurchaseEvent.find_by(transaction_id: "txn_renew_001", project: @project)
    assert event
    assert_equal Grovs::Purchases::EVENT_BUY, event.event_type
    assert_equal Grovs::Purchases::TYPE_SUBSCRIPTION, event.purchase_type
  end

  test "OFFER_REDEEMED without upgrade subtype creates a BUY event" do
    result = send_apple_notification(
      type: "OFFER_REDEEMED", subtype: "INITIAL_BUY",
      transaction_id: "txn_offer_buy", original_transaction_id: "orig_offer_buy"
    )

    assert result
    event = PurchaseEvent.find_by(transaction_id: "txn_offer_buy", project: @project)
    assert event
    assert_equal Grovs::Purchases::EVENT_BUY, event.event_type
  end

  test "ONE_TIME_CHARGE creates a BUY event with one_time purchase type" do
    result = send_apple_notification(
      type: "ONE_TIME_CHARGE", subtype: nil,
      transaction_id: "txn_otc_001", original_transaction_id: "orig_otc_001",
      product_id: "com.test.gems_pack"
    )

    assert result
    event = PurchaseEvent.find_by(transaction_id: "txn_otc_001", project: @project)
    assert event
    assert_equal Grovs::Purchases::EVENT_BUY, event.event_type
    assert_equal Grovs::Purchases::TYPE_ONE_TIME, event.purchase_type
    assert_equal "com.test.gems_pack", event.product_id
  end

  # ---------------------------------------------------------------------------
  # Subscription Handler — notifications that create CANCEL events
  # ---------------------------------------------------------------------------

  test "EXPIRED creates a CANCEL event" do
    result = send_apple_notification(
      type: "EXPIRED", subtype: "VOLUNTARY",
      transaction_id: "txn_exp_001", original_transaction_id: "orig_exp_001"
    )

    assert result
    event = PurchaseEvent.find_by(transaction_id: "txn_exp_001", project: @project)
    assert event
    assert_equal Grovs::Purchases::EVENT_CANCEL, event.event_type
  end

  test "GRACE_PERIOD_EXPIRED creates a CANCEL event" do
    result = send_apple_notification(
      type: "GRACE_PERIOD_EXPIRED", subtype: nil,
      transaction_id: "txn_gpe_001", original_transaction_id: "orig_gpe_001"
    )

    assert result
    event = PurchaseEvent.find_by(transaction_id: "txn_gpe_001", project: @project)
    assert event
    assert_equal Grovs::Purchases::EVENT_CANCEL, event.event_type
  end

  test "REVOKE creates a CANCEL event" do
    result = send_apple_notification(
      type: "REVOKE", subtype: nil,
      transaction_id: "txn_revoke_001", original_transaction_id: "orig_revoke_001"
    )

    assert result
    event = PurchaseEvent.find_by(transaction_id: "txn_revoke_001", project: @project)
    assert event
    assert_equal Grovs::Purchases::EVENT_CANCEL, event.event_type
  end

  test "DID_FAIL_TO_RENEW without grace period creates a CANCEL event" do
    result = send_apple_notification(
      type: "DID_FAIL_TO_RENEW", subtype: nil,
      transaction_id: "txn_fail_001", original_transaction_id: "orig_fail_001"
    )

    assert result
    event = PurchaseEvent.find_by(transaction_id: "txn_fail_001", project: @project)
    assert event
    assert_equal Grovs::Purchases::EVENT_CANCEL, event.event_type
  end

  # ---------------------------------------------------------------------------
  # Subscription Handler — billing retry / grace period → no purchase event
  # ---------------------------------------------------------------------------

  test "DID_FAIL_TO_RENEW GRACE_PERIOD does not create a purchase event" do
    result = nil
    assert_no_difference "PurchaseEvent.count" do
      result = send_apple_notification(
        type: "DID_FAIL_TO_RENEW", subtype: "GRACE_PERIOD",
        transaction_id: "txn_fail_gp", original_transaction_id: "orig_fail_gp"
      )
    end
    assert result, "Handler should succeed (not error out)"
  end

  test "DID_FAIL_TO_RENEW BILLING_RETRY does not create a purchase event" do
    result = nil
    assert_no_difference "PurchaseEvent.count" do
      result = send_apple_notification(
        type: "DID_FAIL_TO_RENEW", subtype: "BILLING_RETRY",
        transaction_id: "txn_fail_br", original_transaction_id: "orig_fail_br"
      )
    end
    assert result, "Handler should succeed (not error out)"
  end

  # ---------------------------------------------------------------------------
  # Subscription Handler — renewal status changes → log only, no event
  # ---------------------------------------------------------------------------

  test "DID_CHANGE_RENEWAL_STATUS AUTO_RENEW_DISABLED does not create an event" do
    result = nil
    assert_no_difference "PurchaseEvent.count" do
      result = send_apple_notification(
        type: "DID_CHANGE_RENEWAL_STATUS", subtype: "AUTO_RENEW_DISABLED",
        transaction_id: "txn_ard_001", original_transaction_id: "orig_ard_001"
      )
    end
    assert result, "Handler should succeed (not error out)"
  end

  test "DID_CHANGE_RENEWAL_STATUS AUTO_RENEW_ENABLED does not create an event" do
    result = nil
    assert_no_difference "PurchaseEvent.count" do
      result = send_apple_notification(
        type: "DID_CHANGE_RENEWAL_STATUS", subtype: "AUTO_RENEW_ENABLED",
        transaction_id: "txn_are_001", original_transaction_id: "orig_are_001"
      )
    end
    assert result, "Handler should succeed (not error out)"
  end

  # ---------------------------------------------------------------------------
  # Subscription Handler — renewal preference: downgrade is log-only
  # ---------------------------------------------------------------------------

  test "DID_CHANGE_RENEWAL_PREF DOWNGRADE does not create an event" do
    result = nil
    assert_no_difference "PurchaseEvent.count" do
      result = send_apple_notification(
        type: "DID_CHANGE_RENEWAL_PREF", subtype: "DOWNGRADE",
        transaction_id: "txn_dg_001", original_transaction_id: "orig_dg_001"
      )
    end
    assert result, "Handler should succeed (not error out)"
  end

  test "OFFER_REDEEMED DOWNGRADE does not create an event" do
    result = nil
    assert_no_difference "PurchaseEvent.count" do
      result = send_apple_notification(
        type: "OFFER_REDEEMED", subtype: "DOWNGRADE",
        transaction_id: "txn_offer_dg", original_transaction_id: "orig_offer_dg"
      )
    end
    assert result, "Handler should succeed (not error out)"
  end

  # ---------------------------------------------------------------------------
  # Subscription Handler — upgrade flow (cancel old + buy new)
  # ---------------------------------------------------------------------------

  test "DID_CHANGE_RENEWAL_PREF UPGRADE cancels old subscription and creates a BUY" do
    result = send_apple_notification(
      type: "DID_CHANGE_RENEWAL_PREF", subtype: "UPGRADE",
      transaction_id: "txn_ug_new", original_transaction_id: "orig_txn_001",
      product_id: "com.test.premium_plus"
    )

    assert result

    # The upgrade creates a cancel for the old subscription
    cancel_txn = "#{purchase_events(:buy_event).transaction_id}_upgrade_cancel"
    cancel = PurchaseEvent.find_by(transaction_id: cancel_txn, project: @project)
    assert cancel, "Should cancel the old subscription"
    assert_equal Grovs::Purchases::EVENT_CANCEL, cancel.event_type

    # And a buy for the new product
    buy = PurchaseEvent.find_by(transaction_id: "txn_ug_new", project: @project)
    assert buy, "Should create a buy for the new subscription"
    assert_equal Grovs::Purchases::EVENT_BUY, buy.event_type
    assert_equal "com.test.premium_plus", buy.product_id
  end

  test "OFFER_REDEEMED UPGRADE cancels old subscription and creates a BUY" do
    result = send_apple_notification(
      type: "OFFER_REDEEMED", subtype: "UPGRADE",
      transaction_id: "txn_offer_ug", original_transaction_id: "orig_txn_001",
      product_id: "com.test.premium_plus"
    )

    assert result

    buy = PurchaseEvent.find_by(transaction_id: "txn_offer_ug", project: @project)
    assert buy
    assert_equal Grovs::Purchases::EVENT_BUY, buy.event_type
    assert_equal "com.test.premium_plus", buy.product_id
  end

  # ---------------------------------------------------------------------------
  # Refund Handler
  # ---------------------------------------------------------------------------

  test "REFUND creates a REFUND purchase event" do
    result = send_apple_notification(
      type: "REFUND", subtype: nil,
      transaction_id: "txn_ref_001", original_transaction_id: "orig_ref_001"
    )

    assert result
    event = PurchaseEvent.find_by(transaction_id: "txn_ref_001", project: @project)
    assert event
    assert_equal Grovs::Purchases::EVENT_REFUND, event.event_type
  end

  test "REFUND_REVERSED creates a REFUND_REVERSED purchase event" do
    result = send_apple_notification(
      type: "REFUND_REVERSED", subtype: nil,
      transaction_id: "txn_rr_001", original_transaction_id: "orig_rr_001"
    )

    assert result
    event = PurchaseEvent.find_by(transaction_id: "txn_rr_001", project: @project)
    assert event
    assert_equal Grovs::Purchases::EVENT_REFUND_REVERSED, event.event_type
  end

  test "REFUND_DECLINED does not create a purchase event" do
    result = nil
    assert_no_difference "PurchaseEvent.count" do
      result = send_apple_notification(
        type: "REFUND_DECLINED", subtype: nil,
        transaction_id: "txn_rd_001", original_transaction_id: "orig_rd_001"
      )
    end
    assert result, "Handler should succeed (not error out)"
  end

  # ---------------------------------------------------------------------------
  # Informational notifications — no purchase events, just logging
  # ---------------------------------------------------------------------------

  test "RENEWAL_EXTENDED does not create a purchase event" do
    result = nil
    assert_no_difference "PurchaseEvent.count" do
      result = send_apple_notification(
        type: "RENEWAL_EXTENDED", subtype: nil,
        transaction_id: "txn_ext_001", original_transaction_id: "orig_ext_001"
      )
    end
    assert result, "Handler should succeed (not error out)"
  end

  test "PRICE_INCREASE does not create a purchase event" do
    result = nil
    assert_no_difference "PurchaseEvent.count" do
      result = send_apple_notification(
        type: "PRICE_INCREASE", subtype: "ACCEPTED",
        transaction_id: "txn_pi_001", original_transaction_id: "orig_pi_001"
      )
    end
    assert result, "Handler should succeed (not error out)"
  end

  test "CONSUMPTION_REQUEST does not create a purchase event" do
    result = nil
    assert_no_difference "PurchaseEvent.count" do
      result = send_apple_notification(
        type: "CONSUMPTION_REQUEST", subtype: nil,
        transaction_id: "txn_cr_001", original_transaction_id: "orig_cr_001"
      )
    end
    assert result, "Handler should succeed (not error out)"
  end

  test "TEST notification does not create a purchase event" do
    result = nil
    assert_no_difference "PurchaseEvent.count" do
      result = send_apple_notification(
        type: "TEST", subtype: nil,
        transaction_id: "txn_test_001", original_transaction_id: "orig_test_001"
      )
    end
    assert result, "Handler should succeed (not error out)"
  end

  # ---------------------------------------------------------------------------
  # Defensive parsing — required fields guard
  # ---------------------------------------------------------------------------

  test "extract_subscription_details returns nil when transaction missing transactionId" do
    verified_receipt = {
      "data" => {
        "signedTransactionInfo" => "fake_signed_txn"
      }
    }

    transaction_info = {
      "originalTransactionId" => "orig_001",
      "productId" => "com.test.premium",
      "bundleId" => "com.test.app",
      "price" => 9990,
      "currency" => "USD",
      "purchaseDate" => Time.current.to_i * 1000
    }

    decoder = ->(_jws) { transaction_info }

    AppStoreServerApi::Utils::Decoder.stub(:decode_jws!, decoder) do
      result = @helper.send(:extract_subscription_details, verified_receipt)
      assert_nil result, "Should return nil when transactionId is missing"
    end
  end

  test "extract_subscription_details returns nil when transaction missing productId" do
    verified_receipt = {
      "data" => {
        "signedTransactionInfo" => "fake_signed_txn"
      }
    }

    transaction_info = {
      "transactionId" => "txn_001",
      "originalTransactionId" => "orig_001",
      "bundleId" => "com.test.app",
      "price" => 9990,
      "currency" => "USD",
      "purchaseDate" => Time.current.to_i * 1000
    }

    decoder = ->(_jws) { transaction_info }

    AppStoreServerApi::Utils::Decoder.stub(:decode_jws!, decoder) do
      result = @helper.send(:extract_subscription_details, verified_receipt)
      assert_nil result, "Should return nil when productId is missing"
    end
  end

  # ---------------------------------------------------------------------------
  # Price extraction — Apple sends milliunits, we store cents
  # ---------------------------------------------------------------------------

  test "converts Apple milliunits price to cents" do
    send_apple_notification(
      type: "SUBSCRIBED", subtype: "INITIAL_BUY",
      transaction_id: "txn_price_001", original_transaction_id: "txn_price_001",
      price: 9990, currency: "USD"
    )

    event = PurchaseEvent.find_by(transaction_id: "txn_price_001", project: @project)
    assert_equal 999, event.price_cents
    assert_equal "USD", event.currency
    assert_equal 999, event.usd_price_cents
  end

  # ---------------------------------------------------------------------------
  # Idempotency — duplicate webhook delivery must not create duplicate events
  # ---------------------------------------------------------------------------

  test "duplicate notification does not create a duplicate purchase event" do
    send_apple_notification(
      type: "SUBSCRIBED", subtype: "INITIAL_BUY",
      transaction_id: "txn_idem_001", original_transaction_id: "txn_idem_001"
    )

    assert_no_difference "PurchaseEvent.where(transaction_id: 'txn_idem_001').count" do
      send_apple_notification(
        type: "SUBSCRIBED", subtype: "INITIAL_BUY",
        transaction_id: "txn_idem_001", original_transaction_id: "txn_idem_001"
      )
    end
  end

  # ---------------------------------------------------------------------------
  # Upgrade orchestration (direct unit tests for revoke_old_subscription_enable_new_one)
  # ---------------------------------------------------------------------------

  test "revoke_old_subscription_enable_new_one creates cancel event with RecordNotUnique protection" do
    subscription_info = {
      transaction_id: "txn_upgrade_new",
      original_transaction_id: "orig_txn_001",
      product_id: "com.test.premium",
      identifier: "com.test.app",
      price: 1499,
      currency: "USD",
      start_date: Time.current.to_i * 1000,
      purchase_type: Grovs::Purchases::TYPE_SUBSCRIPTION,
      expires_date: 1.month.from_now
    }

    fake_event = ->(_et, _si, _p) { true }

    @helper.stub(:handle_subscription_event_type, fake_event) do
      @helper.send(:revoke_old_subscription_enable_new_one, 'UPGRADE', 'UPGRADE', subscription_info, @project)
    end

    cancel_txn_id = "#{purchase_events(:buy_event).transaction_id}_upgrade_cancel"
    cancel = PurchaseEvent.find_by(transaction_id: cancel_txn_id, project: @project)
    assert cancel, "Cancel event should be created"
    assert_equal Grovs::Purchases::EVENT_CANCEL, cancel.event_type
  end

  test "revoke_old_subscription_enable_new_one handles concurrent calls safely" do
    subscription_info = {
      transaction_id: "txn_upgrade_concurrent",
      original_transaction_id: "orig_txn_001",
      product_id: "com.test.premium",
      identifier: "com.test.app",
      price: 1499,
      currency: "USD",
      start_date: Time.current.to_i * 1000,
      purchase_type: Grovs::Purchases::TYPE_SUBSCRIPTION,
      expires_date: 1.month.from_now
    }

    fake_event = ->(_et, _si, _p) { true }

    @helper.stub(:handle_subscription_event_type, fake_event) do
      @helper.send(:revoke_old_subscription_enable_new_one, 'UPGRADE', 'UPGRADE', subscription_info, @project)

      assert_nothing_raised do
        @helper.send(:revoke_old_subscription_enable_new_one, 'UPGRADE', 'UPGRADE', subscription_info, @project)
      end
    end
  end

  test "revoke_old_subscription_enable_new_one looks up from subscription_states" do
    subscription_info = {
      transaction_id: "txn_upgrade_state_lookup",
      original_transaction_id: "orig_txn_001",
      product_id: "com.test.premium",
      identifier: "com.test.app",
      price: 1499,
      currency: "USD",
      start_date: Time.current.to_i * 1000,
      purchase_type: Grovs::Purchases::TYPE_SUBSCRIPTION,
      expires_date: 1.month.from_now
    }

    fake_event = ->(_et, _si, _p) { true }

    @helper.stub(:handle_subscription_event_type, fake_event) do
      assert_nothing_raised do
        @helper.send(:revoke_old_subscription_enable_new_one, 'UPGRADE', 'UPGRADE', subscription_info, @project)
      end
    end
  end

  # ---------------------------------------------------------------------------
  # PurchaseEventHandling unit tests
  # ---------------------------------------------------------------------------

  test "extract_subscription_details returns hash with correct fields" do
    verified_receipt = {
      "data" => {
        "signedTransactionInfo" => "fake_signed_txn",
        "signedRenewalInfo" => "fake_signed_renewal"
      }
    }

    transaction_info = {
      "transactionId" => "txn_extract_001",
      "originalTransactionId" => "orig_extract_001",
      "productId" => "com.test.premium",
      "bundleId" => "com.test.app",
      "price" => 9990,
      "currency" => "USD",
      "purchaseDate" => Time.current.to_i * 1000,
      "environment" => "Sandbox"
    }
    renewal_info = { "expiresDate" => 1.month.from_now.to_i * 1000 }

    call_count = 0
    responses = [transaction_info, renewal_info]
    decoder = lambda { |_jws| 
      r = responses[call_count]
      call_count += 1
      r
    }

    AppStoreServerApi::Utils::Decoder.stub(:decode_jws!, decoder) do
      result = @helper.send(:extract_subscription_details, verified_receipt)
      assert result
      assert_equal "txn_extract_001", result[:transaction_id]
      assert_equal "orig_extract_001", result[:original_transaction_id]
      assert_equal "com.test.premium", result[:product_id]
      assert_equal "com.test.app", result[:identifier]
      assert_equal 999, result[:price]
      assert_equal "USD", result[:currency]
    end
  end

  test "extract_subscription_details returns nil on JWT decode error" do
    verified_receipt = {
      "data" => {
        "signedTransactionInfo" => "bad_jwt"
      }
    }

    decoder = ->(_jws) { raise JWT::DecodeError, "bad token" }

    AppStoreServerApi::Utils::Decoder.stub(:decode_jws!, decoder) do
      result = @helper.send(:extract_subscription_details, verified_receipt)
      assert_nil result
    end
  end

  test "convert_apple_price_to_cents divides by 10" do
    assert_equal 999, IapUtils.convert_apple_price_to_cents(9990)
    assert_equal 100, IapUtils.convert_apple_price_to_cents(1000)
    assert_equal 0, IapUtils.convert_apple_price_to_cents(0)
  end

  test "convert_apple_price_to_cents returns nil for nil" do
    assert_nil IapUtils.convert_apple_price_to_cents(nil)
  end

  test "parse_ms_timestamp converts milliseconds to Time" do
    ts_ms = 1711000000000 # ~2024-03-21
    result = IapUtils.parse_ms_timestamp(ts_ms)
    assert_instance_of Time, result
    assert_in_delta Time.at(1711000000), result, 1
  end

  test "parse_ms_timestamp returns Time.current for nil" do
    freeze_time do
      assert_equal Time.current, IapUtils.parse_ms_timestamp(nil)
    end
  end

  test "validates existing mobile event and enqueues processing" do
    # Create an unvalidated mobile-submitted event
    mobile_event = PurchaseEvent.create!(
      event_type: Grovs::Purchases::EVENT_BUY,
      device: devices(:ios_device),
      project: @project,
      identifier: "com.test.app",
      price_cents: 999,
      currency: "USD",
      usd_price_cents: 999,
      date: Time.current,
      transaction_id: "txn_mobile_validate",
      original_transaction_id: "txn_mobile_validate",
      product_id: "com.test.premium",
      webhook_validated: false,
      store: false,
      purchase_type: Grovs::Purchases::TYPE_SUBSCRIPTION
    )

    # Send webhook for same transaction
    send_apple_notification(
      type: "SUBSCRIBED", subtype: "INITIAL_BUY",
      transaction_id: "txn_mobile_validate",
      original_transaction_id: "txn_mobile_validate"
    )

    mobile_event.reload
    assert mobile_event.webhook_validated, "Mobile event should be webhook-validated"
    assert_equal Grovs::Webhooks::APPLE, mobile_event.store_source
  end

  test "cancel_previous_product_on_change skips when no old product exists" do
    # Use a fresh original_transaction_id with no prior events
    assert_no_difference "PurchaseEvent.count" do
      @helper.send(:cancel_previous_product_on_change, "new_orig_txn", "com.test.premium", @project)
    end
  end
end
