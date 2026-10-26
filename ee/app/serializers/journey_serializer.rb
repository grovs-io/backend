class JourneySerializer < BaseSerializer
  attributes :name, :status, :revision, :lock_version, :re_entry, :goals, :control_group, :start_at, :end_at, :first_step,
             :launched_at, :ended_at, :created_at, :updated_at
  ENTRY = { "type" => nil, "event" => nil, "segment_id" => nil, "audience_segment_id" => nil }.freeze

  # stats: { journey_id => { "active" => n, "entered" => n } }, read for the whole list page at once.
  def build(slim: false, stats: nil)
    h = super()
    h["id"] = record.hashid
    h["entry"] = ENTRY.merge(record.entry)
    h["steps"] = record.steps unless slim
    h["stats"] = stats.fetch(record.id, { "active" => 0, "entered" => 0 }) if stats
    h
  end

  def self.stats(journeys)
    ids = journeys.map(&:id)
    active = JourneyPerson.inside.where(journey_id: ids).group(:journey_id).count
    sql = "SELECT journey_id, SUM(people) FROM journey_counts WHERE journey_id IN (?) AND step_id = '' AND branch = 'entered' GROUP BY journey_id"
    entered = JourneyPerson.connection.select_rows(JourneyPerson.sanitize_sql([sql, ids.presence || [0]])).to_h { |id, n| [id, n.to_i] }
    ids.index_with { |id| { "active" => active.fetch(id, 0), "entered" => entered.fetch(id, 0) } }
  end
end
