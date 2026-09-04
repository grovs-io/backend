class ApplicationController < ActionController::API
  include AuditContext
  before_action :configure_permitted_parameters, if: :devise_controller?

  rescue_from ActiveRecord::RecordNotFound, with: :record_not_found
  rescue_from Date::Error, with: :invalid_date_format
  rescue_from JSON::ParserError, with: :invalid_json_format
  rescue_from Clickhouse::Unavailable, with: :clickhouse_unavailable
  rescue_from Clickhouse::Stale, with: :clickhouse_stale
  rescue_from RevenueLedger::Unavailable, with: :revenue_unavailable
  rescue_from LinksService::PathGenerationError, with: :path_generation_failed


  # helper method to access the current user from the token
  def current_user
    @current_user ||= doorkeeper_token && User.find_by(id: doorkeeper_token[:resource_owner_id])
  end

  protected
    
  def configure_permitted_parameters
    devise_parameter_sanitizer.permit(:sign_in, keys: [:otp_attempt])
  end

  private

  # error_code distinguishes this from analytics being switched off, which renders the same body.
  def clickhouse_unavailable(exception)
    Rails.logger.error("clickhouse.read.unavailable surface=#{exception.message}")
    render json: { error: 'Analytics temporarily unavailable', error_code: 'clickhouse_unavailable' },
           status: :service_unavailable
  end

  # Distinct code from clickhouse_unavailable: ClickHouse is up, the rebuild is not.
  def clickhouse_stale(exception)
    Rails.logger.error("clickhouse.rollups.stale #{exception.message}")
    render json: { error: 'Analytics temporarily unavailable', error_code: 'clickhouse_stale' },
           status: :service_unavailable
  end

  # Namespace exhaustion is a retryable capacity condition, not a client error.
  def path_generation_failed(exception)
    Rails.logger.error("links.path_generation_failed #{exception.message}")
    render json: { error: 'Could not allocate a link path', error_code: 'path_generation_failed' },
           status: :service_unavailable
  end

  # Only reachable with PG_SHADOW_WRITES off, where the stat-table fallback is a table of zeros.
  def revenue_unavailable(exception)
    Rails.logger.error("revenue_ledger.unavailable surface=#{exception.message}")
    render json: { error: 'Revenue temporarily unavailable', error_code: 'revenue_unavailable' },
           status: :service_unavailable
  end

  def record_not_found(exception)
    render json: {
      error: exception.message
    }, status: :not_found
  end

  def invalid_date_format(exception)
    render json: { error: "Invalid date format: #{exception.message}" }, status: :bad_request
  end

  def invalid_json_format(exception)
    render json: { error: "Invalid JSON: #{exception.message}" }, status: :bad_request
  end

end
