class Public::BaseController < ActionController::Base
  before_action :set_cache_headers

  def self.local_prefixes
    super + ["public/display"]
  end

  private

  def set_cache_headers
    response.headers["Cache-Control"] = "no-cache, no-store"
    response.headers["Pragma"] = "no-cache"
    response.headers["Expires"] = "Mon, 01 Jan 1990 00:00:00 GMT"
  end

  def render_not_found
    render template: "public/display/not_found", formats: [:html]
  end

  def render_quota_exceeded
    render template: "public/display/quota_exceeded/quota_exceeded", formats: [:html]
  end
end
