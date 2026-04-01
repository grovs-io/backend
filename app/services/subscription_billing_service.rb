class SubscriptionBillingService
  def initialize(instance:, project_service: nil)
    @instance = instance
    @project_service = project_service || ProjectService.new
  end

  # Returns { url: String } — Stripe Checkout session URL.
  # Raises if instance already has active subscription.
  def create_checkout_session(user:, price_id: nil)
    subscription = @instance.subscription
    raise ArgumentError, "This project is already subscribed" if subscription

    price_id ||= ENV["STRIPE_STANDARD_PRICE_ID"]
    session = StripeService.create_checkout_session_for_product(price_id, user, "scale_up", @instance)
    { url: session[:url] }
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

    StripeService.cancel_subscription(subscription)
  end

  # Returns Hash with subscription details (stripe or enterprise) or nil if no subscription.
  def subscription_details
    subscription = @instance.subscription
    if subscription
      return stripe_subscription_details(subscription)
    end

    enterprise = @instance.valid_enterprise_subscription
    if enterprise
      return enterprise_subscription_details(enterprise)
    end

    nil
  end

  # Returns { current_quantity: Integer, total_available: String }
  def current_mau
    current_qty = @project_service.current_mau(@instance)
    { current_quantity: current_qty, total_available: ENV["FREE_MAU_COUNT"] }
  end

  # Returns Hash with billing usage info or nil if no subscription.
  def current_usage
    subscription = @instance.subscription
    if subscription&.active
      return stripe_usage(subscription)
    end

    enterprise = @instance.valid_enterprise_subscription
    if enterprise&.active
      return enterprise_usage(enterprise)
    end

    nil
  end

  private

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

    free_maus = ENV.fetch("FREE_MAU_COUNT", "10000").to_i
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
