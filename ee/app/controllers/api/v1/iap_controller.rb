class Api::V1::IapController < Api::V1::ProjectsBaseController

  before_action :initialize_services
  before_action :load_project_from_path, only: [:apple_prod, :apple_test]
  before_action :load_instance_from_path, only: [:google_handling]
  before_action :verify_google_pubsub_token, only: [:google_handling]

  def apple_prod
    handle_apple_notification
  end

  def apple_test
    handle_apple_notification
  end

  def google_handling
    unless @instance&.revenue_collection_enabled?
      return render json: { result: "revenue collection not enabled" }, status: :ok
    end

    pubsub_message = params[:message]
    if pubsub_message.blank?
      return render json: { error: "Missing message" }, status: :bad_request
    end

    iap_webhook_message = IapWebhookMessage.create!(
      payload: pubsub_message,
      notification_type: "",
      source: Grovs::Webhooks::GOOGLE,
      project: nil,
      instance: @instance
    )

    encoded_data = pubsub_message[:data] || pubsub_message["data"]
    if encoded_data.blank?
      return render json: { error: "Missing data in message" }, status: :bad_request
    end
    decoded_json = Base64.decode64(encoded_data)
    parsed_data = JSON.parse(decoded_json)

    Rails.logger.info "Received RTDN event: #{parsed_data.inspect}"

    ProcessGoogleNotificationJob.perform_async(iap_webhook_message.id, parsed_data, @instance.id)

    render json: { result: "ok" }, status: :ok
  rescue JSON::ParserError => e
    Rails.logger.error "Failed to parse decoded RTDN JSON: #{e.message}"
    render json: { error: "Invalid JSON" }, status: :bad_request
  rescue StandardError => e
    Rails.logger.error "Google webhook processing error: #{e.message}\n#{e.backtrace.first(5).join("\n")}"
    render json: { error: "Processing failed" }, status: :internal_server_error
  end

  private

  def handle_apple_notification
    unless @instance&.revenue_collection_enabled?
      return render json: { result: "revenue collection not enabled" }, status: :ok
    end

    notification = JSON.parse(request.body.read)

    value = @apple.handle_notification(notification, @project)
    if value
      render json: { result: "ok" }, status: :ok
    else
      render json: { result: "unprocessed" }, status: :ok
    end
  rescue JSON::ParserError => e
    render json: { error: "invalid payload" }, status: :bad_request
  rescue StandardError => e
    Rails.logger.error "Apple webhook processing error: #{e.message}\n#{e.backtrace.first(5).join("\n")}"
    render json: { error: "processing failed" }, status: :internal_server_error
  end

  def initialize_services
    @apple = AppleIapService.new
  end

  def load_project_from_path
    @project = Project.find_by_hashid(path_param)
    unless @project
      render json: { error: "Forbidden" }, status: :forbidden
      return
    end

    @instance = @project.instance
  end

  def load_instance_from_path
    @instance = Instance.find_by_hashid(path_param)
    unless @instance
      render json: { error: "Forbidden" }, status: :forbidden
    end
  end

  def verify_google_pubsub_token
    token = request.headers["Authorization"]&.sub(/\ABearer\s+/i, "")
    unless token.present?
      return render json: { error: "Missing authorization" }, status: :forbidden
    end

    payload = GooglePubsubVerifier.verify(token)
    unless payload
      render json: { error: "Invalid token" }, status: :forbidden
    end
  end

  def path_param
    params.require(:path)
  end
end
