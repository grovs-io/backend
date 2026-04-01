class ApplicationController < ActionController::API
  before_action :configure_permitted_parameters, if: :devise_controller?

  rescue_from ActiveRecord::RecordNotFound, with: :record_not_found
  rescue_from Date::Error, with: :invalid_date_format
  rescue_from JSON::ParserError, with: :invalid_json_format


  # helper method to access the current user from the token
  def current_user
    @current_user ||= User.find_by(id: doorkeeper_token[:resource_owner_id])
  end

  protected
    
  def configure_permitted_parameters
    devise_parameter_sanitizer.permit(:sign_in, keys: [:otp_attempt])
  end

  private

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
