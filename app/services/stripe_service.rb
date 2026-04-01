require 'bigdecimal'
require 'bigdecimal/util'
require 'zlib'

class StripeService
  class WebhookLockContention < StandardError; end

  class << self
    include StripeService::WebhookHandlers

    # Methods

    def create_checkout_session_for_product(price_id, user, product_type, instance)
      session_id = instance.id.to_s

      stripe_create_session_params = {
          success_url: ENV['REACT_HOST_PROTOCOL'] + ENV['REACT_HOST'] + '/settings?instance_id=' + session_id,
          cancel_url: ENV['REACT_HOST_PROTOCOL'] + ENV['REACT_HOST'] + '/settings?cancel=true' + session_id ,
          mode: 'subscription',
          customer_email: user.email,
          client_reference_id: session_id,
          line_items: [{
            price: price_id,
          }],
      }

      session = Stripe::Checkout::Session.create(stripe_create_session_params)

      create_payment_intent_for_session(user, session, product_type, instance)

      session
    end

    def handle_webhook(event)
      event_id = event['id']

      with_event_lock(event_id) do
        existing = StripeWebhookMessage.find_by(stripe_event_id: event_id)

        if existing
          return if existing.processed

          # Previous attempt crashed before finishing — re-process
          process_event(event)
          existing.update_columns(processed: true)
        else
          # New event — record before processing
          record = StripeWebhookMessage.create!(
            data: event['data'],
            message_type: event['type'],
            stripe_event_id: event_id,
            processed: false
          )
          process_event(event)
          record.update_columns(processed: true)
        end
      end
    end

    def pause_subscription(subscription)
      Stripe::Subscription.update(
          subscription.subscription_id,
          {pause_collection: {behavior: 'void'}},
        )
    end

    def resume_subscription(subscription)
      Stripe::Subscription.update(
          subscription.subscription_id,
          {
            pause_collection: ''
          }
      )
    end

    def cancel_subscription(subscription)
      
      Stripe::Subscription.cancel(subscription.subscription_id)
    rescue Stripe::StripeError => e
      # Handle other Stripe-related errors
      Rails.logger.error("Stripe error: #{e.message}")
      
    end

    def generate_portal_link(instance)
      subscription = instance.subscription
      if subscription.nil?
        return nil
      end

      session = Stripe::BillingPortal::Session.create({
          customer: subscription.customer_id,
          return_url: ENV['REACT_HOST_PROTOCOL'] + ENV['REACT_HOST'] + ENV['REACT_HOST_DASHBOARD_PATH'],
      })

      session[:url]
    end

    def get_subscription_details(subscription_id)
      Stripe::Subscription.retrieve(
          subscription_id,)

      
    end

    def set_usage(instance)
      subscription = instance.subscription
      unless subscription
        return
      end

      billing_cycle = get_billing_cycle(subscription)
      unless billing_cycle
        return
      end

      billing_cycle_start = billing_cycle[:start]
      billing_cycle_end = billing_cycle[:end]

      quantity = ProjectService.new.compute_maus_per_month_total(instance, billing_cycle_start, billing_cycle_end)

      Stripe::SubscriptionItem.create_usage_record(
          subscription.subscription_item_id,
          {
            quantity: quantity,
            timestamp: DateTime.now.to_i,
            action: 'set',
          }
      )

      apply_discounts(subscription, quantity)
    rescue Stripe::StripeError => e
      Rails.logger.error("Error setting usage: #{e.message}")
      nil
    end

    def get_usage(subscription)
      Stripe::SubscriptionItem.list_usage_record_summaries(subscription.subscription_item_id)
    end

    def get_next_invoice(subscription)
      Stripe::Invoice.upcoming({subscription: subscription.subscription_id})
    end

    def monthly_total_snapshot(subscription)
      inv  = Stripe::Invoice.upcoming(subscription: subscription.subscription_id)
      line = inv.lines&.data&.find { |l| l.type == "subscription" } || inv.lines&.data&.first

      total_cents = inv.total.to_i

      if total_cents.zero? && line
        # Stripe puts the computed unit price on the *invoice line* for tiered/metered
        unit_dec = line.pricing&.unit_amount_decimal # e.g. "0.199" (cents per unit)
        qty      = line.quantity.to_i
        total_cents = (BigDecimal(unit_dec) * qty).round if unit_dec
      end

      {
          amount_cents: total_cents,
          amount_formatted: "#{inv.currency.upcase} #{(total_cents / 100.0).round(2)}",
          maus_from_invoice_line: line&.quantity.to_i,
          period_start: inv.period_start,
          period_end:   inv.period_end,
          next_payment_attempt: inv.next_payment_attempt
      }
    end

    # Billing cycle

    def get_billing_cycle(subscription)
      
      # Retrieve the subscription from Stripe
      subscription = Stripe::Subscription.retrieve(subscription.subscription_id)

      # Extract the start and end of the current billing cycle
      billing_cycle_start = Time.at(subscription.current_period_start).to_datetime
      billing_cycle_end = Time.at(subscription.current_period_end).to_datetime

      # Return both start and end dates
      {
        start: billing_cycle_start,
        end: billing_cycle_end
      }
    rescue Stripe::StripeError => e
      # Handle errors (e.g., subscription not found, Stripe API issues)
      Rails.logger.warn("Error retrieving subscription details: #{e.message}")
      nil
      
    end

    private

    def process_event(event)
      case event.type
      when 'checkout.session.completed'
        # Payment is successful and the subscription is created.
        # You should provision the subscription and save the customer ID to your database.
        handle_subscription_started(event)

      when 'invoice.paid'
        # Continue to provision the subscription as payments continue to be made.
        # Store the status in your database and check when a user accesses your service.
        # This approach helps you avoid hitting rate limits.
        handle_subscription_continued(event)

      when 'invoice.payment_failed'
        # The payment failed or the customer does not have a valid payment method.
        # The subscription becomes past_due. Notify your customer and send them to the
        # customer portal to update their payment information.
        handle_subscription_payment_fail(event)

      when 'customer.subscription.updated'
        # Subscription has changed
        handle_subscription_updated(event)

      when 'customer.subscription.created'
        # Subscription trial started
        handle_subscription_created(event)

      when 'customer.subscription.deleted'
        # Subscription is deleted
        handle_subscription_updated(event)

      else
        Rails.logger.warn("Unhandled event type: #{event.type}")
      end
    end

    def with_event_lock(event_id)
      lock_key = Zlib.crc32(event_id.to_s)
      conn = ActiveRecord::Base.connection
      acquired = conn.select_value("SELECT pg_try_advisory_lock(#{lock_key})")
      raise WebhookLockContention, "Stripe webhook #{event_id} is being processed by another request" unless acquired

      begin
        yield
      ensure
        conn.execute("SELECT pg_advisory_unlock(#{lock_key})")
      end
    end

    def create_payment_intent_for_session(user, session, product_type, instance)
      session_id = session[:id]

      payment_intent = StripePaymentIntent.new(product_type: product_type, intent_id: session_id)
      instance.stripe_payment_intents << payment_intent
      user.stripe_payment_intents << payment_intent
    end
  end
end
