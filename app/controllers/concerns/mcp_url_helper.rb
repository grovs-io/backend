module McpUrlHelper
  extend ActiveSupport::Concern

  private

  def mcp_base_url
    protocol = request.ssl? ? "https" : "http"
    "#{protocol}://#{request.host_with_port}"
  end
end
