# Core entry point for the server push API; a no-op without ee/.
module PushCampaignGateway
  module_function

  def create(project:, params:)
    return [:unavailable] unless defined?(PushCampaign)

    [:ok, PushCampaign.server_create(project: project, params: params).api_json]
  rescue PushCampaign::Invalid => e
    [:invalid, e.message]
  rescue PushCampaign::RateLimited => e
    [:rate_limited, e.message]
  end

  def report(project:, id:)
    return :unavailable unless defined?(PushCampaign)

    project.push_campaigns.find_by_hashid(id)&.api_json
  end
end
