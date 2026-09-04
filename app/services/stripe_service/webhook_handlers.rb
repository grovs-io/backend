module StripeService::WebhookHandlers
  extend ActiveSupport::Concern

  private

  def handle_subscription_started(event)
    subscription_id = event[:data][:object][:subscription]
    customer_id = event[:data][:object][:customer]
    instance_id = event[:data][:object][:client_reference_id]

    payment_intent = StripePaymentIntent.where(instance_id: instance_id).order(id: :desc).first
    unless payment_intent
      Rails.logger.error("No payment intent found for instance #{instance_id}")
      return
    end

    instance = payment_intent.instance

    # Create the subscription
    StripeSubscription.create!(instance_id: instance.id,
        stripe_payment_intent_id: payment_intent.id,
        subscription_id: subscription_id,
        product_type: payment_intent.product_type,
        active: false,
        status: "pending",
        customer_id: customer_id
    )
  end

  def handle_subscription_created(event)
    subscription_id = event[:data][:object][:id]
    status = event[:data][:object][:status]
    trial_end = event[:data][:object][:trial_end]
    subscription_item_id = event[:data][:object][:items][:data][0][:id]

    subscription = StripeSubscription.find_by(subscription_id: subscription_id)
    unless subscription
      # Could not find this subscription
      return
    end

    instance = Instance.find_by(id: subscription.instance_id)
    unless instance
      # The user does not exist
      return
    end

    # Don't enable until the first charge settles: incomplete/incomplete_expired stay off.
    enabled = %w[active trialing].include?(status)
    subscription.active = enabled
    subscription.status = status
    subscription.subscription_item_id = subscription_item_id
    subscription.save!

    mark_project_enabled(instance, enabled)
  end

  def handle_subscription_continued(event)
    # Do nothing for now
  end

  def handle_subscription_payment_fail(event)
    subscription_id = event[:data][:object][:subscription]
    customer_id = event[:data][:object][:customer]

    subscription = StripeSubscription.find_by(customer_id: customer_id)
    if subscription
      subscription.active = false
      subscription.status = "payment_failed"
      subscription.save!

      instance = subscription.instance
      if instance
        # Disable planka access
        mark_project_enabled(instance, false)
      end
    end
  end

  def handle_subscription_updated(event)
    subscription_id = event[:data][:object][:id]
    customer_id = event[:data][:object][:customer]

    cancel_at = event[:data][:object][:cancel_at]
    cancel_at_period_end = event[:data][:object][:cancel_at_period_end]
    canceled_at = event[:data][:object][:canceled_at]

    trial_end = event[:data][:object][:trial_end]
    status = event[:data][:object][:status]

    subscription = StripeSubscription.find_by(subscription_id: subscription_id)
    unless subscription
      # Could not find this subscription
      return
    end

    instance = subscription.instance
    unless instance
      # The project does not exist
      return
    end

    if status == "canceled" || cancel_at || canceled_at || cancel_at_period_end
      if status == "canceled"
        # Effective cancellation: immediate cancel, or the period-end subscription.deleted event.
        subscription.active = false
        subscription.status = "canceled"
        subscription.cancels_at ||= DateTime.now
        subscription.save!

        mark_project_enabled(instance, false)
      else
        # Scheduled cancel — paid through the period; subscription.deleted does the actual cutoff.
        subscription.cancels_at = Time.at(cancel_at).to_datetime if cancel_at
        subscription.save!
      end

      return
    end

    paused_collection = event[:data][:object][:pause_collection]
    paused_collection_hash = paused_collection.to_h.symbolize_keys

    if paused_collection && paused_collection_hash.key?(:behavior)
      # Subscription is paused
      subscription.active = false
      subscription.status = "paused"
      subscription.save!
      mark_project_enabled(instance, false)

      return
    end

    if trial_end && status == "trialing"
      # Currently on trial
      subscription.active = true
      subscription.status = "trialing"
      subscription.save!

      mark_project_enabled(instance, true)
      return
    end

    # Only a paying status keeps service on; dunning states must disable, not re-enable.
    enabled = %w[active trialing].include?(status)
    subscription.active = enabled
    subscription.status = status || (enabled ? "active" : "inactive")
    subscription.save!
    mark_project_enabled(instance, enabled)
  end

  def mark_project_enabled(instance, enabled)
    if enabled
      instance.quota_exceeded = false
      instance.save!

      return
    end

    current_usage = project_helper.current_mau(instance)
    if current_usage > Grovs.free_mau_count
      instance.quota_exceeded = true
    else
      instance.quota_exceeded = false
    end
    instance.save!
  rescue ProjectService::MauReadUnavailable => e
    # Skip (quota untouched, self-corrects in 10 min) — raising would 500 the Stripe webhook.
    Rails.logger.error("clickhouse.mau.read_failed instance=#{instance.id} — subscription-change quota pass skipped: #{e.message}")
  end

  # Lazy default; tests inject the ivar (a bare @project_helper was nil in production).
  def project_helper
    @project_helper ||= ProjectService.new
  end

  # Discounts
  def apply_discounts(subscription, quantity)
    # Apply discounts if needed
    if quantity >= ENV['SECOND_DISCOUNT_MAUS_THRESHOLD'].to_i
      create_and_apply_coupon(subscription, ENV['SECOND_DISCOUNT_PERCENTAGE'].to_i)
    elsif quantity >= ENV['FIRST_DISCOUNT_MAUS_THRESHOLD'].to_i
      create_and_apply_coupon(subscription, ENV['FIRST_DISCOUNT_PERCENTAGE'].to_i)
    elsif quantity >= Grovs.free_mau_count
      apply_first_10_k_maus_coupon(subscription)
    else
      # No discount
      remove_coupon(subscription)
    end
  end

  # Removes any active coupon from the subscription
  def remove_coupon(subscription)
    # Removes the coupon from the subscription
    Stripe::Subscription.delete_discount(subscription.subscription_id)
  rescue Stripe::StripeError => e
    Rails.logger.error("Error removing coupon: #{e.message}")
  end

  # Creates a coupon in Stripe
  def create_coupon(percent_off: nil, amount_off: nil, duration: 'once')
    # Validate input
    if percent_off.nil? && amount_off.nil?
      raise "You must provide either percent_off or amount_off"
    end

    coupon_params = { duration: duration }

    if percent_off
      coupon_params[:percent_off] = percent_off
    elsif amount_off
      coupon_params[:amount_off] = (amount_off.to_d * 100).round # convert dollars to cents
      coupon_params[:currency] = 'usd'
    end

    Stripe::Coupon.create(coupon_params)
  rescue Stripe::StripeError => e
    Rails.logger.error("Error creating coupon: #{e.message}")
    nil
  end

  def create_and_apply_coupon(subscription, discount_amount)
    # Remove coupon
    remove_coupon(subscription)

    # Create the coupon (percent off, applied once)
    coupon = create_coupon(percent_off: discount_amount)

    # If coupon creation was successful, apply it to the subscription
    if coupon
      apply_coupon(subscription, coupon.id)
      Rails.logger.info("Coupon with #{discount_amount}% discount applied successfully to subscription #{subscription.subscription_id}")
    else
      Rails.logger.error("Failed to create coupon for #{discount_amount}% discount.")
    end
  end

  def apply_first_10_k_maus_coupon(subscription)
    # Remove coupon
    remove_coupon(subscription)

    # Create the coupon (percent off, applied once)
    coupon = create_coupon(amount_off: 19.99)

    # If coupon creation was successful, apply it to the subscription
    if coupon
      apply_coupon(subscription, coupon.id)
      Rails.logger.info("Coupon with 19.99 discount applied successfully to subscription #{subscription.subscription_id}")
    else
      Rails.logger.error("Failed to create coupon for $19.99 discount.")
    end
  end

  def apply_coupon(subscription, coupon_id)
    Stripe::Subscription.update(
        subscription.subscription_id,
        { coupon: coupon_id }
    )
  rescue Stripe::StripeError => e
    Rails.logger.error("Error applying coupon: #{e.message}")
  end
end
