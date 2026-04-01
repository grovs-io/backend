class SdkPaymentService
  def initialize(project:, device:, visitor:, platform:, identifier:)
    @project = project
    @device = device
    @visitor = visitor
    @platform = platform
    @identifier = identifier
  end

  # Returns { success: true, message: "..." } or { success: false, error: "...", status: :symbol }
  def create_or_update(event_params:)
    unless @project.instance&.revenue_collection_enabled?
      return { success: true, message: "Revenue collection not enabled" }
    end

    identifier = event_params[:bundle_id] || @identifier

    attributed_link_id = VisitorLastVisit.find_by(
      visitor_id: @visitor.id, project_id: @project.id
    )&.link_id

    new_event = PurchaseEvent.new(event_params.except(:bundle_id))
    new_event.identifier = identifier
    new_event.date ||= Time.current

    old_event = PurchaseEvent.find_by(
      transaction_id: new_event.transaction_id,
      event_type: new_event.event_type,
      project_id: @project.id
    )

    if old_event
      update_existing(old_event, identifier, attributed_link_id, event_params)
      return { success: true, message: "Event added" }
    end

    new_event.project = @project
    new_event.device = @device
    new_event.link_id = attributed_link_id

    new_event.save!
    new_event.reload

    Rails.logger.info(
      "add_payment_event: saved event #{new_event.id} | type=#{new_event.event_type} " \
      "product_id=#{new_event.product_id} price_cents=#{new_event.price_cents} " \
      "usd_price_cents=#{new_event.usd_price_cents} currency=#{new_event.currency} " \
      "store=#{new_event.store} webhook_validated=#{new_event.webhook_validated} " \
      "project_id=#{new_event.project_id} date=#{new_event.date}"
    )

    enqueue_validation(new_event)

    { success: true, message: "Event added" }
  rescue ActiveRecord::RecordNotUnique
    existing = PurchaseEvent.find_by(
      transaction_id: new_event.transaction_id,
      event_type: new_event.event_type,
      project_id: @project.id
    )
    if existing
      backfill_and_enqueue(existing, attributed_link_id)
    end
    { success: true, message: "Event added" }
  rescue ActiveRecord::RecordInvalid => e
    { success: false, error: e.message, status: :unprocessable_entity }
  end

  private

  def update_existing(event, identifier, attributed_link_id, event_params)
    unless event.webhook_validated?
      event.assign_attributes(event_params.except(:bundle_id).to_h.compact)
      event.identifier = identifier
    end
    event.date ||= Time.current
    event.project = @project

    device_was_nil = event.device_id.nil?
    event.device = @device
    backfill_and_enqueue(event, attributed_link_id, device_was_nil)
  end

  def backfill_and_enqueue(event, attributed_link_id, device_was_nil = event.device_id.nil?)
    event.device ||= @device
    event.link_id ||= attributed_link_id
    event.save!

    if event.processed? && device_was_nil && event.device_id.present?
      ReattributePurchaseJob.perform_async(event.id)
    else
      enqueue_validation(event)
    end
  end

  def enqueue_validation(event)
    if event.store?
      return if event.webhook_validated?
      ValidatePurchaseEventJob.perform_async(event.id, @platform)
    else
      ProcessPurchaseEventJob.perform_async(event.id) unless event.processed?
    end
  end
end
