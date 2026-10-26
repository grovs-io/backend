# Claims due people of one journey, walks each to their next stop, and commits channels, moves and counts together.
class Journeys::Stepper
  BATCH = 1_000
  CHAIN = 20
  RUNS = %w[live ended].freeze
  CLAIM_SQL = <<~SQL.squish.freeze
    UPDATE journey_people SET state = 'claimed', claimed_at = :now
    WHERE id IN (
      SELECT id FROM journey_people
      WHERE journey_id = :journey AND state = 'active' AND due_at <= :now %<only>s
      ORDER BY due_at LIMIT :limit FOR UPDATE SKIP LOCKED
    )
    RETURNING id, person_key, visitor_id, step_id, until_hit, entered_at, claimed_at
  SQL
  MOVE_SQL = <<~SQL.squish.freeze
    UPDATE journey_people AS j
    SET step_id = v.step_id, due_at = v.due_at, until_event = CASE WHEN v.keep THEN j.until_event ELSE v.until_event END,
        until_hit = v.keep AND j.until_hit, state = v.state,
        left_at = v.left_at, left_reason = v.left_reason, claimed_at = NULL
    FROM (VALUES %<values>s) AS v(id, step_id, due_at, until_event, state, left_at, left_reason, keep)
    WHERE j.id = v.id AND j.state = 'claimed'
  SQL

  Plan = Struct.new(:row, :step_id, :due_at, :until_event, :state, :reason, :ops, :counts, :run, :keep, :paths, keyword_init: true)

  def initialize(journey, now: Time.current)
    @journey = journey
    @steps = journey.steps
    @now = now
    @written = Hash.new { |h, k| h[k] = {} }
  end

  # Rows claimed, or :busy when a split could not ask ClickHouse; a paused journey moves nobody.
  def run(ids: nil)
    return 0 unless RUNS.include?(@journey.status) && Journeys.running?

    rows = claim(ids)
    return 0 if rows.empty?

    commit(walk(rows))
    rows.size
  rescue Segments::Busy, Clickhouse::Unavailable => e
    Rails.logger.warn("journeys.step_deferred journey=#{@journey.id} #{e.class}")
    release(rows)
    :busy
  rescue StandardError
    release(rows)
    raise
  end

  private

  def claim(ids)
    return [] if ids&.empty?

    only = ids ? "AND id IN (#{ids.map { |id| Integer(id) }.join(',')})" : ""
    sql = JourneyPerson.sanitize_sql([format(CLAIM_SQL, only: only), { now: @now, journey: @journey.id, limit: BATCH }])
    JourneyPerson.connection.exec_query(sql).to_a.tap { |rows| @claimed_at = rows.first&.dig("claimed_at") }
  end

  # Only rows still under this claim: the tick may have handed a stale one to another worker.
  def mine(rows) = JourneyPerson.where(id: rows.pluck("id"), state: "claimed", claimed_at: @claimed_at)

  # Back to due, unchanged, for the next tick.
  def release(rows)
    return if rows.blank?

    mine(rows).update_all(state: "active", claimed_at: nil)
  end

  def walk(rows)
    plans = rows.map { |row| start(row) }
    CHAIN.times do
      waiting = plans.select(&:run)
      break if waiting.empty?

      waiting.group_by(&:step_id).each do |step_id, group|
        step = @steps[step_id]
        branches = step["type"] == "split" ? forks.decide(step, group.map { |p| p.row["visitor_id"] }) : {}
        group.each { |plan| advance(plan, step, branches[plan.row["visitor_id"]] || "next") }
      end
    end
    # The only chain cap: whoever still runs after CHAIN instant steps waits, due now, for the next pass.
    plans.select(&:run).each { |plan| stop(plan, @now, nil) }
    plans
  end

  def forks = @forks ||= Journeys::Forks.new(@journey, @written)

  def start(row)
    plan = Plan.new(row: row, step_id: row["step_id"], state: "active", ops: [], counts: Hash.new(0), run: false, keep: false, paths: [])
    step = @steps[row["step_id"]]
    hide(plan, step) if step && step["type"] == "in_app"
    return leave(plan, "expired") if row["entered_at"] <= Journey::PERSON_DAYS.days.ago
    return arrive(plan, @journey.first_step) if row["step_id"].nil?
    return leave(plan, "finished") if step.nil?

    case step["type"]
    when "wait"
      branch = step["until"] && !row["until_hit"] ? "timeout_next" : "next"
      plan.counts[[step["id"], branch]] += 1
      arrive(plan, step[branch])
    when "in_app"
      plan.counts[[step["id"], "next"]] += 1
      arrive(plan, step["next"])
    else
      plan.run = true
      plan
    end
  end

  def arrive(plan, target)
    return leave(plan, "finished") if target.nil?

    step = @steps[target]
    plan.counts[[target, "reached"]] += 1
    plan.step_id = target
    plan.run = false
    case step["type"]
    when "wait"
      stop(plan, [@now + step["minutes"].minutes, last_day(plan)].min, Journeys::Watchlist.until_key(@journey, step))
    when "in_app"
      plan.ops << [:show, step, plan.row]
      stop(plan, [@now + step["valid_days"].days, last_day(plan)].min, Journeys::Watchlist.until_key(@journey, step))
    else
      plan.run = true
    end
    plan
  end

  def advance(plan, step, branch)
    plan.ops << [step["type"] == "push" ? :push : :attribute, step, plan.row] unless step["type"] == "split"
    @written[plan.row["visitor_id"]][step["key"]] = step["value"] if step["type"] == "set_attribute"
    plan.paths << [step["id"], branch] if step["type"] == "split" && step["mode"] == "percent"
    plan.counts[[step["id"], branch]] += 1
    arrive(plan, Journey.pointers(step)[branch])
  end

  # Nobody waits past their 90 days; at that moment they leave as expired.
  def last_day(plan) = plan.row["entered_at"] + Journey::PERSON_DAYS.days

  def stop(plan, due_at, until_event)
    plan.due_at = due_at
    plan.until_event = until_event
    plan.run = false
  end

  def hide(plan, step) = plan.ops << [:hide, step, plan.row]

  def leave(plan, reason)
    plan.state = "left"
    plan.reason = reason
    plan.run = false
    plan.due_at = nil
    plan.until_event = nil
    plan.counts[["", reason]] += 1
    plan
  end

  # Goals and waited-for events that arrived during the claim are read again under the row lock before anything moves.
  def commit(plans)
    channels = Journeys::Channels.new(@journey, @now)
    final = ActiveRecord::Base.transaction do
      flags = mine(plans.map(&:row)).order(:id).lock.pluck(:id, :until_hit, :goal_hit).to_h { |id, hit, goal| [id, [hit, goal]] }
      final = plans.filter_map { |plan| recheck(plan, flags[plan.row["id"]]) }
      channels.apply(final.flat_map(&:ops))
      final.each { |plan| after_send(plan, channels.sends[plan.row["id"]]) }
      move(final)
      Journeys::Tally.add(@journey.id, final.map(&:counts).reduce(Hash.new(0)) { |all, c| all.merge(c) { |_, a, b| a + b } }, at: @now)
      final
    end
    channels.announce
    record_paths(final)
  end

  # Committed moves only: a person pulled out at recheck never took the path.
  def record_paths(plans)
    taken = plans.flat_map { |plan| plan.paths.uniq.map { |step_id, branch| [plan.row["visitor_id"], step_id, branch] } }
    return if taken.empty?

    devices = Visitor.where(id: taken.map(&:first).uniq).pluck(:id, :device_id).to_h
    rows = taken.filter_map do |visitor_id, step_id, branch|
      devices[visitor_id] && [devices[visitor_id], { "campaign_id" => @journey.hashid, "step_id" => step_id, "path" => branch }]
    end
    Experiments::Held.push(@journey.project_id, Journeys::Entry::PATH, rows, at: @now)
  rescue StandardError => e # the moves are committed; a lost record only thins the A/B report
    Grovs::Metrics.increment("journeys.path_record_failed", tags: { error: e.class.name })
    Rails.logger.warn("journeys.path_record_failed #{e.class}: #{e.message}")
  end

  def recheck(plan, flags)
    return nil if flags.nil?

    hit, goal = flags
    if goal
      step = @steps[plan.row["step_id"]]
      fresh = Plan.new(row: plan.row, step_id: plan.row["step_id"], ops: [], counts: Hash.new(0), keep: false, paths: [])
      hide(fresh, step) if step && step["type"] == "in_app"
      return leave(fresh, "goal")
    end
    return plan if hit == plan.row["until_hit"]

    Plan.new(row: plan.row, step_id: plan.row["step_id"], due_at: @now, state: "active", ops: [], counts: {}, keep: true, paths: [])
  end

  # A wait after a push held for quiet hours counts from when the push goes out.
  def after_send(plan, sent_at)
    return unless sent_at && sent_at > @now && plan.state == "active" && @steps[plan.step_id]&.dig("type") == "wait"

    plan.due_at = [plan.due_at + (sent_at - @now), last_day(plan)].min
  end

  def move(plans)
    return if plans.empty?

    conn = JourneyPerson.connection
    values = plans.map do |p|
      left = p.state == "left" ? @now : nil
      "(#{Integer(p.row['id'])}::bigint, #{conn.quote(p.step_id)}::varchar, #{conn.quote(p.due_at)}::timestamp, #{conn.quote(p.until_event)}::varchar, " \
        "#{conn.quote(p.state)}::varchar, #{conn.quote(left)}::timestamp, #{conn.quote(p.reason)}::varchar, #{p.keep})"
    end
    conn.execute(format(MOVE_SQL, values: values.join(", ")))
  end
end
