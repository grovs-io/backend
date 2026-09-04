class Api::V1::Sdk::VisitorsController < Api::V1::Sdk::BaseController
  def visitor_attributes
    render json: {visitor: VisitorSerializer.serialize(@visitor)}, status: :ok
  end

  def set_visitor_attributes
    @visitor.sdk_attributes = sdk_attributes_param || nil

    @visitor.sdk_identifier = sdk_identifier_param || nil

    if push_token_param
      @device.push_token = push_token_param
    end

    identity_changed = @visitor.sdk_identifier_changed? || @visitor.sdk_attributes_changed?

    # Committing the visitor before a failing device save would leave nothing dirty for the retry.
    ActiveRecord::Base.transaction do
      @visitor.save!
      @device.save!
    end

    SyncVisitorProfileJob.perform_later(@visitor.id) if identity_changed

    render json: {visitor: VisitorSerializer.serialize(@visitor)}, status: :ok
  end

  private

  def sdk_attributes_param
    params.permit(:sdk_attributes => {})[:sdk_attributes]
  end

  # presence, not raw: "" would store a genuine empty string that sorts differently from NULL.
  def sdk_identifier_param
    params.permit(:sdk_identifier)[:sdk_identifier].presence
  end

  def push_token_param
    params.permit(:push_token)[:push_token]
  end
end
