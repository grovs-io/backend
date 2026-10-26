require_relative "../../../test/contracts/sdk_contracts"
require_relative "segment_contracts"
require_relative "in_app_contracts"

module ApiContracts
  SERVER_API_FAILURES = { 400 => ERROR, 403 => { "anyOf" => [ERROR, PUSH_CODED_ERROR] } }.freeze

  # A server API subclass answers like its dashboard parent, with key failures in place of the dashboard's 401.
  def self.register_server_subclass(action, parent:)
    base = contracts.fetch(parent)
    register action, request: base.request, responses: base.responses.except(401).merge(SERVER_API_FAILURES)
  end

  {
    "SegmentsController" => %w[index fields estimate create show update destroy count identifier_list],
    "InAppCampaignsController" => %w[index create show update destroy launch pause resume finish test report]
  }.each do |controller, actions|
    actions.each { |a| register_server_subclass "Api::V1::Server::#{controller}##{a}", parent: "Api::V1::#{controller}##{a}" }
  end
end
