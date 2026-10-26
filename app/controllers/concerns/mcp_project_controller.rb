# Turns a dashboard project controller subclass into an MCP one: MCP token auth, hashid project ids.
module McpProjectController
  extend ActiveSupport::Concern
  include McpAuthentication
  include McpQuotaWarning

  included do
    skip_before_action :doorkeeper_authorize!
    skip_before_action :authenticate_mcp_token!
    prepend_before_action :authenticate_mcp_token!
  end

  private

  def id_param
    Project.decode_id(params.require(:id))
  end

  # segment_id would build segment results in the dashboard's permit lane; MCP tools never send it.
  def reject_segment_filter
    return if params[:segment_id].blank?

    render json: { error: "segment_id is not supported through MCP", error_code: "unsupported_filter" }, status: :bad_request
  end

  def render_field_not_allowed(field)
    render json: { error: "#{field} is not available through MCP", error_code: "field_not_allowed" }, status: :bad_request
  end
end
