class Api::V1::Sdk::PushController < Api::V1::Sdk::BaseController
  wrap_parameters false

  def open
    campaign_id = params[:campaign_id].to_s
    return render json: { error: "campaign_id is required" }, status: :bad_request if campaign_id.blank?

    case PushOutcomes.opened(project: @project, visitor: @visitor, campaign_id: campaign_id)
    when :ok
      EventIngestionService.log_async(Grovs::Events::CUSTOM, @project, @device, { "campaign_id" => campaign_id }, nil, nil,
                                      event_name: Grovs::Events::PUSH_OPEN, session_id: params[:session_id].presence)
      render json: { message: "Recorded" }, status: :ok
    when :noop
      render json: { message: "Already recorded" }, status: :ok
    else
      render json: { error: "Push campaign not found" }, status: :not_found
    end
  end
end
