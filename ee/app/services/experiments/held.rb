# Records that a person was kept from a message, once a day, so the control groups can be counted.
module Experiments::Held
  IN_APP = "in_app_held".freeze
  PUSH = "push_held".freeze
  PUSH_DELIVERED = "push_delivered".freeze
  DAY = 86_400

  module_function

  def key(project, visitor, campaign) = "in_app:held:#{project.id}:#{visitor.id}:#{campaign || 'project'}"

  # Whether today's hold is still to be written; false on a Redis error so nothing else runs either.
  def pending?(project, visitor, campaign: nil)
    !REDIS.with { |r| r.exists?(key(project, visitor, campaign)) }
  rescue Redis::BaseError
    false
  end

  def mark(project, visitor, campaign: nil)
    REDIS.with { |r| r.set(key(project, visitor, campaign), "1", nx: true, ex: DAY) }
  rescue Redis::BaseError
    nil
  end

  def in_app(project:, device:, visitor:, campaign: nil)
    return if device.nil?
    return unless REDIS.with { |r| r.set(key(project, visitor, campaign), "1", nx: true, ex: DAY) }

    properties = campaign ? { "campaign_id" => campaign, "scope" => "campaign" } : { "scope" => "project" }
    EventIngestionService.log_async(Grovs::Events::CUSTOM, project, device, properties, nil, nil, event_name: IN_APP)
  rescue Redis::BaseError => e
    Rails.logger.warn("in_app.held_failed #{e.class}")
  end

  # Many rows at once, as the push jobs have them: [[device_id, properties], ...] under one name and time.
  def push(project_id, name, rows, at: Time.current)
    payloads = rows.map do |device_id, properties|
      { type: Grovs::Events::CUSTOM, project_id: project_id, device_id: device_id, data: properties, link_id: nil, engagement_time: nil,
        created_at: at.iso8601(3), event_name: name, session_id: "", tags: [] }
        .merge(EventIngestionService.frozen_ch_fields(Grovs::Events::CUSTOM, project_id, device_id, nil, at, name, "", nil, properties))
    end
    EventIngestionService.enqueue_events(payloads)
  end
end
