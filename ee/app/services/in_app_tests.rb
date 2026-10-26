# A message sent to one person's devices to look at, outside every rule a launched campaign follows.
module InAppTests
  TTL = 30.minutes.to_i # longer than the web SDK's 15 minute sync, so an idle page still gets it
  DEVICES = 50

  module_function

  def key(visitor_id) = "in_app:test:#{visitor_id}"

  # Returns how many devices will show it; none when nobody in the project has that identifier.
  def deliver(campaign, identifier)
    problems = InAppDefinition.problems(campaign.definition)
    raise InAppCampaign::Refused, problems.first(3).join("; ") if problems.any?

    ids = Visitor.where(project_id: campaign.project_id, sdk_identifier: identifier.to_s).limit(DEVICES).pluck(:id)
    return 0 if ids.empty?

    body = campaign.definition.to_json
    REDIS.with { |conn| conn.pipelined { |pipe| ids.each { |id| pipe.set(key(id), body, ex: TTL) } } }
    InAppStamps.touch_users(ids)
    ids.size
  rescue Redis::BaseError
    raise InAppCampaign::Refused, "The test could not be sent right now; try again in a moment"
  end

  # Handed over once: the device shows it and the next sync finds nothing.
  def take(visitor_id)
    body = REDIS.with { |conn| conn.getdel(key(visitor_id)) }
    body ? [JSON.parse(body)] : []
  rescue Redis::BaseError, JSON::ParserError
    []
  end
end
