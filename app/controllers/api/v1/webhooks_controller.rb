class Api::V1::WebhooksController < Api::V1::ProjectsBaseController
  # Stripe webhook
  def stripe_webhook
    sig_header = request.env['HTTP_STRIPE_SIGNATURE']
    payload = request.body.read

    begin
      event = Stripe::Webhook.construct_event(
        payload, sig_header, ENV['STRIPE_WEBHOOK_SECRET']
      )
    rescue JSON::ParserError => e
      render json: {error: "Failed to parse"}, status: :bad_request
      return
    rescue Stripe::SignatureVerificationError => e
      Rails.logger.error("Stripe signature verification failed: #{e.message}")
      render json: {error: "Failed"}, status: :bad_request
      return
    end

    begin
      StripeService.handle_webhook(event)
      render json: {message: "Ok"}, status: :ok
    rescue StripeService::WebhookLockContention
      # Another request is already processing this event — tell Stripe all is well
      render json: {message: "Ok"}, status: :ok
    rescue StandardError => e
      Rails.logger.error("Stripe webhook error: #{e.message}\n#{e.backtrace.first(10).join("\n")}")
      render json: {error: "Internal server error"}, status: :internal_server_error
    end
  end

  def send_stripe_quotas
    api_key = request.headers['X-API-KEY'].to_s
    unless ActiveSupport::SecurityUtils.secure_compare(api_key, ENV.fetch('SENT_QUOTAS_WEBHOOK_KEY', ''))
      render json: {error: "Forbidden"}, status: :forbidden
      return
    end

    Instance.find_each(batch_size: 100) do |instance|
      StripeService.set_usage(instance)
    end

    render json: {message: "Ok"}, status: :ok
  end

end