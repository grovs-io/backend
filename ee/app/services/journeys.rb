# The journey engine's entry points; core code reaches them only through JourneyGateway.
module Journeys
  CAMPAIGN_KEYS = { Grovs::Events::PUSH_OPEN => "o", "in_app_clicked" => "c", "in_app_viewed" => "v" }.freeze
  PAGE = 1_000
  # A store purchase travels under a name event batches may never carry.
  PURCHASE = "journey_purchase".freeze
  PURCHASE_KEY = "p:".freeze

  TrackedSegment = Struct.new(:project, :project_id, :segment_id, :segment_key, :segment_definition, :segment_list_generation, :status,
                              keyword_init: true)

  module_function

  def running? = Grovs.journeys_enabled? && Grovs.in_app_enabled?

  # "e:" a custom event, "s:" a screen (any case), "t:" a system event; the rest are message events. Goals say "event".
  def event_key(spec)
    return PURCHASE_KEY if Experiments::Goal.purchase?(spec)
    return "t:#{spec['system']}" if spec["system"].present?

    spec["screen"].present? ? "s:#{spec['screen'].to_s.downcase}" : "e:#{spec['name'] || spec['event']}"
  end

  # A system event travels under its type as the name; custom events may not use those names.
  def keys_of(name, screen, properties)
    return [PURCHASE_KEY] if name == PURCHASE
    return ["s:#{screen.downcase}"] if screen
    return ["t:#{name}"] if Experiments::Goal::SYSTEM.include?(name)

    campaign = properties["campaign_id"].to_s
    kind = CAMPAIGN_KEYS[name]
    kind && campaign.present? ? ["e:#{name}", "#{kind}:#{campaign}"] : ["e:#{name}"]
  end

  # One cache read per project, and a job only for a project whose journeys wait for a name in the batch.
  def observe(event_rows, visitors_index)
    return unless running?

    by_project = event_rows.group_by { |row| row[:project_id] }
    lists = Watchlist.for(by_project.keys)
    received_ms = (Time.current.to_f * 1000).to_i
    by_project.each do |project_id, rows|
      list = lists[project_id]
      next if list.nil? || list["keys"].empty?

      payload = rows.filter_map { |row| watched(row, visitors_index, list)&.push(received_ms) }
      JourneyEventJob.perform_async(project_id, payload) if payload.any?
    end
  end

  def watched(row, visitors_index, list)
    system = Experiments::Goal::SYSTEM.include?(row[:event])
    return unless system || [Grovs::Events::CUSTOM, Grovs::Events::SCREEN_VIEW].include?(row[:event])
    return if Grovs::Events::SERVER_EVENT_NAMES.include?(row[:event_name]) || row[:event_name] == PURCHASE

    visitor = visitors_index[[row[:project_id], row[:device_id]]]
    return if visitor.nil?

    data = properties_of(row[:data])
    screen = row[:event] == Grovs::Events::SCREEN_VIEW ? data["screen_name"].to_s.strip.presence : nil
    name = system ? row[:event] : row[:event_name].to_s
    return if keys_of(name, screen, data).none? { |key| list["keys"].include?(key) }

    [visitor.id, InAppViews.person_key(visitor), name, screen, data.slice("campaign_id", *list["props"]),
     (row[:created_at].to_f * 1000).to_i]
  end

  # Best effort, like observe: a lost enqueue leaves the person in; the report still counts the purchase.
  def purchased(event)
    return unless running? && event.event_type == Grovs::Purchases::EVENT_BUY && event.visitor_id.present?
    return unless Watchlist.for([event.project_id])[event.project_id]&.dig("keys")&.include?(PURCHASE_KEY)

    visitor = Visitor.redis_find_by(:id, event.visitor_id)
    return if visitor.nil?

    row = [visitor.id, InAppViews.person_key(visitor), PURCHASE, nil, { "product_id" => event.product_id.to_s },
           (event.created_at.to_f * 1000).to_i]
    # No receive time: a reattributed purchase is processed late, and must not let back someone who bought before leaving.
    JourneyEventJob.perform_async(event.project_id, [row])
  rescue StandardError => e
    Grovs::Metrics.increment("journeys.purchase_failed", tags: { error: e.class.name })
    Rails.logger.warn("journeys.purchase_failed #{e.class}: #{e.message}")
  end

  def properties_of(data)
    return data.stringify_keys if data.is_a?(Hash)

    parsed = data.is_a?(String) ? JSON.parse(data) : {}
    parsed.is_a?(Hash) ? parsed : {}
  rescue JSON::ParserError
    {}
  end

  # Newcomers to a journey's entry segment, as the membership refresh found them.
  def admit(journey, visitor_ids)
    return unless running? && journey.entry_open?

    visitor_ids.each_slice(PAGE) { |slice| Entry.call(journey, people_of(slice), run: false) }
    JourneyStepJob.perform_async(journey.id)
  end

  def people_of(visitor_ids)
    Visitor.where(id: visitor_ids).order(:id).pluck(:id, :sdk_identifier).map { |id, ident| [id, ident.present? ? "i:#{ident}" : "v:#{id}"] }
  end

  # Every tracked segment of a journey; one a served campaign shares is already refreshed by that campaign.
  def refresh_segments(journey_id)
    journey = Journey.where.not(status: "draft").find_by(id: journey_id, finished_at: nil)
    return if journey.nil?

    # The entry segment goes last: newcomers are checked against an audience segment that is already current.
    journey.segment_keys.sort_by { |role, _| role == "entry" ? 1 : 0 }.each do |role, spec|
      next if role != "entry" && InAppCampaign.served.where.not(audience_type: "journey").exists?(segment_key: spec["key"])

      tracked = TrackedSegment.new(project: journey.project, project_id: journey.project_id, segment_id: spec["segment_id"], status: journey.status,
                                   segment_key: spec["key"], segment_definition: spec["definition"], segment_list_generation: spec["list_generation"])
      entered = role == "entry" ? ->(ids) { admit(journey, ids) } : nil
      InAppMemberships.refresh(tracked, announce: false, entered: entered)
    end
  end

  # Called on every identify, so a project without unfinished journeys costs one cache read.
  def identified(visitor)
    list = Watchlist.for([visitor.project_id])[visitor.project_id]
    return unless list && (list["any"] || list["keys"].any?)

    carry(visitor.project_id, from: "v:#{visitor.id}", to: InAppViews.person_key(visitor), visitor_id: visitor.id)
  end

  def merge(from:, to:)
    carry(from.project_id, from: "v:#{from.id}", to: InAppViews.person_key(to), visitor_id: to.id)
  end

  # The row still inside wins, else the older, so a person is never in one journey twice.
  def carry(project_id, from:, to:, visitor_id:)
    return if from == to

    journey_ids = Journey.where(project_id: project_id, finished_at: nil).where.not(status: "draft").pluck(:id)
    return if journey_ids.empty?

    JourneyPerson.where(journey_id: journey_ids, person_key: from).find_each do |row|
      other = JourneyPerson.find_by(journey_id: row.journey_id, person_key: to)
      next drop(row) if other && keeps?(other, row)

      drop(other) if other
      row.update_columns(person_key: to, visitor_id: visitor_id)
    end
  end

  def keeps?(other, row)
    inside = [other, row].map { |r| JourneyPerson::INSIDE.include?(r.state) }
    inside.uniq.size == 2 ? inside.first : other.entered_at <= row.entered_at
  end

  def drop(row)
    step = row.journey.step(row.step_id)
    if step && step["type"] == "in_app" && row.state != "left"
      SegmentMembership.where(segment_key: row.journey.membership_key(row.step_id), visitor_id: row.visitor_id).delete_all
      ActiveRecord.after_all_transactions_commit { InAppStamps.touch_users([row.visitor_id]) }
    end
    row.delete
  end
end
