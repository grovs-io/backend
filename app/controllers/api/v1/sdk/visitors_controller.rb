class Api::V1::Sdk::VisitorsController < Api::V1::Sdk::BaseController
  # wrap_parameters nests JSON bodies under :visitor, breaking the strict request contract.
  wrap_parameters false

  def visitor_attributes
    render json: {visitor: VisitorSerializer.serialize(@visitor)}, status: :ok
  end

  def set_visitor_attributes
    @visitor.sdk_attributes = with_journey_keys(sdk_attributes_param)

    @visitor.sdk_identifier = sdk_identifier_param || nil

    if push_token_param
      @device.push_token = push_token_param
    end

    identity_changed = @visitor.sdk_identifier_changed? || @visitor.sdk_attributes_changed?
    identifier_changed = @visitor.sdk_identifier_changed?

    # Committing the visitor before a failing device save would leave nothing dirty for the retry.
    ActiveRecord::Base.transaction do
      @visitor.save!
      @device.save!
    end

    SyncVisitorProfileJob.perform_later(@visitor.id) if identity_changed
    # Every time, not only on a change: a transfer that failed is finished by the next request.
    InAppGateway.identified(@visitor, changed: identifier_changed) if @visitor.sdk_identifier.present? || identifier_changed
    JourneyGateway.identified(@visitor) if @visitor.sdk_identifier.present?

    render json: {visitor: VisitorSerializer.serialize(@visitor)}, status: :ok
  end

  private

  def sdk_attributes_param
    params.permit(:sdk_attributes => {})[:sdk_attributes]
  end

  # The app replaces its attributes whole and never names journey_ keys, so the ones a journey set stay.
  def with_journey_keys(given)
    kept = @visitor.sdk_attributes.is_a?(Hash) ? @visitor.sdk_attributes.select { |key, _| key.to_s.start_with?("journey_") } : {}
    kept.empty? ? given : given.to_h.merge(kept)
  end

  # presence, not raw: "" would store a genuine empty string that sorts differently from NULL.
  def sdk_identifier_param
    params.permit(:sdk_identifier)[:sdk_identifier].presence
  end

  def push_token_param
    params.permit(:push_token)[:push_token]
  end
end
