# One project's batch of watched events: people enter, reach goals, or end a wait. Only events after entry count.
class Journeys::Signals
  LATE = 1.hour
  Seen = Struct.new(:visitor_id, :person_key, :name, :screen, :properties, :at, :keys, :received)
  GOAL_SQL = <<~SQL.squish.freeze
    UPDATE journey_people AS j
    SET goal_hit = true,
        state = CASE WHEN j.state = 'active' THEN 'left' ELSE j.state END,
        left_at = CASE WHEN j.state = 'active' THEN %<now>s ELSE j.left_at END,
        left_reason = CASE WHEN j.state = 'active' THEN 'goal' ELSE j.left_reason END,
        due_at = CASE WHEN j.state = 'active' THEN NULL ELSE j.due_at END
    FROM (VALUES %<values>s) AS v(person_key, at)
    WHERE j.journey_id = %<journey>d AND j.person_key = v.person_key AND j.state IN ('active', 'claimed') AND j.entered_at < v.at
    RETURNING j.id, j.state, j.step_id, j.visitor_id
  SQL
  # A claimed row keeps its due time: the step job sees the hit when it rereads the row.
  UNTIL_SQL = <<~SQL.squish.freeze
    UPDATE journey_people AS j
    SET until_hit = true, due_at = CASE WHEN j.state = 'active' THEN %<now>s ELSE j.due_at END
    FROM (VALUES %<values>s) AS v(id, until_event)
    WHERE j.id = v.id AND j.until_event = v.until_event AND j.state IN ('active', 'claimed')
    RETURNING j.id
  SQL

  def initialize(project, rows)
    @project = project
    @now = Time.current
    # The person as they are now: an identify between the batch and this job must not enrol them twice.
    people = Journeys.people_of(rows.map(&:first).uniq).to_h
    @seen = rows.filter_map do |visitor_id, _queued, name, screen, properties, at_ms, received_ms|
      next unless people[visitor_id]

      properties = properties.to_h
      Seen.new(visitor_id, people[visitor_id], name, screen, properties, Time.zone.at(at_ms / 1000.0), Journeys.keys_of(name.to_s, screen, properties),
               received_ms && Time.zone.at(received_ms / 1000.0))
    end
  end

  def call
    Journey.where(project_id: @project.id, status: %w[live paused ended], finished_at: nil).find_each do |journey|
      enter(journey)
      reach_goals(journey)
      end_waits(journey)
    end
  end

  private

  def enter(journey)
    return unless journey.entry["type"] == "event" && journey.entry_open?(@now)

    spec = journey.entry["event"]
    key = Journeys.event_key(spec)
    fresh = @seen.select { |e| e.at >= LATE.ago && e.keys.include?(key) && Journeys::Matcher.pass?(spec["filters"], e.properties) }
    return if fresh.empty?

    received = fresh.map(&:received)
    # Entered at the event's own time, so a goal or until-event later in the same batch counts.
    Journeys::Entry.call(journey, fresh.map { |e| [e.visitor_id, e.person_key, [e.at, @now].min] }, received_at: received.all? ? received.max : nil)
  end

  def reach_goals(journey)
    reached = @seen.select { |e| journey.goals.any? { |goal| reaches?(goal, e) } }
                   .group_by(&:person_key).transform_values { |list| list.map(&:at).max }
    return if reached.empty?

    conn = JourneyPerson.connection
    values = reached.sort.map { |key, at| "(#{conn.quote(key)}::varchar, #{conn.quote(at)}::timestamp)" }.join(", ")
    shown = JourneyPerson.transaction do
      left = conn.exec_query(format(GOAL_SQL, values: values, now: conn.quote(@now), journey: journey.id)).to_a.select { |row| row["state"] == "left" }
      leave_messages(journey, left)
    end
    InAppStamps.touch_users(shown.pluck("visitor_id")) if shown.any?
  end

  # Marking them left, taking their in-app messages away and counting them commit together.
  def leave_messages(journey, left)
    return [] if left.empty?

    shown = left.select { |row| journey.step(row["step_id"])&.dig("type") == "in_app" }
    shown.group_by { |row| row["step_id"] }.each do |step_id, rows|
      SegmentMembership.where(segment_key: journey.membership_key(step_id), visitor_id: rows.pluck("visitor_id")).delete_all
    end
    Journeys::Tally.add(journey.id, { ["", "goal"] => left.size }, at: @now)
    shown
  end

  def reaches?(goal, seen)
    products = goal["products"]
    seen.keys.include?(Journeys.event_key(goal)) && (products.blank? || products.include?(seen.properties["product_id"]))
  end

  def end_waits(journey)
    watched = journey.steps.values.to_h { |step| [step["id"], Journeys::Watchlist.until_key(journey, step)] }.compact
    return if watched.empty?

    events = @seen.select { |e| e.keys.intersect?(watched.values) }
    return if events.empty?

    candidates = JourneyPerson.where(journey_id: journey.id, person_key: events.map(&:person_key).uniq, state: %w[active claimed],
                                     until_event: watched.values.uniq).pluck(:id, :person_key, :step_id, :until_event, :entered_at)
    hits = candidates.select { |_, key, step_id, until_event, entered_at| hit?(journey.step(step_id), events, key, until_event, entered_at) }
    return if hits.empty?

    conn = JourneyPerson.connection
    values = hits.map { |id, _, _, until_event, _| "(#{Integer(id)}::bigint, #{conn.quote(until_event)}::varchar)" }.join(", ")
    conn.exec_query(format(UNTIL_SQL, values: values, now: conn.quote(@now)))
    JourneyStepJob.perform_async(journey.id) unless journey.status == "paused"
  end

  def hit?(step, events, person_key, until_event, entered_at)
    filters = step&.dig("until", "kind") == "event" ? step.dig("until", "event", "filters") : nil
    events.any? do |e|
      e.person_key == person_key && e.at > entered_at && e.keys.include?(until_event) && Journeys::Matcher.pass?(filters, e.properties)
    end
  end
end
