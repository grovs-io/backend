class Api::V1::Mcp::SegmentsController < Api::V1::SegmentsController
  include McpProjectController

  before_action :reject_identity_breakdown, only: :breakdown

  private

  def segment_lane = :mcp

  def reject_identity_breakdown
    by = params[:by].to_s
    render_field_not_allowed(by) if McpIdentityPolicy.blocked?(by, builtin: Segments::Breakdown::DIMENSIONS)
  end
end
