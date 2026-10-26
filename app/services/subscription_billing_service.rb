class SubscriptionBillingService
  ENDED_STATUSES = %w[canceled incomplete_expired].freeze

  def initialize(instance:, project_service: nil)
    @instance = instance
    @project_service = project_service || ProjectService.new
  end

  # Returns { client_secret: }; raises ArgumentError, UnknownPlan or CheckoutAlreadyCompleted.
  def create_checkout_session(user:, plan:, interval:)
    price_id = Billing::Plans.price(plan, interval)

    @instance.with_lock do
      raise ArgumentError, "This project is already subscribed" if subscribed_or_unresolved?

      StripeService.expire_open_checkout_sessions(@instance)
      session = StripeService.create_checkout_session_for_product(price_id, user, plan, @instance)
      { client_secret: session[:client_secret] }
    end
  end

  # Returns { url: String } — Stripe billing portal URL.
  def portal_url
    url = StripeService.generate_portal_link(@instance)
    { url: url }
  end

  # Cancels Stripe subscription. Returns result hash or nil if no subscription.
  def cancel_subscription
    subscription = @instance.subscription
    return nil unless subscription

    result = StripeService.cancel_subscription(subscription)
    apply_flat_update(subscription, result)
    result
  end

  # Resumes a flat plan's pending cancellation. Returns result hash or nil if there is no flat subscription.
  def resume_subscription
    subscription = @instance.subscription
    return nil unless subscription && Billing::Plans.flat?(subscription.product_type)

    result = StripeService.resume_cancellation(subscription)
    apply_flat_update(subscription, result)
    result
  end

  # Returns Hash with subscription details (stripe or enterprise) or nil if no subscription.
  def subscription_details
    subscription = @instance.subscription
    if subscription
      return flat_details(subscription) if Billing::Plans.flat?(subscription.product_type)

      return stripe_subscription_details(subscription)
    end

    enterprise = @instance.valid_enterprise_subscription
    if enterprise
      return enterprise_subscription_details(enterprise)
    end

    unresolved = @instance.unresolved_subscription
    if unresolved
      return {
        type: "stripe",
        payment_issue: true,
        status: unresolved.status,
        plan: (unresolved.product_type if Billing::Plans.flat?(unresolved.product_type))
      }
    end

    nil
  end

  # Returns { current_quantity: Integer, total_available: String }
  def current_mau
    current_qty = @project_service.current_mau(@instance)
    { current_quantity: current_qty, total_available: Grovs.free_mau_count.to_s }
  end

  # Returns Hash with billing usage info or nil if no subscription.
  def current_usage
    subscription = @instance.subscription
    if subscription&.active
      return flat_details(subscription) if Billing::Plans.flat?(subscription.product_type)

      return stripe_usage(subscription)
    end

    enterprise = @instance.valid_enterprise_subscription
    if enterprise&.active
      return enterprise_usage(enterprise)
    end

    nil
  end

  private

  # Applies the cancel/resume response immediately, so cancels_at is visible without waiting for the webhook.
  def apply_flat_update(subscription, remote)
    return unless remote && Billing::Plans.flat?(subscription.product_type)

    StripeService.apply_flat_subscription(subscription, remote)
  end

  def subscribed_or_unresolved?
    @instance.valid_enterprise_subscription.present? ||
      @instance.subscription.present? ||
      @instance.stripe_subscriptions.where.not(status: ENDED_STATUSES).exists?
  end

  def stripe_subscription_details(subscription)
    result = { active: subscription.active, paused: (subscription.status == "paused") }

    stripe_subscription = StripeService.get_subscription_details(subscription.subscription_id)

    billing_cycle = StripeService.get_billing_cycle(subscription)
    quantity_for_current_billing_cycle =
      if billing_cycle
        @project_service.compute_maus_per_month_total(@instance, billing_cycle[:start], billing_cycle[:end])
      else
        0
      end

    snap = StripeService.monthly_total_snapshot(subscription) || {}

    free_maus = Grovs.free_mau_count
    raw_quantity = snap[:maus_from_invoice_line].to_i

    paid_maus = raw_quantity > free_maus ? raw_quantity - free_maus : 0

    result[:price] = snap[:amount_cents]

    {
      type: "stripe",
      details: result,
      stripe_subscription: stripe_subscription,
      quantity_for_current_billing_cycle: paid_maus,
      amount_cents: snap[:amount_cents],
      amount_formatted: snap[:amount_formatted],
      maus: quantity_for_current_billing_cycle || snap[:maus_from_invoice_line],
      period_start: snap[:period_start],
      period_end: snap[:period_end],
      next_payment_attempt: snap[:next_payment_attempt]
    }
  end

  def flat_details(subscription)
    remote = StripeService.get_subscription_details(subscription.subscription_id, expand: ["latest_invoice"])
    invoice = StripeService.upcoming_invoice_or_nil(subscription)
    latest = remote[:latest_invoice]
    first_item = remote[:items][:data][0]
    interval = first_item[:price][:recurring][:interval] == "year" ? "yearly" : "monthly"
    # flexible billing_mode subscriptions carry the period on the item, not the subscription itself
    period_start = remote[:current_period_start] || first_item[:current_period_start]
    period_end = remote[:current_period_end] || first_item[:current_period_end]

    {
      type: "stripe",
      plan: subscription.product_type,
      interval: interval,
      mau_cap: Billing::Plans.mau_cap(subscription.product_type),
      maus: @project_service.current_mau(@instance),
      details: { active: subscription.active, paused: subscription.status == "paused" },
      stripe_subscription: { current_period_start: period_start, current_period_end: period_end },
      amount_cents: invoice&.total,
      next_payment_attempt: invoice&.next_payment_attempt,
      period_start: period_start,
      period_end: period_end,
      cancels_at: subscription.cancels_at,
      latest_invoice: latest_invoice_summary(latest),
      billed_to: billed_to(latest)
    }
  end

  def latest_invoice_summary(invoice)
    return nil unless invoice

    {
      number: invoice[:number],
      invoice_pdf: invoice[:invoice_pdf],
      hosted_invoice_url: invoice[:hosted_invoice_url],
      amount_paid: invoice[:amount_paid],
      status: invoice[:status],
      paid_at: invoice[:status_transitions]&.[](:paid_at)
    }
  end

  def billed_to(invoice)
    return nil unless invoice

    {
      name: invoice[:customer_name],
      tax_id: Array(invoice[:customer_tax_ids]).first&.[](:value),
      address_lines: address_lines(invoice[:customer_address])
    }
  end

  def address_lines(address)
    return nil unless address

    lines = [
      [address[:line1], address[:line2]].compact_blank.join(", "),
      [[address[:postal_code], address[:city]].compact_blank.join(" "), address[:state]].compact_blank.join(", "),
      address[:country]
    ].compact_blank
    lines.presence
  end

  def enterprise_subscription_details(enterprise)
    {
      type: "enterprise",
      current_maus: cached_enterprise_maus(enterprise),
      total_maus: enterprise.total_maus,
      start_at: enterprise.start_date,
      end_at: enterprise.end_date
    }
  end

  def stripe_usage(subscription)
    stripe_sub = StripeService.get_subscription_details(subscription.subscription_id)
    start_date = stripe_sub[:start_date] if stripe_sub

    invoice = StripeService.get_next_invoice(subscription)
    amount = invoice[:total] if invoice
    next_payment_attempt = invoice[:next_payment_attempt] if invoice

    usage = StripeService.get_usage(subscription)
    quantity = usage[:data][0][:total_usage] if usage

    { amount: amount, maus: quantity, next_payment_attempt: next_payment_attempt, start_date: start_date }
  end

  def enterprise_usage(enterprise)
    {
      type: "enterprise",
      current_maus: cached_enterprise_maus(enterprise),
      total_maus: enterprise.total_maus,
      start_at: enterprise.start_date,
      end_at: enterprise.end_date
    }
  end

  # Reads pre-computed enterprise MAU from cache (warmed by BackfillLast3DaysJob).
  # Falls back to on-demand computation on cache miss.
  def cached_enterprise_maus(enterprise)
    Rails.cache.fetch("enterprise_mau:#{@instance.id}", expires_in: 30.minutes) do
      @project_service.compute_maus_per_month_total(@instance, enterprise.start_date, DateTime.now)
    end
  end
end
