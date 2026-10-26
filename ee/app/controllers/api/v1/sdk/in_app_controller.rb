class Api::V1::Sdk::InAppController < Api::V1::Sdk::BaseController
  wrap_parameters false

  def sync
    held = { "campaigns_changed_at" => params[:campaigns_changed_at].to_s, "user_changed_at" => params[:user_changed_at].to_s }
    render json: InAppSync.call(project: @project, visitor: @visitor, held: held, platform: @platform, device: @device), status: :ok
  end
end
