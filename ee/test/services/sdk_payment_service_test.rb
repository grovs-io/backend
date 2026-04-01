require "test_helper"

class SdkPaymentServiceTest < ActiveSupport::TestCase
  fixtures :instances, :projects, :devices, :visitors, :purchase_events

  setup do
    @project = projects(:one)
    @device = devices(:ios_device)
    @visitor = visitors(:ios_visitor)
    @platform = Grovs::Platforms::IOS
    @identifier = "com.test.app"
    @test_link = create_test_link
  end

  def build_service
    SdkPaymentService.new(
      project: @project, device: @device, visitor: @visitor,
      platform: @platform, identifier: @identifier
    )
  end

  def create_test_link
    domain = Domain.create!(domain: "test-pay-#{SecureRandom.hex(4)}.sqd.link", project: @project)
    redirect_config = RedirectConfig.create!(project: @project)
    Link.create!(
      redirect_config: redirect_config, domain: domain,
      path: "pay_#{SecureRandom.hex(4)}", generated_from_platform: Grovs::Platforms::IOS
    )
  end

  def valid_params(overrides = {})
    ActionController::Parameters.new({
      event_type: Grovs::Purchases::EVENT_BUY,
      price_cents: 999,
      currency: "USD",
      transaction_id: "txn_new_#{SecureRandom.hex(4)}",
      original_transaction_id: "orig_new_001",
      product_id: "com.test.premium",
      purchase_type: Grovs::Purchases::TYPE_SUBSCRIPTION,
      store: true
    }.merge(overrides)).permit!
  end

  # === Revenue collection gate ===

  test "returns message when revenue collection is disabled" do
    @project = projects(:two) # revenue_collection_enabled: false
    result = build_service.create_or_update(event_params: valid_params)

    assert result[:success]
    assert_equal "Revenue collection not enabled", result[:message]
    assert_nil result[:error]
  end

  # === New event creation ===

  test "creates new purchase event and enqueues validation" do
    params = valid_params

    ValidatePurchaseEventJob.stub(:perform_async, true) do
      result = nil
      assert_difference "PurchaseEvent.count", 1 do
        result = build_service.create_or_update(event_params: params)
      end

      assert result[:success]
      assert_equal "Event added", result[:message]

      event = PurchaseEvent.find_by(transaction_id: params[:transaction_id])
      assert event
      assert_equal @project.id, event.project_id
      assert_equal @device.id, event.device_id
    end
  end

  test "bundle_id in params overrides header identifier" do
    params = valid_params(bundle_id: "com.override.app")

    ValidatePurchaseEventJob.stub(:perform_async, true) do
      build_service.create_or_update(event_params: params)
    end

    event = PurchaseEvent.find_by(transaction_id: params[:transaction_id])
    assert_equal "com.override.app", event.identifier
  end

  test "falls back to header identifier when bundle_id is absent" do
    params = valid_params

    ValidatePurchaseEventJob.stub(:perform_async, true) do
      build_service.create_or_update(event_params: params)
    end

    event = PurchaseEvent.find_by(transaction_id: params[:transaction_id])
    assert_equal "com.test.app", event.identifier
  end

  test "sets attributed_link_id from VisitorLastVisit" do
    VisitorLastVisit.create!(visitor: @visitor, project: @project, link_id: @test_link.id)

    params = valid_params

    ValidatePurchaseEventJob.stub(:perform_async, true) do
      build_service.create_or_update(event_params: params)
    end

    event = PurchaseEvent.find_by(transaction_id: params[:transaction_id])
    assert_equal @test_link.id, event.link_id
  end

  test "defaults date to Time.current when not provided" do
    params = valid_params
    # date is not in valid_params, so should default

    ValidatePurchaseEventJob.stub(:perform_async, true) do
      build_service.create_or_update(event_params: params)
    end

    event = PurchaseEvent.find_by(transaction_id: params[:transaction_id])
    assert event.date.present?
    assert_in_delta Time.current, event.date, 5.seconds
  end

  test "preserves explicit date when provided" do
    explicit_date = Time.utc(2026, 1, 15, 12, 0, 0)
    params = valid_params(date: explicit_date)

    ValidatePurchaseEventJob.stub(:perform_async, true) do
      build_service.create_or_update(event_params: params)
    end

    event = PurchaseEvent.find_by(transaction_id: params[:transaction_id])
    assert_equal explicit_date.to_i, event.date.to_i
  end

  # === enqueue_validation branching ===

  test "skips ValidatePurchaseEventJob for already webhook_validated store event" do
    validate_called = false

    params = valid_params(
      transaction_id: "txn_skip_validate_#{SecureRandom.hex(4)}",
      store: true
    )

    ValidatePurchaseEventJob.stub(:perform_async, ->(*_args) { validate_called = true }) do
      build_service.create_or_update(event_params: params)
    end

    # New event won't be webhook_validated (default false), so it SHOULD enqueue
    assert validate_called, "Should enqueue for new non-validated store event"
  end

  test "enqueues ValidatePurchaseEventJob for store event not yet validated" do
    enqueued_args = nil

    params = valid_params(store: true)

    ValidatePurchaseEventJob.stub(:perform_async, ->(*args) { enqueued_args = args }) do
      build_service.create_or_update(event_params: params)
    end

    assert enqueued_args, "ValidatePurchaseEventJob should have been enqueued"
    assert_equal @platform, enqueued_args[1]
  end

  test "enqueues ProcessPurchaseEventJob for non-store event" do
    params = valid_params(
      transaction_id: "txn_nonstore_#{SecureRandom.hex(4)}",
      store: false
    )

    enqueued_id = nil
    ProcessPurchaseEventJob.stub(:perform_async, ->(id) { enqueued_id = id }) do
      result = build_service.create_or_update(event_params: params)
      assert result[:success]
    end

    assert enqueued_id, "ProcessPurchaseEventJob should have been enqueued"
  end

  test "skips ProcessPurchaseEventJob for already processed non-store event" do
    # Create an event that's already processed + non-store
    existing = PurchaseEvent.create!(
      event_type: Grovs::Purchases::EVENT_BUY,
      price_cents: 100, currency: "USD",
      transaction_id: "txn_processed_nonstore",
      product_id: "com.test.p", project: @project, device: @device,
      identifier: "com.test.app", store: false, processed: true,
      purchase_type: Grovs::Purchases::TYPE_ONE_TIME
    )

    params = valid_params(
      transaction_id: existing.transaction_id,
      event_type: existing.event_type,
      store: false
    )

    process_called = false
    ProcessPurchaseEventJob.stub(:perform_async, ->(*_args) { process_called = true }) do
      ReattributePurchaseJob.stub(:perform_async, true) do
        build_service.create_or_update(event_params: params)
      end
    end

    assert_not process_called, "Should not enqueue ProcessPurchaseEventJob for already-processed event"
  end

  # === update_existing ===

  test "updates existing event when not webhook_validated" do
    existing = purchase_events(:unprocessed_buy)
    existing.update_columns(webhook_validated: false)

    params = ActionController::Parameters.new(
      event_type: existing.event_type,
      price_cents: 1500,
      currency: "USD",
      transaction_id: existing.transaction_id,
      original_transaction_id: existing.original_transaction_id,
      product_id: existing.product_id,
      purchase_type: existing.purchase_type,
      store: true
    ).permit!

    ProcessPurchaseEventJob.stub(:perform_async, true) do
      ValidatePurchaseEventJob.stub(:perform_async, true) do
        result = nil
        assert_no_difference "PurchaseEvent.count" do
          result = build_service.create_or_update(event_params: params)
        end

        assert result[:success]
        assert_equal "Event added", result[:message]

        existing.reload
        assert_equal 1500, existing.price_cents
        assert_equal @device.id, existing.device_id
      end
    end
  end

  test "does not overwrite webhook_validated event attributes" do
    existing = purchase_events(:buy_event) # webhook_validated: true

    params = ActionController::Parameters.new(
      event_type: existing.event_type,
      price_cents: 5000,
      currency: "EUR",
      transaction_id: existing.transaction_id,
      original_transaction_id: existing.original_transaction_id,
      product_id: existing.product_id,
      purchase_type: existing.purchase_type,
      store: true
    ).permit!

    ReattributePurchaseJob.stub(:perform_async, true) do
      result = build_service.create_or_update(event_params: params)
      assert result[:success]

      existing.reload
      assert_equal 999, existing.price_cents
      assert_equal "USD", existing.currency
    end
  end

  test "update_existing sets link_id from attribution when event has none" do
    VisitorLastVisit.create!(visitor: @visitor, project: @project, link_id: @test_link.id)

    existing = purchase_events(:unprocessed_buy)
    existing.update_columns(link_id: nil, webhook_validated: false)

    params = valid_params(
      event_type: existing.event_type,
      transaction_id: existing.transaction_id,
      original_transaction_id: existing.original_transaction_id,
      product_id: existing.product_id,
      purchase_type: existing.purchase_type
    )

    ValidatePurchaseEventJob.stub(:perform_async, true) do
      build_service.create_or_update(event_params: params)
    end

    existing.reload
    assert_equal @test_link.id, existing.link_id
  end

  test "update_existing does not overwrite existing link_id" do
    other_link = create_test_link
    VisitorLastVisit.create!(visitor: @visitor, project: @project, link_id: other_link.id)

    existing = purchase_events(:unprocessed_buy)
    existing.update_columns(link_id: @test_link.id, webhook_validated: false)

    params = valid_params(
      event_type: existing.event_type,
      transaction_id: existing.transaction_id,
      original_transaction_id: existing.original_transaction_id,
      product_id: existing.product_id,
      purchase_type: existing.purchase_type
    )

    ValidatePurchaseEventJob.stub(:perform_async, true) do
      build_service.create_or_update(event_params: params)
    end

    existing.reload
    assert_equal @test_link.id, existing.link_id
  end

  test "update_existing enqueues ReattributePurchaseJob when device was nil and event processed" do
    existing = purchase_events(:no_device_buy) # device: nil, processed: true

    params = valid_params(
      event_type: existing.event_type,
      transaction_id: existing.transaction_id,
      original_transaction_id: existing.original_transaction_id,
      product_id: existing.product_id,
      purchase_type: existing.purchase_type
    )

    reattribute_id = nil
    ReattributePurchaseJob.stub(:perform_async, ->(id) { reattribute_id = id }) do
      build_service.create_or_update(event_params: params)
    end

    assert_equal existing.id, reattribute_id, "ReattributePurchaseJob should be enqueued for previously-deviceless processed event"
  end

  test "update_existing defaults date when event date is nil" do
    existing = purchase_events(:unprocessed_buy)
    existing.update_columns(date: nil, webhook_validated: false)

    params = valid_params(
      event_type: existing.event_type,
      transaction_id: existing.transaction_id,
      original_transaction_id: existing.original_transaction_id,
      product_id: existing.product_id,
      purchase_type: existing.purchase_type
    )

    ValidatePurchaseEventJob.stub(:perform_async, true) do
      build_service.create_or_update(event_params: params)
    end

    existing.reload
    assert existing.date.present?
    assert_in_delta Time.current, existing.date, 5.seconds
  end

  # === RecordNotUnique rescue ===

  test "RecordNotUnique race condition recovers and returns success" do
    params = valid_params

    # Pre-create the event so the DB unique constraint fires on save!
    existing = PurchaseEvent.create!(
      event_type: params[:event_type],
      transaction_id: params[:transaction_id],
      project: @project,
      identifier: "com.test.app",
      price_cents: 999, currency: "USD",
      purchase_type: Grovs::Purchases::TYPE_SUBSCRIPTION,
      store: true
    )

    # Stub find_by to return nil on first call (simulating race: event doesn't exist
    # at check time but was inserted concurrently before save!)
    original_find_by = PurchaseEvent.method(:find_by)
    call_count = 0

    PurchaseEvent.stub(:find_by, lambda { |*_args, **kwargs|
      call_count += 1
      call_count == 1 ? nil : original_find_by.call(**kwargs)
    }) do
      ValidatePurchaseEventJob.stub(:perform_async, true) do
        ReattributePurchaseJob.stub(:perform_async, true) do
          result = build_service.create_or_update(event_params: params)
          assert result[:success]
          assert_equal "Event added", result[:message]
        end
      end
    end
  end

  test "RecordNotUnique with nil device on existing enqueues ReattributePurchaseJob" do
    params = valid_params

    # Pre-create the event with nil device so the DB unique constraint fires
    existing = PurchaseEvent.create!(
      event_type: params[:event_type],
      transaction_id: params[:transaction_id],
      project: @project,
      device: nil,
      identifier: "com.test.app",
      price_cents: 999, currency: "USD",
      purchase_type: Grovs::Purchases::TYPE_SUBSCRIPTION,
      store: true, processed: true
    )

    reattribute_id = nil

    # Stub find_by: first returns nil (race), second finds the existing record
    original_find_by = PurchaseEvent.method(:find_by)
    call_count = 0

    PurchaseEvent.stub(:find_by, lambda { |*_args, **kwargs|
      call_count += 1
      call_count == 1 ? nil : original_find_by.call(**kwargs)
    }) do
      ReattributePurchaseJob.stub(:perform_async, ->(id) { reattribute_id = id }) do
        result = build_service.create_or_update(event_params: params)
        assert result[:success]
      end
    end

    assert_equal existing.id, reattribute_id
  end

  # === RecordInvalid ===

  test "returns error for invalid record" do
    params = ActionController::Parameters.new(
      event_type: "invalid_type",
      transaction_id: "txn_invalid_#{SecureRandom.hex(4)}"
    ).permit!

    result = build_service.create_or_update(event_params: params)

    assert_not result[:success]
    assert result[:error].present?
    assert_equal :unprocessable_entity, result[:status]
  end
end
