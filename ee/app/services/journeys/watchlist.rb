# The event keys a project's journeys react to, kept in Redis so a batch pays one read per project.
module Journeys::Watchlist
  TTL = 1.day.to_i
  EMPTY = { "keys" => [], "props" => [], "any" => false }.freeze

  module_function

  def key(project_id) = "journeys:watch:#{Integer(project_id)}"

  def for(project_ids)
    return {} if project_ids.empty?

    values = REDIS.with { |conn| conn.mget(*project_ids.map { |id| key(id) }) }
    project_ids.zip(values).to_h { |id, value| [id, value ? JSON.parse(value) : refresh(id)] }
  rescue Redis::BaseError => e
    Rails.logger.warn("journeys.watchlist_failed #{e.class}")
    {}
  end

  def refresh(project_id)
    list = compute(project_id)
    REDIS.with { |conn| conn.set(key(project_id), list.to_json, ex: TTL) }
    list
  rescue Redis::BaseError => e
    Rails.logger.warn("journeys.watchlist_failed #{e.class}")
    list || EMPTY
  end

  def compute(project_id)
    keys = Set.new
    props = Set.new
    any = false
    Journey.where(project_id: project_id, status: %w[live paused ended], finished_at: nil).find_each do |journey|
      any = true
      specs = journey.goals.dup
      specs << journey.entry["event"] if journey.entry["type"] == "event" && journey.entry["event"].is_a?(Hash)
      journey.steps.each_value do |step|
        until_spec = step["until"]
        specs << until_spec["event"] if step["type"] == "wait" && until_spec.is_a?(Hash) && until_spec["kind"] == "event"
        keys << until_key(journey, step) if step["type"] == "in_app" || (until_spec.is_a?(Hash) && until_spec["kind"] != "event")
      end
      specs.each do |spec|
        keys << Journeys.event_key(spec)
        Array(spec["filters"]).each { |filter| props << filter["field"] }
      end
    end
    { "keys" => keys.compact.sort, "props" => props.sort, "any" => any }
  end

  # The key a person waits on at this step; nil when nothing but time moves them on.
  def until_key(journey, step)
    return "v:#{step['campaign_id']}" if step["type"] == "in_app"

    spec = step["until"]
    return nil unless spec.is_a?(Hash)
    return Journeys.event_key(spec["event"]) if spec["kind"] == "event"

    campaign = journey.step(spec["step"])&.dig("campaign_id")
    campaign && "#{spec['kind'] == 'opened' ? 'o' : 'c'}:#{campaign}"
  end
end
