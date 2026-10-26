# People per step and branch per day; one upsert per batch of moves. Step "" holds the journey's own totals.
module Journeys::Tally
  UPSERT = <<~SQL.squish.freeze
    INSERT INTO journey_counts (journey_id, step_id, branch, day, people) VALUES %<values>s
    ON CONFLICT (journey_id, step_id, branch, day) DO UPDATE SET people = journey_counts.people + EXCLUDED.people
  SQL

  module_function

  # counts: { [step_id, branch] => n }; sorted, so two batches never lock the same rows in opposite orders.
  def add(journey_id, counts, at: Time.current)
    counts = counts.reject { |_, n| n.zero? }
    return if counts.empty?

    conn = ActiveRecord::Base.connection
    day = conn.quote(at.utc.to_date)
    values = counts.sort.map { |(step, branch), n| "(#{Integer(journey_id)}, #{conn.quote(step.to_s)}, #{conn.quote(branch)}, #{day}, #{Integer(n)})" }
    conn.execute(format(UPSERT, values: values.join(", ")))
  end
end
