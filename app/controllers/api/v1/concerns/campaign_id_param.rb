module Api::V1::Concerns
  # Clients send campaign_id as a JSON integer or a decimal string; anything else is a 400.
  module CampaignIdParam
    extend ActiveSupport::Concern

    CAMPAIGN_ID_FORMAT = /\A\d+\z/

    private

    def campaign_id_param
      return @campaign_id_param if defined?(@campaign_id_param)

      value = params.permit(:campaign_id)[:campaign_id].to_s.strip
      @campaign_id_param = value.match?(CAMPAIGN_ID_FORMAT) ? value.to_i : nil
    end

    def validate_campaign_id!
      return if campaign_id_omitted? || campaign_id_param
      render json: { error: "campaign_id must be an integer" }, status: :bad_request
    end

    # Only nil and blank strings mean "no filter"; false/[]/{} are malformed, not absent.
    def campaign_id_omitted?
      raw = params[:campaign_id]
      raw.nil? || (raw.is_a?(String) && raw.strip.empty?)
    end
  end
end
