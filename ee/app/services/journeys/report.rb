# People per step and branch from journey_counts, who is inside now, and the goal and A/B split cards from the experiments report.
class Journeys::Report
  LEFT = %w[finished goal expired].freeze
  LIVE_CACHE = 60.seconds

  def self.call(journey, from:, to:) = new(journey, from, to).call

  def initialize(journey, from, to)
    @journey = journey
    @from = Date.iso8601(from.to_s)
    @to = Date.iso8601(to.to_s)
    raise InAppReport::Invalid, "the range must be 1 to #{InAppReport::MAX_DAYS} days" unless (@to - @from).to_i.between?(0, InAppReport::MAX_DAYS - 1)
  rescue Date::Error
    raise InAppReport::Invalid, "from and to must be dates such as 2026-10-01"
  end

  def call
    counts = JourneyPerson.connection.select_rows(JourneyPerson.sanitize_sql([<<~SQL.squish, @journey.id, @from, @to]))
      SELECT step_id, branch, SUM(people) FROM journey_counts WHERE journey_id = ? AND day BETWEEN ? AND ? GROUP BY step_id, branch
    SQL
    counts = counts.to_h { |step, branch, n| [[step, branch], n.to_i] }
    now = live
    { "entered" => counts.fetch(["", "entered"], 0), "held" => counts.fetch(["", "held"], 0), "active" => now.values.sum,
      "left" => LEFT.index_with { |reason| counts.fetch(["", reason], 0) },
      "steps" => @journey.steps.to_h { |id, step| [id, step_counts(id, step, counts, now)] },
      "goal" => @journey.experiment? ? Experiments::Report.journey(@journey, from: @from.iso8601, to: @to.iso8601) : nil,
      "paths" => @journey.steps.select { |_, step| step["type"] == "split" && step["mode"] == "percent" }
                         .to_h { |id, _| [id, Experiments::Report.journey_path(@journey, id, from: @from.iso8601, to: @to.iso8601)] } }
  end

  private

  # People inside by step (nil: just entered), read at most once a minute.
  def live
    Rails.cache.fetch("journeys:live:#{@journey.id}", expires_in: LIVE_CACHE) { JourneyPerson.inside.where(journey_id: @journey.id).group(:step_id).count }
  end

  def step_counts(id, step, counts, now)
    { "reached" => counts.fetch([id, "reached"], 0), "now" => now.fetch(id, 0),
      "branches" => Journey.pointers(step).keys.index_with { |branch| counts.fetch([id, branch], 0) } }
  end
end
