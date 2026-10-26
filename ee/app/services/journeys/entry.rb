# Lets people into a journey: audience, re-entry and control groups are decided here, in one upsert.
class Journeys::Entry
  ENTERED = "journey_entered".freeze
  HELD = "journey_held".freeze
  PATH = "journey_path".freeze
  COLUMNS = "journey_id, person_key, visitor_id, step_id, due_at, until_event, until_hit, goal_hit, state, entered_at, left_at, left_reason, claimed_at".freeze
  RESET = "visitor_id = EXCLUDED.visitor_id, step_id = NULL, due_at = EXCLUDED.due_at, until_event = NULL, until_hit = false, " \
          "goal_hit = false, state = EXCLUDED.state, entered_at = EXCLUDED.entered_at, left_at = EXCLUDED.left_at, " \
          "left_reason = EXCLUDED.left_reason, claimed_at = NULL".freeze

  # A held person would only be held again, the same bucket deciding, and counted twice.
  LEFT_NOT_HELD = "journey_people.state = 'left' AND journey_people.left_reason IS DISTINCT FROM 'held'".freeze

  # people: [[visitor_id, person_key, entered_at?], ...]. With run, the first steps run at once, so "send now" is sent now.
  def self.call(journey, people, run: true, received_at: nil) = new(journey, received_at).call(people, run: run)

  def initialize(journey, received_at = nil)
    @journey = journey
    @project = journey.project
    @received_at = received_at
  end

  def call(people, run:)
    people = audience(people.uniq { |person| person[1] })
    return [] if people.empty?

    now = Time.current
    rows = upsert(people, now)
    record(rows, now)
    active = rows.select { |row| row["state"] == "active" }.pluck("id")
    Journeys::Stepper.new(@journey).run(ids: active) if run && active.any?
    rows
  end

  private

  def audience(people)
    spec = @journey.entry["audience_segment_id"] && @journey.segment_keys[@journey.entry["audience_segment_id"]]
    return people if spec.nil?

    inside = SegmentMembership.where(segment_key: spec["key"], visitor_id: people.map(&:first)).pluck(:visitor_id).to_set
    people.select { |visitor_id, _| inside.include?(visitor_id) }
  end

  # nil, or the control the person is kept in: the project's first, as in-app and push do.
  def held_scope(visitor_id)
    return "project" if project_control.positive? && Experiments::Bucket.of(@project.hashid, visitor_id) < project_control

    "campaign" if @journey.control_group.to_i.positive? && Experiments::Bucket.of(@journey.hashid, visitor_id) < @journey.control_group
  end

  def project_control = @project_control ||= InAppSetting.for(@project).control_group

  def upsert(people, now)
    conn = JourneyPerson.connection
    @held = {}
    @entered_at = people.to_h { |_, key, at| [key, at || now] }
    values = people.sort_by { |person| person[1] }.map do |visitor_id, key, at|
      scope = held_scope(visitor_id)
      @held[key] = scope if scope
      state, due, left, reason = scope ? ["left", nil, now, "held"] : ["active", now, nil, nil]
      "(#{[@journey.id, key, visitor_id, nil, due, nil, false, false, state, at || now, left, reason, nil].map { |v| conn.quote(v) }.join(', ')})"
    end
    sql = "INSERT INTO journey_people (#{COLUMNS}) VALUES #{values.join(', ')} #{on_conflict(conn, now)} RETURNING id, person_key, visitor_id, state"
    conn.exec_query(sql).to_a
  end

  # The unique row per person is the re-entry check: an update happens only when the rule lets them back in.
  def on_conflict(conn, now)
    case @journey.re_entry["mode"]
    # Received after the exit (server clock) and newer than the last entry (device clock): re-sends are refused.
    when "after_exit"
      since = @received_at ? conn.quote(@received_at) : "EXCLUDED.entered_at"
      "ON CONFLICT (journey_id, person_key) DO UPDATE SET #{RESET} WHERE #{LEFT_NOT_HELD} AND journey_people.left_at < #{since} " \
        "AND journey_people.entered_at < EXCLUDED.entered_at"
    when "after_days"
      cutoff = conn.quote(now - @journey.re_entry["days"].to_i.days)
      "ON CONFLICT (journey_id, person_key) DO UPDATE SET #{RESET} WHERE #{LEFT_NOT_HELD} AND journey_people.left_at <= #{cutoff}"
    else "ON CONFLICT (journey_id, person_key) DO NOTHING"
    end
  end

  def record(rows, now)
    return if rows.empty?

    devices = Visitor.where(id: rows.pluck("visitor_id")).pluck(:id, :device_id).to_h
    entered, held = rows.partition { |row| row["state"] == "active" }
    push(ENTERED, entered, devices) { {} }
    push(HELD, held, devices) { |row| { "scope" => @held[row["person_key"]] } }
    Journeys::Tally.add(@journey.id, { ["", "entered"] => entered.size, ["", "held"] => held.size }, at: now)
  end

  # Exposure is stamped with each person's entry time, so a goal right after the triggering event counts.
  def push(name, rows, devices)
    events = rows.filter_map do |row|
      device = devices[row["visitor_id"]]
      device && [device, { "campaign_id" => @journey.hashid }.merge(yield(row)), @entered_at[row["person_key"]]]
    end
    events.group_by(&:last).each { |at, list| Experiments::Held.push(@project.id, name, list.map { |device, props, _| [device, props] }, at: at) }
  end
end
